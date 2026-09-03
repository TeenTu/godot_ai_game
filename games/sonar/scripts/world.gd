class_name World
extends RefCounted
## world.gd — 固定步长仿真主循环（阶段一，无 UI）。
##
## 职责：
##   - 持有全部 Truth 实体（本艇 + 目标）、环境、传感器、测量生成器
##   - 按固定步长推进运动学
##   - 按各传感器 update_interval 触发测量生成
##   - 收集所有测量流（Measurement）
##   - 支持暂停 / 时间加速（1x/2x/4x/8x）——阶段三接 UI，阶段一保留接口
##
## Truth 隔离：本类只产出 Measurement，绝不把 Truth 位置直接暴露给上层 UI。

# 艇首主动阵 id（S1-04B-REQ-20）：仅当场景显式配置 own_ship.active_sonar
# （或 sensors 含 array_type=="active"）时才具备主动能力——无硬件绝不自动构造。
const ACTIVE_SENSOR_ID: String = "hull_active"

var world: Dictionary = {}
var sim_time: float = 0.0
var measurements: Array = []  # 全部生成的 Measurement
# Operator Layer：false 时传感器不再自动产生 Measurement，
# 测量只能由玩家 Mark / 已分配 Tracker / Autocrew 产生。
var auto_measurements: bool = true
var weapons: WeaponSystem = null  # 阶段四：发射管与在水鱼雷

# ---- 主动声呐 Ping（S1-04B PingSession）----
# 玩家发一次脉冲 → 按往返传播延迟 τ=2R/c 结算单次在途 PingSession
# （READY→LISTENING→RETURN/NO_RETURN→READY）。单在途：新 Ping 绝不
# 清空未返回回波（REQ-16/17）。测距即测时：R_meas 以发射时刻登记的几何
# 距离为基准（REQ-19），到达时绝不回填当前 Truth 距离。
# 硬件显式配置（REQ-20）：own_ship.active_sonar 块存在（或 sensors 含
# array_type=="active"）才有主动能力；否则 UNAVAILABLE 并禁用。
var ping_sl_db: float = 210.0
var ping_cooldown_s: float = 15.0
var ping_freq_min_hz: float = 2000.0
var ping_freq_max_hz: float = 4000.0
var ping_array_gain_db: float = 24.0
var ping_sound_speed_m_s: float = AcousticService.SOUND_SPEED_M_S
var ping_listen_window_s: float = 15.0  # 监听窗口：发射后等待回波的最长秒数
var ping_pulse_duration_s: float = 0.25  # 脉冲时长（ActiveEmissionEvent/暴露刻画，REQ-05）
var ping_hardware: bool = false  # 场景显式配置主动阵才为 true
# ---- S1-04C-REQ-05 主动暴露事件 ----
# 每次显式发射记录一条 ActiveEmissionEvent（本艇发射事实，非目标 Truth）：
#   {emitter_internal_ref, emit_time, source_position_internal:{e,n},
#    center_frequency_hz, bandwidth_hz, source_level_db, pulse_duration_s}
# 阶段一只记录事件供敌方被动截获判定/审计使用（完整敌方行为 S2-05 接入）。
var active_emissions: Array = []

var _sensor_timers: Dictionary = {}  # sensor_id -> 下次触发时间
var _paused: bool = false
var _time_scale: float = 1.0
# 单在途 PingSession（S1-04B-REQ-16/17）；{} = 无在途（READY）。
# 结构：{state, ping_id, emit_t, listen_end_t, cooldown_until,
#        echoes:[{target_id, arrive_t, range_ref_m, range_ref_time_s,
#                 settled, detected, se_db, pd, bearing_deg, range_m,
#                 range_sigma_m}], returned_count, sensor}
var _ping_session: Dictionary = {}
# 已结算回波摘要缓冲（take_arrived_echoes 排空）。独立于会话存活：
# 远目标回波 τ 可能远超冷却期，会话提前清空也不得丢已结算结果。
var _ping_results: Array = []
var _next_ping_id: int = 1


