class_name Torpedo
extends RefCounted
## torpedo.gd — 鱼雷实体（S1-07 正交状态重构版，Commit 1-4）。
##
## 信息链纪律（S1-07 §2.1/§2.2）：
##   - 本类不接收 TruthEntity targets：step(dt, sim_time, ctx) 的 ctx 只含
##     服务接口（TorpedoContext），结构上禁止 Guidance 读目标 Truth；
##   - 发射参数来自 WeaponProgram 快照（SystemSolution 只是可选预填来源，
##     本批仍由 WeaponSystem.fire 统一构建程序）；
##   - 目标 Truth 选择 / 声自导捕获（Seeker 采样 → SeekerTrack）是 Commit 6
##     以后的事，本批不做——鱼雷是"线导直航 + 默认被动监听"的诚实中间态。
##
## 线导（S1-07 §5.4/§5.5，Commit 4）：wire_link 持有线长/放线/断裂/切断状态，
## 命令门只认 CONNECTED；导线 BROKEN/CUT 后拒绝新命令并执行发射前保存的
## fallback program（保持最后命令航向 → 预设搜索深度带 → 按预设距离/时间
## 授权自主与开主动 → 预设扇区 SEARCH）。命令全部记 CommandLog，绝不改写
## 发射程序快照。
##
## Seeker 采样（S1-07 §6.3/§6.5，Commit 6）：发射并安全出管后被动接收机默认
## ON（REQ-DECISION-01），经 ctx 注入的 TorpedoSensorAdapter 周期采样并收集
## 净化 SeekerReturn（无 target_id / 无被动真实 range）；主动 Ping 的回波按
## tau=2R/c 延迟到达。本类只消费净化 Return，绝不接触 Truth targets；转向 /
## 捕获 / 跟踪（SeekerTrack）为 Commit 7，本批仅"监听并记录"。
##
## 正交状态模型（S1-07 §3，REQ-DECISION-02）：不再用一个 State 同时暗含
## "主动开机、已锁定、导线断裂、引信已解保"。任务/Seeker/主动发射机/制导
## 权限/导线/深度/引信各自独立状态机，见下方 enum。
##
## 生命周期（任务层）：
##   STOWED → LAUNCHING → WIRE_RUN（→ SEARCH/ATTACK/TERMINAL 由后续 Commit
##   的 Seeker/命中链驱动）→ DEAD（燃料耗尽 / 命中 / 自毁）。

signal event_occurred(torpedo_id: String, kind: String, detail: Dictionary)

enum MissionState { STOWED, LAUNCHING, WIRE_RUN, SEARCH, ATTACK, TERMINAL, DEAD }
enum SeekerState {
	PASSIVE_LISTEN, ACTIVE_SEARCH, COMBINED_SEARCH, ACQUIRING, TRACKING, LOST, REACQUIRE
}
enum ActiveTxState { OFF, WAITING_TRIGGER, PINGING, COOLDOWN }
enum GuidanceAuthority { WIRE_ONLY, ASSISTED, AUTONOMOUS }
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

var trail: Array = []  # [{e, n, t}] 供海图画轨迹（自身状态，非 Truth）
# Commit 4 命令日志（S1-07 §5.1：线控命令另记 CommandLog，绝不悄悄改写原始
# 发射程序）。_fallback_active：导线断/切后进入 fallback 执行态。
var command_log: Array = []  # [{t, cmd, detail}] 已接受线控命令（封顶 256）
# Commit 6（§6.5）：净化后的 SeekerReturn 记录（被动周期采样 + 主动回波到达）。
# 只存 SeekerReturn 对象/其 to_dict——不含 target_id / Truth（可直供 UI/日志）。
var seeker_returns: Array = []
# Commit 6（REQ-DECISION-01）：被动接收机默认 ON；发射并安全出管后开始监听。
var passive_receiver_on: bool = true
var _cmd_course_deg: float = -1.0  # <0 = 无航向命令（保持当前航向）
var _launch_t: float = 0.0
var _sim_time: float = 0.0
var _tx_cycle_s: float = 0.0
var _tx_manual_armed: bool = false
var _depth_model: RefCounted = null  # DepthLayerModel（Commit 2 由 ctx 注入）
var _fallback_active: bool = false
# Commit 5：ctx 注入的声学事件总线（null=无总线，如直接单测不发射）。
var _emission_bus: AcousticEmissionBus = null
var _noise_timer_s: float = 0.0
# Commit 6：ctx 注入的传感器采样适配器（仿真内核唯一可触 Truth 的武器侧对象，
# 输出净化 SeekerReturn）与被动采样计时。
var _sensor_adapter: TorpedoSensorAdapter = null
var _passive_sample_timer_s: float = 0.0
# Commit 7（§7）：Seeker 航迹/相位 + 制导。只消费净化 SeekerReturn，绝不接触
# Truth；_guidance_course_deg >= 0 时按 AUTONOMOUS / ASSISTED-accepted 制导转向，
# WIRE_ONLY 恒 -1（Seeker 只侦听提示，§7.7）。
var _seeker: TorpedoSeeker = null
var _assist_track_id: int = -1  # ASSISTED：玩家 ACCEPT_SEEKER_TRACK 接受的航迹
var _guidance_course_deg: float = -1.0


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
	if program != null:
		wire_link.enabled = program.wire_guidance_enabled
		guidance_authority = program.guidance_authority
		# Commit 5：速度/续航来自声学画像（§6.2 模式同时改速度与续航）。
		acoustic_profile = TorpedoAcousticProfile.make_default()
		var sm: String = WeaponProgram.speed_mode_name(program.speed_mode)
		speed_mode = program.speed_mode
		speed_kn = acoustic_profile.speed_kn(sm)
		fuel_left_s = acoustic_profile.endurance_s(sm)
		course_deg = NavUtils.wrap360(program.initial_course_deg)
		commanded_depth_band = program.initial_depth_band
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
	if not _wire_accepts_command():
		return false
	_cmd_course_deg = NavUtils.wrap360(deg)
	_log_command("SET_COURSE", {"course_deg": _cmd_course_deg})
	return true


