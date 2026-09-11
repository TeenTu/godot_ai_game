extends SceneTree
## threat_multi_return_test.gd — S109 §5 多回波/一对一/选择纪律验收
## （AT-17 / AT-18 / AT-19 + P0-07/P0-08 回归）。
##
##   MR-17  一次 Ping 多回波（敌潜艇 + 逼近敌雷）：每条回波独立
##          ActiveReturnRecord（local_return_id 唯一、measurement 保留）；
##          PG-05 后归到威胁航迹（TT）的回波只留档、不另建普通航迹；
##          ASSISTED 待 Apply = 本次 Ping 最高优先的**可拟合**回波——
##          既不是"最后写入"，也不会落在无普通航迹的 TT 回波上（P0-07）。
##   MR-18  同帧两条近方位证据 → 一对一分配：不得贪心并入同一 TT。
##   MR-19  静态扫描：main_ui 回波回调/重拟合回调不得写 selected_track_id
##          （P0-08：主动回波不抢玩家当前选择）。

const SEED := 90811


func _initialize() -> void:
	var fails: Array = []
	_mr_18(fails)
	_mr_19(fails)
	_mr_17(fails)
	_finish(fails)


func _mr_17(fails: Array) -> void:
	var w := _mk_world(SEED)
	w.auto_measurements = false
	w.run_steps(30)
	var tp := _fire_enemy_torpedo(w)
	if tp == null:
		fails.append("MR-17 enemy torpedo launched")
		_finish(fails)
		return
	_approach_torpedo(w, 1500.0)
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.fit_mode = ActivePingController.MODE_ASSISTED
	var fit: Array = []
	c.on_fit_requested = func(tid: String) -> void: fit.append(tid)
	if not w.issue_ping():
		fails.append("MR-17 issue_ping")
		_finish(fails)
		return
	# 阶段一：等到第一条回波定标 preferred。
	for i in range(120):
		w.run_steps(1)
		c.refresh_panel(null)
		if not c.records_snapshot().is_empty():
			break
	var recs0: Array = c.records_snapshot()
	if not recs0.is_empty():
		c.preferred_track_id = str(recs0[0]["track_id"])
	# 阶段二：其余回波到达；ASSISTED 每次重裁决都按 preferred 优先。
	for i in range(240):
		w.run_steps(1)
		c.refresh_panel(null)
	var recs: Array = c.records_snapshot()
	_assert(fails, recs.size() >= 2, "MR-17 multi-echo records kept: %d" % recs.size())
	if recs.size() < 2:
		_finish(fails)
		return
	# 每条记录：local_return_id 唯一、range 有效、同一 ping_id。
	var rid_set: Dictionary = {}
	var pid: int = int(recs[0]["ping_id"])
	var all_ok: bool = true
	for r in recs:
		if rid_set.has(str(r["local_return_id"])) or float(r["range_m"]) <= 0.0:
			all_ok = false
		if int(r["ping_id"]) != pid:
			all_ok = false
		rid_set[str(r["local_return_id"])] = true
	_assert(fails, all_ok, "MR-17 distinct local_return_id + range kept per echo")
	# PG-05：归到威胁航迹的回波留档但不另建普通航迹（信息只融合一次，不双计）。
	var tt_recs: Array = []
	var ct_recs: Array = []
	for r in recs:
		if str(r.get("owner_kind", "")) == ActiveReturnAttribution.KIND_THREAT:
			tt_recs.append(r)
		elif str(r.get("owner_kind", "")) == ActiveReturnAttribution.KIND_CONTACT:
			ct_recs.append(r)
	_assert(fails, not tt_recs.is_empty(), "MR-17 threat-owned echo recorded (owner_kind=THREAT)")
	if not tt_recs.is_empty():
		var tt_tid: String = str(tt_recs[0]["track_id"])
		_assert(
			fails,
			tt_tid.begins_with("TT"),
			"MR-17 threat-owned echo keeps its TT label (%s)" % tt_tid
		)
		_assert(
			fails,
			c.tracker.track_by_id(tt_tid) == null,
			"MR-17 threat-owned echo builds no ordinary track (%s)" % tt_tid
		)
	var last_tid: String = str(recs[recs.size() - 1]["track_id"])
	# preferred/pending 只认可拟合回波：本次 Ping 中优先级最高的普通接触，
	# 而不是"最后写入"的那条（PG-05 后第一条回波已归 TT，无普通航迹可拟合）。
	var first_tid: String = ""
	if ct_recs.size() >= 2:
		first_tid = str(ct_recs[0]["track_id"])
		c.preferred_track_id = first_tid
	var pend_before: String = c.pending_track_id()
	if first_tid != "" and first_tid != last_tid:
		_assert(
			fails,
			pend_before == first_tid,
			(
				"MR-17 pending Apply = preferred fittable echo (%s) not last-written (%s)"
				% [first_tid, last_tid]
			),
		)
	_assert(
		fails,
		pend_before != "" and c.tracker.track_by_id(pend_before) != null,
		"MR-17 pending Apply targets a fittable ordinary track (%s)" % pend_before
	)
	# Apply → 拟合请求目标 = pending 记录的 Track。
	if c.has_pending_apply():
		if c.apply_pending():
			_assert(
				fails,
				not fit.is_empty() and str(fit[0]) == pend_before,
				(
					"MR-17 apply fits the pending record (fit=%s want=%s)"
					% [str(fit[0]) if not fit.is_empty() else "-", pend_before]
				),
			)
	else:
		fails.append("MR-17 ASSISTED pending armed after multi-echo")
		_finish(fails)
		return


