class_name Decoy
extends TruthEntity

## Decoy（S1-07 §8.2/§8.4，Commit 8）：玩家/敌方皆可发射的假声源。继承
## TruthEntity 同一 AcousticContact 接口（id/位置/深度/航速 + AcousticProfile），
## 进 TorpedoSensorAdapter 参与同一条声学采样链——Seeker 只见 SeekerReturn 的
## 谱特征与运动一致性，绝不读取 is_decoy/类型（CM-04：删除任何 force_lock 逻辑）。
##
## 类型效果全部来自声学与运动参数竞争（§8.4）：
##   MOBILE_DECOY：模拟目标运动与噪声（稳定谱线 + 真实机动）。
##   JAMMER_CONFUSER：宽带高噪抬噪声底 + 运行时抖动的假峰谱线（稀释/混淆，
##     不稳定谱 → 航迹 classification_match 低 → score 竞争中被稀释）。
##
## P1-C 运动约定（DC-01..DC-03）：
##   - 运动**只**由自身 course/speed/commanded_depth 积分（TruthEntity.advance），
##     本艇转弯/提速/换层与地图平移缩放都不改变诱饵世界坐标；
##   - 出管方向只有一个来源：program 的投放方向（course<0 时）或显式高级巡航
##     航向（DC-02）；发射后程序已快照，本艇后续命令不再作用于诱饵；
##   - 出管瞬间**一次**继承平台动量作为初速度（不持续绑定平台），随后按自身
##     加速度限制收敛到分离速度/巡航速度（DC-03）；
##   - 分离阶段（separation_duration_s）产生真实有限位移，之后降到 speed_kn。

## REQ-CM-01：全局唯一序号，存于主循环 meta（跨 World 实例单调递增）。不用
## static var——Godot 4.5 Windows 退出阶段 static 清理会随机段错误（曾是
## decoy_test 关机 crash 的根因）；主循环 meta 随 SceneTree 释放，无此问题。
const _SERIAL_META := "_decoy_serial_next"
## DC-03：出管后速度收敛率（kn/s）。只限制诱饵自身速度变化，不影响平台。
const DEFAULT_DECEL_KN_S: float = 1.0
## DC-04：诱饵状态（STANDBY 出管未激活 / ACTIVE / EXPIRED），单一口径。
const STATE_STANDBY := "STANDBY"
const STATE_ACTIVE := "ACTIVE"
const STATE_EXPIRED := "EXPIRED"

var decoy_type: String = DecoyProgram.TYPE_MOBILE
var activation_delay_s: float = 2.0
var lifetime_s: float = 120.0
var launched_from_id: String = ""

var age_s: float = 0.0
var activated: bool = false
var expired: bool = false

## DC-01/DC-04：出管方向与分离阶段留档（地图方向显示、调试记录与测试断言用）。
var launch_bearing_deg: float = 0.0
var separation_duration_s: float = 0.0
var separation_speed_kn: float = 0.0
var cruise_speed_kn: float = 0.0
var initial_speed_kn: float = 0.0
## DC-02：是否为高级独立巡航方向（与投放方向不同）。
var advanced_course: bool = false

var signature_ac: RefCounted = null  # 诱饵声学画像（adapter 经 contact_acs 读取）
var _jitter_rng: RandomNumberGenerator = null
var _base_tonals: Array = []  # 出厂谱线（JAMMER 抖动的基准）
var _sep_done: bool = false


## 全局自增序号（REQ-CM-01）。经 Engine.get_main_loop() meta 持久化；无主循环
## （纯脚本静态上下文）时退化为 0，调用方仍可显式指定 id_str。
func _next_serial() -> int:
	var ml := Engine.get_main_loop()
	if ml == null:
		return 0
	var n: int = int(ml.get_meta(_SERIAL_META, 0)) + 1
	ml.set_meta(_SERIAL_META, n)
	return n


