class_name Torpedo
extends RefCounted
## torpedo.gd — 鱼雷实体（S1-07 正交状态重构版 + REQ 制导重构批）。
##
## 信息链纪律（S1-07 §2.1/§2.2）：本类不接收 TruthEntity targets——step() 的
## ctx 只含服务接口（TorpedoContext），结构上禁止 Guidance 读目标 Truth；
## 发射参数来自 WeaponProgram 快照；Seeker/Guidance 只消费净化 SeekerReturn
## （无 target_id / 无被动真实 range），主动 Ping 回波按 tau=2R/c 延迟到达。
##
## 线导（§5.4/§5.5）：wire_link 持有线长/放线/断裂/切断状态，命令门只认
## CONNECTED；导线 BROKEN/CUT 后拒绝新命令并执行发射前保存的 fallback
## program。命令全部记 CommandLog，绝不改写发射程序快照。
##
## 正交状态模型（§3，REQ-DECISION-02）：任务/Seeker/主动发射机/制导权限/
## 导线/深度/引信各自独立状态机（REQ 批再加四轴呈现：Seeker Phase /
## Guidance Authority / Steering Source / Mission，进 ATTACK 需同持有效
## 航迹 + 权限 + 制导实际接管）。

signal event_occurred(torpedo_id: String, kind: String, detail: Dictionary)

enum MissionState { STOWED, LAUNCHING, WIRE_RUN, SEARCH, ATTACK, TERMINAL, DEAD }
enum SeekerState {
	PASSIVE_LISTEN, ACTIVE_SEARCH, COMBINED_SEARCH, ACQUIRING, TRACKING, COAST, LOST, REACQUIRE
}
enum ActiveTxState { OFF, WAITING_TRIGGER, PINGING, COOLDOWN }
enum GuidanceAuthority { WIRE_ONLY, ASSISTED, AUTONOMOUS }
## REQ-04：制导输出两态——直接转率命令（PN 拦截）或期望航向（重搜扫掠/COAST
## 预测方位）。_apply_steering 按优先级消费，全部受 omega_max 限幅。
enum GuidanceMode { NONE, COURSE, RATE }
enum DepthState { HOLDING_UPPER, DIVING, HOLDING_LOWER, CLIMBING }
enum FuzeState { SAFE, ARMED, TRIGGERED, INERT }

# 速度/续航/运行噪声源级由 TorpedoAcousticProfile 承载（Commit 5，§6.2：
# 速度模式同时改变速度/噪声/续航，绝不单改地图速度）。
const RUNNING_NOISE_CADENCE_S: float = 1.0
const DEFAULT_TURN_RATE_DEG_S: float = 6.0
const LAUNCH_TRANSITION_S: float = 1.0
# Commit 6（§6.3）：被动采样周期（固定间隔，不必每帧扫全部声源，§15.1）。
const PASSIVE_SAMPLE_INTERVAL_S: float = 1.0
# 深度带占位 hold 深度（Commit 2 起由 DepthLayerModel 配置覆盖）。
const DEFAULT_UPPER_HOLD_DEPTH_M: float = 70.0
const DEFAULT_LOWER_HOLD_DEPTH_M: float = 180.0
# 主动发射机节拍由 TorpedoAcousticProfile.active_pulse_duration_s /
# active_ping_interval_s 提供（Commit 5 起）；PingSession/回波 TOF 为 Commit 6 链。

## 集中任务状态迁移（P0-02.8）：非法转换拒绝并发出结构化事件；合法转换
## 统一在此发射迁移事件。DEAD 由 _die 处理（终态，不经本表）。
const _MISSION_TRANSITIONS := {
	MissionState.LAUNCHING: [MissionState.WIRE_RUN],
	MissionState.WIRE_RUN: [MissionState.SEARCH, MissionState.ATTACK, MissionState.TERMINAL],
	MissionState.SEARCH: [MissionState.ATTACK],
	MissionState.ATTACK: [MissionState.TERMINAL, MissionState.SEARCH],
	MissionState.TERMINAL: [MissionState.SEARCH],
}

var torpedo_id: String = ""
var program: WeaponProgram = null

var mission_state: int = MissionState.STOWED
var seeker_state: int = SeekerState.PASSIVE_LISTEN
var active_tx_state: int = ActiveTxState.OFF
var guidance_authority: int = GuidanceAuthority.WIRE_ONLY
var depth_state: int = DepthState.HOLDING_UPPER
var fuze_state: int = FuzeState.SAFE

# S1-07 §5.4（Commit 4）：导线链路唯一状态源（CONNECTED/BROKEN/CUT + 放线长）。
var wire_link: WireLink = WireLink.new()

var pos_east_m: float = 0.0
var pos_north_m: float = 0.0
var course_deg: float = 0.0
# Commit 5：声学画像（速度/续航/自噪声/主动参数）与当前速度模式。
var acoustic_profile: TorpedoAcousticProfile = TorpedoAcousticProfile.make_default()
var speed_mode: int = WeaponProgram.SpeedMode.CRUISE
var speed_kn: float = 40.0
var fuel_left_s: float = 1200.0
var traveled_m: float = 0.0

# 深度（S1-07A 双层伪三维，Commit 2 接连续升降）：命令与实际分离，禁止瞬移
# 换层。commanded_depth_m < 0 = 无垂向命令（保持当前深度）。
var actual_depth_m: float = 50.0
var commanded_depth_m: float = -1.0
var commanded_depth_band: String = ""  # "" = 无垂向层命令
var max_vertical_speed_m_s: float = 2.0
var min_depth_m: float = 0.0
var max_depth_m: float = 400.0
var max_turn_rate_deg_s: float = DEFAULT_TURN_RATE_DEG_S
## REQ-07：横向过载限（m/s²）。omega_max = min(mech_limit, lat_accel/speed)。
## 默认 4.5：40kn → 12.5°/s > 机械 6°/s（机械限仍绑定）。禁止仅靠提高
## 转率掩盖制导错误。
var max_lateral_accel_m_s2: float = 4.5
## REQ-07/验收14：转向诊断——命令/实际转率、饱和状态。
var turn_saturated: bool = false
var commanded_turn_rate_deg_s: float = 0.0
var actual_turn_rate_deg_s: float = 0.0
## 验收14：脱靶原因（死亡时确定；七种枚举之一或空=命中/未终局）。
var miss_reason: String = ""

