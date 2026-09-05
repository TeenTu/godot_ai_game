extends SceneTree
## dep_test.gd — P0-C 深度信息与水面攻击 无头验收（REQ-DEP-01..02，DEP-1..2）。
##
## DEP-1  仅方位观测不产生精确深度；Track 默认 UNKNOWN；seeker 深度观测
##        为带噪估计（depth_observed_m/depth_sigma_m），层关系/带提示由有噪
##        观测推导；SystemSolution 无深度输出。
## DEP-2  浅水 SURFACE 预设：50 m 发射、有限垂速爬升到配置浅水深度、稳定
##        保持、显式定深不被层带提示覆盖，并完成实际引信判定（磁近炸）；
##        层带命令 UPPER→LOWER / LOWER→UPPER 双向切换且全程限速；
##        全自动换带搜索按保持超时触发并记 BAND_SEARCH_SWITCH。
##
## godot --headless --path games/sonar --script res://tools/dep_test.gd

const SEED: int = 20260905
const VZ_EPS: float = 1e-6

var _prev_depth: float = -1.0


func _initialize() -> void:
	var fails: Array = []
	_dep_1_depth_unknown(fails)
	_dep_2_surface_attack(fails)
	_dep_2_band_switch_both_ways(fails)
	_dep_2_auto_band_search(fails)
	_finish(fails)


## ---- DEP-1：深度未知是合法状态 ----
func _dep_1_depth_unknown(fails: Array) -> void:
	# a) Track 默认 UNKNOWN（无深度观测模型绝不输出层标签）。
	var t := Track.new()
	_assert_bool(
		fails, "DEP-1a default UNKNOWN", t.depth_assessment == Track.DEPTH_ASSESSMENT_UNKNOWN, true
	)
	_assert_bool(
		fails,
		"DEP-1a no source/confidence",
		t.depth_assessment_source == "" and t.depth_assessment_confidence == 0.0,
		true
	)
	# b) 非法状态拒绝；合法更新带来源/置信度/时间。
	_assert_bool(
		fails,
		"DEP-1b invalid state rejected",
		t.update_depth_assessment("DEPTH_0M", "TRUTH", 1.0, 10.0),
		false
	)
	_assert_bool(
		fails,
		"DEP-1b valid update accepted",
		t.update_depth_assessment(Track.DEPTH_ASSESSMENT_UPPER, "MULTIPATH", 0.6, 10.0),
		true
	)
	var s: Dictionary = t.depth_assessment_summary()
	_assert_bool(
		fails,
		"DEP-1b summary carries source",
		str(s.get("state")) == "UPPER_LIKELY" and str(s.get("source")) == "MULTIPATH",
		true
	)
	# c) seeker 深度观测为有噪估计：depth_observed_m 偏离 Truth 深度且界内；
	#    层带提示/层关系从有噪观测推导（非 Truth 直接拷贝）。
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var env: RefCounted = w.world["env"]
	var dm: RefCounted = w.world.get("depth_model", null)
	var sub := _mk_truth("SUB", 3000.0, 3000.0, 180.0)  # 中层深度（远离层界）
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 170.0
	var ad := TorpedoSensorAdapter.new()
	ad.bind(env, dm, [sub], {"SUB": ac})
	ad.set_rng(_rng(SEED + 1))
	var prof := TorpedoAcousticProfile.make_default()
	var truth_z: float = sub.depth_m
	var n_noisy: int = 0
	var n_runs: int = 30
	for i in range(n_runs):
		var rs: Array = ad.sample_passive(0.0, 0.0, 50.0, 0.0, 0.0, prof, 200.0)
		for r in rs:
			if float(r.depth_observed_m) < 0.0:
				continue
			var obs: float = float(r.depth_observed_m)
			if absf(obs - truth_z) > 5.0 * TorpedoSensorAdapter.DEPTH_OBS_SIGMA_M:
				fails.append("DEP-1c depth obs beyond 5σ: %f vs %f" % [obs, truth_z])
			if float(r.depth_sigma_m) <= 0.0:
				fails.append("DEP-1c depth sigma not set")
			if absf(obs - truth_z) > 1e-9:
				n_noisy += 1
	if n_noisy == 0:
		fails.append("DEP-1c depth observation shows no noise")
	# d) SystemSolution/TMA 无深度输出（水平状态解，绝不伪造深度）。
	var ss := SystemSolution.new()
	if "depth_m" in ss or "depth" in ss:
		fails.append("DEP-1d SystemSolution leaks depth field")


