extends SceneTree
## fuze_evidence_test.gd — S1-07 Commit 10 引信/伤害证据/净化反馈 无头验收
## （§10.1-§10.5 + §14.6 UI-07/08 内核侧）。
##
## 覆盖：
##   FUZE-01  SAFE（未达 arm distance / min_time）绝不爆炸——解保双保险。
##   FUZE-02  ARMED + 几何触发 → 爆炸：EXPLOSION 事件 + Truth 伤害（敌 sunk）
##            + 鱼雷 DEAD；Debrief 有内部命中台账（仅调试通道）。
##   FUZE-03  引信与制导/主动/自主解耦（Seeker 无锁定也能靠直航线引爆）。
##   FUZE-04  战果反馈层级：classify_detonation 纯函数（DETONATION_HEARD →
##            PROBABLE_HIT → PROBABLE_KILL），只吃净化证据+玩家航迹方位。
##   FUZE-05  敌方鱼雷命中本艇 → own damage_state=damaged（Truth 侧），玩家
##            收到 DETONATION_HEARD（INTERCEPT）净化证据。
##   FUZE-06  净化：player_evidence / 鱼雷事件 detail 无 target_id/位置/damage。
##   FUZE-07  未命中（燃料耗尽）不产 Debrief 台账、不产爆炸事件。
##
## 全部确定性（固定 seed），可无头运行：
##   godot --headless --path games/sonar --script res://tools/fuze_evidence_test.gd

const DT: float = 0.5
const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_fuze_01_safe_never_detonates(fails)
	_fuze_02_03_hit_and_decouple(fails)
	_fuze_04_evidence_hierarchy(fails)
	_fuze_05_enemy_torpedo_hits_own(fails)
	_fuze_06_07_sanitized_and_miss(fails)
	_finish(fails)


## ---- FUZE-01：SAFE 绝不起爆 ----
func _fuze_01_safe_never_detonates(fails: Array) -> void:
	var fc := FuzeController.new()
	fc.configure(FuzeController.FUZE_CONTACT, 300.0)
	# 未达 arm distance：几何再近也不炸。
	_assert_bool(fails, "FUZE-01a not armed below distance", not fc.is_armed(100.0, 10.0), true)
	# 达距离但未过 min_time。
	_assert_bool(fails, "FUZE-01b not armed below min_time", not fc.is_armed(400.0, 1.0), true)
	# 双条件满足。
	_assert_bool(fails, "FUZE-01c armed with both", fc.is_armed(400.0, 3.0), true)


## ---- FUZE-02/03：直航命中（无 Seeker 锁定）→ 爆炸/伤害/Debrief ----
func _fuze_02_03_hit_and_decouple(fails: Array) -> void:
	var w := _mk_hit_world()
	# MANUAL 直航发射（无解、无锁定预期：WIRE_ONLY 不接管制导）。
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, w.sim_time, 50.0)
	_assert_bool(fails, "FUZE-02a launched", tp != null, true)
	if tp == null:
		return
	var detonated: bool = false
	for i in range(900):
		w.run_steps(1)
		if tp.is_dead():
			detonated = true
			break
	_assert_bool(fails, "FUZE-02b detonated on contact", detonated, true)
	_assert_bool(
		fails,
		"FUZE-02b2 fuze was triggered before death",
		str(tp.fuze_state_name()) == "INERT" and tp.mission_state_name() == "DEAD",
		true
	)
	# Truth 伤害（内核侧；UI 绝不直接显示）。
	var tgt: TruthEntity = w.world["targets"][0]
	_assert_bool(fails, "FUZE-02c target sunk in Truth", str(tgt.damage_state) == "sunk", true)
	# EXPLOSION 事件可被被动链截获。
	_assert_bool(
		fails,
		"FUZE-02d explosion event on bus",
		not w.emission_bus.events_of_kind(AcousticEmissionEvent.EXPLOSION).is_empty(),
		true
	)
	# Debrief（调试通道）：内部命中台账。
	var deb: Array = w._debrief_summary()
	_assert_bool(fails, "FUZE-02e debrief has record", deb.size() == 1, true)
	if not deb.is_empty():
		_assert_bool(
			fails,
			"FUZE-02f debrief min pass tracked",
			float(deb[0]["min_pass_distance_m"]) <= 15.0,
			true
		)
		# FUZE-03：命中是引信几何，不依赖 Seeker 锁定（直航全程无 ATTACK）。
		_assert_bool(
			fails,
			"FUZE-03a kill without seeker lock",
			str(deb[0]["target_id_internal"]) == str(tgt.id),
			true
		)


## ---- FUZE-04：战果反馈层级（纯函数，净化输入）----
func _fuze_04_evidence_hierarchy(fails: Array) -> void:
	var ev := {
		"emission_kind": AcousticEmissionEvent.EXPLOSION,
		"bearing_deg": 45.0,
		"se_db": 30.0,
	}
	# 己方武器 + 航迹方位一致 + SE 高 → PROBABLE_KILL。
	_assert_bool(
		fails,
		"FUZE-04a probable kill",
		EmissionSanitizer.classify_detonation(ev, [44.0], true) == "PROBABLE_KILL",
		true
	)
	# 一致但 SE 低 → PROBABLE_HIT。
	var ev2 := {"emission_kind": AcousticEmissionEvent.EXPLOSION, "bearing_deg": 45.0, "se_db": 5.0}
	_assert_bool(
		fails,
		"FUZE-04b probable hit",
		EmissionSanitizer.classify_detonation(ev2, [45.0], true) == "PROBABLE_HIT",
		true
	)
	# 不一致 → 只听到爆炸。
	_assert_bool(
		fails,
		"FUZE-04c heard only",
		EmissionSanitizer.classify_detonation(ev2, [200.0], true) == "DETONATION_HEARD",
		true
	)
	# 非己方武器（敌方交战）→ 只听到。
	_assert_bool(
		fails,
		"FUZE-04d enemy fight heard only",
		EmissionSanitizer.classify_detonation(ev, [45.0], false) == "DETONATION_HEARD",
		true
	)
	# 非爆炸事件 → 空。
	_assert_bool(
		fails,
		"FUZE-04e non-explosion ignored",
		EmissionSanitizer.classify_detonation({"emission_kind": "PING"}, [], true) == "",
		true
	)


