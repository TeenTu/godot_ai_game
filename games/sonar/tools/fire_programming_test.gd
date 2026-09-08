extends SceneTree
## REQ-0908 Batch 4 — 发射前武器编程与自然命中闭环验收（REQ-B4-01~04）。
##
## 覆盖（无头可验证）：
##   验收 1  SOLUTION 程序 source_track_id/source_solution_version 与提交解一致；
##   验收 2  stale 解被联锁拒绝（build_program 返回 SOLUTION_STALE）；
##   验收 3  发射后被动监听立即 ON、主动 TX 默认 OFF；
##   验收 4  到达自治触发条件（DISTANCE）后自动进入允许自主制导状态；
##   验收 5  MANUAL active 可由导线开启；导线切断后命令无效并执行 fallback；
##   验收 6  LaunchProgrammer 玩家覆盖项生效（BEARING_ONLY/MANUAL 路径）；
##   验收 7  固定自然场景真实发生起爆与伤害（敌舰 damage_state=sunk）。
## 运行：godot --headless --path games/sonar --script res://tools/fire_programming_test.gd

const SEED := 1001


func _initialize() -> void:
	var fails: Array = []
	var ctx: Dictionary = _natural_scenario(SEED)
	var w: World = ctx["world"]
	var fcc: FireControlContext = ctx["fcc"]
	var tracker: Tracker = ctx["tracker"]
	var track: Track = ctx["track"]

	# ---- 验收 1：SOLUTION 程序来源绑定与提交解一致 ----
	var prog: WeaponProgram = null
	var prog_res: Dictionary = ctx["programmer"].build_program(
		"SOLUTION", w.weapons, w, fcc, tracker, track.track_id
	)
	_assert(
		fails,
		bool(prog_res.get("ok", false)),
		"SOLUTION program built: %s" % str(prog_res.get("reason", ""))
	)
	if bool(prog_res.get("ok", false)):
		prog = prog_res["program"]
		_assert(
			fails,
			prog.source_track_id == track.track_id and prog.source_solution_version > 0,
			(
				"program source_track_id/version bound to committed solution (%s v%d)"
				% [prog.source_track_id, prog.source_solution_version]
			),
		)
		_assert(
			fails,
			absf(prog.source_solution_time - w.sim_time) < 1e-6,
			"program source_solution_time = solution commit time",
		)
		# REQ-B4-02 推荐默认：自治 DISTANCE（由解射程推导）、主动 MANUAL。
		_assert(
			fails,
			(
				prog.autonomy_enable_mode == WeaponProgram.AutonomyEnableMode.DISTANCE
				and prog.autonomy_enable_distance_m >= 800.0
			),
			"SOLUTION recommended autonomy DISTANCE from estimated range",
		)
		_assert(
			fails,
			prog.active_enable_mode == WeaponProgram.ActiveEnableMode.MANUAL,
			"SOLUTION recommended active TX stays MANUAL",
		)

		# ---- 验收 2：证据变化 → 解 STALE → 发射联锁拒绝 ----
		var m_extra := Measurement.new()
		m_extra.timestamp = w.sim_time + 1.0
		m_extra.detected = true
		m_extra.measured_bearing_deg = 47.0
		m_extra.bearing_sigma_deg = 1.0
		m_extra.observer_east_m = 0.0
		m_extra.observer_north_m = 0.0
		m_extra.evidence_id = "ev_extra_stale"
		track.add_measurement(m_extra)
		fcc.sync_revision(track)
		var stale_res: Dictionary = ctx["programmer"].build_program(
			"SOLUTION", w.weapons, w, fcc, tracker, track.track_id
		)
		_assert(
			fails,
			(
				not bool(stale_res.get("ok", false))
				and str(stale_res.get("reason", "")) == "SOLUTION_STALE"
			),
			"stale solution rejected by programmer interlock",
		)

		# ---- 验收 3/4：用旧程序快照发射（发射前构建，模拟 stale 之前）----
		var tp: Torpedo = w.weapons.fire_program(prog, 0.0, 0.0, w.sim_time, 50.0)
		_assert(fails, tp != null, "torpedo launched from program snapshot")
		if tp != null:
			_assert(
				fails,
				(
					bool(tp.passive_receiver_on)
					and int(tp.active_tx_state) == Torpedo.ActiveTxState.OFF
				),
				"post-launch passive receiver ON / active TX OFF",
			)
			# ---- 验收 4：自治条件（DISTANCE）自动满足 → AUTONOMOUS ----
			var became_auto: bool = (
				int(tp.guidance_authority) == Torpedo.GuidanceAuthority.AUTONOMOUS
			)
			for i in range(1200):
				w.run_steps(1)
				if int(tp.guidance_authority) == Torpedo.GuidanceAuthority.AUTONOMOUS:
					became_auto = true
					break
			print(
				(
					"DBG autonomy: became=%s auth=%d traveled=%.0f need=%.0f state=%s dead=%s"
					% [
						str(became_auto),
						int(tp.guidance_authority),
						float(tp.traveled_m),
						float(tp.program.autonomy_enable_distance_m),
						tp.mission_state_name(),
						str(tp.is_dead())
					]
				)
			)
			_assert(fails, became_auto, "autonomy DISTANCE trigger engages automatically")
			# ---- 验收 5：导线在时 MANUAL active；切断后命令拒绝 + fallback ----
			var tx_ok: bool = tp.set_active_tx(true)
			_assert(
				fails,
				tx_ok and int(tp.active_tx_state) != Torpedo.ActiveTxState.OFF,
				"manual active TX enabled via wire",
			)
			var cut_ok: bool = tp.cut_wire()
			var tx_after: bool = tp.set_active_tx(false) if cut_ok else true
			_assert(
				fails,
				cut_ok and not tx_after,
				"command rejected after wire cut",
			)
			_assert(fails, bool(tp._fallback_active), "fallback program engaged after wire cut")

	# ---- 验收 6：BEARING_ONLY / MANUAL 程序与玩家覆盖项 ----
	var p2 := LaunchProgrammer.new()
	p2.search_half_angle_deg = 45.0
	p2.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	p2.autonomy_enable_value = 800.0
	var bo_res: Dictionary = p2.build_program(
		"BEARING_ONLY", w.weapons, w, fcc, tracker, track.track_id
	)
	if bool(bo_res.get("ok", false)):
		var bo: WeaponProgram = bo_res["program"]
		_assert(
			fails,
			(
				bo.fire_mode == WeaponProgram.FireMode.BEARING_ONLY
				and bo.search_half_angle_deg == 45.0
				and bo.autonomy_enable_mode == WeaponProgram.AutonomyEnableMode.DISTANCE
				and absf(bo.autonomy_enable_distance_m - 800.0) < 1e-6
			),
			"BEARING_ONLY uses wide sector + editable autonomy (player overrides apply)",
		)
	else:
		_assert(fails, false, "BEARING_ONLY program built")
	var p3 := LaunchProgrammer.new()
	p3.initial_course_deg = 123.0
	var man_res: Dictionary = p3.build_program("MANUAL", w.weapons, w, fcc, tracker, "")
	if bool(man_res.get("ok", false)):
		var mp: WeaponProgram = man_res["program"]
		_assert(
			fails,
			(
				mp.fire_mode == WeaponProgram.FireMode.MANUAL
				and absf(mp.initial_course_deg - 123.0) < 1e-6
			),
			"MANUAL program uses explicit player course (no track needed)",
		)
	else:
		_assert(fails, false, "MANUAL program built")

	# ---- 验收 7：真实起爆/伤害（本 seed 自然链命中；不按 Truth 瞄准）----
	# A 雷已被切线进入 fallback；从另一管用同一程序快照补射 B 雷完 成闭环。
	if prog != null:
		var tp_b: Torpedo = w.weapons.fire_program(prog, 0.0, 0.0, w.sim_time, 50.0)
		_assert(fails, tp_b != null, "second tube fires same program snapshot")
		var enemy: TruthEntity = w.world["targets"][0]
		var sunk: bool = str(enemy.damage_state) == "sunk"
		for i in range(1600):
			if sunk:
				break
			w.run_steps(1)
			sunk = str(enemy.damage_state) == "sunk"
		_assert(fails, sunk, "fixed natural scenario produced real detonation (damage_state=sunk)")

	_finish(fails)