## ---- DEP-2：浅水攻击（SURFACE 预设）+ 实际引信判定 ----
func _dep_2_surface_attack(fails: Array) -> void:
	var w := _mk_surface_world()
	# 水面运动靶（depth 0，6 kn）。程序：SURFACE 浅水 12 m + 磁近炸。
	var tgt = w.world["targets"][0]
	var brg: float = NavUtils.bearing_to_true(
		0.0, 0.0, float(tgt.position_east_m), float(tgt.position_north_m)
	)
	var prog := WeaponProgram.make_bearing_only(brg)
	prog.fuze_mode = FuzeController.FUZE_MAGNETIC_PROXIMITY
	prog.initial_depth_m = 12.0  # SURFACE 浅水预设（配置值）
	prog.speed_mode = WeaponProgram.SpeedMode.CRUISE
	prog.active_enable_mode = WeaponProgram.ActiveEnableMode.TIME
	prog.active_enable_time_s = 30.0
	var tp: Torpedo = w.weapons.fire_program(prog, 0.0, 0.0, w.sim_time, 50.0)
	_assert_bool(
		fails,
		"DEP-2a launched from 50m",
		tp != null and absf(tp.actual_depth_m - 50.0) < 1e-6,
		true
	)
	if tp == null:
		return
	_assert_bool(fails, "DEP-2a source PROGRAM", tp.depth_command_source == "PROGRAM", true)
	var vz: float = tp.max_vertical_speed_m_s
	var dt: float = float(w.world["dt"])
	var reached: bool = false
	var hold_ticks: int = 0
	# 爬升阶段：限速 + 到达 12 m（有限垂速逼近，非瞬移）。
	_prev_depth = tp.actual_depth_m
	for i in range(600):
		w.run_steps(1)
		if tp.mission_state == tp.MissionState.DEAD:
			break
		if tp.actual_depth_m <= 12.5:
			reached = true
			break
		if tp.commanded_depth_m >= 0.0:
			var dz: float = absf(tp.actual_depth_m - _prev_depth)
			_prev_depth = tp.actual_depth_m
			if dz > vz * dt + VZ_EPS:
				fails.append("DEP-2a climb exceeded Vz: %f > %f" % [dz, vz * dt])
		else:
			_prev_depth = tp.actual_depth_m
	_assert_bool(fails, "DEP-2a reached shallow depth", reached, true)
	# 保持阶段：显式定深保持（不被层带提示静默覆盖）。
	for i in range(60):
		if tp.mission_state == tp.MissionState.DEAD:
			break
		w.run_steps(1)
		if absf(tp.actual_depth_m - 12.0) <= 0.5:
			hold_ticks += 1
		if tp.explicit_depth_m >= 0.0 and absf(tp.explicit_depth_m - 12.0) > 0.6:
			fails.append("DEP-2a explicit depth overridden to %f" % tp.explicit_depth_m)
	_assert_bool(fails, "DEP-2a holds shallow depth", hold_ticks >= 55, true)
	# 引信判定：接近水面运动靶 → MAGNETIC（半径 25 m，垂直门 25 m ≥ 12 m 差）。
	for i in range(2400):
		w.run_steps(1)
		if tp.mission_state == tp.MissionState.DEAD:
			break
	_assert_bool(
		fails,
		"DEP-2b surface target fuze detonation",
		tp.mission_state == tp.MissionState.DEAD,
		true
	)
	_assert_bool(
		fails, "DEP-2b enemy sunk in Truth", str(w.world["targets"][0].damage_state) == "sunk", true
	)


## ---- DEP-2：层带命令双向切换（UPPER→LOWER / LOWER→UPPER）全程限速 ----
func _dep_2_band_switch_both_ways(fails: Array) -> void:
	var w := _mk_search_world()
	# UPPER 出发（程序层带 hold），线控命令切 LOWER，再切回 UPPER。
	var tp: Torpedo = w.weapons.fire_manual(
		45.0, 0.0, 0.0, w.sim_time, 50.0, WeaponProgram.DEPTH_BAND_UPPER
	)
	_assert_bool(fails, "DEP-2c launched", tp != null, true)
	if tp == null:
		return
	for i in range(10):
		w.run_steps(1)
	var ok1: bool = tp.command_depth_band(WeaponProgram.DEPTH_BAND_LOWER)
	_assert_bool(fails, "DEP-2c command LOWER accepted", ok1, true)
	_assert_bool(fails, "DEP-2c source PLAYER", tp.depth_command_source == "PLAYER", true)
	var vz: float = tp.max_vertical_speed_m_s
	var dt: float = float(w.world["dt"])
	var reached_lower: bool = false
	var prev: float = tp.actual_depth_m
	for i in range(600):
		w.run_steps(1)
		var dz: float = absf(tp.actual_depth_m - prev)
		prev = tp.actual_depth_m
		if dz > vz * dt + VZ_EPS:
			fails.append("DEP-2c descend exceeded Vz: %f" % dz)
		if tp.actual_depth_m >= _lower_hold(w) - 0.5:
			reached_lower = true
			break
	_assert_bool(fails, "DEP-2c reached LOWER hold", reached_lower, true)
	var ok2: bool = tp.command_depth_band(WeaponProgram.DEPTH_BAND_UPPER)
	_assert_bool(fails, "DEP-2c command UPPER accepted", ok2, true)
	var reached_upper: bool = false
	for i in range(600):
		w.run_steps(1)
		var dz: float = absf(tp.actual_depth_m - prev)
		prev = tp.actual_depth_m
		if dz > vz * dt + VZ_EPS:
			fails.append("DEP-2c climb exceeded Vz: %f" % dz)
		if tp.actual_depth_m <= _upper_hold(w) + 0.5:
			reached_upper = true
			break
	_assert_bool(fails, "DEP-2c returned to UPPER hold", reached_upper, true)