func _mr_18(fails: Array) -> void:
	var mgr := ThreatTrackManager.new()
	var ev1 := _ev(1, 90.2)
	var ev2 := _ev(2, 90.6)
	mgr.ingest(ev1, 10.0)
	mgr.ingest(ev2, 10.0)
	_assert(fails, mgr.tracks().size() == 2, "MR-18 near-bearing pair not merged")
	_assert(
		fails,
		str(ev2.get("threat_track_id", "")) != str(ev1.get("threat_track_id", "")),
		"MR-18 one-to-one assignment (no greedy reuse of one track)"
	)
	# 下一帧新证据仍可正常关联最优航迹（exclusivity 不跨帧）。
	var ev3 := _ev(3, 90.3)
	mgr.ingest(ev3, 11.0)
	_assert(fails, str(ev3.get("threat_track_id", "")) != "", "MR-18 next-frame association works")


func _mr_19(fails: Array) -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/ui/main_ui.gd")
	_assert(fails, src.length() > 100, "MR-19 main_ui.gd readable")
	for fname in ["_on_ping_echo_hits", "_on_ping_fit_requested"]:
		var i0: int = src.find("func " + fname)
		var body: String = ""
		if i0 >= 0:
			var i1: int = src.find("\nfunc ", i0 + 5)
			body = src.substr(i0, (i1 if i1 > 0 else src.length()) - i0)
		_assert(
			fails,
			i0 >= 0 and not body.contains("selected_track_id ="),
			"MR-19 %s never steals selection" % fname
		)


# ---------------- helpers ----------------


func _ev(id: int, brg: float) -> Dictionary:
	return {
		"evidence_id": id,
		"evidence_kind": "RUNNING_NOISE",
		"bearing_deg": brg,
		"bearing_sigma_deg": 1.0,
		"confidence": 0.8,
		"p_torpedo": 0.8,
		"class_state": "PROBABLE_TORPEDO",
		"observer_e_m": 0.0,
		"observer_n_m": 0.0,
		"timestamp": 10.0,
	}


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


func _approach_torpedo(w: World, max_rng: float) -> void:
	for i in range(300):
		w.run_steps(1)
		if not w.enemy_weapons.torpedoes.is_empty():
			var t0: Torpedo = w.enemy_weapons.torpedoes[0]
			var d: float = (
				NavUtils
				. distance(
					float(t0.pos_east_m),
					float(t0.pos_north_m),
					float(w.world["own"].position_east_m),
					float(w.world["own"].position_north_m),
				)
			)
			if d <= max_rng:
				return


func _mk_world(seed_val: int) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
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
		print("THREAT-MULTI-RETURN TEST PASS")
		quit(0)
	else:
		print("THREAT-MULTI-RETURN TEST FAIL (%d)" % fails.size())
		quit(1)