## 从场景 JSON 构建并初始化世界。
func load_scenario(scenario: Dictionary) -> void:
	world = ScenarioLoader.build(scenario)
	sim_time = 0.0
	measurements.clear()
	weapons = WeaponSystem.new()
	_sensor_timers.clear()
	for s in world["sensors"]:
		_sensor_timers[s.sensor_id] = 0.0
	# 主动声呐配置（S1-04B-REQ-20）：own_ship.active_sonar 块存在 = 平台
	# 装有艇首主动阵硬件（显式声明）；sensors 含 array_type=="active" 也视为
	# 硬件。两者皆无 → ping_hardware=false：Ping 显示 UNAVAILABLE 并禁用，
	# 绝不自动构造缺省主动阵（Truth/硬件隔离）。
	var as_cfg: Dictionary = scenario.get("own_ship", {}).get("active_sonar", {})
	ping_hardware = not as_cfg.is_empty()
	for s in world["sensors"]:
		if str(s.array_type) == "active":
			ping_hardware = true
	ping_sl_db = float(as_cfg.get("ping_sl_db", ping_sl_db))
	ping_cooldown_s = float(as_cfg.get("cooldown_s", ping_cooldown_s))
	ping_freq_min_hz = float(as_cfg.get("freq_min_hz", ping_freq_min_hz))
	ping_freq_max_hz = float(as_cfg.get("freq_max_hz", ping_freq_max_hz))
	ping_array_gain_db = float(as_cfg.get("array_gain_db", ping_array_gain_db))
	ping_sound_speed_m_s = float(as_cfg.get("sound_speed_m_s", ping_sound_speed_m_s))
	ping_listen_window_s = maxf(float(as_cfg.get("listen_window_s", ping_listen_window_s)), 0.5)
	ping_pulse_duration_s = maxf(float(as_cfg.get("pulse_duration_s", ping_pulse_duration_s)), 0.05)
	_ping_session = {}
	_ping_results.clear()
	_next_ping_id = 1
	active_emissions.clear()


## 推进内部仿真时间 dt（秒）。dt 已由上层按 time_scale 折算。
## 固定步长：world.dt 是每 tick 的物理步长。
func tick() -> void:
	if _paused:
		return
	if not auto_measurements:
		_advance_only()
		return
	var dt: float = world["dt"]
	sim_time += dt

	# 1) 推进所有 Truth 实体
	world["own"].advance(dt)
	for t in world["targets"]:
		t.advance(dt)

	# 2) 按传感器更新间隔触发测量
	for sensor in world["sensors"]:
		var next_t: float = _sensor_timers.get(sensor.sensor_id, 0.0)
		if sim_time >= next_t:
			_emit_for_sensor(sensor)
			_sensor_timers[sensor.sensor_id] = sim_time + sensor.update_interval_s

## 仅推进实体运动（Operator 模式：无自动测量）。
	# 3) 推进在水鱼雷（自导/命中为仿真引擎内部行为）
	if weapons != null and not weapons.torpedoes.is_empty():
		weapons.step(dt, sim_time, world["targets"])
	# 4) 推进 PingSession（结算到点回波 + 状态转移，与自动测量无关）
	_advance_ping_session()


func _advance_only() -> void:
	var dt: float = world["dt"]
	sim_time += dt
	world["own"].advance(dt)
	for t in world["targets"]:
		t.advance(dt)
	if weapons != null and not weapons.torpedoes.is_empty():
		weapons.step(dt, sim_time, world["targets"])
	_advance_ping_session()


## 为某个传感器生成一次测量（针对所有目标）。
## S1-00（GAP-DATA-01/02）：
##   - 主动阵（array_type=="active"）绝不在本函数自动产测量——唯一玩家路径是
##     issue_ping() → PingSession → 回波到达 → generate_active（REQ-03）；否则
##     同一项目同时存在"显式 Ping"与"自动主动测量"两套矛盾链路。
##   - 未探测样本（detected=false）绝不 append 进 measurements——miss 不携带
##     未加噪真方位进入玩家链。
func _emit_for_sensor(sensor: RefCounted) -> void:
	if str(sensor.array_type) == "active":
		return  # 主动阵只由 PingSession 驱动（REQ-03），跳过自动旁路
	var gen: RefCounted = world["generator"]
	for t in world["targets"]:
		var ac: RefCounted = world["target_acs"][t.id]
		var m: Measurement = gen.generate_passive(world["own"], t, ac, sensor, sim_time)
		if m.detected:
			measurements.append(m)


## 推进 n 个固定步长。
func run_steps(n: int) -> void:
	for i in range(n):
		tick()


func set_paused(p: bool) -> void:
	_paused = p


func is_paused() -> bool:
	return _paused


func set_time_scale(scale: float) -> void:
	_time_scale = maxf(scale, 1.0)


