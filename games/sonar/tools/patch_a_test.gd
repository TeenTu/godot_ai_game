extends SceneTree
## patch_a_test.gd — 评审 Patch A 回归（数据正确性与身份）。
##
## 覆盖（评审文档 §二 Patch A / §六 AT-01/AT-02）：
##   PA-01（P0-01）敌方被动采样与事件截获的真方位来自几何 bearing_to_true，
##         绝不把目标深度当方位（depth_m != bearing_deg 的刻意组合）。
##   PA-02（P0-05）双方鱼雷 ID 全局唯一：玩家 "T01"、敌方 "ET01"；
##         fire_program 尊重 id_prefix，不按数组序号重编号。
##   PA-03（P1-09）敌方在水武器结算后计数释放：鱼雷 DEAD → notify_torpedo_
##         resolved 恰好一次 → doctrine 可再次反击（计数归零）。
##
## godot --headless --path games/sonar --script res://tools/patch_a_test.gd

const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_pa_01_enemy_bearing_geometry(fails)
	_pa_02_torpedo_id_uniqueness(fails)
	_pa_03_resolved_count_release(fails)
	_finish(fails)


## ---- PA-01：敌方感知方位 = 几何真方位（深度≠方位刻意组合）----
func _pa_01_enemy_bearing_geometry(fails: Array) -> void:
	var ad := _mk_adapter()
	var obs := _mk_entity("enemy", "red", 0.0, 0.0, 0.0, 100.0)
	# 目标：真方位 220°、2km、深度 50m、航速 10kn、响（SL0=170 → 确定性探测）。
	var b: float = deg_to_rad(220.0)
	var tgt := _mk_entity("S01", "blue", sin(b) * 2000.0, cos(b) * 2000.0, 10.0, 50.0)
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 170.0
	ad.contacts = [tgt]
	ad.contact_acs = {"S01": ac}

	# 被动连续声源：证据方位必须围绕 220°，绝不围绕 50°（= 深度值）。
	var out: Array = ad.sample_passive(obs, 100.0)
	_assert_bool(fails, "PA-01a passive contact detected", out.size() == 1, true)
	if not out.is_empty():
		var e: Dictionary = out[0]
		var err220: float = absf(NavUtils.wrap180(float(e["bearing_deg"]) - 220.0))
		var err50: float = absf(NavUtils.wrap180(float(e["bearing_deg"]) - 50.0))
		_assert_bool(
			fails,
			"PA-01b passive bearing ~220 (err=%.1f)" % err220,
			err220 <= 3.0 * float(e["bearing_sigma_deg"]),
			true
		)
		_assert_bool(fails, "PA-01c bearing NOT depth (err50=%.1f)" % err50, err50 > 20.0, true)

	# 声学事件截获：同一几何（方位 220°、深度 50m）→ 证据方位围绕 220°。
	var ad2 := _mk_adapter()
	var ev := _mk_event(AcousticEmissionEvent.PLATFORM_ACTIVE_PING, 220.0, 2000.0, 210.0)
	var out2: Array = ad2.intercept_events([ev], obs, 100.0)
	_assert_bool(fails, "PA-01d intercept detected", out2.size() == 1, true)
	if not out2.is_empty():
		var e2: Dictionary = out2[0]
		var err220b: float = absf(NavUtils.wrap180(float(e2["bearing_deg"]) - 220.0))
		var err50b: float = absf(NavUtils.wrap180(float(e2["bearing_deg"]) - 50.0))
		_assert_bool(
			fails,
			"PA-01e intercept bearing ~220 (err=%.1f)" % err220b,
			err220b <= 3.0 * float(e2["bearing_sigma_deg"]),
			true
		)
		_assert_bool(fails, "PA-01f intercept bearing NOT depth", err50b > 20.0, true)