## 速度模式命令（§6.2，Commit 5）：模式同时改速度与续航——切模式时按
## 新旧模式续航比等比折算剩余燃料（HIGH 更快烧完，QUIET 更省），并更新
## 运行噪声源级（由 acoustic_profile 派生，_emit_running_noise 消费）。
func command_speed_mode(mode: int) -> bool:
	if not _wire_accepts_command():
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
	if not _wire_accepts_command():
		return false
	if not _command_depth_band_internal(band):
		return false
	_log_command("SET_DEPTH_BAND", {"band": band})
	return true


func set_active_tx(on: bool) -> bool:
	if not _wire_accepts_command():
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
	if not _wire_accepts_command():
		return false
	guidance_authority = GuidanceAuthority.AUTONOMOUS
	_log_command("AUTHORIZE_AUTONOMY", {})
	event_occurred.emit(torpedo_id, "AUTONOMY_AUTHORIZED", {"via": "wire"})
	return true


func return_to_wire_only() -> bool:
	if not _wire_accepts_command():
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
	if not _wire_accepts_command():
		return false
	if _seeker == null or _seeker.track_by_id(track_id) == null:
		return false
	_assist_track_id = track_id
	_log_command("ACCEPT_SEEKER_TRACK", {"track_id": track_id})
	event_occurred.emit(torpedo_id, "TRACK_ACCEPTED", {"track_id": track_id})
	return true


## 玩家主动切断（§5.4 CUT_WIRE）：切断后执行 fallback 并拒绝后续命令。
func cut_wire() -> bool:
	if not _wire_accepts_command():
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
	if mission_state == MissionState.WIRE_RUN or mission_state == MissionState.SEARCH:
		mission_state = MissionState.SEARCH
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

	fired_event = fired_event or _advance_mission(dt, sim_time)
	_advance_running_noise(dt)
	fired_event = fired_event or _advance_fallback_autonomy()
	fired_event = fired_event or _advance_fuze()
	fired_event = fired_event or _advance_active_tx(dt)
	_advance_vertical(dt)
	# Commit 7（§7）：采样/回波收集 → Seeker 相位推进 → 制导期望航向；
	# 之后 _advance_mission 按优先级（制导 > 线控命令 > 搜索扫掠）有限速率转向。
	_advance_seeker_passive(dt, sim_time)
	_collect_active_returns(sim_time)
	_advance_seeker_and_guidance(sim_time)

	# 平移（水平）
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
	# Commit 6：传感器采样适配器（输出净化 SeekerReturn，无 Truth）。
	if ctx.sensor_adapter != null:
		_sensor_adapter = ctx.sensor_adapter


