extends SceneTree
## truth_torpedo_overlay_test.gd — S109 §7 Show Truth 真值层隔离验收（AT-24..27）。
##
##   AT-24 真值集合同时包含己方和敌方在水鱼雷（§7.1 全字段）。
##   AT-25 鱼雷真方位用 NavUtils.bearing_to_true 从当前本艇位置计算；
##         四基准 N/E/S/W = 0/90/180/270°。
##   AT-26 Show Truth 开/关（provider 被调用 vs 完全不调用）两次同 seed 运行，
##         World 测量/威胁航迹/仿真状态摘要逐项一致（调试链纯读）。
##   AT-27 开关关闭 → truth_snapshot 恒空数组（海图不注入即无残留图元）；
##         main_ui 不得旁路直调 provider。


func _initialize() -> void:
	var fails: Array = []
	_at24_25(fails)
	_at26(fails)
	_at27(fails)
	_finish(fails)


func _at24_25(fails: Array) -> void:
	var w := _mk_world(90831)
	w.run_steps(20)
	var et := _fire_enemy_torpedo(w)
	var ot := _fire_own_torpedo(w)
	w.run_steps(10)
	_assert(fails, et != null and ot != null, "AT-24 both-side torpedoes in water")
	var torps: Array = TruthDebugProvider.collect_torpedoes(w)
	var sides := {}
	for e in torps:
		sides[str(e["side"])] = true
	_assert(
		fails,
		bool(sides.get("FRIENDLY", false)) and bool(sides.get("ENEMY", false)),
		"AT-24 truth set covers friendly + enemy torpedoes (got %s)" % str(sides)
	)
	var full: bool = true
	for e in torps:
		for k in [
			"debug_id",
			"kind",
			"pos",
			"depth_m",
			"course_deg",
			"speed_kn",
			"state",
			"bearing_from_own_deg",
			"range_from_own_m"
		]:
			if not e.has(k):
				full = false
	_assert(fails, full, "AT-24 §7.1 entry fields complete")
	# AT-25：四基准方位约定 + 逐雷一致（从当前本艇位置、观测者先参）。
	var own: TruthEntity = w.world["own"]
	var oe: float = float(own.position_east_m)
	var on: float = float(own.position_north_m)
	var brgs: Array = [
		NavUtils.bearing_to_true(oe, on, oe, on + 1000.0),
		NavUtils.bearing_to_true(oe, on, oe + 1000.0, on),
		NavUtils.bearing_to_true(oe, on, oe, on - 1000.0),
		NavUtils.bearing_to_true(oe, on, oe - 1000.0, on),
	]
	var ok4: bool = true
	for i in range(4):
		if absf(float(brgs[i]) - float(i * 90)) > 1e-6:
			ok4 = false
	_assert(fails, ok4, "AT-25 N/E/S/W = 0/90/180/270 (%s)" % str(brgs))
	var match_ok: bool = not torps.is_empty()
	for e in torps:
		var p: Vector2 = e["pos"]  # float32；provider 用 float64 内核坐标，容差按 float32 噪声。
		var expect: float = NavUtils.bearing_to_true(oe, on, p.x, p.y)
		if absf(float(e["bearing_from_own_deg"]) - expect) > 0.05:
			match_ok = false
		if absf(float(e["range_from_own_m"]) - NavUtils.distance(oe, on, p.x, p.y)) > 0.5:
			match_ok = false
	_assert(fails, match_ok, "AT-25 per-torpedo bearing/range from own match geometry")


func _at26(fails: Array) -> void:
	var da: String = _digest_run(90833, true)
	var db: String = _digest_run(90833, false)
	_assert(fails, da != "", "AT-26 digest produced")
	_assert(fails, da == db, "AT-26 Show Truth on/off runs identical")
	# 纯读：同一 World 上重复快照逐字节一致。
	var w := _mk_world(90835)
	w.run_steps(30)
	var s1: String = str(TruthDebugProvider.collect_truth(w))
	var s2: String = str(TruthDebugProvider.collect_truth(w))
	_assert(fails, s1 == s2, "AT-26 provider repeatable (read-only)")


