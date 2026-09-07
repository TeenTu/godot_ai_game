extends SceneTree
## REQ-0908 Batch 0 — P0-07 失败回归：敌雷命中本艇无 Game Over。
## 根因：World 引信结算只写 world["own"].damage_state="damaged"，仿真继续。
## 契约（Batch 5）：敌雷完成解保+swept 触发+起爆结算后必须
## mission_state=PLAYER_DEFEATED、own.damage_state="sunk"、仿真冻结。
## Batch 5 落地时本测试加入 ci_tests.txt。

const SEED := 90804


func _initialize() -> void:
	var fails: Array = []
	var w := _mk_world()
	w.run_steps(30)

	# 敌方（固定 2000m/正东）向本艇发射直航鱼雷（HIGH 速度、TIME 开主动、
	# 自治授权，保证无导线也直航碰撞）。几何固定 → 自然制导命中。
	var e: TruthEntity = w.enemy_ai.entity
	var brg_e2own: float = NavUtils.bearing_to_true(
		float(e.position_east_m), float(e.position_north_m),
		float(w.world["own"].position_east_m), float(w.world["own"].position_north_m),
	)
	var prog := WeaponProgram.make_bearing_only(brg_e2own)
	prog.speed_mode = WeaponProgram.SpeedMode.HIGH
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

	# 推进至命中（2000m @ ~25m/s ≈ 80s；预算 240s 兜底）。
	var hit: bool = false
	for i in range(1440):
		w.run_steps(1)
		if str(w.world["own"].damage_state) != "":
			hit = true
			break
	_assert(fails, hit, "enemy torpedo detonation reached own ship within budget")

	# ---- 终局契约（当前代码全部缺失 → 本组断言失败）----
	_assert(
		fails,
		w.get("mission_state") != null,
		"World.mission_state exists",
	)
	if w.get("mission_state") != null:
		_assert(
			fails,
			int(w.mission_state) == 1,  # MissionState.PLAYER_DEFEATED
			"mission_state == PLAYER_DEFEATED (got %d)" % int(w.mission_state),
		)
		var frozen: bool = true
		var t0: float = w.sim_time
		for i in range(100):
			w.run_steps(1)
			if not is_equal_approx(w.sim_time, t0):
				frozen = false
				break
		_assert(fails, frozen, "simulation frozen after mission end")
	_assert(
		fails,
		str(w.world["own"].damage_state) == "sunk",
		"own damage_state == sunk (got '%s')" % str(w.world["own"].damage_state),
	)

	_finish(fails)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	var b: float = deg_to_rad(90.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 90.0,
		"bearing_max_deg": 90.0,
		"range_min_m": 2000.0,
		"range_mode_m": 2000.0,
		"range_max_m": 2000.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 10,
		"fallback_spawn": {
			"position_east_m": sin(b) * 2000.0,
			"position_north_m": cos(b) * 2000.0,
			"course_deg": 270.0,
			"speed_kn": 6.0,
			"depth_m": 50.0,
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
		print("ENEMY-HIT-GAMEOVER TEST PASS")
		quit(0)
	else:
		print("ENEMY-HIT-GAMEOVER TEST FAIL (%d)" % fails.size())
		quit(1)