func _advance_mission(dt: float, sim_time: float) -> bool:
	match mission_state:
		MissionState.LAUNCHING:
			if sim_time - _launch_t >= LAUNCH_TRANSITION_S:
				mission_state = MissionState.WIRE_RUN
				event_occurred.emit(torpedo_id, "WIRE_RUN", {"course_deg": course_deg})
				# §9.2：动力启动瞬态（一次）。出管瞬态由 WeaponSystem.fire 记录。
				_emit_motor_start()
				return true
		MissionState.WIRE_RUN, MissionState.SEARCH, MissionState.ATTACK, MissionState.TERMINAL:
			# 期望航向优先级（Commit 7，§7.7）：制导（AUTONOMOUS/ASSISTED 已接受）
			# > 线控命令 > 搜索扫掠（仅 SEARCH 且无锁定、无命令时）。全部经最大
			# 转向率逼近——绝无瞬时指向（WPN-SEEK-13）。
			var desired: float = _guidance_course_deg
			if desired < 0.0:
				desired = _cmd_course_deg
			if desired < 0.0 and mission_state == MissionState.SEARCH:
				desired = _search_sweep_course(sim_time)
			if desired >= 0.0:
				var err: float = NavUtils.wrap180(desired - course_deg)
				var rate: float = maxf(max_turn_rate_deg_s, 0.1)
				course_deg = NavUtils.wrap360(course_deg + clampf(err, -rate * dt, rate * dt))
				if (
					absf(NavUtils.wrap180(desired - course_deg)) < 0.05
					and desired == _cmd_course_deg
				):
					course_deg = NavUtils.wrap360(desired)
					_cmd_course_deg = -1.0
	return false


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
			event_occurred.emit(torpedo_id, "ACTIVE_TX_PING", {})
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
			event_occurred.emit(torpedo_id, "ACTIVE_TX_PING", {})
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
## 记录进 ctx 注入的 AcousticEmissionBus；无总线（直接单测 ctx=null）时跳过。
## 事件只带 torpedo_id 与自身状态/位置，绝不含任何目标 Truth / target_id。


## 动力启动瞬态（出管后进入 WIRE_RUN 时一次）。
func _emit_motor_start() -> void:
	if _emission_bus == null:
		return
	var t: Dictionary = acoustic_profile.motor_start_transient
	(
		_emission_bus
		. record(
			AcousticEmissionEvent.TORPEDO_MOTOR_START,
			torpedo_id,
			_sim_time,
			Vector3(pos_east_m, pos_north_m, actual_depth_m),
			float(t.get("center_frequency_hz", 800.0)),
			float(t.get("bandwidth_hz", 4000.0)),
			float(t.get("sl_db", 158.0)),
			float(t.get("duration_s", 1.5)),
		)
	)


## 主动 Ping（每次进入 PINGING 记录；TOF/回波由 adapter 按 tau=2R/c 延迟结算，
## §6.4——绝不瞬时返回）。
func _emit_active_ping() -> void:
	if _emission_bus != null:
		(
			_emission_bus
			. record(
				AcousticEmissionEvent.TORPEDO_ACTIVE_PING,
				torpedo_id,
				_sim_time,
				Vector3(pos_east_m, pos_north_m, actual_depth_m),
				acoustic_profile.active_center_frequency_hz,
				acoustic_profile.active_bandwidth_hz,
				acoustic_profile.active_source_level_db,
				acoustic_profile.active_pulse_duration_s,
			)
		)
	# Commit 6：登记各接触回波（Ping 时刻几何为测距基准；到点后净化为
	# ACTIVE SeekerReturn）。仅当 adapter 存在（ctx 注入）时登记。
	if _sensor_adapter != null:
		_sensor_adapter.schedule_active_echoes(
			torpedo_id, pos_east_m, pos_north_m, acoustic_profile, _sim_time
		)