var trail: Array = []  # [{e, n, t}] 供海图画轨迹（自身状态，非 Truth）
# Commit 4 命令日志（S1-07 §5.1：线控命令另记 CommandLog，绝不悄悄改写原始
# 发射程序）。_fallback_active：导线断/切后进入 fallback 执行态。
var command_log: Array = []  # [{t, cmd, detail}] 已接受线控命令（封顶 256）
# P1-01：最近一次 UI 命令被拒的具体原因（WIRE CUT / LAUNCHING /
# NO CANDIDATE / INVALID STATE ...），供武器卡显示；命令成功时清空。
var last_cmd_reject_reason: String = ""
# Commit 6（§6.5）：净化后的 SeekerReturn 记录（被动周期采样 + 主动回波到达）。
# 只存 SeekerReturn 对象/其 to_dict——不含 target_id / Truth（可直供 UI/日志）。
var seeker_returns: Array = []
# Commit 6（REQ-DECISION-01）：被动接收机默认 ON；发射并安全出管后开始监听。
var passive_receiver_on: bool = true
# REQ-07/验收14：本次运行是否曾取得制导权限并实际操舵（NO_GUIDANCE_AUTHORITY
# 判定依据）；是否曾发生转率饱和（TURN_RATE_SATURATED 判定依据）。
var _ever_guidance_engaged: bool = false
var _ever_turn_saturated: bool = false
var _cmd_course_deg: float = -1.0  # <0 = 无航向命令（保持当前航向）
var _launch_t: float = 0.0
var _sim_time: float = 0.0
# P2-01：搜索扫掠相位连续初始化——进入 SEARCH 时记录进入时刻并把扫掠
# 相位偏置到当前航向（不跳到全局 sim_time 相位）。离开 SEARCH 失效。
var _search_sweep_active: bool = false
var _search_enter_t: float = 0.0
var _search_phase_offset_s: float = 0.0
var _tx_cycle_s: float = 0.0
var _tx_manual_armed: bool = false
var _depth_model: RefCounted = null  # DepthLayerModel（Commit 2 由 ctx 注入）
var _fallback_active: bool = false
# P0-09：主动链 ping 序号与在途 ping 台账（ping_id -> {emit_t, heard}，串联
# TX_PING → ECHO / LISTEN_COMPLETE_NO_RETURN）。
var _ping_seq: int = 0
## 上一步实际执行的转向率（自身运动学；喂给 seeker 做惯性视线率补偿）。
var _last_turn_rate_deg_s: float = 0.0
var _active_pings_outstanding: Dictionary = {}

# Commit 5：ctx 注入的声学事件总线（null=无总线）；_emitter 收敛 bus 写入。
var _emission_bus: AcousticEmissionBus = null
var _emitter: TorpedoEmitter = TorpedoEmitter.new()
var _noise_timer_s: float = 0.0
# Commit 6：ctx 注入的传感器采样适配器（仿真内核唯一可触 Truth 的武器侧对象，
# 输出净化 SeekerReturn）与被动采样计时。
var _sensor_adapter: TorpedoSensorAdapter = null
var _passive_sample_timer_s: float = 0.0
# Commit 7（§7）：Seeker 航迹/相位 + 制导。只消费净化 SeekerReturn，绝不接触
# Truth（WIRE_ONLY 恒不接管操舵，§7.7）。
var _seeker: TorpedoSeeker = null
var _assist_track_id: int = -1  # ASSISTED：玩家 ACCEPT_SEEKER_TRACK 接受的航迹
var _guidance_course_deg: float = -1.0
var _guidance_mode: int = GuidanceMode.NONE
var _guidance_turn_rate_cmd: float = 0.0


## REQ-07：omega_max = min(机械限，横向过载限/速度)；不靠提转率掩盖制导错误。
func _max_turn_rate() -> float:
	var mech: float = maxf(max_turn_rate_deg_s, 0.1)
	var v_ms: float = NavUtils.kn_to_ms(speed_kn)
	if max_lateral_accel_m_s2 > 0.0 and v_ms > 0.1:
		var lat: float = max_lateral_accel_m_s2 / v_ms * 180.0 / PI
		return minf(mech, lat)
	return mech


## 发射：装入 WeaponProgram 快照并进入 LAUNCHING。from_depth = 发射平台深度。
func launch(
	id: String, p: WeaponProgram, from_e: float, from_n: float, from_depth: float, sim_time: float
) -> void:
	torpedo_id = id
	program = p.snapshot() if p != null else null
	mission_state = MissionState.LAUNCHING
	pos_east_m = from_e
	pos_north_m = from_n
	actual_depth_m = from_depth
	commanded_depth_m = -1.0
	commanded_depth_band = ""
	seeker_state = SeekerState.PASSIVE_LISTEN  # REQ-DECISION-01：发射即被动监听
	active_tx_state = ActiveTxState.OFF  # REQ-DECISION-02：主动发射默认关闭
	# Commit 4：发射即建链（§5.4 发射后默认建立 WireLink）；wire_guidance_enabled
	# =false 的程序（如直接以断线态发射的极端配置）不建链、命令门关闭。
	_fallback_active = false
	command_log.clear()
	wire_link.reset()
	_noise_timer_s = 0.0
	# Commit 6：被动接收机默认 ON、采样记录清空（安全出管后开始监听）。
	passive_receiver_on = true
	seeker_returns.clear()
	_passive_sample_timer_s = 0.0
	_sensor_adapter = null
	# Commit 7：Seeker 航迹机（阈值 §7.3；捕获前为 SEARCH 相位 → PASSIVE_LISTEN）。
	_seeker = TorpedoSeeker.new()
	_seeker.configure(_seeker_cfg())
	_assist_track_id = -1
	_guidance_course_deg = -1.0
	# REQ-04/07/验收14：制导模式与转向诊断复位。
	_guidance_mode = GuidanceMode.NONE
	_guidance_turn_rate_cmd = 0.0
	turn_saturated = false
	commanded_turn_rate_deg_s = 0.0
	actual_turn_rate_deg_s = 0.0
	_ever_guidance_engaged = false
	_ever_turn_saturated = false
	miss_reason = ""
	if program != null:
		wire_link.enabled = program.wire_guidance_enabled
		guidance_authority = program.guidance_authority
		# Commit 5：速度/续航来自声学画像（§6.2 模式同时改速度与续航）。
		acoustic_profile = TorpedoAcousticProfile.make_default()
		_emitter.torpedo_id = id
		_emitter.profile = acoustic_profile
		var sm: String = WeaponProgram.speed_mode_name(program.speed_mode)
		speed_mode = program.speed_mode
		speed_kn = acoustic_profile.speed_kn(sm)
		fuel_left_s = acoustic_profile.endurance_s(sm)
		course_deg = NavUtils.wrap360(program.initial_course_deg)
		commanded_depth_band = program.initial_depth_band
		# P1-08 配套修复：发射初始化只写了层带标签、没写 hold 深度命令，
		# 鱼雷从此停在发射深度（_advance_vertical 因 commanded_depth_m=-1
		# 直接返回）——层带 hold 从未真正执行。补上垂直命令。
		commanded_depth_m = _hold_depth_for_band(program.initial_depth_band)
		if program.active_enable_mode == WeaponProgram.ActiveEnableMode.IMMEDIATE:
			active_tx_state = ActiveTxState.WAITING_TRIGGER
	depth_state = (
		_depth_state_for_band(program.initial_depth_band)
		if program != null
		else DepthState.HOLDING_UPPER
	)
	_launch_t = sim_time
	trail.append({"e": from_e, "n": from_n, "t": sim_time})
	event_occurred.emit(torpedo_id, "LAUNCH", {"course_deg": course_deg, "speed_kn": speed_kn})


func is_dead() -> bool:
	return mission_state == MissionState.DEAD


