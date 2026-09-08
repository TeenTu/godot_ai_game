extends SceneTree
## REQ-0908 Batch 5 — 敌雷命中本艇即 Game Over（REQ-B5-01..05）。
## 契约：敌雷完成解保+swept 触发+起爆结算后必须
## mission_state=PLAYER_DEFEATED、own.damage_state="sunk"、仿真冻结、
## mission_ended 信号恰好一次（reason=TORPEDO_HIT），且终局后所有操作
## 命令（发射/Ping/诱饵/线控）统一拒绝（MISSION_ENDED）。

const SEED := 90804
const SEED_SPAN := 60

var _end_results: Array = []


func _initialize() -> void:
	var fails: Array = []
	# Pass 1：seed 扫描——固定几何脚手架下找到确定性命中本艇的 seed。
	var hit_seed: int = -1
	for sv in range(SEED, SEED + SEED_SPAN):
		if _run_torpedo_to_end(_mk_world(sv)):
			hit_seed = sv
			break
	_assert(fails, hit_seed >= 0, "found seed where enemy torpedo detonates on own ship")
	if hit_seed < 0:
		_finish(fails)
		return

	# Pass 2：用命中 seed 重建世界，验证完整终局契约。
	var w := _mk_world(hit_seed)
	w.mission_ended.connect(func(r: Dictionary): _end_results.append(r))
	_run_torpedo_to_end(w)

	# ---- 终局契约（REQ-B5-01/02/03）----
	_assert(
		fails,
		w.get("mission_state") != null,
		"World.mission_state exists",
	)
	_assert(fails, _end_results.size() == 1, "mission_ended signal fired exactly once")
	if _end_results.size() >= 1:
		var res: Dictionary = _end_results[0]
		_assert(fails, str(res.get("reason", "")) == "TORPEDO_HIT", "end reason == TORPEDO_HIT")
		_assert(
			fails,
			str(res.get("own_damage_state", "")) == "sunk",
			"signal payload own_damage_state == sunk",
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
			is_equal_approx(float(w.mission_end_time), t0),
			"mission_end_time == freeze time",
		)
	_assert(
		fails,
		str(w.world["own"].damage_state) == "sunk",
		"own damage_state == sunk (got '%s')" % str(w.world["own"].damage_state),
	)

	# ---- REQ-B5-05：终局后操作命令统一拒绝 ----
	_assert(
		fails,
		w.command_reject_reason() == "MISSION_ENDED",
		"command_reject_reason == MISSION_ENDED",
	)
	_assert(fails, w.issue_ping() == false, "issue_ping rejected after mission end")
	_assert(fails, w._launch_decoy(null) == false, "decoy launch rejected after mission end")
	_assert(
		fails,
		str(w.last_decoy_reject_reason) == "MISSION_ENDED",
		"decoy reject reason == MISSION_ENDED",
	)
	var fe := FireExecutor.new()
	var fr: Dictionary = fe.execute(w.weapons, w, "MANUAL", "")
	_assert(
		fails,
		not bool(fr.get("ok", true)) and str(fr.get("reason", "")) == "MISSION_ENDED",
		"fire command rejected after mission end",
	)

	# ---- REQ-B5-03：end_mission 幂等（后续事件不可覆盖首因）----
	_assert(
		fails,
		w.end_mission(0, "OVERWRITE_ATTEMPT") == false,
		"second end_mission call rejected",
	)
	_assert(
		fails,
		str(w.mission_end_reason) == "TORPEDO_HIT",
		"first end reason preserved (got '%s')" % str(w.mission_end_reason),
	)

	_finish(fails)


## 敌方向本艇发射直航鱼雷（HIGH 速度、TIME 开主动、自治授权，无导线），
## 推进至命中（damage_state 进入 damaged/sunk）或预算耗尽。返回是否命中。
func _run_torpedo_to_end(w: World) -> bool:
	w.run_steps(30)
	var e: TruthEntity = w.enemy_ai.entity
	var brg_e2own: float = (
		NavUtils
		. bearing_to_true(
			float(e.position_east_m),
			float(e.position_north_m),
			float(w.world["own"].position_east_m),
			float(w.world["own"].position_north_m),
		)
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
	if tp == null:
		return false
	for i in range(1440):
		w.run_steps(1)
		var ds: String = str(w.world["own"].damage_state)
		if ds == "damaged" or ds == "sunk":
			return true
	return false


func _mk_world(seed_val: int) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["targets"] = []
	# 固定几何脚手架：本艇静止 + 与鱼雷 UPPER 层带（70m hold）同深度，
	# 保证直航鱼雷沿发射方位精确扫过本艇（自然制导，非 Truth 瞄准）。
	if sc.has("own_ship"):
		sc["own_ship"]["speed_kn"] = 0.0
		sc["own_ship"]["depth_m"] = 70.0
	var b: float = deg_to_rad(90.0)
	var r0: float = 800.0
	sc["enemy_spawn"] = {
		"bearing_min_deg": 90.0,
		"bearing_max_deg": 90.0,
		"range_min_m": 800.0,
		"range_mode_m": 800.0,
		"range_max_m": 800.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 500.0,
		"max_generation_attempts": 10,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * r0,
			"position_north_m": cos(b) * r0,
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
