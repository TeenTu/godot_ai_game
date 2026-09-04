extends SceneTree
## s1_07_state_model_test.gd — S1-07 Commit 1 正交状态模型 + WeaponProgram 无头验收。
##
## 覆盖（S1-07 §3 / §5 / §17 本批范围）：
##   SM1  发射后默认正交状态：MissionState→WIRE_RUN、SeekerState=PASSIVE_LISTEN、
##        ActiveTxState=OFF、WireState=CONNECTED、Guidance=WIRE_ONLY、Fuze=SAFE
##        （REQ-DECISION-01/02：被动默认 ON、主动默认 OFF，互不耦合）。
##   SM2  WeaponProgram 快照不可变：发射后修改原程序不影响在水鱼雷。
##   SM3  Guidance API 不接受 TruthEntity：step() 只收 TorpedoContext；鱼雷
##        直航不因任何 Truth 目标而转向、无 ACQUIRE/HIT 事件、事件不带 target_id。
##   SM4  引信独立解保：FUZE 按 arm distance 从 SAFE→ARMED，与主动/自主解耦。
##   SM5  线控命令通道：CONNECTED 时 course/active_tx/autonomy 命令生效；
##        CUT 后一律拒绝并给事件。
##   SM6  主动发射机状态机占位：OFF→WAITING_TRIGGER(手动开启)→PINGING→COOLDOWN→
##        PINGING（周期占位），ACTIVE_TX 事件可观测。
##   SM7  深度带命令走 commanded/actual 分离（S1-07A）：DIVING 需有限时间，
##        无瞬移换层。
##
## 全部确定性，可无头运行：
##   godot --headless --path games/sonar --script res://tools/s1_07_state_model_test.gd

const DT: float = 0.5


func _mk_program(course: float) -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.SOLUTION
	p.initial_course_deg = course
	p.speed_mode = WeaponProgram.SpeedMode.CRUISE
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_center_deg = course
	p.search_half_angle_deg = 30.0
	p.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 300.0
	p.fallback_program = p.make_default_fallback()
	return p