## 引信触发起爆（S1-07 §10，Commit 10）：由 World 引信引擎在几何判定通过后
## 调用（内核边界；本方法绝不接触 Truth）。SAFE 状态拒绝起爆（双保险）。
## detail 只含自身几何/状态（min_distance_m 等），绝不含 target_id。
func detonate(detail: Dictionary) -> bool:
	if mission_state == MissionState.DEAD or mission_state == MissionState.STOWED:
		return false
	if fuze_state != FuzeState.ARMED:
		return false
	fuze_state = FuzeState.TRIGGERED
	event_occurred.emit(torpedo_id, "DETONATION", detail)
	_die("DETONATED", detail)
	return true


## ---- 状态可读名（UI/事件用） ----
func mission_state_name() -> String:
	return _enum_name(MissionState.keys(), mission_state, "STOWED")


func seeker_state_name() -> String:
	return _enum_name(SeekerState.keys(), seeker_state, "PASSIVE_LISTEN")


func active_tx_state_name() -> String:
	return _enum_name(ActiveTxState.keys(), active_tx_state, "OFF")


func guidance_authority_name() -> String:
	return _enum_name(GuidanceAuthority.keys(), guidance_authority, "WIRE_ONLY")


func wire_state_name() -> String:
	return wire_link.state_name()


## 剩余可放线长（UI/In-water console 用；§11.2 wire CONNECTED/BROKEN/CUT +
## 剩余线长）。
func wire_remaining_m() -> float:
	return maxf(wire_link.max_length_m - wire_link.paid_out_m, 0.0)


func fuze_state_name() -> String:
	return _enum_name(FuzeState.keys(), fuze_state, "SAFE")


func state_name() -> String:
	return mission_state_name()


static func _enum_name(keys: Array, v: int, fallback: String) -> String:
	if v >= 0 and v < keys.size():
		return str(keys[v])
	return fallback


## ---- 线控命令通道（S1-07 §5.4 WireLink 语义，Commit 4）----
## 命令只改 commanded_*（_cmd_course_deg / commanded_depth_* / 状态），实际
## 航向/深度按速率限制响应（见 _advance_mission/_advance_vertical）。导线非
## CONNECTED（BROKEN/CUT/未建链）时拒绝新命令并返回 false（调用方 UI 给出
## 原因）。每个已接受命令记入 command_log（§5.1：绝不改写发射程序快照）。


func command_course(deg: float) -> bool:
	if not _cmd_gate():
		return false
	_cmd_course_deg = NavUtils.wrap360(deg)
	_log_command("SET_COURSE", {"course_deg": _cmd_course_deg})
	return true


## 速度模式命令（§6.2，Commit 5）：模式同时改速度与续航——切模式时按
## 新旧模式续航比等比折算剩余燃料（HIGH 更快烧完，QUIET 更省），并更新
## 运行噪声源级（由 acoustic_profile 派生，_emit_running_noise 消费）。
func command_speed_mode(mode: int) -> bool:
	if not _cmd_gate():
		return false
	if mode == speed_mode:
		return true
	var old_name: String = WeaponProgram.speed_mode_name(speed_mode)
	var new_name: String = WeaponProgram.speed_mode_name(mode)
	var old_end: float = acoustic_profile.endurance_s(old_name)
	var new_end: float = acoustic_profile.endurance_s(new_name)
	if old_end > 0.0:
		fuel_left_s = fuel_left_s * new_end / old_end
	speed_kn = acoustic_profile.speed_kn(new_name)
	speed_mode = mode
	_log_command("SET_SPEED_MODE", {"mode": new_name})
	return true


## 深度带命令：写 commanded_depth_band 并解析目标 hold 深度（Commit 2 起
## DepthLayerModel 注入后按模型配置；无模型用占位 hold 深度）。
func command_depth_band(band: String) -> bool:
	if not _cmd_gate():
		return false
	if not _command_depth_band_internal(band):
		return false
	_log_command("SET_DEPTH_BAND", {"band": band})
	return true


func set_active_tx(on: bool) -> bool:
	if not _cmd_gate():
		return false
	if on:
		if active_tx_state == ActiveTxState.OFF:
			_tx_manual_armed = true
			active_tx_state = ActiveTxState.WAITING_TRIGGER
			_log_command("ACTIVE_TX_ON", {})
			event_occurred.emit(torpedo_id, "ACTIVE_TX_ON", {})
		return true
	_tx_manual_armed = false
	active_tx_state = ActiveTxState.OFF
	_log_command("ACTIVE_TX_OFF", {})
	event_occurred.emit(torpedo_id, "ACTIVE_TX_OFF", {})
	return true


func authorize_autonomy() -> bool:
	if not _cmd_gate():
		return false
	guidance_authority = GuidanceAuthority.AUTONOMOUS
	# P0-02.4：无锁时进入 SEARCH 并从当前航向平滑进入程序扇区扫掠；
	# 有有效航迹（ACQUIRING/TRACKING/REACQUIRE）时交由 seeker 相位机接管。
	var has_lock: bool = (
		_seeker != null
		and (
			_seeker.phase
			in [
				TorpedoSeeker.Phase.ACQUIRING,
				TorpedoSeeker.Phase.TRACKING,
				TorpedoSeeker.Phase.REACQUIRE,
			]
		)
	)
	if mission_state == MissionState.WIRE_RUN and not has_lock:
		_try_mission(MissionState.SEARCH, "SEARCH", {"reason": "AUTONOMY_AUTHORIZED"})
	_log_command("AUTHORIZE_AUTONOMY", {})
	event_occurred.emit(torpedo_id, "AUTONOMY_AUTHORIZED", {"via": "wire"})
	return true


func return_to_wire_only() -> bool:
	if not _cmd_gate():
		return false
	guidance_authority = GuidanceAuthority.WIRE_ONLY
	_assist_track_id = -1
	_log_command("RETURN_TO_WIRE_ONLY", {})
	event_occurred.emit(torpedo_id, "RETURN_WIRE_ONLY", {})
	return true


## 玩家接受 SeekerTrack 候选（§5.4 ACCEPT_SEEKER_TRACK / §7.7 ASSISTED）：
## 导线连接时接受某条航迹作为制导输入；候选列表来自 seeker 的净化摘要
## （track_summaries），绝不暴露 Truth。断线后命令被拒。
func accept_seeker_track(track_id: int) -> bool:
	if not _cmd_gate():
		return false
	if _seeker == null or _seeker.track_by_id(track_id) == null:
		last_cmd_reject_reason = "NO CANDIDATE"
		return false
	_assist_track_id = track_id
	# P0-02.5：接受航迹成功 = 显式进入 ASSISTED；绝不出现“按钮成功但
	# authority 仍 WIRE_ONLY”的静默失效。
	guidance_authority = GuidanceAuthority.ASSISTED
	_log_command("ACCEPT_SEEKER_TRACK", {"track_id": track_id})
	event_occurred.emit(torpedo_id, "TRACK_ACCEPTED", {"track_id": track_id})
	return true


## 玩家主动切断（§5.4 CUT_WIRE）：切断后执行 fallback 并拒绝后续命令。
func cut_wire() -> bool:
	if not _cmd_gate():
		return false
	if not wire_link.cut():
		return false
	_log_command("CUT_WIRE", {})
	event_occurred.emit(torpedo_id, "WIRE_CUT", {})
	_enter_fallback()
	return true


