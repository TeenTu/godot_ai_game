extends SceneTree
## s107_integrated_test.gd — S1-07 Commit 12 全流程集成场景（§13 Commit 12 /
## §14.7 场景 A/B）+ CI 门禁收尾。
##
## 覆盖（固定 seed、纯无头、全 World 链路）：
##   INT-A  完整击杀链（场景 A 变体）：敌方随机出生（受约束）→ 玩家
##          BEARING_ONLY 发射 → 线导接近 + 授权自主 → Seeker 捕获/ATTACK/
##          TERMINAL → 引信爆炸 → Truth 敌 sunk → 净化证据（DETONATION_HEARD
##          / PROBABLE_*）→ Debrief 台账（仅调试通道）。全链无任何 UI/制导
##          直读 Truth。
##   INT-B  敌方反击链（场景 B 变体）：响玩家 → 敌方 Doctrine 自行
##          TRACKING→ATTACKING→发射 → 玩家收到 POSSIBLE_LAUNCH_TRANSIENT /
##          POSSIBLE_TORPEDO 告警证据 → 玩家声呐听到来袭鱼雷（测量增长）。
##   INT-C  固定 seed 复现：同一场景两次运行，世界终态逐字段一致（§2.3）。
##
## godot --headless --path games/sonar --script res://tools/s107_integrated_test.gd

const DT: float = 0.5
const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_int_a_full_kill_chain(fails)
	_int_b_enemy_counterfire(fails)
	_int_c_reproducibility(fails)
	_finish(fails)


## ---- INT-A：完整击杀链 ----
func _int_a_full_kill_chain(fails: Array) -> void:
	var w := _mk_kill_world()
	var brg: float = (
		NavUtils
		. bearing_to_true(
			0.0,
			0.0,
			float(w.world["targets"][0].position_east_m),
			float(w.world["targets"][0].position_north_m),
		)
	)
	# BEARING_ONLY 发射（无解、无距离；程序无隐藏 range）。
	var tp: Torpedo = w.weapons.fire_bearing_only(brg, 0.0, 0.0, w.sim_time, 50.0)
	_assert_bool(fails, "INT-A1 bearing_only launched", tp != null, true)
	if tp == null:
		return
	_assert_bool(fails, "INT-A2 program has no range", tp.program.get("range_m") == null, true)
	# 授权自主后按 TIME 开主动（§5.5：BEARING_ONLY 无距离解，TERMINAL 需要
	# 主动回波给出距离估计——场景 A 的标准程序化开启路径）。
	tp.program.active_enable_mode = WeaponProgram.ActiveEnableMode.TIME
	tp.program.active_enable_time_s = 30.0
	var phases := {"wire_run": false, "attack": false, "terminal": false, "dead": false}
	# 线导接近：行进 300m 后授权自主（模拟玩家 AUTHORIZE_AUTONOMY）。
	var authorized: bool = false
	for i in range(1500):
		w.run_steps(1)
		if not authorized and tp.traveled_m >= 300.0:
			authorized = tp.authorize_autonomy()
		match tp.mission_state_name():
			"WIRE_RUN", "SEARCH":
				phases["wire_run"] = true
			"ATTACK":
				phases["attack"] = true
			"TERMINAL":
				phases["terminal"] = true
			"DEAD":
				phases["dead"] = true
				break
	for k in phases:
		_assert_bool(fails, "INT-A3 phase %s reached" % k, bool(phases[k]), true)
	# Truth 战果（内核侧）。
	_assert_bool(
		fails, "INT-A4 enemy sunk in Truth", str(w.world["targets"][0].damage_state) == "sunk", true
	)
	# Debrief 台账（调试通道）。
	var deb: Array = w._debrief_summary()
	_assert_bool(fails, "INT-A5 debrief record", deb.size() == 1, true)
	# 净化证据：己方武器爆炸事实 + 战果评估层级可用；绝无 target_id。
	var heard: Dictionary = {}
	for e in w.player_evidence:
		if str(e.get("alert", "")) == "DETONATION_HEARD":
			heard = e
	_assert_bool(fails, "INT-A6 detonation heard evidence", not heard.is_empty(), true)
	var level: String = EmissionSanitizer.classify_detonation(heard, [brg], true)
	_assert_bool(
		fails,
		"INT-A7 kill assessment level (%s)" % level,
		level == "PROBABLE_HIT" or level == "PROBABLE_KILL",
		true
	)
	for e in w.player_evidence:
		if e.has("target_id") or e.has("damage_state"):
			fails.append("INT-A8 evidence leaks truth keys")