## 部署：从发射平台当前实际位置/深度出发（REQ-CM-02：不瞬移到层带 hold），
## 按程序设定航向/速度/命令深度（限速率爬降由 TruthEntity.advance 执行）。
func deploy(
	prog: DecoyProgram,
	from: TruthEntity,
	initial_depth_m: float,
	z_cmd_m: float,
	id_str: String = ""
) -> void:
	# REQ-CM-01：唯一 ID——外部未指定时用全局序号；旧 "DCY-%s" % from.id 会
	# 让同平台第二枚覆盖第一枚的画像（_acoustic_scene_acs 按 ID 建表）。
	id = id_str if id_str != "" else "DCY-%d" % _next_serial()
	launched_from_id = from.id
	decoy_type = prog.decoy_type
	activation_delay_s = prog.activation_delay_s
	lifetime_s = prog.lifetime_s
	side = from.side
	platform_type = "decoy"  # 仅 Truth 侧标注；绝不进入玩法链（adapter 只采样）
	position_east_m = from.position_east_m
	position_north_m = from.position_north_m
	depth_m = initial_depth_m
	commanded_depth_m = z_cmd_m  # REQ-CM-02：修复参数遮蔽（原句等于自赋值）
	max_vertical_speed_m_s = 2.0
	# DC-02：方向只有一个来源。出管瞬间朝投放方向，随后（如有）转到程序的
	# 出管航向——未设置独立巡航方向时二者相同，不存在后台默认航向。
	launch_bearing_deg = NavUtils.wrap360(prog.launch_bearing_deg)
	advanced_course = prog.is_advanced_course()
	course_deg = launch_bearing_deg
	commanded_course_deg = prog.resolved_course_deg()
	# DC-03：分离阶段与巡航速度；出管动量只在此处取一次平台实际航速。
	separation_duration_s = prog.separation_duration_s
	separation_speed_kn = prog.resolved_separation_speed_kn()
	cruise_speed_kn = prog.speed_kn
	initial_speed_kn = from.speed_kn
	speed_kn = initial_speed_kn
	commanded_speed_kn = separation_speed_kn if prog.has_separation_phase() else cruise_speed_kn
	turn_rate_deg_s = 4.0
	acceleration_kn_s = DEFAULT_DECEL_KN_S
	_motion_commanded = true


## DC-04：对外状态（地图 DTO 与面板共用同一口径）。
func state() -> String:
	if expired:
		return STATE_EXPIRED
	return STATE_ACTIVE if activated else STATE_STANDBY


func bind_signature(ac: RefCounted) -> void:
	signature_ac = ac
	if ac != null and ac.get("tonal_lines") != null:
		_base_tonals = (ac.tonal_lines as Array).duplicate(true)


## 注入谱抖动 RNG（JAMMER 用；与世界 RNG 同源派生，§2.3 确定性）。
func bind_jitter_rng(r: RandomNumberGenerator) -> void:
	_jitter_rng = r


## 每步：寿命/激活推进 + 运动（TruthEntity.advance 同源限速率）+ JAMMER 谱抖动。
## 返回 true 表示本帧刚激活（供 World 记 DECOY_ACTIVATION 事件，§9.1）。
## DC-03：声学激活延时**不**阻止出管后的运动——advance 在激活判定之前执行；
## 分离阶段在 advance 之前切换速度命令，保证分离位移真实存在。
func step(dt: float) -> bool:
	age_s += dt
	if expired:
		return false
	_step_separation()
	advance(dt)
	if not activated and age_s >= activation_delay_s:
		activated = true
		return true
	if age_s >= lifetime_s:
		expired = true
		return false
	if activated and decoy_type == DecoyProgram.TYPE_JAMMER and _jitter_rng != null:
		_jitter_tonals()
	return false


## 分离阶段结束 → 把速度命令降到巡航/漂浮速度（只改命令，实际按加速度收敛）。
func _step_separation() -> void:
	if _sep_done or age_s < separation_duration_s:
		return
	_sep_done = true
	if absf(commanded_speed_kn - cruise_speed_kn) > 0.001:
		commanded_speed_kn = cruise_speed_kn


## JAMMER：每次声学采样推进对假峰频率做小幅随机游走 → 航迹谱一致性被稀释
## （§8.2）。抖动由固定 dt 的仿真 tick 驱动（不随显示帧率变化，§2.3）。
func _jitter_tonals() -> void:
	var ac: RefCounted = signature_ac
	if ac == null or _base_tonals.is_empty():
		return
	var lines: Array = []
	for tl in _base_tonals:
		var f: float = float(tl.get("freq_hz", 0.0))
		var drift: float = _jitter_rng.randf_range(-60.0, 60.0)
		lines.append({"freq_hz": maxf(f + drift, 10.0), "level_db": float(tl.get("level_db", 0.0))})
	ac.set("tonal_lines", lines)