## 命令门（§5.4）：导线 CONNECTED 且鱼雷在水（非 STOWED/LAUNCHING/DEAD）。
func _wire_accepts_command() -> bool:
	if not wire_link.accepts_commands():
		return false
	return (
		mission_state != MissionState.STOWED
		and mission_state != MissionState.LAUNCHING
		and mission_state != MissionState.DEAD
	)


func _cmd_gate() -> bool:
	if mission_state == MissionState.STOWED or mission_state == MissionState.DEAD:
		last_cmd_reject_reason = "INVALID STATE %s" % mission_state_name()
		return false
	if mission_state == MissionState.LAUNCHING:
		last_cmd_reject_reason = "LAUNCHING"
		return false
	if not wire_link.accepts_commands():
		last_cmd_reject_reason = "WIRE %s" % wire_state_name()
		return false
	last_cmd_reject_reason = ""
	return true


## Fallback 执行（§5.5，Commit 4）：导线 BROKEN/CUT 后——
##   1) 保持最后合法命令航向（有待执行航向命令继续执行；无则按 fallback
##      预设搜索中心渐进转向，受 max_turn_rate 约束，绝不瞬时变向）；
##   2) 前往预设 search depth band（内部深度命令，不走线控门）；
##   3) 进入 SEARCH（预设搜索扇区参数在 fallback 内，由后续 Seeker 链消费）；
##   4) 主动/自主按 fallback 预设条件触发（_advance_active_tx /
##      _advance_fallback_autonomy）。
func _enter_fallback() -> void:
	if program == null or program.fallback_program == null:
		return
	var fb := program.fallback_program
	_fallback_active = true
	_assist_track_id = -1  # 断线后 ASSISTED 接受失效（按 fallback 预设授权）
	if _cmd_course_deg < 0.0:
		_cmd_course_deg = NavUtils.wrap360(fb.search_center_deg)
	_command_depth_band_internal(fb.search_depth_band)
	if mission_state == MissionState.WIRE_RUN:
		_try_mission(MissionState.SEARCH, "SEARCH", {"reason": "FALLBACK"})
	_log_command(
		"FALLBACK",
		{"search_center_deg": fb.search_center_deg, "search_depth_band": fb.search_depth_band},
	)
	(
		event_occurred
		. emit(
			torpedo_id,
			"FALLBACK",
			{
				"search_center_deg": fb.search_center_deg,
				"search_depth_band": fb.search_depth_band,
				"authority_target": fb.guidance_authority,
			},
		)
	)


## Fallback 自主授权（§5.5）：断线后按 fallback 预设距离/时间把制导权限升到
## fb.guidance_authority（通常 AUTONOMOUS）。MANUAL/WAYPOINT 模式不自动授权。
func _advance_fallback_autonomy() -> bool:
	if not _fallback_active or program == null or program.fallback_program == null:
		return false
	if guidance_authority == GuidanceAuthority.AUTONOMOUS:
		return false
	var fb := program.fallback_program
	var met: bool = false
	match fb.autonomy_enable_mode:
		WeaponProgram.AutonomyEnableMode.DISTANCE:
			met = traveled_m >= fb.autonomy_enable_distance_m
		WeaponProgram.AutonomyEnableMode.TIME:
			met = _launch_t >= 0.0 and (_sim_time - _launch_t) >= fb.autonomy_enable_time_s
	if not met:
		return false
	guidance_authority = fb.guidance_authority
	_log_command("FALLBACK_AUTONOMY", {"via": "fallback"})
	event_occurred.emit(torpedo_id, "AUTONOMY_AUTHORIZED", {"via": "fallback"})
	return true


## 内部深度带命令（不经过线控门；fallback/程序自执行用）。
func _command_depth_band_internal(band: String) -> bool:
	if band != WeaponProgram.DEPTH_BAND_UPPER and band != WeaponProgram.DEPTH_BAND_LOWER:
		return false
	commanded_depth_band = band
	commanded_depth_m = _hold_depth_for_band(band)
	if commanded_depth_m > actual_depth_m + 0.5:
		depth_state = DepthState.DIVING
	elif commanded_depth_m < actual_depth_m - 0.5:
		depth_state = DepthState.CLIMBING
	else:
		depth_state = _depth_state_for_band(band)
	return true


func _log_command(kind: String, detail: Dictionary) -> void:
	command_log.append({"t": _sim_time, "cmd": kind, "detail": detail})
	if command_log.size() > 256:
		command_log.pop_front()


## ---- 推进 ----
## ctx: TorpedoContext（服务接口；绝不含 Truth targets）。
## REQ-05 tick 顺序（每物理 tick 固定）：①权限推进 → ②主动发射机（Ping 排程）
## → ③被动采样+到点回波收集 → ④航迹/Seeker 相位 → ⑤制导命令 → ⑥有限转率
## 转向 → ⑦垂直 → ⑧平移（引信 swept 由 World 在运动后统一判定）。捕获并
## 取得权限后同一 tick 即开始实际转向（≤1 tick）。
func step(dt: float, sim_time: float, ctx: RefCounted) -> bool:
	if mission_state == MissionState.DEAD or mission_state == MissionState.STOWED:
		return false
	_bind_ctx(ctx)
	_sim_time = sim_time
	var fired_event: bool = false
	fuel_left_s -= dt
	traveled_m += speed_kn * NavUtils.KNOT_TO_MS * dt
	if fuel_left_s <= 0.0:
		_die("FUEL_OUT", {})
		return true

	if _seeker != null:
		_seeker.own_turn_rate_deg_s = _last_turn_rate_deg_s
	_advance_running_noise(dt)
	# (1) 权限推进（P0-02.2/3 主程序 + fallback）。
	fired_event = fired_event or _advance_fallback_autonomy()
	fired_event = fired_event or _advance_program_autonomy()
	fired_event = fired_event or _advance_fuze()
	# (2) 主动发射机（本轮 Ping 的回波最早也要 tau 后才到，绝不同 tick 返回）。
	fired_event = fired_event or _advance_active_tx(dt)
	# (3) 采样：被动周期扫描 + 到点主动回波（净化 return 喂航迹机）。
	_advance_seeker_passive(dt, sim_time)
	_collect_active_returns(sim_time)
	# (4)+(5) Seeker 相位推进 + 制导命令计算（转率/期望航向）。
	_advance_seeker_and_guidance(sim_time)
	# (6) 转向（制导 > 线控命令 > 搜索扫掠，全受 omega_max）。
	fired_event = fired_event or _advance_mission(dt, sim_time)
	# (7) 垂直。
	_advance_vertical(dt)
	# (8) 平移（水平）。
	var v_ms: float = NavUtils.kn_to_ms(speed_kn)
	fired_event = fired_event or _advance_wire(dt, v_ms)
	var next: Dictionary = NavUtils.advance_pos(pos_east_m, pos_north_m, course_deg, v_ms, dt)
	pos_east_m = next["x"]
	pos_north_m = next["y"]
	trail.append({"e": pos_east_m, "n": pos_north_m, "t": sim_time})
	if trail.size() > 4000:
		trail.pop_front()
	return fired_event


