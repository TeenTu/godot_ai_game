extends SceneTree
## weapon_program_test.gd — S1-07 Commit 3 发射模式无头验收（§14.1 WPN-PROG）。
##
## 覆盖：
##   WPN-PROG-01  无 SystemSolution 的 MANUAL 发射成功（解非发射许可）；
##                程序 fire_mode=MANUAL、initial_course=玩家航向、管 EMPTY。
##   WPN-PROG-02  只有 bearing 的 BEARING_ONLY 发射成功；初始航向/搜索中心=
##                方位、宽搜索半角（>=45°）；程序不含任何隐藏 range 字段。
##   WPN-PROG-03  SOLUTION 只负责预填：玩家修改后的快照是实际发射程序；
##                fire(sys) 构建 SOLUTION 程序，fire_program(玩家改版) 用改版。
##   WPN-PROG-04  发射后 tube=EMPTY，鱼雷结束（燃料耗尽）也不瞬时补装。
##
## 全部确定性（固定种子 stage1_basic_passive），可无头运行：
##   godot --headless --path games/sonar --script res://tools/weapon_program_test.gd

const DT: float = 0.5


func _initialize() -> void:
	var fails: Array = []
	var world := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	world.load_scenario(sc)
	world.auto_measurements = false
	_wpn_prog_01_manual(fails, world)
	_wpn_prog_02_bearing_only(fails, world)
	_wpn_prog_03_solution_prefill(fails, world)
	_wpn_prog_04_tube_empty(fails, world)
	_finish(fails)


func _mk_sys(world: World) -> SystemSolution:
	# 测试作者权限：为构造"已完美解算"的 SystemSolution 读一次 Truth。
	var wd: Dictionary = world.world
	var own: RefCounted = wd["own"]
	var tgt: RefCounted = wd["targets"][0]
	var sys := SystemSolution.new()
	sys.bearing_deg = (
		NavUtils
		. bearing_to_true(
			float(own.position_east_m),
			float(own.position_north_m),
			float(tgt.position_east_m),
			float(tgt.position_north_m),
		)
	)
	sys.range_m = (
		Vector2(
			float(tgt.position_east_m) - float(own.position_east_m),
			float(tgt.position_north_m) - float(own.position_north_m),
		)
		. length()
	)
	sys.course_deg = float(tgt.course_deg)
	sys.speed_kn = float(tgt.speed_kn)
	sys.solution_time = world.sim_time
	sys.estimated_position_east_m = float(tgt.position_east_m)
	sys.estimated_position_north_m = float(tgt.position_north_m)
	sys.confidence = 0.9
	return sys


func _wpn_prog_01_manual(fails: Array, world: World) -> void:
	var own: RefCounted = world.world["own"]
	var ws: WeaponSystem = world.weapons
	var n0: int = ws.torpedoes.size()
	var tp: Torpedo = (
		ws
		. fire_manual(
			42.0,
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
			WeaponProgram.DEPTH_BAND_LOWER,
		)
	)
	if tp == null:
		fails.append("PROG-01 manual fire returned null")
		return
	if ws.torpedoes.size() != n0 + 1:
		fails.append("PROG-01 manual fire did not add torpedo")
	if tp.program.fire_mode != WeaponProgram.FireMode.MANUAL:
		fails.append("PROG-01 fire_mode not MANUAL")
	_assert_float(fails, "PROG-01 initial course", tp.program.initial_course_deg, 42.0, 1e-6)
	if tp.program.initial_depth_band != WeaponProgram.DEPTH_BAND_LOWER:
		fails.append("PROG-01 depth band not LOWER")
	# 无解发射绝不携带隐藏射程：程序无 range 字段。
	if tp.program.get("range_m") != null:
		fails.append("PROG-01 program leaked range field")
	var idx: int = _tube_of(ws, tp.torpedo_id)
	if idx >= 0 and ws.tubes[idx]["state"] != WeaponSystem.TubeState.EMPTY:
		fails.append("PROG-01 tube not EMPTY after manual launch")
	# 默认正交状态（发射后 PASSIVE_LISTEN、ACTIVE OFF）
	if tp.seeker_state != Torpedo.SeekerState.PASSIVE_LISTEN:
		fails.append("PROG-01 passive not ON after manual launch")
	if tp.active_tx_state != Torpedo.ActiveTxState.OFF:
		fails.append("PROG-01 active TX not OFF after manual launch")


