extends SceneTree
## wire_guidance_test.gd — S1-07 Commit 4 WireLink 与 fallback 无头验收（§14.1 WPN-WIRE）。
##
## 覆盖（S1-07 §5.4/§5.5）：
##   WPN-WIRE-01  导线 CONNECTED 时 course/depth band/speed/active_tx/autonomy
##                命令全部生效（只改 commanded_*/状态，实际按速率逼近）；
##                命令记入 command_log（§5.1 不改写发射程序）。
##   WPN-WIRE-02  实际航向按 max_turn_rate 渐进、深度按 Vz_max 渐进——无瞬时
##                转向/瞬移换层；每个 tick 的增量有界。
##   WPN-WIRE-03  CUT 后与超长 BROKEN 后一律拒绝新命令（course/depth/active/
##                autonomy/return/cut）。
##   WPN-WIRE-04  断线执行 fallback：保持航向渐进转预设搜索中心 → 预设搜索
##                深度带 → 按预设距离开主动 TX → 按预设距离授权自主（AUTONOMOUS）；
##                全部确定性、无 Truth。
##
## 另含 WireLink 单元断言（放线累计/超长确定性断线/cut 门）。可无头运行：
##   godot --headless --path games/sonar --script res://tools/wire_guidance_test.gd

const DT: float = 0.5
const CRUISE_MS: float = 40.0 * 0.514444  # ~20.58 m/s（NavUtils.KNOT_TO_MS 同源）


func _initialize() -> void:
	var fails: Array = []
	var sim_t: float = 100.0
	_wire_link_units(fails)
	_wpn_wire_01_commands(fails, sim_t)
	_wpn_wire_02_rate_limits(fails, sim_t)
	_wpn_wire_03_reject_after_cut(fails, sim_t)
	_wpn_wire_03b_reject_after_break(fails, sim_t)
	_wpn_wire_04_fallback(fails, sim_t)
	_finish(fails)


## ---- WireLink 单元 ----
func _wire_link_units(fails: Array) -> void:
	# WL-1 放线累计 + 超长确定性断线
	var wl := WireLink.new()
	wl.reset()
	wl.max_length_m = 100.0
	var broke: bool = wl.update(10.0, 5.0)
	_assert_bool(fails, "WL-1a no break under limit", broke, false)
	_assert_float(fails, "WL-1b paid out", wl.paid_out_m, 50.0, 1e-6)
	_assert_eq(fails, "WL-1c still connected", wl.state, WireLink.State.CONNECTED)
	broke = wl.update(11.0, 5.0)  # 50+55=105 > 100
	_assert_bool(fails, "WL-1d break on excess", broke, true)
	_assert_eq(fails, "WL-1e state broken", wl.state, WireLink.State.BROKEN)
	_assert_bool(fails, "WL-1f commands refused after break", wl.accepts_commands(), false)
	# WL-2 break_on_excess_length=false：超长也不断（只继续放线）
	var wl2 := WireLink.new()
	wl2.reset()
	wl2.max_length_m = 100.0
	wl2.break_on_excess_length = false
	_assert_bool(fails, "WL-2a no break policy", wl2.update(30.0, 5.0), false)
	_assert_float(fails, "WL-2b paid past max", wl2.paid_out_m, 150.0, 1e-6)
	_assert_eq(fails, "WL-2c still connected", wl2.state, WireLink.State.CONNECTED)
	# WL-3 cut 只从 CONNECTED 生效
	var wl3 := WireLink.new()
	wl3.reset()
	_assert_bool(fails, "WL-3a cut ok", wl3.cut(), true)
	_assert_eq(fails, "WL-3b state cut", wl3.state, WireLink.State.CUT)
	_assert_bool(fails, "WL-3c second cut refused", wl3.cut(), false)
	# WL-4 enabled=false：命令门关闭（等效无导线）
	var wl4 := WireLink.new()
	wl4.reset()
	wl4.enabled = false
	_assert_bool(fails, "WL-4a disabled refuses commands", wl4.accepts_commands(), false)
	_assert_bool(fails, "WL-4b disabled cannot cut", wl4.cut(), false)