func _bind_ctx(ctx: RefCounted) -> void:
	if ctx == null:
		return
	if ctx.depth_model != null:
		_depth_model = ctx.depth_model
	# Commit 5：声学事件总线（null=无总线，跳过声源广播）。
	if ctx.emission_bus != null:
		_emission_bus = ctx.emission_bus
		_emitter.bus = ctx.emission_bus
	# Commit 6：传感器采样适配器（输出净化 SeekerReturn，无 Truth）。
	if ctx.sensor_adapter != null:
		_sensor_adapter = ctx.sensor_adapter


func _advance_mission(dt: float, sim_time: float) -> bool:
	if mission_state != MissionState.SEARCH:
		_search_sweep_active = false  # P2-01：离开 SEARCH 后重置扫掠相位
	match mission_state:
		MissionState.LAUNCHING:
			if sim_time - _launch_t >= LAUNCH_TRANSITION_S:
				_try_mission(MissionState.WIRE_RUN, "WIRE_RUN", {"course_deg": course_deg})
				# §9.2：动力启动瞬态（一次）。出管瞬态由 WeaponSystem.fire 记录。
				_emit_motor_start()
				return true
		MissionState.WIRE_RUN, MissionState.SEARCH, MissionState.ATTACK, MissionState.TERMINAL:
			_apply_steering(dt, sim_time)
		_:
			_last_turn_rate_deg_s = 0.0
			commanded_turn_rate_deg_s = 0.0
			turn_saturated = false
	return false


## REQ-05(6)/REQ-07：转向应用（每 tick 恰好一次）。优先级：制导（转率命令/
## 期望航向）> 线控命令 > 搜索扫掠。全部受 omega_max = min(机械限，
## 横向过载限/速度) 约束；记录命令/实际转率与饱和状态（诊断 + 脱靶原因）。
func _apply_steering(dt: float, sim_time: float) -> void:
	var omega: float = _max_turn_rate()
	var rate_cmd: float = 0.0
	var have: bool = false
	var from_guidance: bool = false
	if _guidance_mode == GuidanceMode.RATE:
		rate_cmd = _guidance_turn_rate_cmd
		have = true
		from_guidance = true
		turn_saturated = absf(rate_cmd) > omega + 0.05
	elif _guidance_mode == GuidanceMode.COURSE and _guidance_course_deg >= 0.0:
		var g_err: float = NavUtils.wrap180(_guidance_course_deg - course_deg)
		rate_cmd = clampf(g_err / maxf(dt, 0.001), -omega, omega)
		have = true
		from_guidance = true
		turn_saturated = absf(g_err) > omega * dt + 0.05
	elif _cmd_course_deg >= 0.0:
		var err: float = NavUtils.wrap180(_cmd_course_deg - course_deg)
		rate_cmd = clampf(err / maxf(dt, 0.001), -omega, omega)
		have = true
		turn_saturated = absf(err) > omega * dt + 0.05
		if absf(err) < 0.05:
			course_deg = NavUtils.wrap360(_cmd_course_deg)
			_cmd_course_deg = -1.0
			turn_saturated = false
	elif mission_state == MissionState.SEARCH:
		var desired: float = _search_sweep_course(sim_time)
		if desired >= 0.0:
			var serr: float = NavUtils.wrap180(desired - course_deg)
			rate_cmd = clampf(serr / maxf(dt, 0.001), -omega, omega)
			have = true
			turn_saturated = absf(serr) > omega * dt + 0.05
	if not have:
		turn_saturated = false
	commanded_turn_rate_deg_s = rate_cmd if have else 0.0
	var applied: float = clampf(rate_cmd, -omega * dt, omega * dt) if have else 0.0
	_last_turn_rate_deg_s = applied / maxf(dt, 0.001)
	actual_turn_rate_deg_s = _last_turn_rate_deg_s
	course_deg = NavUtils.wrap360(course_deg + applied)
	if turn_saturated:
		_ever_turn_saturated = true


func _try_mission(to: int, ev: String, detail: Dictionary) -> bool:
	if mission_state == to:
		return true
	var allowed: Array = _MISSION_TRANSITIONS.get(mission_state, [])
	if not allowed.has(to):
		(
			event_occurred
			. emit(
				torpedo_id,
				"TRANSITION_REJECTED",
				{"from": mission_state_name(), "to": str(to), "via": ev},
			)
		)
		return false
	mission_state = to
	event_occurred.emit(torpedo_id, ev, detail)
	return true


## 主程序自主触发（P0-02.2/3）：wire_guidance_enabled=false 的无导线发射
## 也必须能推进 autonomy_enable_mode——旧实现只有 fallback 路径能推进自主
## （_advance_fallback_autonomy），无导线鱼雷会永久直航。fallback 仅负责
## 断线后的替代程序。
func _advance_program_autonomy() -> bool:
	if _fallback_active or program == null:
		return false
	if program.autonomy_enable_mode == WeaponProgram.AutonomyEnableMode.MANUAL:
		return false
	if guidance_authority == GuidanceAuthority.AUTONOMOUS:
		return false
	var met: bool = false
	match program.autonomy_enable_mode:
		WeaponProgram.AutonomyEnableMode.DISTANCE:
			met = traveled_m >= program.autonomy_enable_distance_m
		WeaponProgram.AutonomyEnableMode.TIME:
			met = _launch_t >= 0.0 and (_sim_time - _launch_t) >= program.autonomy_enable_time_s
	if not met:
		return false
	guidance_authority = GuidanceAuthority.AUTONOMOUS
	if mission_state == MissionState.WIRE_RUN:
		var has_lock: bool = (
			_seeker != null
			and (
				_seeker.phase
				in [
					TorpedoSeeker.Phase.ACQUIRING,
					TorpedoSeeker.Phase.TRACKING,
					TorpedoSeeker.Phase.REACQUIRE,
				]
			)
		)
		if not has_lock:
			_try_mission(MissionState.SEARCH, "SEARCH", {"reason": "AUTONOMY_ENABLED"})
	_log_command("PROGRAM_AUTONOMY", {"via": "program"})
	event_occurred.emit(torpedo_id, "AUTONOMY_AUTHORIZED", {"via": "program"})
	return true


## 引信解保与任务/自主/主动解耦：只按 traveled 距离解保（REQ-DECISION-02）。
func _advance_fuze() -> bool:
	if fuze_state != FuzeState.SAFE or program == null:
		return false
	if traveled_m >= program.warhead_arm_distance_m:
		fuze_state = FuzeState.ARMED
		event_occurred.emit(torpedo_id, "FUZE_ARMED", {"traveled_m": traveled_m})
		return true
	return false