func _wpn_prog_02_bearing_only(fails: Array, world: World) -> void:
	var own: RefCounted = world.world["own"]
	var ws: WeaponSystem = world.weapons
	var brg: float = 123.0
	var tp: Torpedo = (
		ws
		. fire_bearing_only(
			brg,
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp == null:
		fails.append("PROG-02 bearing-only fire returned null")
		return
	if tp.program.fire_mode != WeaponProgram.FireMode.BEARING_ONLY:
		fails.append("PROG-02 fire_mode not BEARING_ONLY")
	_assert_float(fails, "PROG-02 initial course", tp.program.initial_course_deg, brg, 1e-6)
	_assert_float(fails, "PROG-02 search center", tp.program.search_center_deg, brg, 1e-6)
	if tp.program.search_half_angle_deg < 45.0:
		fails.append("PROG-02 search half-angle not wide (%.0f)" % tp.program.search_half_angle_deg)
	# 无隐藏距离：程序结构上无 range 字段
	if tp.program.get("range_m") != null:
		fails.append("PROG-02 program leaked range field")


func _wpn_prog_03_solution_prefill(fails: Array, world: World) -> void:
	var own: RefCounted = world.world["own"]
	var ws: WeaponSystem = world.weapons
	# 3a. fire(sys) → SOLUTION 程序（解是预填来源）
	var tp_sol: Torpedo = (
		ws
		. fire(
			_mk_sys(world),
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp_sol == null:
		fails.append("PROG-03a solution fire returned null")
	else:
		if tp_sol.program.fire_mode != WeaponProgram.FireMode.SOLUTION:
			fails.append("PROG-03a fire_mode not SOLUTION")
		# 预填的 initial course 指向解外推瞄准点（非 Truth 直读）—— 0..360 合法即可
		if tp_sol.program.initial_course_deg < 0.0 or tp_sol.program.initial_course_deg > 360.0:
			fails.append("PROG-03a prefill course out of range")
	# 3b. SOLUTION 只负责预填：玩家编辑后的程序（仍标 SOLUTION）实际生效，
	#     解不会覆盖玩家修改。
	var prog := WeaponProgram.new()
	prog.fire_mode = WeaponProgram.FireMode.SOLUTION
	prog.initial_course_deg = 200.0
	prog.initial_depth_band = WeaponProgram.DEPTH_BAND_LOWER
	prog.search_depth_band = WeaponProgram.DEPTH_BAND_LOWER
	prog.search_center_deg = 200.0
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	var tp_edit: Torpedo = (
		ws
		. fire_program(
			prog,
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp_edit == null:
		fails.append("PROG-03b edited program fire returned null")
		return
	if tp_edit.program.initial_course_deg != 200.0:
		fails.append("PROG-03b edited initial_course not used (prefill override)")
	if tp_edit.program.initial_depth_band != WeaponProgram.DEPTH_BAND_LOWER:
		fails.append("PROG-03b edited depth band not used")
	# 3c. 发射瞬间快照不可变：改原程序不影响已发射鱼雷
	prog.initial_course_deg = 99.0
	if absf(tp_edit.program.initial_course_deg - 200.0) > 1e-9:
		fails.append("PROG-03c launched snapshot mutated by later program edit")


func _wpn_prog_04_tube_empty(fails: Array, world: World) -> void:
	var own: RefCounted = world.world["own"]
	var ws: WeaponSystem = world.weapons
	# 找一枚空管装填后再 BEARING_ONLY 发射，跑到燃料耗尽验证不补装
	for i in range(ws.tubes.size()):
		if ws.tubes[i]["state"] == WeaponSystem.TubeState.EMPTY:
			ws.reload_tube(i)
			break
	var tp: Torpedo = (
		ws
		. fire_bearing_only(
			10.0,
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp == null:
		fails.append("PROG-04 reload+fire returned null")
		return
	var idx: int = _tube_of(ws, tp.torpedo_id)
	if idx < 0:
		fails.append("PROG-04 torpedo not bound to tube")
		return
	if ws.tubes[idx]["state"] != WeaponSystem.TubeState.EMPTY:
		fails.append("PROG-04 tube not EMPTY right after launch")
	tp.fuel_left_s = 5.0
	var guard: int = 0
	while not tp.is_dead() and guard < 300:
		world.tick()
		guard += 1
	if not tp.is_dead():
		fails.append("PROG-04 torpedo never died on fuel out")
		return
	# 鱼雷结束：该管保持 EMPTY，绝不自动 LOADED
	if ws.tubes[idx]["state"] == WeaponSystem.TubeState.LOADED:
		fails.append("PROG-04 tube auto-reloaded after torpedo dead (must stay EMPTY)")


func _tube_of(ws: WeaponSystem, tid: String) -> int:
	for i in range(ws.tubes.size()):
		if ws.tubes[i]["torpedo_id"] == tid:
			return i
	return -1


func _assert_float(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _finish(fails: Array) -> void:
	for f in fails:
		print("WPN_PROG_FAIL ", f)
	if fails.is_empty():
		print("WEAPON_PROGRAM_TEST result=PASS")
	else:
		print("WEAPON_PROGRAM_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
