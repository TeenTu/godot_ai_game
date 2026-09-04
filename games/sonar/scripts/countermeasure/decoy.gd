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

var decoy_type: String = DecoyProgram.TYPE_MOBILE
var activation_delay_s: float = 2.0
var lifetime_s: float = 120.0
var launched_from_id: String = ""

var age_s: float = 0.0
var activated: bool = false
var expired: bool = false

var signature_ac: RefCounted = null  # 诱饵声学画像（adapter 经 contact_acs 读取）
var _jitter_rng: RandomNumberGenerator = null
var _base_tonals: Array = []  # 出厂谱线（JAMMER 抖动的基准）


## 部署：从发射平台位置/深度出发，按程序设定航向/速度/深度带。
func deploy(
	prog: DecoyProgram, from: TruthEntity, initial_depth_m: float, commanded_depth_m: float
) -> void:
	id = "DCY-%s" % from.id
	launched_from_id = from.id
	decoy_type = prog.decoy_type
	activation_delay_s = prog.activation_delay_s
	lifetime_s = prog.lifetime_s
	side = from.side
	platform_type = "decoy"  # 仅 Truth 侧标注；绝不进入玩法链（adapter 只采样）
	position_east_m = from.position_east_m
	position_north_m = from.position_north_m
	depth_m = initial_depth_m
	commanded_depth_m = commanded_depth_m
	max_vertical_speed_m_s = 2.0
	course_deg = prog.launch_bearing_deg
	commanded_course_deg = (
		prog.course_deg if prog.decoy_type == DecoyProgram.TYPE_MOBILE else prog.launch_bearing_deg
	)
	speed_kn = 0.0
	commanded_speed_kn = prog.speed_kn if prog.decoy_type == DecoyProgram.TYPE_MOBILE else 0.0
	turn_rate_deg_s = 4.0
	_motion_commanded = true


func bind_signature(ac: RefCounted) -> void:
	signature_ac = ac
	if ac != null and ac.get("tonal_lines") != null:
		_base_tonals = (ac.tonal_lines as Array).duplicate(true)


## 注入谱抖动 RNG（JAMMER 用；与世界 RNG 同源派生，§2.3 确定性）。
func bind_jitter_rng(r: RandomNumberGenerator) -> void:
	_jitter_rng = r


## 每步：寿命/激活推进 + 运动（TruthEntity.advance 同源限速率）+ JAMMER 谱抖动。
## 返回 true 表示本帧刚激活（供 World 记 DECOY_ACTIVATION 事件，§9.1）。
func step(dt: float) -> bool:
	age_s += dt
	if expired:
		return false
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


## JAMMER：每次采样间隔对假峰频率做小幅随机游走 → 航迹谱一致性被稀释（§8.2）。
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