## 自然链场景：autocrew → Tracker → TMA → Enter Solution（绝不读 Truth 瞄准）。
func _natural_scenario(seed_val: int) -> Dictionary:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["duration"] = 99999.0
	sc["own_ship"]["turn_rate_deg_s"] = 1.5
	sc["doctrine"] = {
		"sensor_false_alarm_rate": 0.0,
		"counterfire_probability": 0.0,
		"fire_quality_threshold": 99.0,
		"decoy_launch_probability": 0.0,
	}
	var w := World.new()
	w.load_scenario(sc)
	w.weapons.default_attack_depth_m = 12.0
	var own: TruthEntity = w.world["own"]
	var tracker := Tracker.new()
	var fcc := FireControlContext.new()
	var programmer := LaunchProgrammer.new()
	var op: OperatorSonar = OperatorSonar.new()
	op.setup(w.world)
	var track: Track = null
	var legs := [[20.0, 90.0], [90.0, 315.0]]
	var leg_i: int = 0
	while w.sim_time < 300.0:
		w.run_steps(1)
		if leg_i < legs.size() and w.sim_time >= float(legs[leg_i][0]):
			own.command_course(float(legs[leg_i][1]))
			leg_i += 1
		op.catch_up_rows(
			w.sim_time, w.world["targets"] + w._acoustic_scene_emitters(), w.world["target_acs"]
		)
		var auto_ms: Array = op.autocrew_step(w.sim_time)
		if auto_ms.is_empty():
			continue
		var pm: Measurement = auto_ms[0]
		var grp: Array = [pm]
		var i2: int = 1
		while (
			i2 < auto_ms.size()
			and auto_ms[i2].evidence_id == pm.evidence_id
			and auto_ms[i2].has_ambiguity()
		):
			grp.append(auto_ms[i2])
			i2 += 1
		var tt: Track = tracker.feed_evidence_group(grp, "", 8.0)
		if tt == null:
			tt = tracker.mark(pm, "M")
			for j in range(1, grp.size()):
				tt.add_measurement(grp[j] as Measurement)
		track = tt
		fcc.sync_revision(track)
		if track.evidence_count() >= 8:
			break
	if track != null and track.evidence_count() >= 4:
		fcc.solve_and_store(track, null, w.sim_time)
		fcc.commit_solution(track.track_id, w.sim_time)
	return {"world": w, "fcc": fcc, "tracker": tracker, "track": track, "programmer": programmer}


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("FIRE-PROGRAMMING TEST PASS")
		quit(0)
	else:
		print("FIRE-PROGRAMMING TEST FAIL (%d)" % fails.size())
		quit(1)
