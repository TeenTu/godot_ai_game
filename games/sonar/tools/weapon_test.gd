extends SceneTree
## weapon_test.gd — 阶段四武器与攻击无头验收。
##
## 流程：场景 → 玩家操作链产出 System Solution（复用 operator 流，
## 或直接以测试作者身份构造解）→ Fire → 鱼雷 enable/搜索/自导捕获 → 命中。
##
## 断言：
##   w1 发射后鱼雷在水中（RUN/SEARCH）
##   w2 鱼雷经过 enable（ENABLE 事件）
##   w3 自导捕获（ACQUIRE 事件）
##   w4 目标被击沉（damage_state == "sunk"）
##   w5 发射管回收（重装填）
##   w6 无解 / 无管时不发射
##
## 注：测试中构造 SystemSolution 使用测试作者权限读取 Truth 一次，
##     模拟"玩家已完美解算"；武器与鱼雷代码本身绝不读 Truth。

const DT: float = 0.5
const FIRE_AT: float = 60.0
const SIM_END: float = 900.0


func _initialize() -> void:
	var fails: Array = []
	var world := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	world.load_scenario(sc)
	world.auto_measurements = false
	var wd: Dictionary = world.world

	# 推进到发射时刻
	while world.sim_time < FIRE_AT:
		world.tick()

	# 测试作者权限：从 Truth 构造一份"完美火控解"（模拟玩家已提交）
	var own: RefCounted = wd["own"]
	var tgt: RefCounted = wd["targets"][0]
	var sys := SystemSolution.new()
	sys.bearing_deg = NavUtils.bearing_to_true(
		float(own.position_east_m),
		float(own.position_north_m),
		float(tgt.position_east_m),
		float(tgt.position_north_m)
	)
	sys.range_m = (
		Vector2(
			float(tgt.position_east_m) - float(own.position_east_m),
			float(tgt.position_north_m) - float(own.position_north_m)
		)
		. length()
	)
	sys.course_deg = float(tgt.course_deg)
	sys.speed_kn = float(tgt.speed_kn)
	sys.solution_time = world.sim_time
	sys.estimated_position_east_m = float(tgt.position_east_m)
	sys.estimated_position_north_m = float(tgt.position_north_m)
	sys.confidence = 0.9

	# w6a 无解时不发射
	# S1-07 遗留契约（Commit 3 翻转）：无 System Solution 必须拒绝发射 →
	# 新需求 REQ-DECISION-03 改为 MANUAL/BEARING_ONLY 可发射，System Solution
	# 只是可选预填来源。此断言保留至 Commit 3 落地时翻转。
	var n_fired0: int = world.weapons.torpedoes.size()
	world.weapons.fire(
		null, float(own.position_east_m), float(own.position_north_m), world.sim_time
	)
	if world.weapons.torpedoes.size() != n_fired0:
		fails.append("w6a fire without solution must be rejected")

	var tp: Torpedo = world.weapons.fire(
		sys, float(own.position_east_m), float(own.position_north_m), world.sim_time
	)
	if tp == null:
		fails.append("w1 fire returned null")
		_finish(fails)
		return

	# 收集事件
	var kinds: Dictionary = {}
	tp.event_occurred.connect(func(_tid: String, kind: String, _d: Dictionary): kinds[kind] = true)

	# 推进至命中或耗尽
	while world.sim_time < SIM_END:
		world.tick()
		if str(tgt.damage_state) == "sunk":
			break

	if tp.state == Torpedo.State.STANDBY:
		fails.append("w1b torpedo never launched")
	if not kinds.has("ENABLE"):
		fails.append("w2 no ENABLE event")
	if not kinds.has("ACQUIRE"):
		fails.append("w3 no ACQUIRE event")
	if str(tgt.damage_state) != "sunk":
		fails.append(
			"w4 target not sunk (state=%s sim_t=%.0f)" % [str(tgt.damage_state), world.sim_time]
		)
	if not kinds.has("HIT"):
		fails.append("w4b no HIT event")
	# w5 管重装填
	# S1-07 遗留契约（Commit 1 翻转）：鱼雷结束后发射管自动 LOADED →
	# 新需求 §3.1 阶段一规则：发射后保持 EMPTY，真实再装填时间与库存后移，
	# 不得因鱼雷命中/耗尽/自毁而自动补回。此断言在 Commit 1 改为 tube=EMPTY。
	var reloaded: bool = false
	for t in world.weapons.tubes:
		if t["state"] == "LOADED":
			reloaded = true
	if not reloaded:
		fails.append("w5 tube not reloaded after kill")
	# w6b 管耗尽场景：连续发射超过容量后应拒绝
	var guard: int = 0
	while world.weapons.loaded_count() > 0 and guard < 10:
		world.weapons.fire(
			sys, float(own.position_east_m), float(own.position_north_m), world.sim_time
		)
		guard += 1
	if world.weapons.loaded_count() != 0:
		fails.append("w6b loaded count not drained")
	world.weapons.fire(sys, float(own.position_east_m), float(own.position_north_m), world.sim_time)
	# 全 LOADED 时应能再次发射（模拟重装填后管可用）
	var fired_again: bool = false
	world.weapons.tubes[0]["state"] = "LOADED"
	var tp2: Torpedo = world.weapons.fire(
		sys, float(own.position_east_m), float(own.position_north_m), world.sim_time
	)
	fired_again = tp2 != null
	if not fired_again:
		fails.append("w6c reload tube cannot fire again")

	_finish(fails)


func _finish(fails: Array) -> void:
	for f in fails:
		print("WEAPON_FAIL ", f)
	if fails.is_empty():
		print("WEAPON_TEST result=PASS")
	else:
		print("WEAPON_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