## 主动发射机状态机（Commit 5：PingSession 前占位；节拍由 acoustic_profile
## active_pulse_duration_s / active_ping_interval_s 提供）。每次进入 PINGING
## 记录一条 TORPEDO_ACTIVE_PING 声学事件（§9.1，可被被动阵概率截获）。
func _advance_active_tx(dt: float) -> bool:
	var fired_event: bool = false
	if active_tx_state == ActiveTxState.OFF:
		if _tx_program_trigger_met():
			active_tx_state = ActiveTxState.WAITING_TRIGGER
	elif active_tx_state == ActiveTxState.WAITING_TRIGGER:
		if _tx_trigger_met():
			active_tx_state = ActiveTxState.PINGING
			_tx_cycle_s = acoustic_profile.active_pulse_duration_s
			_emit_active_ping()
			fired_event = true
	elif active_tx_state == ActiveTxState.PINGING:
		_tx_cycle_s -= dt
		if _tx_cycle_s <= 0.0:
			active_tx_state = ActiveTxState.COOLDOWN
			_tx_cycle_s = acoustic_profile.active_ping_interval_s
	elif active_tx_state == ActiveTxState.COOLDOWN:
		_tx_cycle_s -= dt
		if _tx_cycle_s <= 0.0:
			active_tx_state = ActiveTxState.PINGING
			_tx_cycle_s = acoustic_profile.active_pulse_duration_s
			_emit_active_ping()
			fired_event = true
	return fired_event


## 主动触发所用的程序：fallback 激活后按 fallback 预设（§5.5），否则按发射程序。
func _active_tx_program() -> WeaponProgram:
	if _fallback_active and program != null and program.fallback_program != null:
		return program.fallback_program
	return program


func _tx_program_trigger_met() -> bool:
	var prog := _active_tx_program()
	if prog == null:
		return false
	match prog.active_enable_mode:
		WeaponProgram.ActiveEnableMode.IMMEDIATE:
			return true
		WeaponProgram.ActiveEnableMode.DISTANCE:
			return traveled_m >= prog.active_enable_distance_m
		WeaponProgram.ActiveEnableMode.TIME:
			return _launch_t >= 0.0 and (_sim_time - _launch_t) >= prog.active_enable_time_s
	return false


func _tx_trigger_met() -> bool:
	return _tx_manual_armed or _tx_program_trigger_met()


## ---- 声学事件广播（§9.2，Commit 5）----
## bus 写入收敛在 _emitter（TorpedoEmitter）；无总线时全部跳过。
## 事件只带 torpedo_id 与自身状态/位置，绝不含任何目标 Truth / target_id。


## 动力启动瞬态（出管后进入 WIRE_RUN 时一次）。
func _emit_motor_start() -> void:
	_emitter.motor_start(Vector3(pos_east_m, pos_north_m, actual_depth_m), _sim_time)


## 主动 Ping（每次进入 PINGING 记录；TOF/回波由 adapter 按 tau=2R/c 延迟结算，
## §6.4——绝不瞬时返回）。P0-09：每次 Ping 生成唯一 ping_id，同 id 串联
## TX_PING 事件 / 回波 return / 监听完成事件。
func _emit_active_ping() -> void:
	_ping_seq += 1
	var pid: String = "%s-P%03d" % [torpedo_id, _ping_seq]
	_active_pings_outstanding[pid] = {"emit_t": _sim_time, "heard": false}
	event_occurred.emit(torpedo_id, "ACTIVE_TX_PING", {"ping_id": pid})
	_emitter.active_ping(Vector3(pos_east_m, pos_north_m, actual_depth_m), _sim_time, pid)
	# Commit 6：登记各接触回波（Ping 时刻几何为测距基准；到点后净化为
	# ACTIVE SeekerReturn）。仅当 adapter 存在（ctx 注入）时登记。
	if _sensor_adapter != null:
		(
			_sensor_adapter
			. schedule_active_echoes(
				torpedo_id,
				pos_east_m,
				pos_north_m,
				course_deg,
				acoustic_profile,
				_sim_time,
				pid,
				actual_depth_m,
				speed_kn,
			)
		)


## 航行噪声（持续声源）：按 RUNNING_NOISE_CADENCE_S 周期性广播，源级随速度
## 模式（§6.2：HIGH 更响）。事件 duration = 本次发射代表的一段时间。
func _advance_running_noise(dt: float) -> void:
	if (
		mission_state != MissionState.WIRE_RUN
		and mission_state != MissionState.SEARCH
		and mission_state != MissionState.ATTACK
		and mission_state != MissionState.TERMINAL
	):
		return
	_noise_timer_s -= dt
	if _noise_timer_s > 0.0:
		return
	_noise_timer_s = RUNNING_NOISE_CADENCE_S
	(
		_emitter
		. running_noise(
			Vector3(pos_east_m, pos_north_m, actual_depth_m),
			_sim_time,
			WeaponProgram.speed_mode_name(speed_mode),
			RUNNING_NOISE_CADENCE_S,
		)
	)


## 放线推进（§5.4，Commit 4）：在水运行段按鱼雷速度累计放线长；超长且
## break_on_excess_length → 确定性 BROKEN → 广播 WIRE_BROKEN 并执行 fallback。
func _advance_wire(dt: float, v_ms: float) -> bool:
	if (
		mission_state != MissionState.WIRE_RUN
		and mission_state != MissionState.SEARCH
		and mission_state != MissionState.ATTACK
		and mission_state != MissionState.TERMINAL
	):
		return false
	if not wire_link.update(dt, v_ms):
		return false
	(
		event_occurred
		. emit(
			torpedo_id,
			"WIRE_BROKEN",
			{"paid_out_m": wire_link.paid_out_m, "max_length_m": wire_link.max_length_m},
		)
	)
	_enter_fallback()
	return true


## ---- Seeker 采样（§6.3/§6.4，Commit 6）----
## 被动接收机默认 ON（REQ-DECISION-01），安全出管后按 PASSIVE_SAMPLE_INTERVAL_S
## 周期经 adapter 采样。返回只记净化 SeekerReturn；miss 帧无 return（不产生
## 记录）。adapter 为 null（直接单测 ctx 不含）时跳过，行为与旧版一致。


func _advance_seeker_passive(dt: float, sim_time: float) -> void:
	if _sensor_adapter == null or not passive_receiver_on:
		return
	if not _in_water():
		return
	_passive_sample_timer_s -= dt
	if _passive_sample_timer_s > 0.0:
		return
	_passive_sample_timer_s = PASSIVE_SAMPLE_INTERVAL_S
	var returns: Array = (
		_sensor_adapter
		. sample_passive(
			pos_east_m,
			pos_north_m,
			actual_depth_m,
			speed_kn,
			course_deg,
			acoustic_profile,
			sim_time,
		)
	)
	_record_seeker_returns(returns)
	# REQ-03：本轮被动扫描完成——对无关联 return 的 FOV 内航迹按机会计一次
	# miss（窗口限频；有 return 的航迹已被关联更新，不受罚）。
	if _seeker != null:
		_seeker.notify_passive_scan(sim_time)