func time_scale() -> float:
	return _time_scale


## 当前所有测量（只读）。调试时可按需过滤。
func measurement_count() -> int:
	return measurements.size()


# ------------------------------------------------------------------
#  主动声呐 Ping（S1-04B PingSession）
#  单在途状态机：READY →(issue_ping) LISTENING →(全部回波结算/监听窗口
#  结束) RETURN | NO_RETURN →(冷却到) READY。UNAVAILABLE = 无硬件。
#  铁律（REQ-16/17/19/20）：
#    - 单在途：新 Ping 绝不清空未返回回波、绝不覆盖在途会话；
#    - 测距即测时：R_meas 以发射时刻登记距离（c·τ/2 静态近似）为基准，
#      到达时绝不读当前 Truth 距离回填；τ 内目标位移并入 range_sigma；
#    - 无显式硬件（own_ship.active_sonar 或 sensors 含 active 阵）→
#      UNAVAILABLE，禁止 Ping，绝不自动构造缺省主动阵。
# ------------------------------------------------------------------


## 是否有主动阵硬件（REQ-20）。无硬件 → UNAVAILABLE 并禁用 Ping。
func ping_available() -> bool:
	return ping_hardware


## 当前 PingSession 状态：UNAVAILABLE / READY / LISTENING / RETURN / NO_RETURN。
func ping_state_name() -> String:
	if not ping_hardware:
		return "UNAVAILABLE"
	if _ping_session.is_empty():
		return "READY"
	return str(_ping_session.get("state", "READY"))


## 当前在途 PingSession id（无在途返回 -1）。主动测量用 ping_id 溯源。
func ping_session_id() -> int:
	if _ping_session.is_empty():
		return -1
	return int(_ping_session.get("ping_id", -1))


## 本艇最近一次发射时刻（无在途返回 -1）。本艇事实，供 UI 显示
## TRANSMITTING→LISTENING 相位（S1-04C-REQ-01 徽标，非目标 Truth）。
func ping_emit_time() -> float:
	if _ping_session.is_empty():
		return -1.0
	return float(_ping_session.get("emit_t", -1.0))


## 当前是否可发起 Ping：有硬件 + 无在途 PingSession（单在途，REQ-16/17）。
func can_ping() -> bool:
	return ping_hardware and _ping_session.is_empty()


## 距下一次可 Ping 的剩余冷却秒数（READY/UNAVAILABLE 返回 0）。
func ping_cooldown_remaining() -> float:
	if _ping_session.is_empty():
		return 0.0
	return maxf(float(_ping_session.get("cooldown_until", sim_time)) - sim_time, 0.0)


## 主动脉冲中心频率（Hz，参数展示用，S1-04C-REQ-01 卡片）。
func ping_center_freq_hz() -> float:
	return 0.5 * (ping_freq_min_hz + ping_freq_max_hz)


## 主动脉冲带宽（Hz）。
func _ping_bandwidth_hz() -> float:
	return maxf(ping_freq_max_hz - ping_freq_min_hz, 1.0)


## 配置监听窗对应的最大可测距（m）：R_max = c·T_listen/2（REQ-04）。
## 监听窗固定来自本艇配置，绝不随场景目标/Truth 距离变化。
func ping_max_range_m() -> float:
	return 0.5 * ping_sound_speed_m_s * ping_listen_window_s