## ---- WPN-WIRE-01 连接中命令生效 ----
func _wpn_wire_01_commands(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var tp := Torpedo.new()
	tp.launch("W1", _mk_program(0.0, WeaponProgram.DEPTH_BAND_UPPER), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp.step(DT, sim_t, null)
		sim_t += DT
	_assert_eq(fails, "WIRE-01a in wire run", tp.mission_state, Torpedo.MissionState.WIRE_RUN)
	_assert_bool(fails, "WIRE-01b course cmd", tp.command_course(90.0), true)
	_assert_bool(
		fails, "WIRE-01c depth cmd", tp.command_depth_band(WeaponProgram.DEPTH_BAND_LOWER), true
	)
	_assert_float(fails, "WIRE-01d cmd depth", tp.commanded_depth_m, 180.0, 1e-6)
	_assert_eq(fails, "WIRE-01e depth state diving", tp.depth_state, Torpedo.DepthState.DIVING)
	_assert_bool(
		fails, "WIRE-01f speed cmd", tp.command_speed_mode(WeaponProgram.SpeedMode.HIGH), true
	)
	_assert_float(fails, "WIRE-01g speed now", tp.speed_kn, 50.0, 1e-6)
	_assert_bool(fails, "WIRE-01h active on", tp.set_active_tx(true), true)
	_assert_eq(
		fails, "WIRE-01i tx waiting", tp.active_tx_state, Torpedo.ActiveTxState.WAITING_TRIGGER
	)
	_assert_bool(fails, "WIRE-01j authorize", tp.authorize_autonomy(), true)
	_assert_eq(
		fails, "WIRE-01k authority", tp.guidance_authority, Torpedo.GuidanceAuthority.AUTONOMOUS
	)
	_assert_bool(fails, "WIRE-01l return wire only", tp.return_to_wire_only(), true)
	_assert_eq(
		fails, "WIRE-01m authority back", tp.guidance_authority, Torpedo.GuidanceAuthority.WIRE_ONLY
	)
	# 命令日志：至少 6 条且第一条为 SET_COURSE（§5.1 CommandLog）
	if tp.command_log.size() < 6:
		fails.append("WIRE-01n command_log too short (%d)" % tp.command_log.size())
	elif str(tp.command_log[0]["cmd"]) != "SET_COURSE":
		fails.append("WIRE-01o first log not SET_COURSE")
	# 命令不改发射程序快照
	if tp.program.initial_course_deg != 0.0:
		fails.append("WIRE-01p wire cmd mutated launch program")


## ---- WPN-WIRE-02 实际值按速率逼近（无瞬移）----
func _wpn_wire_02_rate_limits(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var tp := Torpedo.new()
	tp.launch("W2", _mk_program(0.0, WeaponProgram.DEPTH_BAND_UPPER), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp.step(DT, sim_t, null)
		sim_t += DT
	# 航向 0→180，max_turn_rate 6°/s → 每 0.5s tick ≤3°
	_assert_bool(fails, "WIRE-02a course cmd", tp.command_course(180.0), true)
	var max_turn: float = 0.0
	var reached: bool = false
	var guard: int = 0
	while guard < 300:
		var before: float = tp.course_deg
		tp.step(DT, sim_t, null)
		sim_t += DT
		var delta: float = absf(NavUtils.wrap180(tp.course_deg - before))
		max_turn = maxf(max_turn, delta)
		if absf(NavUtils.wrap180(tp.course_deg - 180.0)) < 0.5:
			reached = true
			break
		guard += 1
	_assert_bool(fails, "WIRE-02b course reached", reached, true)
	if max_turn > 3.0 + 1e-3:
		fails.append("WIRE-02c per-tick turn %.3f deg exceeds turn-rate limit" % max_turn)
	if guard < 58:
		fails.append("WIRE-02d course slewed too fast (ticks=%d)" % guard)
	# 深度 50→180（Vz=2m/s → 每 0.5s tick ≤1m，理论 130 tick）
	var tp2 := Torpedo.new()
	tp2.launch("W2D", _mk_program(0.0, WeaponProgram.DEPTH_BAND_UPPER), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp2.step(DT, sim_t, null)
		sim_t += DT
	_assert_bool(
		fails, "WIRE-02e depth cmd", tp2.command_depth_band(WeaponProgram.DEPTH_BAND_LOWER), true
	)
	var max_dz: float = 0.0
	var arrived: bool = false
	var ticks: int = 0
	for i in range(300):
		var before: float = tp2.actual_depth_m
		tp2.step(DT, sim_t, null)
		sim_t += DT
		max_dz = maxf(max_dz, absf(tp2.actual_depth_m - before))
		ticks += 1
		if tp2.commanded_depth_m < 0.0 and absf(tp2.actual_depth_m - 180.0) < 1.0:
			arrived = true
			break
	_assert_bool(fails, "WIRE-02f depth reached", arrived, true)
	if max_dz > 1.0 + 1e-3:
		fails.append("WIRE-02g per-tick dz %.3f m exceeds Vz limit" % max_dz)
	if ticks < 128:
		fails.append("WIRE-02h depth change too fast (ticks=%d)" % ticks)


## ---- WPN-WIRE-03 CUT 后拒绝新命令 ----
func _wpn_wire_03_reject_after_cut(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var tp := Torpedo.new()
	tp.launch("W3", _mk_program(0.0, WeaponProgram.DEPTH_BAND_UPPER), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp.step(DT, sim_t, null)
		sim_t += DT
	_assert_bool(fails, "WIRE-03a cut ok", tp.cut_wire(), true)
	_assert_eq(fails, "WIRE-03b state cut", tp.wire_link.state, WireLink.State.CUT)
	_assert_bool(fails, "WIRE-03c course refused", tp.command_course(90.0), false)
	_assert_bool(
		fails,
		"WIRE-03d depth refused",
		tp.command_depth_band(WeaponProgram.DEPTH_BAND_LOWER),
		false
	)
	_assert_bool(
		fails, "WIRE-03e speed refused", tp.command_speed_mode(WeaponProgram.SpeedMode.HIGH), false
	)
	_assert_bool(fails, "WIRE-03f active on refused", tp.set_active_tx(true), false)
	_assert_bool(fails, "WIRE-03g active off refused", tp.set_active_tx(false), false)
	_assert_bool(fails, "WIRE-03h autonomy refused", tp.authorize_autonomy(), false)
	_assert_bool(fails, "WIRE-03i return refused", tp.return_to_wire_only(), false)
	_assert_bool(fails, "WIRE-03j second cut refused", tp.cut_wire(), false)


## ---- WPN-WIRE-03b 超长确定性 BROKEN 后拒绝新命令并触发 fallback ----
func _wpn_wire_03b_reject_after_break(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var tp := Torpedo.new()
	tp.launch("W3B", _mk_program(0.0, WeaponProgram.DEPTH_BAND_UPPER), 0.0, 0.0, 50.0, sim_t)
	tp.wire_link.max_length_m = 150.0
	var kinds: Dictionary = {}
	tp.event_occurred.connect(func(_tid: String, kind: String, _d: Dictionary): kinds[kind] = true)
	# 出管（2 tick）+ 跑到 150m 超长断线：CRUISE ~20.58m/s → 约 8s
	var guard: int = 0
	while tp.wire_link.state != WireLink.State.BROKEN and guard < 120:
		tp.step(DT, sim_t, null)
		sim_t += DT
		guard += 1
	_assert_eq(fails, "WIRE-03b1 broken by length", tp.wire_link.state, WireLink.State.BROKEN)
	if tp.wire_link.paid_out_m <= 150.0:
		fails.append("WIRE-03b2 paid_out not past max (%.1f)" % tp.wire_link.paid_out_m)
	if not kinds.has("WIRE_BROKEN"):
		fails.append("WIRE-03b3 no WIRE_BROKEN event")
	if not kinds.has("FALLBACK"):
		fails.append("WIRE-03b4 no FALLBACK event after break")
	_assert_bool(fails, "WIRE-03b5 course refused", tp.command_course(90.0), false)
	_assert_bool(fails, "WIRE-03b6 active refused", tp.set_active_tx(true), false)


## ---- WPN-WIRE-04 断线执行 fallback（§5.5）----
func _wpn_wire_04_fallback(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var fb := _mk_fallback(
		WeaponProgram.DEPTH_BAND_LOWER,  # search depth band：断线后下潜 LOWER
		250.0,  # autonomy 预设距离
		150.0,  # active TX 预设距离
		20.0,  # 预设搜索中心航向
	)
	var p := _mk_program(0.0, WeaponProgram.DEPTH_BAND_UPPER, fb)
	var tp := Torpedo.new()
	tp.launch("W4", p, 0.0, 0.0, 50.0, sim_t)
	var kinds: Dictionary = {}
	var tx_pings: Array = []  # 引用语义：lambda 内 append 才对外层可见（值捕获坑）
	tp.event_occurred.connect(
		func(_tid: String, kind: String, _d: Dictionary):
			kinds[kind] = true
			if kind == "ACTIVE_TX_PING":
				tx_pings.append(kind)
	)
	for i in range(3):
		tp.step(DT, sim_t, null)
		sim_t += DT
	if tp.mission_state != Torpedo.MissionState.WIRE_RUN:
		fails.append("WIRE-04a not wire run before cut")
	# 玩家切断 → fallback
	_assert_bool(fails, "WIRE-04b cut ok", tp.cut_wire(), true)
	_assert_eq(fails, "WIRE-04c state cut", tp.wire_link.state, WireLink.State.CUT)
	if not kinds.has("FALLBACK"):
		fails.append("WIRE-04d no FALLBACK event")
	if tp.mission_state != Torpedo.MissionState.SEARCH:
		fails.append("WIRE-04e mission not SEARCH after fallback")
	# 预设搜索深度带命令已下发（LOWER → 180m hold）
	if tp.commanded_depth_band != WeaponProgram.DEPTH_BAND_LOWER:
		fails.append("WIRE-04f depth band not LOWER")
	_assert_float(fails, "WIRE-04g cmd depth", tp.commanded_depth_m, 180.0, 1e-6)
	_assert_eq(fails, "WIRE-04h diving", tp.depth_state, Torpedo.DepthState.DIVING)
	# 断线后命令一律拒绝
	_assert_bool(fails, "WIRE-04i course refused after cut", tp.command_course(50.0), false)
	# 推进：航向渐进转向预设搜索中心 20°（每 tick ≤3°），无瞬时跳变
	var max_turn: float = 0.0
	var saw_active_ping: bool = false
	var autonomy_authorized: bool = false
	var guard: int = 0
	while guard < 240:
		var before: float = tp.course_deg
		tp.step(DT, sim_t, null)
		sim_t += DT
		max_turn = maxf(max_turn, absf(NavUtils.wrap180(tp.course_deg - before)))
		if tx_pings.size() >= 1:
			saw_active_ping = true
		if tp.guidance_authority == Torpedo.GuidanceAuthority.AUTONOMOUS:
			autonomy_authorized = true
		if saw_active_ping and autonomy_authorized and absf(tp.course_deg - 20.0) < 0.5:
			break
		guard += 1
	_assert_bool(fails, "WIRE-04j active ping by preset distance", saw_active_ping, true)
	_assert_bool(fails, "WIRE-04k autonomy by preset distance", autonomy_authorized, true)
	if max_turn > 3.0 + 1e-3:
		fails.append("WIRE-04m fallback turn exceeded rate (%.3f)" % max_turn)
	# 深度实际按 Vz 下潜（无瞬移），最终应到达 LOWER hold
	if tp.actual_depth_m <= 50.0:
		fails.append("WIRE-04n depth never moved after fallback")
	# 日志含 CUT_WIRE 与 FALLBACK（CommandLog）
	var log_kinds: Array = []
	for e in tp.command_log:
		log_kinds.append(str(e["cmd"]))
	if not log_kinds.has("CUT_WIRE"):
		fails.append("WIRE-04o no CUT_WIRE in log")
	if not log_kinds.has("FALLBACK"):
		fails.append("WIRE-04p no FALLBACK in log")


## ---- 构造 ----
func _mk_program(course: float, band: String, fb: WeaponProgram = null) -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.MANUAL
	p.initial_course_deg = course
	p.speed_mode = WeaponProgram.SpeedMode.CRUISE
	p.initial_depth_band = band
	p.search_depth_band = band
	p.search_center_deg = course
	p.search_half_angle_deg = 60.0
	p.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	p.wire_guidance_enabled = true
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 300.0
	p.fallback_program = fb if fb != null else p.make_default_fallback()
	return p


func _mk_fallback(
	search_band: String, autonomy_dist: float, active_dist: float, center: float
) -> WeaponProgram:
	var fb := WeaponProgram.new()
	fb.fire_mode = WeaponProgram.FireMode.MANUAL
	fb.initial_course_deg = center
	fb.initial_depth_band = search_band
	fb.search_depth_band = search_band
	fb.search_center_deg = center
	fb.search_half_angle_deg = 60.0
	fb.speed_mode = WeaponProgram.SpeedMode.CRUISE
	fb.guidance_authority = WeaponProgram.GuidanceAuthority.AUTONOMOUS
	fb.wire_guidance_enabled = false
	fb.active_enable_mode = WeaponProgram.ActiveEnableMode.DISTANCE
	fb.active_enable_distance_m = active_dist
	fb.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	fb.autonomy_enable_distance_m = autonomy_dist
	fb.warhead_arm_distance_m = 300.0
	return fb


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
		print("WIRE_FAIL ", f)
	if fails.is_empty():
		print("WIRE_GUIDANCE_TEST result=PASS")
	else:
		print("WIRE_GUIDANCE_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