## 主动回波（§6.4）：adapter 到点（tau=2R/c）结算的 ACTIVE return 收集。
func _collect_active_returns(sim_time: float) -> void:
	if _sensor_adapter == null:
		return
	if not _in_water():
		return
	var returns: Array = (
		_sensor_adapter
		. collect_due_active_returns(
			torpedo_id,
			pos_east_m,
			pos_north_m,
			actual_depth_m,
			speed_kn,
			acoustic_profile,
			sim_time,
		)
	)
	_record_seeker_returns(returns)
	# P0-09：同 ping_id 回波到达标记 heard；监听窗超时仍无回波 → 显式
	# LISTEN_COMPLETE_NO_RETURN（UI/测试可观测“本周期无回波”，绝无“永远等待”）。
	for r in returns:
		var pid := str(r.ping_id)
		if pid != "" and _active_pings_outstanding.has(pid):
			_active_pings_outstanding[pid]["heard"] = true
			event_occurred.emit(torpedo_id, "ECHO_RECEIVED", {"ping_id": pid})
	var listen_window: float = _sensor_adapter.active_listen_window_s
	var done: Array = []
	for pid2 in _active_pings_outstanding:
		var rec: Dictionary = _active_pings_outstanding[pid2]
		if sim_time - float(rec["emit_t"]) > listen_window:
			done.append(pid2)
			if not bool(rec["heard"]):
				event_occurred.emit(torpedo_id, "LISTEN_COMPLETE_NO_RETURN", {"ping_id": pid2})
	for pid3 in done:
		_active_pings_outstanding.erase(pid3)
	# REQ-03：主动监听窗结束且无回波——对 FOV 内航迹记一次 active miss
	#（每次 Ping 恰好一次；两次 Ping 之间绝不按 tick 扣分）。
	if _seeker != null and not done.is_empty():
		_seeker.notify_active_miss(sim_time)


func _record_seeker_returns(returns: Array) -> void:
	# P1-12.2：TargetEligibility 默认拒绝 OWN/FRIENDLY 接管——return 可在
	# 传感器内部产生（本艇是真实声源），但绝不进航迹/制导；拒绝可观测
	# （结构化事件只带 token 原因，不泄露 Truth）。
	var eligible: Array = []
	for r in returns:
		var tok: String = str(r.source_token)
		if tok == "OWN" or tok == "FRIENDLY":
			event_occurred.emit(torpedo_id, "CONTACT_REJECTED_SAFETY", {"source_token": tok})
			continue
		seeker_returns.append(r)
		eligible.append(r)
	while seeker_returns.size() > 256:
		seeker_returns.pop_front()
	# Commit 7：净化 return 同步喂 Seeker 航迹机（关联/更新，§7.2）。
	# P1-12：只喂资格通过的 return（OWN/FRIENDLY 已剔除）。
	if _seeker != null and not eligible.is_empty():
		_seeker.process_returns(eligible, _sim_time)


## Seeker/制导共用配置（默认值收敛在 TorpedoGuidance.default_seeker_cfg）。
func _seeker_cfg() -> Dictionary:
	return TorpedoGuidance.default_seeker_cfg(acoustic_profile)


func _advance_seeker_and_guidance(sim_time: float) -> void:
	if _seeker == null or not _in_water():
		return
	# REQ-06：机会/COAST 判定用实际艏向 + 接收半角（与物理采样同一 FOV 门）。
	_seeker.own_course_deg = course_deg
	_seeker.fov_half_deg = _passive_fov_half()
	var res: Dictionary = _seeker.update(sim_time)
	if bool(res.get("changed", false)):
		_on_seeker_phase_changed()
	_advance_guidance(sim_time)
	# REQ-01：任务联动每 tick 评估（不只相位变化时）——TRACKING 可能发生在
	# WIRE_ONLY 期间、之后才授权自主；只在相位变化时评估会永久停在 WIRE_RUN。
	# 进 ATTACK 需同持有效航迹 + 权限 + 航迹达标。
	if _seeker.phase in [TorpedoSeeker.Phase.TRACKING, TorpedoSeeker.Phase.REACQUIRE]:
		var can_steer := false
		if guidance_authority == GuidanceAuthority.AUTONOMOUS:
			can_steer = _seeker.selected_track() != null
		elif guidance_authority == GuidanceAuthority.ASSISTED and _assist_track_id >= 0:
			var at: SeekerTrack = _seeker.track_by_id(_assist_track_id)
			can_steer = (
				at != null
				and at.lock_quality >= float(_seeker_cfg().get("acquire_threshold", 0.65))
			)
		if (
			can_steer
			and (mission_state == MissionState.WIRE_RUN or mission_state == MissionState.SEARCH)
		):
			_try_mission(MissionState.ATTACK, "ATTACK", {"track_id": _seeker.selected_track_id})


## 接收 FOV 半角（REQ-06）：画像独立字段优先；旧配置回退 0.5×beamwidth。
func _passive_fov_half() -> float:
	if acoustic_profile.passive_fov_half_deg > 0.0:
		return acoustic_profile.passive_fov_half_deg
	return 0.5 * acoustic_profile.horizontal_beamwidth_deg


## 相位变化 → SeekerState 呈现 + 任务状态联动（§3.2/§3.3 + REQ-01）。
func _on_seeker_phase_changed() -> void:
	var mapped: int = SeekerState.PASSIVE_LISTEN
	match _seeker.phase:
		TorpedoSeeker.Phase.SEARCH:
			if (
				active_tx_state == ActiveTxState.PINGING
				or active_tx_state == ActiveTxState.COOLDOWN
			):
				mapped = SeekerState.COMBINED_SEARCH
			elif _tx_manual_armed:
				mapped = SeekerState.ACTIVE_SEARCH
			else:
				mapped = SeekerState.PASSIVE_LISTEN
		TorpedoSeeker.Phase.ACQUIRING:
			mapped = SeekerState.ACQUIRING
		TorpedoSeeker.Phase.TRACKING:
			mapped = SeekerState.TRACKING
		TorpedoSeeker.Phase.COAST:
			mapped = SeekerState.COAST
		TorpedoSeeker.Phase.LOST:
			mapped = SeekerState.LOST
		TorpedoSeeker.Phase.REACQUIRE:
			mapped = SeekerState.REACQUIRE
	if mapped != seeker_state:
		seeker_state = mapped
		event_occurred.emit(torpedo_id, "SEEKER_PHASE", {"state": seeker_state_name()})
	# 任务联动（REQ-01）：进 ATTACK 条件在 _advance_seeker_and_guidance 每
	# tick 评估；此处仅处理 LOST → SEARCH 重搜（COAST 保持 ATTACK）。
	if _seeker.phase == TorpedoSeeker.Phase.LOST and mission_state == MissionState.ATTACK:
		_try_mission(MissionState.SEARCH, "SEARCH", {"reason": "SEEKER_LOST"})