func _at27(fails: Array) -> void:
	var w := _mk_world(90837)
	w.run_steps(20)
	_fire_enemy_torpedo(w)
	w.run_steps(10)
	_assert(
		fails,
		not TmaUiData.truth_snapshot(w, true).is_empty(),
		"AT-27 snapshot non-empty when shown"
	)
	_assert(
		fails,
		TmaUiData.truth_snapshot(w, false).is_empty(),
		"AT-27 snapshot empty when hidden (no residual primitives)"
	)
	var f: FileAccess = FileAccess.open("res://scripts/ui/main_ui.gd", FileAccess.READ)
	var src: String = f.get_as_text() if f != null else "MISSING"
	_assert(
		fails,
		not ("collect_truth(world)" in src),
		"AT-27 main_ui routes truth only via truth_snapshot"
	)


## 两次同 seed 运行摘要；probe=true 时每 10 tick 调 provider（模拟 Show Truth
## 全程开启）。任何 provider 对 World/RNG 的写入都会使两个摘要分叉。
func _digest_run(seed_val: int, probe: bool) -> String:
	var w := _mk_world(seed_val)
	_fire_enemy_torpedo(w)
	for i in range(120):
		w.run_steps(1)
		if probe and i % 10 == 0:
			TmaUiData.truth_snapshot(w, true)
	var own: TruthEntity = w.world["own"]
	var parts: Array = [
		"t=%.3f" % w.sim_time,
		(
			"own=%.9f,%.9f,%.6f,%.6f"
			% [own.position_east_m, own.position_north_m, own.course_deg, own.speed_kn]
		),
	]
	for t in w.world["targets"]:
		parts.append("T:%s=%.9f,%.9f" % [t.id, t.position_east_m, t.position_north_m])
	var ee: RefCounted = w.enemy_ai.entity
	parts.append("E:%s=%.9f,%.9f" % [ee.id, ee.position_east_m, ee.position_north_m])
	for sys in [w.weapons, w.enemy_weapons]:
		for tp in sys.torpedoes:
			parts.append(
				(
					"TP:%s=%.9f,%.9f,%s"
					% [tp.torpedo_id, tp.pos_east_m, tp.pos_north_m, tp.mission_state_name()]
				)
			)
	var ev_ids: Array = []
	for e in w.player_evidence:
		ev_ids.append("%s/%s" % [str(e.get("evidence_id", "")), str(e.get("bearing_deg", ""))])
	parts.append("EV=%d[%s]" % [w.player_evidence.size(), str(ev_ids).sha256_text()])
	var tts: Array = []
	for tr in w.threat_tracks.tracks():
		tts.append("%s:%s" % [str(tr.get("track_id", "")), str(tr.get("state", ""))])
	parts.append("TT=%d[%s]" % [w.threat_tracks.tracks().size(), str(tts).sha256_text()])
	return "|".join(parts)


func _fire_own_torpedo(w: World) -> Torpedo:
	var own: TruthEntity = w.world["own"]
	var prog := (
		WeaponProgram
		. make_bearing_only(
			(
				NavUtils
				. bearing_to_true(
					float(own.position_east_m),
					float(own.position_north_m),
					float(w.enemy_ai.entity.position_east_m),
					float(w.enemy_ai.entity.position_north_m),
				)
			)
		)
	)
	prog.autonomy_enable_distance_m = 2000.0
	return w.weapons.fire_program(
		prog,
		float(own.position_east_m),
		float(own.position_north_m),
		w.sim_time,
		float(own.depth_m)
	)


func _fire_enemy_torpedo(w: World) -> Torpedo:
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
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 100.0
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	return w.enemy_weapons.fire_program(
		prog, float(e.position_east_m), float(e.position_north_m), w.sim_time, float(e.depth_m)
	)


func _mk_world(seed_val: int) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["targets"] = []
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
		"fallback_spawn":
		{
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
		print("TRUTH-TORPEDO-OVERLAY TEST PASS")
		quit(0)
	else:
		print("TRUTH-TORPEDO-OVERLAY TEST FAIL (%d)" % fails.size())
		quit(1)