func _initialize() -> void:
	var fails: Array = []
	var sim_t: float = 100.0

	# ---- SM1 默认正交状态 + SM2 快照不可变 + SM4 引信 ----
	var p := _mk_program(45.0)
	var tp := Torpedo.new()
	tp.launch("T1", p, 0.0, 0.0, 50.0, sim_t)
	# 快照不可变：发射后改原程序
	p.initial_course_deg = 180.0
	p.fallback_program.initial_course_deg = 200.0
	_assert_eq(fails, "SM1a mission after launch", tp.mission_state, Torpedo.MissionState.LAUNCHING)
	_assert_eq(fails, "SM1b seeker default", tp.seeker_state, Torpedo.SeekerState.PASSIVE_LISTEN)
	_assert_eq(fails, "SM1c active_tx default", tp.active_tx_state, Torpedo.ActiveTxState.OFF)
	_assert_eq(fails, "SM1d wire default", tp.wire_link.state, WireLink.State.CONNECTED)
	_assert_eq(
		fails, "SM1e guidance default", tp.guidance_authority, Torpedo.GuidanceAuthority.WIRE_ONLY
	)
	_assert_eq(fails, "SM1f fuze default", tp.fuze_state, Torpedo.FuzeState.SAFE)
	if tp.program == null:
		fails.append("SM2 program null")
	else:
		_assert_float(fails, "SM2 course snapshot", tp.program.initial_course_deg, 45.0, 1e-6)
		if tp.program.fallback_program == null:
			fails.append("SM2 fallback null")
		else:
			_assert_float(
				fails,
				"SM2 fallback snapshot",
				tp.program.fallback_program.initial_course_deg,
				45.0,
				1e-6,
			)

	# ---- SM3 Truth 隔离：直航不受 Truth 影响（本类 API 无 targets 入参）----
	# step 只收 TorpedoContext；这里显式传 null ctx 也应稳定直航。
	var course_start: float = tp.course_deg
	var events: Dictionary = {}
	tp.event_occurred.connect(
		func(_tid: String, kind: String, d: Dictionary):
			events[kind] = true
			if d.has("target_id"):
				events["__TARGET_ID_LEAK__"] = true
	)
	var ev: bool = tp.step(DT, sim_t + DT, null)
	sim_t += DT
	_assert_bool(fails, "SM1g step ok", ev, false)
	# LAUNCH_TRANSITION_S=1.0：第 1 步(0.5s)仍 LAUNCHING，第 2 步后 WIRE_RUN
	if tp.mission_state != Torpedo.MissionState.LAUNCHING:
		fails.append("SM1g2 mission left LAUNCHING too early")
	tp.step(DT, sim_t + DT, null)
	sim_t += DT
	if tp.mission_state != Torpedo.MissionState.WIRE_RUN:
		fails.append("SM1h did not reach WIRE_RUN after launch transition")
	# 直航 60s：航向不变、无任何捕获/命中类事件、无 target_id 泄漏
	for i in range(120):
		tp.step(DT, sim_t, null)
		sim_t += DT
	_assert_float(fails, "SM3 course straight", tp.course_deg, course_start, 1e-6)
	if events.has("ACQUIRE") or events.has("HIT") or events.has("PURSUIT"):
		fails.append("SM3 truth-coupled events appeared (ACQUIRE/HIT)")
	if events.has("__TARGET_ID_LEAK__"):
		fails.append("SM3 event leaked target_id")

	# ---- SM4 引信独立解保（arm 300m，CRUISE ~20.6m/s → ~15s）----
	var guard: int = 0
	while tp.fuze_state == Torpedo.FuzeState.SAFE and guard < 200:
		tp.step(DT, sim_t, null)
		sim_t += DT
		guard += 1
	if tp.fuze_state != Torpedo.FuzeState.ARMED:
		fails.append("SM4 fuze never ARMED")
	if not events.has("FUZE_ARMED"):
		fails.append("SM4b no FUZE_ARMED event")
	# 引信解保期间任务仍 WIRE_RUN、主动仍 OFF（解耦）
	if tp.mission_state != Torpedo.MissionState.WIRE_RUN:
		fails.append("SM4c fuze arming changed mission state")
	if tp.active_tx_state != Torpedo.ActiveTxState.OFF:
		fails.append("SM4d fuze arming changed active_tx")

	# ---- SM5 线控命令 + 断线拒绝 ----
	var tp2 := Torpedo.new()
	tp2.launch("T2", _mk_program(0.0), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp2.step(DT, sim_t, null)
		sim_t += DT
	_assert_bool(fails, "SM5a course cmd accepted", tp2.command_course(30.0), true)
	for i in range(5):
		tp2.step(DT, sim_t, null)
		sim_t += DT
	if tp2.course_deg <= 0.0 or tp2.course_deg >= 30.0:
		fails.append("SM5b course did not slew toward cmd (got %.1f)" % tp2.course_deg)
	_assert_bool(fails, "SM5c authorize autonomy", tp2.authorize_autonomy(), true)
	_assert_eq(
		fails, "SM5d authority now", tp2.guidance_authority, Torpedo.GuidanceAuthority.AUTONOMOUS
	)
	_assert_bool(fails, "SM5e return wire-only", tp2.return_to_wire_only(), true)
	_assert_bool(fails, "SM5f cut wire", tp2.cut_wire(), true)
	_assert_bool(fails, "SM5g course cmd after cut", tp2.command_course(90.0), false)
	_assert_bool(fails, "SM5h active_tx after cut", tp2.set_active_tx(true), false)
	_assert_bool(fails, "SM5i autonomy after cut", tp2.authorize_autonomy(), false)

	# ---- SM6 主动发射机占位状态机（MANUAL：命令开启）----
	var tp3 := Torpedo.new()
	tp3.launch("T3", _mk_program(90.0), 0.0, 0.0, 50.0, sim_t)
	var tx_events: Array = []
	tp3.event_occurred.connect(
		func(_tid: String, kind: String, _d: Dictionary):
			if kind.begins_with("ACTIVE_TX"):
				tx_events.append(kind)
	)
	for i in range(3):
		tp3.step(DT, sim_t, null)
		sim_t += DT
	_assert_eq(fails, "SM6a tx off default", tp3.active_tx_state, Torpedo.ActiveTxState.OFF)
	_assert_bool(fails, "SM6b tx on", tp3.set_active_tx(true), true)
	_assert_eq(fails, "SM6c tx waiting", tp3.active_tx_state, Torpedo.ActiveTxState.WAITING_TRIGGER)
	tp3.step(DT, sim_t, null)
	sim_t += DT
	if tp3.active_tx_state != Torpedo.ActiveTxState.PINGING:
		fails.append("SM6d tx not PINGING after manual arm")
	# PINGING(0.5s) → COOLDOWN(8s) → PINGING：跑 20s 应至少再 PING 一次
	var saw_second_ping: bool = false
	for i in range(40):
		tp3.step(DT, sim_t, null)
		sim_t += DT
		if tp3.active_tx_state == Torpedo.ActiveTxState.PINGING and tx_events.size() >= 2:
			saw_second_ping = true
	if not saw_second_ping:
		fails.append("SM6e tx never re-entered PINGING after cooldown")
	if tx_events.size() < 2:
		fails.append("SM6f fewer than 2 ACTIVE_TX_PING events")
	_assert_bool(fails, "SM6g tx off cmd", tp3.set_active_tx(false), true)
	_assert_eq(fails, "SM6h tx off state", tp3.active_tx_state, Torpedo.ActiveTxState.OFF)

	# ---- SM7 深度带命令：commanded/actual 分离，DIVING 有限时间 ----
	var tp4 := Torpedo.new()
	tp4.launch("T4", _mk_program(0.0), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp4.step(DT, sim_t, null)
		sim_t += DT
	_assert_bool(
		fails, "SM7a depth cmd lower", tp4.command_depth_band(WeaponProgram.DEPTH_BAND_LOWER), true
	)
	_assert_eq(fails, "SM7b depth state diving", tp4.depth_state, Torpedo.DepthState.DIVING)
	_assert_float(fails, "SM7c cmd depth", tp4.commanded_depth_m, 180.0, 1e-6)
	tp4.step(DT, sim_t, null)
	sim_t += DT
	if tp4.actual_depth_m <= 50.0:
		fails.append("SM7d actual depth did not start moving")
	if tp4.actual_depth_m >= 180.0:
		fails.append("SM7e instant layer change (teleport)")
	# 剩余 130m @ 2m/s = 65s → 130 步内应到达并清命令
	var arrived: bool = false
	for i in range(150):
		tp4.step(DT, sim_t, null)
		sim_t += DT
		if tp4.commanded_depth_m < 0.0 and absf(tp4.actual_depth_m - 180.0) < 1.0:
			arrived = true
			break
	if not arrived:
		fails.append("SM7f never reached lower hold depth")

	_finish(fails)


func _assert_eq(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _assert_float(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	for f in fails:
		print("SM_FAIL ", f)
	if fails.is_empty():
		print("S1_07_STATE_MODEL result=PASS")
	else:
		print("S1_07_STATE_MODEL result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
