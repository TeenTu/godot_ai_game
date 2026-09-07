extends SceneTree
## REQ-0908 Batch 0 — P0-01 失败回归：平台主动 Ping 无法探测敌方鱼雷。
## 根因：World.issue_ping()/_settle_due_echoes() 只遍历 world["targets"]，
## 敌方在水鱼雷（_enemy_torpedo_shadows / enemy_weapons.torpedoes）不在其中。
## 修复后要求：issue_ping 登记敌雷反射体回波；到达后按发射时刻快照结算。
## Batch 2 落地时本测试加入 ci_tests.txt。

const SEED := 90801


func _initialize() -> void:
	var fails: Array = []
	var w := _mk_world()
	w.run_steps(30)

	# 敌方（fallback_spawn 固定 3000m/正北）向本艇发射一枚直航鱼雷。
	var e: TruthEntity = w.enemy_ai.entity
	var brg_e2own: float = NavUtils.bearing_to_true(
		float(e.position_east_m), float(e.position_north_m),
		float(w.world["own"].position_east_m), float(w.world["own"].position_north_m),
	)
	var prog := WeaponProgram.make_bearing_only(brg_e2own)
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 100.0
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	var tp: Torpedo = w.enemy_weapons.fire_program(
		prog, float(e.position_east_m), float(e.position_north_m), w.sim_time, float(e.depth_m)
	)
	_assert(fails, tp != null, "enemy torpedo launched")
	if tp == null:
		_finish(fails)
		return

	# 推进到敌雷入水并接近（~1500m 内，主动阵覆盖内、监听窗 τ=2R/c 内）。
	for i in range(60):
		w.run_steps(1)
		if not w.enemy_weapons.torpedoes.is_empty():
			var t0: Torpedo = w.enemy_weapons.torpedoes[0]
			var d: float = NavUtils.distance(
				float(t0.pos_east_m), float(t0.pos_north_m),
				float(w.world["own"].position_east_m), float(w.world["own"].position_north_m),
			)
			if d <= 1500.0 and not t0.is_dead():
				break

	# 平台主动 Ping：发射即应把敌雷登记为主动反射体（当前实现只查
	# world["targets"]——那里只有敌潜艇实体 E-S1，无 ET 鱼雷 → 本断言失败）。
	var ok_ping: bool = w.issue_ping()
	_assert(fails, ok_ping, "issue_ping accepted")
	var pending: int = w.pending_echo_count()
	_assert(fails, pending > 0, "pending echoes registered (pending=%d)" % pending)
	var torpedo_echo: Dictionary = {}
	if pending > 0:
		for e2 in w._ping_session["echoes"]:
			if str(e2["target_id"]) == str(tp.torpedo_id):
				torpedo_echo = e2
				break
	_assert(
		fails,
		not torpedo_echo.is_empty(),
		"echo registered for enemy torpedo %s (targets: %s)"
		% [
			str(tp.torpedo_id),
			str(w._ping_session["echoes"].map(func(x): return str(x["target_id"]))),
		],
	)

	# 推进过监听窗：敌雷回波应被结算（detected 与否由声学方程决定）。
	for i in range(60):
		w.run_steps(1)
	w.take_arrived_echoes()
	if not torpedo_echo.is_empty():
		_assert(fails, bool(torpedo_echo["settled"]), "enemy torpedo echo settled")

	_finish(fails)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []  # 只留随机出生敌雷，隔离"P0-01 不含敌雷"的缺陷面
	var b: float = deg_to_rad(0.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 0.0,
		"bearing_max_deg": 0.0,
		"range_min_m": 3000.0,
		"range_mode_m": 3000.0,
		"range_max_m": 3000.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 10,
		"fallback_spawn": {
			"position_east_m": sin(b) * 3000.0,
			"position_north_m": cos(b) * 3000.0,
			"course_deg": 180.0,
			"speed_kn": 6.0,
			"depth_m": 60.0,
		},
		"doctrine": {"sensor_false_alarm_rate": 0.0},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("PING-ENEMY-TORPEDO TEST PASS")
		quit(0)
	else:
		print("PING-ENEMY-TORPEDO TEST FAIL (%d)" % fails.size())
		quit(1)
