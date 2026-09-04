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

# 速度/续航按 speed_mode（占位标定，Commit 5 TorpedoAcousticProfile 外部化
# 时替换；本批先保证"模式同时改速度与续航"，不单改地图速度）。
const SPEED_KN_BY_MODE := {"QUIET": 28.0, "CRUISE": 40.0, "HIGH": 50.0}
const ENDURANCE_S_BY_MODE := {"QUIET": 1800.0, "CRUISE": 1200.0, "HIGH": 800.0}
const DEFAULT_TURN_RATE_DEG_S: float = 6.0
const LAUNCH_TRANSITION_S: float = 1.0
# 深度带占位 hold 深度（Commit 2 起由 DepthLayerModel 配置覆盖）。
const DEFAULT_UPPER_HOLD_DEPTH_M: float = 70.0
const DEFAULT_LOWER_HOLD_DEPTH_M: float = 180.0
# 主动发射机占位节拍（Commit 5/6 接入真实 PingSession/回波前只走状态机）。
const ACTIVE_PULSE_S: float = 0.5
const ACTIVE_PING_INTERVAL_S: float = 8.0

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
var speed_kn: float = SPEED_KN_BY_MODE["CRUISE"]
var fuel_left_s: float = ENDURANCE_S_BY_MODE["CRUISE"]
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
var _cmd_course_deg: float = -1.0  # <0 = 无航向命令（保持当前航向）
var _launch_t: float = 0.0
var _sim_time: float = 0.0
var _tx_cycle_s: float = 0.0
var _tx_manual_armed: bool = false
var _depth_model: RefCounted = null  # DepthLayerModel（Commit 2 由 ctx 注入）
var _fallback_active: bool = false


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
	if program != null:
		wire_link.enabled = program.wire_guidance_enabled
		guidance_authority = program.guidance_authority
		var sm: String = WeaponProgram.speed_mode_name(program.speed_mode)
		speed_kn = float(SPEED_KN_BY_MODE.get(sm, SPEED_KN_BY_MODE["CRUISE"]))
		fuel_left_s = float(ENDURANCE_S_BY_MODE.get(sm, ENDURANCE_S_BY_MODE["CRUISE"]))
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


func command_speed_mode(mode: int) -> bool:
	if not _wire_accepts_command():
		return false
	var sm: String = WeaponProgram.speed_mode_name(mode)
	speed_kn = float(SPEED_KN_BY_MODE.get(sm, speed_kn))
	_log_command("SET_SPEED_MODE", {"mode": sm})
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
	_log_command("RETURN_TO_WIRE_ONLY", {})
	event_occurred.emit(torpedo_id, "RETURN_WIRE_ONLY", {})
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
	fired_event = fired_event or _advance_fallback_autonomy()
	fired_event = fired_event or _advance_fuze()
	fired_event = fired_event or _advance_active_tx(dt)
	_advance_vertical(dt)

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


func _advance_mission(dt: float, sim_time: float) -> bool:
	match mission_state:
		MissionState.LAUNCHING:
			if sim_time - _launch_t >= LAUNCH_TRANSITION_S:
				mission_state = MissionState.WIRE_RUN
				event_occurred.emit(torpedo_id, "WIRE_RUN", {"course_deg": course_deg})
				return true
		MissionState.WIRE_RUN, MissionState.SEARCH, MissionState.ATTACK, MissionState.TERMINAL:
			# 航向按最大转向率逼近命令航向（WIRE_ONLY 下 Seeker 不得擅自转向；
			# 无命令保持直航）。SEARCH/ATTACK 的具体驱动由 Commit 6/7 Seeker 链
			# 接入，本批 WIRE_RUN 语义即"严格跟随线控命令/程序航向"。
			if _cmd_course_deg >= 0.0:
				var err: float = NavUtils.wrap180(_cmd_course_deg - course_deg)
				var rate: float = maxf(max_turn_rate_deg_s, 0.1)
				course_deg = NavUtils.wrap360(course_deg + clampf(err, -rate * dt, rate * dt))
				if absf(NavUtils.wrap180(_cmd_course_deg - course_deg)) < 0.05:
					course_deg = NavUtils.wrap360(_cmd_course_deg)
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


## 主动发射机状态机（占位：Commit 5/6 接 AcousticEmissionBus + PingSession，
## 本批按程序/fallback 触发条件走 OFF→WAITING_TRIGGER→PINGING→COOLDOWN）。
## Commit 4：OFF 也能按程序化触发条件（DISTANCE/TIME/IMMEDIATE）自动进入
## WAITING_TRIGGER——fallback 的"按预设条件开启 active TX"（§5.5）由此生效；
## MANUAL 模式仍只由玩家线控命令（set_active_tx(true)）开启。
func _advance_active_tx(dt: float) -> bool:
	var fired_event: bool = false
	if active_tx_state == ActiveTxState.OFF:
		if _tx_program_trigger_met():
			active_tx_state = ActiveTxState.WAITING_TRIGGER
	elif active_tx_state == ActiveTxState.WAITING_TRIGGER:
		if _tx_trigger_met():
			active_tx_state = ActiveTxState.PINGING
			_tx_cycle_s = ACTIVE_PULSE_S
			event_occurred.emit(torpedo_id, "ACTIVE_TX_PING", {})
			fired_event = true
	elif active_tx_state == ActiveTxState.PINGING:
		_tx_cycle_s -= dt
		if _tx_cycle_s <= 0.0:
			active_tx_state = ActiveTxState.COOLDOWN
			_tx_cycle_s = ACTIVE_PING_INTERVAL_S
	elif active_tx_state == ActiveTxState.COOLDOWN:
		_tx_cycle_s -= dt
		if _tx_cycle_s <= 0.0:
			active_tx_state = ActiveTxState.PINGING
			_tx_cycle_s = ACTIVE_PULSE_S
			event_occurred.emit(torpedo_id, "ACTIVE_TX_PING", {})
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