## 制导命令（§7.7 + REQ-04）：WIRE_ONLY 恒不接管；AUTONOMOUS 跟随选中航迹；
## ASSISTED 只在接受航迹达捕获阈值时跟随。有航迹 → PN 转率命令（RATE）；
## COAST → 预测方位惯性保持（COURSE）；LOST/REACQUIRE → 扩大扇区扫掠。
func _advance_guidance(sim_time: float) -> void:
	_guidance_mode = GuidanceMode.NONE
	_guidance_course_deg = -1.0
	_guidance_turn_rate_cmd = 0.0
	var autonomy: bool = guidance_authority == GuidanceAuthority.AUTONOMOUS
	var assisted: bool = guidance_authority == GuidanceAuthority.ASSISTED and _assist_track_id >= 0
	if not (autonomy or assisted):
		return
	var cfg := _seeker_cfg()
	var track: SeekerTrack = null
	if autonomy:
		if (
			_seeker.phase
			in [
				TorpedoSeeker.Phase.ACQUIRING,
				TorpedoSeeker.Phase.TRACKING,
				TorpedoSeeker.Phase.COAST,
				TorpedoSeeker.Phase.REACQUIRE,
			]
		):
			track = _seeker.selected_track()
	else:
		track = _seeker.track_by_id(_assist_track_id)
		if track != null and track.lock_quality < float(cfg.get("acquire_threshold", 0.65)):
			track = null
	if track != null:
		_ever_guidance_engaged = true
		# REQ-04：比例导航拦截制导（转率命令；输入只有净化航迹 + 自身状态）。
		_guidance_mode = GuidanceMode.RATE
		_guidance_turn_rate_cmd = TorpedoGuidance.intercept_turn_rate_deg_s(
			track, course_deg, NavUtils.kn_to_ms(speed_kn), cfg
		)
		# P1-08 配套：深度带归向——选中航迹的层带提示（测量边界内粗分类）
		# 驱动垂直机动（Vz_max 限速），异层目标才可能进入引信垂直门。
		var band_hint: String = track.depth_band_hint
		if band_hint != "" and band_hint != commanded_depth_band:
			_command_depth_band_internal(band_hint)
		# TERMINAL：主动回波测距进入近程（距离来自回波测量，绝不读 Truth）。
		if (
			mission_state == MissionState.ATTACK
			and track.range_estimate_m >= 0.0
			and track.range_estimate_m <= float(cfg.get("terminal_range_m", 250.0))
		):
			_try_mission(
				MissionState.TERMINAL,
				"TERMINAL",
				{"range_est_m": track.range_estimate_m},
			)
		return
	# COAST（REQ-06）：按最后方位 + 方位率短时预测惯性保持（期望航向模式）。
	if _seeker.phase == TorpedoSeeker.Phase.COAST:
		var ct: SeekerTrack = _seeker.selected_track()
		if ct != null:
			_guidance_mode = GuidanceMode.COURSE
			_guidance_course_deg = ct.predicted_bearing_deg(sim_time)
		return
	# LOST/REACQUIRE（§7.6）：围绕最后预测方位扩大扇区扫掠重搜。
	if _seeker.phase in [TorpedoSeeker.Phase.LOST, TorpedoSeeker.Phase.REACQUIRE]:
		var prog := _search_program()
		var half: float = prog.search_half_angle_deg if prog != null else 60.0
		var sec: Dictionary = _seeker.reacquire_sector(half)
		_guidance_mode = GuidanceMode.COURSE
		_guidance_course_deg = TorpedoGuidance.search_course_deg(
			"SNAKE",
			float(sec.get("center_deg", 0.0)),
			float(sec.get("half_angle_deg", 90.0)),
			sim_time,
			cfg
		)


## 搜索扫掠（§7.5）：SEARCH 且无制导/命令时按程序扇区扫掠；P2-01：扫掠
## 相位在进入 SEARCH 时自当前航向连续初始化，不取全局 sim_time 相位。
func _search_sweep_course(sim_time: float) -> float:
	var prog := _search_program()
	if prog == null:
		return -1.0
	var pattern: String = (
		"SNAKE" if prog.search_pattern == WeaponProgram.SearchPattern.SNAKE else "CIRCLE"
	)
	if not _search_sweep_active:
		_search_sweep_active = true
		_search_enter_t = sim_time
		_search_phase_offset_s = _search_phase_offset_for(prog, pattern)
	var t: float = sim_time - _search_enter_t + _search_phase_offset_s
	return TorpedoGuidance.search_course_deg(
		pattern, prog.search_center_deg, prog.search_half_angle_deg, t, _seeker_cfg()
	)


## P2-01：扫掠相位在进入 SEARCH 时连续初始化——求 t0 使 pattern(t0) = 当前
## 航向（三角波取第一半周期分支，中心外夹到扇区边界；圆周取最近角）。
func _search_phase_offset_for(prog: WeaponProgram, pattern: String) -> float:
	return TorpedoGuidance.search_phase_offset_for(course_deg, prog, pattern, _seeker_cfg())


## 搜索参数来源：fallback 激活后按 fallback（§5.5），否则按发射程序。
func _search_program() -> WeaponProgram:
	if _fallback_active and program != null and program.fallback_program != null:
		return program.fallback_program
	return program


func _in_water() -> bool:
	return (
		mission_state == MissionState.WIRE_RUN
		or mission_state == MissionState.SEARCH
		or mission_state == MissionState.ATTACK
		or mission_state == MissionState.TERMINAL
	)


## 垂直运动（S1-07A）：命令与实际分离，z 按 Vz_max 速率逼近命令深度。
## 模型（DepthLayerModel）提供 surface/bottom 钳制；无命令/无模型保持当前。
func _advance_vertical(dt: float) -> void:
	if commanded_depth_m < 0.0:
		return
	var z_min: float = min_depth_m
	var z_max: float = max_depth_m
	var dm: Variant = _depth_model
	if dm != null:
		z_min = float(dm.get("surface_depth_m"))
		z_max = float(dm.get("bottom_depth_m"))
	var dz: float = clampf(
		commanded_depth_m - actual_depth_m,
		-max_vertical_speed_m_s * dt,
		max_vertical_speed_m_s * dt
	)
	actual_depth_m = clampf(actual_depth_m + dz, z_min, z_max)
	if absf(commanded_depth_m - actual_depth_m) < 0.5:
		actual_depth_m = commanded_depth_m
		var reached_band: String = commanded_depth_band
		commanded_depth_m = -1.0
		commanded_depth_band = ""
		depth_state = _depth_state_for_band(
			reached_band if reached_band != "" else WeaponProgram.DEPTH_BAND_UPPER
		)


func _hold_depth_for_band(band: String) -> float:
	var dm: Variant = _depth_model
	if dm != null and dm.has_method("hold_depth_for_band"):
		return float(dm.call("hold_depth_for_band", band))
	if band == WeaponProgram.DEPTH_BAND_LOWER:
		return DEFAULT_LOWER_HOLD_DEPTH_M
	return DEFAULT_UPPER_HOLD_DEPTH_M


func _depth_state_for_band(band: String) -> int:
	if band == WeaponProgram.DEPTH_BAND_LOWER:
		return DepthState.HOLDING_LOWER
	return DepthState.HOLDING_UPPER


func _die(kind: String, detail: Dictionary) -> void:
	mission_state = MissionState.DEAD
	fuze_state = FuzeState.INERT
	# 验收14：脱靶原因（命中时为空；其余按七种枚举确定性判定，供 Debrief）。
	if kind != "DETONATED":
		if miss_reason == "":
			miss_reason = "FUEL_EXHAUSTED" if kind == "FUEL_OUT" else _compute_miss_reason()
		detail["miss_reason"] = miss_reason
	event_occurred.emit(torpedo_id, kind, detail)


## 脱靶原因确定性判定（验收14）：委托纯函数 TorpedoMissReason（按优先级
## 首个命中项）。
func _compute_miss_reason() -> String:
	var tracks: Array = _seeker.tracks if _seeker != null else []
	return TorpedoMissReason.compute(not _ever_guidance_engaged, _ever_turn_saturated, tracks)