## 玩家发起一次主动脉冲（S1-04B/S1-04C）。发射瞬间按各目标当前几何距离登记
## 在途回波（R=c·τ/2 静态基准），会话进入 LISTENING；每个回波在各自
## arrive_t = emit + 2R/c 结算（检测 + 测距 + 进测量流）。
## REQ-04（固定监听窗）：listen_end_t = emit_t + configured_listen_window_s，
## 绝不用最远 Truth 目标的 τ 延长监听窗；arrive_t 超出窗口的回波在窗口
## 到期时丢弃（不可接收），不延长状态机。
## REQ-05：发射成功即记录一条 ActiveEmissionEvent（本艇发射事实）。
## 无硬件 / 在途未清 / 冷却中返回 false（不发脉冲、不推进冷却）。
func issue_ping() -> bool:
	if not can_ping():
		return false
	var own: TruthEntity = world["own"]
	var sensor: SensorArray = _ping_sensor()
	var echoes: Array = []
	for t in world["targets"]:
		var rng_m: float = NavUtils.distance(
			own.position_east_m, own.position_north_m, t.position_east_m, t.position_north_m
		)
		var tau_s: float = AcousticService.echo_travel_time_s(rng_m, ping_sound_speed_m_s)
		(
			echoes
			. append(
				{
					"target_id": str(t.id),
					"arrive_t": sim_time + tau_s,
					"range_ref_m": rng_m,  # 发射时刻登记距离（测距同源基准）
					"range_ref_time_s": sim_time,
					"settled": false,
					"dropped": false,  # 超出监听窗被丢弃（REQ-04，不可接收）
					"detected": false,
					"se_db": 0.0,
					"pd": 0.0,
					"bearing_deg": 0.0,
					"range_m": -1.0,
					"range_sigma_m": -1.0,
				}
			)
		)
	var listen_end: float = sim_time + ping_listen_window_s
	_ping_session = {
		"state": "LISTENING",
		"ping_id": _next_ping_id,
		"emit_t": sim_time,
		# REQ-04 固定监听窗：只由本艇配置决定，不读任何目标 Truth。
		"listen_end_t": listen_end,
		"cooldown_until": sim_time + ping_cooldown_s,
		"echoes": echoes,
		"returned_count": 0,
		"sensor": sensor,
	}
	_next_ping_id += 1
	# REQ-05：发射成功记录 ActiveEmissionEvent（本艇发射事实）。
	(
		active_emissions
		. append(
			{
				"emitter_internal_ref": "own",
				"emit_time": sim_time,
				"source_position_internal":
				{
					"e": own.position_east_m,
					"n": own.position_north_m,
				},
				"center_frequency_hz": ping_center_freq_hz(),
				"bandwidth_hz": _ping_bandwidth_hz(),
				"source_level_db": ping_sl_db,
				"pulse_duration_s": ping_pulse_duration_s,
			}
		)
	)
	return true


## 未返回（未结算）回波数。Truth 钩子：仅供无头测试/统计，
## 禁止 UI 据此显示目标存在或回波倒计时（Truth 隔离，ISSUE-06）。
func pending_echo_count() -> int:
	if _ping_session.is_empty():
		return 0
	var n: int = 0
	for e in _ping_session["echoes"]:
		if not bool(e["settled"]):
			n += 1
	return n


## 距最早未返回回波到达的剩余秒数；无在途返回 INF。
## Truth 钩子：仅供无头测试/统计，禁止 UI 使用（ISSUE-06）。
func next_echo_in() -> float:
	if _ping_session.is_empty():
		return INF
	var earliest: float = INF
	for e in _ping_session["echoes"]:
		if not bool(e["settled"]):
			earliest = minf(earliest, float(e["arrive_t"]))
	if earliest == INF:
		return INF
	return maxf(earliest - sim_time, 0.0)


## 结算所有已到达回波并取走新结果摘要（UI 控制器每帧轮询即可，无需信号）。
## 返回 [{target_id, ping_id, detected, se_db, pd, bearing_deg, range_m,
##        range_sigma_m, measurement}]；detected 的 Measurement 在到达时刻
## 生成并 append 进 measurements（测量时刻=回波到达时刻）。
## 结算在 tick()/本函数都触发（幂等：settled 标记去重）。结果缓冲独立于
## 会话存活：会话提前清空（冷却/READY）也不丢已结算摘要。
func take_arrived_echoes() -> Array:
	if not _ping_session.is_empty():
		_settle_due_echoes()
	var out: Array = _ping_results
	_ping_results = []
	return out


## 推进 PingSession（tick 每步调用）：结算到点回波 + 状态转移。
func _advance_ping_session() -> void:
	if _ping_session.is_empty():
		return
	_settle_due_echoes()
	var st: String = str(_ping_session["state"])
	if st == "LISTENING":
		if _ping_listen_done():
			# 监听窗结束：丢弃仍未到达/超出窗口的回波（REQ-04，不可接收），
			# 再按已返回 detected 数判 RETURN/NO_RETURN。窗口不因远目标延长。
			_drop_unsettled_echoes()
			_ping_session["state"] = (
				"RETURN" if int(_ping_session["returned_count"]) > 0 else "NO_RETURN"
			)
	elif st == "RETURN" or st == "NO_RETURN":
		# 冷却结束 → 回到 READY（会话清空，单在途释放）
		if sim_time >= float(_ping_session["cooldown_until"]) - 1e-9:
			_ping_session = {}