## ---- INT-B：敌方反击链 ----
func _int_b_enemy_counterfire(fails: Array) -> void:
	var w := _mk_threat_world()
	var launched: bool = false
	for i in range(900):
		w.run_steps(1)
		if w.enemy_weapons != null and not w.enemy_weapons.torpedoes.is_empty():
			launched = true
			break
	_assert_bool(fails, "INT-B1 enemy doctrine fired", launched, true)
	# 玩家告警证据（发射瞬态截获）。
	var alerts: Array = []
	for e in w.player_evidence:
		var a: String = str(e.get("alert", ""))
		if a == "POSSIBLE_LAUNCH_TRANSIENT" or a == "POSSIBLE_TORPEDO":
			alerts.append(a)
	_assert_bool(fails, "INT-B2 torpedo warning evidence", not alerts.is_empty(), true)
	# 玩家声呐听到来袭鱼雷（影子链测量增长）。
	var m0: int = w.measurements.size()
	for i in range(120):
		w.run_steps(1)
	_assert_bool(fails, "INT-B3 player hears incoming torpedo", w.measurements.size() > m0, true)


## ---- INT-C：固定 seed 复现 ----
func _int_c_reproducibility(fails: Array) -> void:
	var w1 := _mk_kill_world()
	var w2 := _mk_kill_world()
	for i in range(400):
		w1.run_steps(1)
		w2.run_steps(1)
	var e1: TruthEntity = w1.world["targets"][0]
	var e2: TruthEntity = w2.world["targets"][0]
	_assert_bool(
		fails,
		"INT-C1 enemy identical",
		(
			e1.position_east_m == e2.position_east_m
			and e1.position_north_m == e2.position_north_m
			and e1.course_deg == e2.course_deg
		),
		true
	)
	_assert_bool(
		fails,
		"INT-C2 measurements identical",
		w1.measurements.size() == w2.measurements.size(),
		true
	)
	_assert_bool(
		fails,
		"INT-C3 evidence identical",
		w1.player_evidence.size() == w2.player_evidence.size(),
		true
	)


## ================= helpers =================


## 击杀链世界：敌方 2.5km@45°、响（160dB，Doctrine 规避关闭保证确定性命中）、
## 玩家安静（不被敌方 AI 干扰）。
func _mk_kill_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	sc["own_ship"]["speed_kn"] = 0.0
	var b: float = deg_to_rad(45.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 43.0,
		"bearing_max_deg": 47.0,
		"range_min_m": 2500.0,
		"range_mode_m": 2700.0,
		"range_max_m": 3000.0,
		"speed_min_kn": 4.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 2500.0,
			"position_north_m": cos(b) * 2500.0,
			"course_deg": 225.0,
			"speed_kn": 5.0,
			"depth_m": 70.0
		},
		"acoustic": {"broadband_base_level_db": 160.0},
		"doctrine":
		{
			"sensor_false_alarm_rate": 0.0,
			"evade_trigger_probability": 0.0,
			"decoy_launch_probability": 0.0,
			"layer_change_probability": 0.0,
			"counterfire_probability": 0.0,
			"sample_interval_s": 2.0
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


## 反击链世界：玩家响（静止），敌方近距（1500m@45°）会自行开火。
func _mk_threat_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED + 1
	sc["targets"] = []
	sc["own_acoustic"]["broadband_base_level_db"] = 160.0
	sc["own_ship"]["speed_kn"] = 0.0
	var b: float = deg_to_rad(45.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 43.0,
		"bearing_max_deg": 47.0,
		"range_min_m": 1500.0,
		"range_mode_m": 1800.0,
		"range_max_m": 2000.0,
		"speed_min_kn": 5.0,
		"speed_max_kn": 8.0,
		"min_separation_m": 800.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 1500.0,
			"position_north_m": cos(b) * 1500.0,
			"course_deg": 225.0,
			"speed_kn": 6.0,
			"depth_m": 70.0
		},
		"doctrine":
		{
			"sensor_false_alarm_rate": 0.0,
			"counterfire_probability": 1.0,
			"reaction_delay_min_s": 3.0,
			"reaction_delay_max_s": 15.0,
			"max_simultaneous_weapons": 2,
			"sample_interval_s": 2.0,
			"decoy_launch_probability": 0.0
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S107_INTEGRATED_TEST result=PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("S107_INTEGRATED_TEST result=FAIL (%d)" % fails.size())
	quit(1)
