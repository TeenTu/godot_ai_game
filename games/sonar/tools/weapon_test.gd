extends SceneTree
## weapon_test.gd — 武器系统无头验收（S1-07 Commit 3 更新版）。
##
## 流程：场景 → 玩家操作链产出 System Solution → Fire → 鱼雷入水默认
## 状态断言 → 线控/引信 → 燃料耗尽 TERMINAL → 发射管保持 EMPTY（不再自动
## 补装，S1-07 §3.1）。
##
## 断言（对应 S1-07 §1.2 必须更新项）：
##   w1  发射后鱼雷在水中（LAUNCHING→WIRE_RUN）
##   w2  默认正交状态：PASSIVE_LISTEN / ACTIVE_TX OFF / WIRE CONNECTED /
##       WIRE_ONLY / FUZE SAFE（REQ-DECISION-01/02）
##   w3  引信按 arm distance 独立解保（FUZE_ARMED），与自主/主动解耦
##   w4  鱼雷结束后发射管保持 EMPTY，不自动 LOADED
##   w5  reload_tube 显式装填后仍可发射
##   w6  [Commit 3 翻转] 无 SystemSolution 也可 MANUAL 发射（管 EMPTY 语义保留）
##
## 注：测试中构造 SystemSolution 使用测试作者权限读取 Truth 一次，模拟
##     "玩家已完美解算"；武器与鱼雷代码本身绝不读 Truth（step 只收 TorpedoContext）。

const DT: float = 0.5
const FIRE_AT: float = 60.0


func _initialize() -> void:
	var fails: Array = []
	var world := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	world.load_scenario(sc)
	world.auto_measurements = false
	var wd: Dictionary = world.world

	while world.sim_time < FIRE_AT:
		world.tick()

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

	# w6 无解 MANUAL 发射移到文件尾（避免占用发射管影响 w1-w5 流程）

	var tp: Torpedo = (
		world
		. weapons
		. fire(
			sys,
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp == null:
		fails.append("w1 fire returned null")
		_finish(fails)
		return

	# 事件收集（LAUNCH 在 connect 前已由 fire 发出，忽略；关注 WIRE_RUN 等）
	var kinds: Dictionary = {}
	tp.event_occurred.connect(func(_tid: String, kind: String, _d: Dictionary): kinds[kind] = true)

	# w1b 发射管在出管后立即 EMPTY（不瞬时补装）
	var tube_idx: int = -1
	for i in range(world.weapons.tubes.size()):
		if world.weapons.tubes[i]["torpedo_id"] == tp.torpedo_id:
			tube_idx = i
	if tube_idx < 0:
		fails.append("w1c fired torpedo not bound to a tube")
	if tube_idx >= 0 and world.weapons.tubes[tube_idx]["state"] != WeaponSystem.TubeState.EMPTY:
		fails.append("w1c tube not EMPTY right after launch")

	# 推进到 WIRE_RUN
	var guard: int = 0
	while tp.mission_state == Torpedo.MissionState.LAUNCHING and guard < 40:
		world.tick()
		guard += 1
	if tp.mission_state != Torpedo.MissionState.WIRE_RUN:
		fails.append("w1b torpedo never reached WIRE_RUN")
	if not kinds.has("WIRE_RUN"):
		fails.append("w1d no WIRE_RUN event")

	# w2 默认正交状态
	if tp.seeker_state != Torpedo.SeekerState.PASSIVE_LISTEN:
		fails.append("w2 passive receiver not ON by default")
	if tp.active_tx_state != Torpedo.ActiveTxState.OFF:
		fails.append("w2 active TX not OFF by default")
	if tp.wire_state != Torpedo.WireState.CONNECTED:
		fails.append("w2 wire not CONNECTED by default")
	if tp.guidance_authority != Torpedo.GuidanceAuthority.WIRE_ONLY:
		fails.append("w2 guidance not WIRE_ONLY by default")
	if tp.fuze_state != Torpedo.FuzeState.SAFE:
		fails.append("w2 fuze not SAFE at launch")
	if tp.program == null or tp.program.fire_mode != WeaponProgram.FireMode.SOLUTION:
		fails.append("w2 program not built from solution")

	# w3 引信独立解保：默认 arm 300m，CRUISE 40kn(~20.6m/s) 约 15s 后 ARMED
	guard = 0
	while tp.fuze_state != Torpedo.FuzeState.ARMED and guard < 200:
		world.tick()
		guard += 1
	if tp.fuze_state != Torpedo.FuzeState.ARMED:
		fails.append("w3 fuze never ARMED at arm distance")
	if not kinds.has("FUZE_ARMED"):
		fails.append("w3b no FUZE_ARMED event")

	# w4 快进到燃料耗尽 TERMINAL：发射管保持 EMPTY（不自动 LOADED）
	tp.fuel_left_s = 5.0
	guard = 0
	while not world.weapons.torpedoes.is_empty() and guard < 200:
		world.tick()
		guard += 1
	if not world.weapons.torpedoes.is_empty():
		fails.append("w4 torpedo never died on fuel out")
	# w4 具体发射管保持 EMPTY（不自动 LOADED）；其余管不受影响仍为 LOADED
	if tube_idx < 0 or world.weapons.tubes[tube_idx]["state"] != WeaponSystem.TubeState.EMPTY:
		fails.append("w4 fired tube auto-reloaded after torpedo dead (must stay EMPTY)")
	if world.weapons.loaded_count() != world.weapons.tubes.size() - 1:
		fails.append("w4b loaded count wrong after terminal (only the fired tube empty)")

	# w5 reload_tube 显式装填后可再次发射
	if tube_idx < 0 or not world.weapons.reload_tube(tube_idx):
		fails.append("w5 reload_tube rejected")
	var tp2: Torpedo = (
		world
		. weapons
		. fire(
			sys,
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp2 == null:
		fails.append("w5 reloaded tube cannot fire again")

	# w6 [Commit 3 翻转] 无 SystemSolution 也可 MANUAL 发射（解非发射许可）
	var n_fired0: int = world.weapons.torpedoes.size()
	var tp_manual: Torpedo = (
		world
		. weapons
		. fire_manual(
			float(own.course_deg),
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if tp_manual == null:
		fails.append("w6 MANUAL fire without solution must succeed")
	elif world.weapons.torpedoes.size() != n_fired0 + 1:
		fails.append("w6b MANUAL fire did not add a torpedo")
	elif tp_manual.program.fire_mode != WeaponProgram.FireMode.MANUAL:
		fails.append("w6c MANUAL fire program fire_mode wrong")

	_finish(fails)


func _finish(fails: Array) -> void:
	for f in fails:
		print("WEAPON_FAIL ", f)
	if fails.is_empty():
		print("WEAPON_TEST result=PASS")
	else:
		print("WEAPON_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