## 监听是否结束（REQ-04 固定监听窗）：
##   - 窗口（configured_listen_window_s）到期即结束——与登记了多少/多远回波
##     无关，绝不因最远 Truth 目标 τ 拉长 LISTENING；
##   - 窗口内若全部登记回波已提前结算（无超窗残留）也可提前结束。
func _ping_listen_done() -> bool:
	var echoes: Array = _ping_session["echoes"]
	if sim_time >= float(_ping_session["listen_end_t"]) - 1e-9:
		return true
	if echoes.is_empty():
		return false
	for e in echoes:
		if not bool(e["settled"]):
			return false
	return true


## 监听窗到期：把仍未结算（未到达/超窗）的回波标记为 dropped（不可接收）。
## 它们不得再被结算（settled=true 拦截），也不进入 returned_count/测量流。
func _drop_unsettled_echoes() -> void:
	var echoes: Array = _ping_session["echoes"]
	for e in echoes:
		if bool(e["settled"]):
			continue
		e["settled"] = true
		e["dropped"] = true
		e["detected"] = false


## 结算已到点（sim_time >= arrive_t）的登记回波。测距以发射时刻登记的
## range_ref_m 为基准（REQ-19 往返测距同源），到达时刻只做检测/测距噪声
## 注入，绝不读当前 Truth 距离回填。未探测到也产出 summary（detected=false）。
func _settle_due_echoes() -> void:
	if _ping_session.is_empty():
		return
	if str(_ping_session["state"]) != "LISTENING":
		return
	var echoes: Array = _ping_session["echoes"]
	var sensor: SensorArray = _ping_session.get("sensor", null)
	var gen: MeasurementGenerator = world["generator"]
	var own: TruthEntity = world["own"]
	var ping_id: int = int(_ping_session["ping_id"])
	for e in echoes:
		if bool(e["settled"]):
			continue
		# REQ-04：超出固定监听窗的回波不可接收——即使 tick 恰好越过窗口也不结算。
		if float(e["arrive_t"]) > float(_ping_session["listen_end_t"]) + 1e-9:
			continue
		if sim_time < float(e["arrive_t"]) - 1e-9:
			continue
		e["settled"] = true
		var target: TruthEntity = null
		for t in world["targets"]:
			if str(t.id) == str(e["target_id"]):
				target = t
				break
		if target == null:
			continue
		var ac: AcousticProfile = world["target_acs"][target.id]
		var m: Measurement = (
			gen
			. generate_active(
				own,
				target,
				ac,
				sensor,
				ping_sl_db,
				sim_time,
				ping_id,
				float(e["range_ref_m"]),
				float(e["range_ref_time_s"]),
			)
		)
		var detected: bool = m.detected
		e["detected"] = detected
		e["se_db"] = m.signal_excess_db
		e["pd"] = m.detection_probability
		e["bearing_deg"] = m.measured_bearing_deg
		e["range_m"] = m.measured_range_m
		e["range_sigma_m"] = m.range_sigma_m
		var summary := {
			"target_id": str(target.id),
			"ping_id": ping_id,
			"detected": detected,
			"se_db": m.signal_excess_db,
			"pd": m.detection_probability,
			"bearing_deg": m.measured_bearing_deg,
			"range_m": m.measured_range_m,
			"range_sigma_m": m.range_sigma_m,
			"measurement": m,
		}
		_ping_results.append(summary)
		if detected:
			_ping_session["returned_count"] = int(_ping_session["returned_count"]) + 1
			measurements.append(m)


## 本次 ping 使用的主动阵：场景 sensors 含 array_type=="active" 则复用它；
## 否则按 own_ship.active_sonar 显式配置物化艇首主动阵。仅在 ping_hardware
## 为真时可到达——无硬件绝不自动构造（REQ-20）。
func _ping_sensor() -> SensorArray:
	for s in world["sensors"]:
		if str(s.array_type) == "active":
			return s
	var s := SensorArray.new()
	(
		s
		. from_dict(
			{
				"sensor_id": ACTIVE_SENSOR_ID,
				"array_type": "active",
				"owner_id": str(world["own"].id),
				"freq_min_hz": ping_freq_min_hz,
				"freq_max_hz": ping_freq_max_hz,
				"array_gain_db": ping_array_gain_db,
				"detection_threshold_db": 0.0,
			}
		)
	)
	s.set_rng(world["rng"])
	return s