## ---- PA-02：双方鱼雷 ID 唯一（id_prefix 生效）----
func _pa_02_torpedo_id_uniqueness(fails: Array) -> void:
	var wp := WeaponSystem.new()
	var we := WeaponSystem.new()
	we.id_prefix = "ET"  # 与 World._setup_enemy_ai 同一设置
	var tp1: Torpedo = wp.fire_bearing_only(45.0, 0.0, 0.0, 100.0, 50.0)
	var tp2: Torpedo = we.fire_bearing_only(45.0, 0.0, 0.0, 100.0, 50.0)
	var tp3: Torpedo = wp.fire_bearing_only(45.0, 0.0, 0.0, 100.0, 50.0)
	var tp4: Torpedo = we.fire_bearing_only(45.0, 0.0, 0.0, 100.0, 50.0)
	_assert_bool(
		fails,
		"PA-02a all launched",
		tp1 != null and tp2 != null and tp3 != null and tp4 != null,
		true
	)
	if tp1 == null or tp2 == null or tp3 == null or tp4 == null:
		return
	var ids: Dictionary = {}
	for tp in [tp1, tp2, tp3, tp4]:
		ids[str(tp.torpedo_id)] = true
	_assert_bool(fails, "PA-02b player id T01", str(tp1.torpedo_id) == "T01", true)
	_assert_bool(fails, "PA-02c enemy id ET01", str(tp2.torpedo_id) == "ET01", true)
	_assert_bool(
		fails,
		"PA-02d counters independent",
		str(tp3.torpedo_id) == "T02" and str(tp4.torpedo_id) == "ET02",
		true
	)
	_assert_bool(fails, "PA-02e ids globally unique", ids.size() == 4, true)


## ---- PA-03：敌方在水武器结算后计数释放（可再次反击）----
func _pa_03_resolved_count_release(fails: Array) -> void:
	var w := _mk_threat_world()
	var launched: bool = false
	var tp: Torpedo = null
	for i in range(900):
		w.run_steps(1)
		if w.enemy_weapons != null and not w.enemy_weapons.torpedoes.is_empty():
			launched = true
			tp = w.enemy_weapons.torpedoes[0]
			break
	_assert_bool(fails, "PA-03a enemy launched", launched, true)
	if not launched:
		return
	var doc: EnemyDoctrineController = w.enemy_ai
	_assert_bool(fails, "PA-03b count=1 after launch", doc.active_torpedo_count() == 1, true)
	# 强制结算：燃料耗尽 → FUEL_OUT → DEAD → WeaponSystem.step 过滤出数组。
	tp.fuel_left_s = 0.01
	w.run_steps(2)
	_assert_bool(fails, "PA-03c torpedo resolved", tp.is_dead(), true)
	_assert_bool(
		fails,
		"PA-03d count released after resolve (got %d)" % doc.active_torpedo_count(),
		doc.active_torpedo_count() == 0,
		true
	)


## ================= helpers =================


func _mk_threat_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
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


func _mk_adapter() -> EnemySensorAdapter:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var ad := EnemySensorAdapter.new()
	ad.bind(w.world["env"], w.world.get("depth_model", null), [], {})
	var r := RandomNumberGenerator.new()
	r.seed = SEED
	ad.set_rng(r)
	return ad


func _mk_entity(
	id: String, side: String, e: float, n: float, spd: float, depth: float
) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = id
	t.side = side
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = depth
	t.speed_kn = spd
	t.course_deg = 40.0
	t.turn_rate_deg_s = 1.5
	return t


## 事件：从原点出发 bearing/range 处、深度 50m 的声学事件。
func _mk_event(kind: String, bearing_deg: float, range_m: float, sl_db: float) -> Dictionary:
	var b: float = deg_to_rad(bearing_deg)
	var src := Vector3(sin(b) * range_m, cos(b) * range_m, 50.0)
	return AcousticEmissionEvent.make(1, kind, "TEST", 100.0, src, 3000.0, 1000.0, sl_db, 0.5)


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("PATCH_A_TEST result=PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("PATCH_A_TEST result=FAIL (%d)" % fails.size())
	quit(1)