## 航行噪声（持续声源）：按 RUNNING_NOISE_CADENCE_S 周期性广播，源级随速度
## 模式（§6.2：HIGH 更响）。事件 duration = 本次发射代表的一段时间。
func _advance_running_noise(dt: float) -> void:
	if _emission_bus == null:
		return
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
	var sm: String = WeaponProgram.speed_mode_name(speed_mode)
	var band: Vector2 = acoustic_profile.running_noise_band_hz()
	var center: float = 0.5 * (band.x + band.y)
	var bw: float = maxf(band.y - band.x, 1.0)
	(
		_emission_bus
		. record(
			AcousticEmissionEvent.TORPEDO_RUNNING_NOISE,
			torpedo_id,
			_sim_time,
			Vector3(pos_east_m, pos_north_m, actual_depth_m),
			center,
			bw,
			acoustic_profile.own_noise_sl_db(sm),
			RUNNING_NOISE_CADENCE_S,
			# Commit 8（§6.1）：窄带谱线随模式（分类/频谱相似度竞争的特征来源）。
			{"tonal_lines": acoustic_profile.tonal_lines(sm)},
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


func _record_seeker_returns(returns: Array) -> void:
	for r in returns:
		seeker_returns.append(r)
	while seeker_returns.size() > 256:
		seeker_returns.pop_front()
	# Commit 7：净化 return 同步喂 Seeker 航迹机（关联/更新，§7.2）。
	if _seeker != null and not returns.is_empty():
		_seeker.process_returns(returns, _sim_time)


## ---- Commit 7（§7）：Seeker 相位推进 + 制导 ----


## Seeker/制导共用配置（§7.3 阈值 + §7.7 提前量 + §7.5 扫掠周期；可测试标定）。
func _seeker_cfg() -> Dictionary:
	return {
		"acquire_threshold": 0.65,
		"stable_track_threshold": 0.80,
		"drop_threshold": 0.25,
		"beta_miss": 0.10,
		"bearing_gate_deg": 12.0,
		"miss_after_s": 1.2,
		"reacquire_timeout_s": 120.0,
		"lead_time_s": 12.0,
		"max_lead_deg": 25.0,
		"snake_period_s": 120.0,
		"circle_period_s": 240.0,
		"terminal_range_m": 250.0,
	}


func _advance_seeker_and_guidance(sim_time: float) -> void:
	if _seeker == null or not _in_water():
		return
	var res: Dictionary = _seeker.update(sim_time)
	if bool(res.get("changed", false)):
		_on_seeker_phase_changed()
	_advance_guidance(sim_time)


## 相位变化 → SeekerState 呈现 + 任务状态联动（§3.2/§3.3）。
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
		TorpedoSeeker.Phase.LOST:
			mapped = SeekerState.LOST
		TorpedoSeeker.Phase.REACQUIRE:
			mapped = SeekerState.REACQUIRE
	if mapped != seeker_state:
		seeker_state = mapped
		event_occurred.emit(torpedo_id, "SEEKER_PHASE", {"state": seeker_state_name()})
	# 任务联动：TRACKING → ATTACK；ATTACK 中 LOST → SEARCH（重搜，§7.6）。
	if (
		_seeker.phase == TorpedoSeeker.Phase.TRACKING
		and (mission_state == MissionState.WIRE_RUN or mission_state == MissionState.SEARCH)
	):
		mission_state = MissionState.ATTACK
		event_occurred.emit(torpedo_id, "ATTACK", {"track_id": _seeker.selected_track_id})
	elif _seeker.phase == TorpedoSeeker.Phase.LOST and mission_state == MissionState.ATTACK:
		mission_state = MissionState.SEARCH
		event_occurred.emit(torpedo_id, "SEARCH", {"reason": "SEEKER_LOST"})


## 制导期望航向（§7.7）：WIRE_ONLY 恒不接管；AUTONOMOUS 跟随 seeker 选中的
## 航迹；ASSISTED 只在玩家 ACCEPT_SEEKER_TRACK 接受且航迹仍达捕获阈值时跟随。
## 期望航向写 _guidance_course_deg，实际转向仍受 max_turn_rate 限制。
func _advance_guidance(sim_time: float) -> void:
	_guidance_course_deg = -1.0
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
				TorpedoSeeker.Phase.REACQUIRE
			]
		):
			track = _seeker.selected_track()
	else:
		track = _seeker.track_by_id(_assist_track_id)
		if track != null and track.lock_quality < float(cfg.get("acquire_threshold", 0.65)):
			track = null
	if track != null:
		_guidance_course_deg = TorpedoGuidance.pursuit_course_deg(track, cfg)
		# TERMINAL：主动回波测距进入近程（距离来自回波测量，绝不读 Truth）。
		if (
			mission_state == MissionState.ATTACK
			and _seeker.phase == TorpedoSeeker.Phase.TRACKING
			and track.range_estimate_m >= 0.0
			and track.range_estimate_m <= float(cfg.get("terminal_range_m", 250.0))
		):
			mission_state = MissionState.TERMINAL
			event_occurred.emit(torpedo_id, "TERMINAL", {"range_est_m": track.range_estimate_m})
		return
	# LOST/REACQUIRE（§7.6）：围绕最后预测方位扩大扇区扫掠重搜。
	if _seeker.phase in [TorpedoSeeker.Phase.LOST, TorpedoSeeker.Phase.REACQUIRE]:
		var prog := _search_program()
		var half: float = prog.search_half_angle_deg if prog != null else 60.0
		var sec: Dictionary = _seeker.reacquire_sector(half)
		_guidance_course_deg = TorpedoGuidance.search_course_deg(
			"SNAKE",
			float(sec.get("center_deg", 0.0)),
			float(sec.get("half_angle_deg", 90.0)),
			sim_time,
			cfg
		)


## 搜索扫掠（§7.5）：SEARCH 且无制导目标、无玩家命令时按程序扇区扫掠
## （SNAKE 三角波 / CIRCLE 旋转），转向速率仍受 max_turn_rate 约束。
func _search_sweep_course(sim_time: float) -> float:
	var prog := _search_program()
	if prog == null:
		return -1.0
	var pattern: String = (
		"SNAKE" if prog.search_pattern == WeaponProgram.SearchPattern.SNAKE else "CIRCLE"
	)
	return TorpedoGuidance.search_course_deg(
		pattern, prog.search_center_deg, prog.search_half_angle_deg, sim_time, _seeker_cfg()
	)


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
	event_occurred.emit(torpedo_id, kind, detail)