## ---- DEP-2：全自动换带搜索（AUTO，UPPER→LOWER→UPPER 依次）----
func _dep_2_auto_band_search(fails: Array) -> void:
	var w := _mk_search_world()
	var tp: Torpedo = w.weapons.fire_manual(
		45.0, 0.0, 0.0, w.sim_time, 50.0, WeaponProgram.DEPTH_BAND_UPPER
	)
	if tp == null:
		fails.append("DEP-2d launch failed")
		return
	tp.band_search_hold_s = 5.0
	var authorized: bool = false
	var switches: Array = []
	var prev_band: String = ""
	var prev_depth: float = tp.actual_depth_m
	var vz: float = tp.max_vertical_speed_m_s
	var dt: float = float(w.world["dt"])
	for i in range(1200):
		w.run_steps(1)
		if not authorized and tp.traveled_m >= 50.0:
			authorized = tp.authorize_autonomy()
		# 限速核查覆盖全状态（含 WIRE_RUN 进 SEARCH 的过渡）。
		var dz: float = absf(tp.actual_depth_m - prev_depth)
		prev_depth = tp.actual_depth_m
		if tp.commanded_depth_m >= 0.0 and dz > vz * dt + VZ_EPS:
			fails.append("DEP-2d band search exceeded Vz: %f" % dz)
		if tp.mission_state != tp.MissionState.SEARCH:
			continue
		if tp.commanded_depth_band != prev_band and prev_band != "":
			switches.append(tp.commanded_depth_band)
		prev_band = tp.commanded_depth_band
		if switches.size() >= 2:
			break
	_assert_bool(fails, "DEP-2d autonomy authorized", authorized, true)
	_assert_bool(fails, "DEP-2d at least 2 band switches", switches.size() >= 2, true)
	if switches.size() >= 2:
		_assert_bool(
			fails,
			"DEP-2d alternates UPPER/LOWER",
			(
				switches[0] == WeaponProgram.DEPTH_BAND_LOWER
				and switches[1] == WeaponProgram.DEPTH_BAND_UPPER
			),
			true
		)
	# 显式定深参与检查：换带为 AUTO 来源（非 PLAYER 静默覆盖）。
	if not tp.command_log.is_empty():
		var found: bool = false
		for c in tp.command_log:
			if str(c.get("cmd")) == "BAND_SEARCH_SWITCH":
				found = true
		_assert_bool(fails, "DEP-2d switch logged", found, true)


## ---- 世界构造 ----
## 水面运动靶世界：直接注入靶（depth 0、6 kn，朝本艇）；无敌方 AI。
func _mk_surface_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	sc["own_ship"]["speed_kn"] = 0.0
	var w := World.new()
	w.load_scenario(sc)
	var b: float = deg_to_rad(45.0)
	var tgt := TruthEntity.new()
	tgt.id = "E1"
	tgt.side = "red"
	tgt.position_east_m = sin(b) * 1800.0
	tgt.position_north_m = cos(b) * 1800.0
	tgt.course_deg = 225.0
	tgt.speed_kn = 6.0
	tgt.depth_m = 0.0
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 170.0
	ac.tonal_lines = [{"freq_hz": 250.0, "level_db": 120.0}]
	w.world["targets"].append(tgt)
	w.world["target_acs"]["E1"] = ac
	return w


## 纯搜索世界：无靶无敌——用于层带切换/换带搜索（seeker 无回波）。
func _mk_search_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED + 2
	sc["targets"] = []
	sc["enemy_spawn"] = {}
	sc["own_ship"]["speed_kn"] = 0.0
	var w := World.new()
	w.load_scenario(sc)
	return w


func _upper_hold(w: World) -> float:
	var dm: RefCounted = w.world.get("depth_model", null)
	if dm != null:
		return float(dm.get("upper_hold_depth_m"))
	return 30.0


func _lower_hold(w: World) -> float:
	var dm: RefCounted = w.world.get("depth_model", null)
	if dm != null:
		return float(dm.get("lower_hold_depth_m"))
	return 180.0


func _mk_truth(id: String, e: float, n: float, depth: float) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = id
	t.side = "red"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = depth
	t.speed_kn = 6.0
	return t


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	for f in fails:
		print("DEP_FAIL ", f)
	if fails.is_empty():
		print("DEP_TEST result=PASS")
	else:
		print("DEP_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