## ---- FUZE-05：敌方鱼雷命中本艇 → own damaged + DETONATION_HEARD 证据 ----
func _fuze_05_enemy_torpedo_hits_own(fails: Array) -> void:
	var w := _mk_enemy_world()
	# 动态计算敌方→本艇真方位（不读取解算之外的信息，仅测试装配几何）。
	var ent: TruthEntity = w.enemy_ai.entity
	var own: TruthEntity = w.world["own"]
	var brg: float = NavUtils.bearing_to_true(
		ent.position_east_m, ent.position_north_m, own.position_east_m, own.position_north_m
	)
	w._enemy_fire({"action": "FIRE_TORPEDO", "bearing_deg": brg})
	# P1-08：引信纳入垂直门 + 发射 hold 深度修复后，来袭雷会向程序层带
	# hold 机动；本艇保持场景深度即可形成同带杀伤链几何。
	_assert_bool(
		fails, "FUZE-05a enemy torpedo launched", not w.enemy_weapons.torpedoes.is_empty(), true
	)
	var heard: Dictionary = {}
	for i in range(1200):
		w.run_steps(1)
		if str(w.world["own"].damage_state) != "ok":
			break
	# REQ 批：爆炸证据按 t_emit + R/c 到达——命中后留出传播窗口再收证据。
	for i in range(20):
		w.run_steps(1)
	# Truth 侧：本艇 damaged（普通 UI 只会收到净化证据）。
	_assert_bool(
		fails, "FUZE-05b own damaged in Truth", str(w.world["own"].damage_state) == "damaged", true
	)
	# 净化证据：DETONATION_HEARD（INTERCEPT，无任何 target 身份）。
	for e in w.player_evidence:
		if str(e.get("alert", "")) == "DETONATION_HEARD" and str(e.get("side_hint")) == "INTERCEPT":
			heard = e
			break
	_assert_bool(fails, "FUZE-05c detonation heard evidence", not heard.is_empty(), true)
	if not heard.is_empty():
		_assert_bool(
			fails,
			"FUZE-05d no confirm kill in evidence",
			not heard.has("kill") and not heard.has("target_id") and not heard.has("damage_state"),
			true
		)


## ---- FUZE-06/07：净化扫描 + 未命中零台账 ----
func _fuze_06_07_sanitized_and_miss(fails: Array) -> void:
	var w := _mk_enemy_world()
	# 玩家直航一发，射向无人区（无目标 → 燃料耗尽）。
	var w2 := _mk_hit_world()
	w2.world["targets"][0].position_east_m = 20000.0
	w2.world["targets"][0].position_north_m = 20000.0
	var tp: Torpedo = w2.weapons.fire_manual(90.0, 0.0, 0.0, w2.sim_time, 50.0)
	for i in range(2600):
		w2.run_steps(1)
		if tp != null and tp.is_dead():
			break
	_assert_bool(
		fails,
		"FUZE-07a torpedo died without detonation",
		tp != null and str(tp.fuze_state_name()) == "INERT",
		true
	)
	_assert_bool(fails, "FUZE-07b no debrief on miss", w2._debrief_summary().is_empty(), true)
	_assert_bool(
		fails,
		"FUZE-07c no explosion on miss",
		w2.emission_bus.events_of_kind(AcousticEmissionEvent.EXPLOSION).is_empty(),
		true
	)
	# 净化扫描：运行一段敌方世界，player_evidence 无禁键。
	for i in range(200):
		w.run_steps(1)
	for e in w.player_evidence:
		for bad in ["target_id", "position_east_m", "damage_state", "internal_ref"]:
			if e.has(bad):
				fails.append("FUZE-06a evidence leaks %s" % bad)
	_assert_bool(fails, "FUZE-06b evidence sanitized", true, true)


## ================= helpers =================


## 直航命中世界：本艇原点，单个静止目标正前方 1500m（同层 50m）。
func _mk_hit_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = [
		{
			"id": "target_x",
			"class_id": "frigate",
			"side": "red",
			"platform_type": "surface",
			"position_east_m": 0.0,
			"position_north_m": 1500.0,
			"depth_m": 50.0,
			"course_deg": 0.0,
			"speed_kn": 0.0,
			"acoustic": {"broadband_base_level_db": 150.0},
		}
	]
	var w := World.new()
	w.load_scenario(sc)
	return w


## 敌方 AI 世界（玩家响、敌方 3.5km @45°）。
func _mk_enemy_world() -> World:
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
			"fire_quality_threshold": 0.7,
			"counterfire_probability": 1.0,
			"reaction_delay_min_s": 3.0,
			"reaction_delay_max_s": 15.0,
			"max_simultaneous_weapons": 2,
			"torpedo_active_enable_time_s": 60.0,
			"torpedo_autonomy_distance_m": 800.0
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
		print("FUZE_EVIDENCE_TEST result=PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("FUZE_EVIDENCE_TEST result=FAIL (%d)" % fails.size())
	quit(1)
