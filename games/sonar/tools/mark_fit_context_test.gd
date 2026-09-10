extends SceneTree
## REQ-0908 Batch 1 — Mark 组/Track/Fit/火控解隔离验收（对应 Batch 0 P0-02/03/04）。
## 覆盖文档验收 1-10 中可无头验证的条目；UI 层以源码扫描保证接线存在。
## P0-03：OperatorSonar.create_mark() 同 row_id+peak_id 去重 + 无峰点击不重抽噪声。
## P0-04：SystemSolution 绑定 source_track_id/fit_version/evidence_revision。
## P0-02：main_ui per-track fit/solution 上下文 + SOLUTION 发射联锁。

const OP_SCRIPT := "res://scripts/sonar/operator_sonar.gd"


func _initialize() -> void:
	var fails: Array = []

	# ---- 验收 5：无峰自由点击重复操作，方位完全一致（不重抽噪声）----
	var op := _mk_operator()
	var row := {
		"array_id": "BOW",
		"t": 10.0,
		"course": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"peaks": [],
	}
	var m1: Measurement = op.create_mark(45.0, 10.0, "", false, row)
	var m2: Measurement = op.create_mark(45.0, 10.0, "", false, row)
	_assert(
		fails,
		absf(NavUtils.angle_diff(m1.measured_bearing_deg, m2.measured_bearing_deg)) < 1e-9,
		(
			"repeat free-click keeps identical bearing (%.4f vs %.4f)"
			% [m1.measured_bearing_deg, m2.measured_bearing_deg]
		),
	)

	# ---- 验收 4：同一 row_id+peak_id 点击 10 次，返回同一 Measurement ----
	var peak_row := {
		"array_id": "BOW",
		"t": 20.0,
		"course": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"row_id": "row_00001",
		"peaks": [{"bearing_deg": 60.0, "peak_id": "p00", "se_db": 12.0, "snr_db": 12.0}],
	}
	var first: Measurement = op.create_mark(60.0, 20.0, "", false, peak_row)
	var same: bool = true
	for i in range(9):
		if op.create_mark(60.0, 20.0, "", false, peak_row) != first:
			same = false
	_assert(fails, same, "repeat row_id+peak_id clicks return same Measurement (no new evidence)")

	# ---- 验收 10：拖曳 A/B 镜像共享同一 physical evidence ----
	var op_src: String = (load(OP_SCRIPT) as Script).source_code
	_assert(
		fails,
		op_src.find("sibling.evidence_id = primary.evidence_id") >= 0,
		"towed mirror branch shares evidence_id (one physical arrival)",
	)

	# ---- 验收 1/2：per-Track Fit 上下文（A/B 各自保留，切回不重算）----
	var tr := Tracker.new()
	var ta := _feed_track(tr, 30.0, 3)
	var tb := _feed_track(tr, 150.0, 3)
	var fcc := FireControlContext.new()
	fcc.sync_revision(ta)
	fcc.sync_revision(tb)
	var r_a: Dictionary = fcc.solve_and_store(ta, null, 100.0)
	var r_b: Dictionary = fcc.solve_and_store(tb, null, 100.0)
	var v_a: int = int(r_a.get("fit_version", -1))
	var v_b: int = int(r_b.get("fit_version", -1))
	_assert(fails, v_a > 0 and v_b > 0 and v_a != v_b, "per-track fit versions distinct")
	var kept: bool = int(fcc.fit_by_track_id.get(ta.track_id, {}).get("fit_version", -1)) == v_a
	_assert(fails, kept, "Fit A retained after Fit B (switch back needs no re-solve)")

	# ---- 验收 3：FULL_AUTO 后台 REFIT 不改 selected_contact_id（源码扫描）----
	var ui_src: String = (load("res://scripts/ui/main_ui.gd") as Script).source_code
	var i_auto: int = ui_src.find("func _auto_refit_track")
	var i_next: int = ui_src.find("func _on_enter_solution", i_auto)
	var auto_body: String = ui_src.substr(i_auto, i_next - i_auto)
	_assert(
		fails,
		auto_body.find("selected_track_id =") < 0,
		"background FULL_AUTO refit never changes selected contact",
	)
	_assert(fails, ui_src.find("fit_by_track_id") >= 0, "main_ui has per-track fit context")
	_assert(
		fails,
		ui_src.find("system_solution_by_track_id") >= 0,
		"main_ui has per-track system solution"
	)

	# ---- 验收 8：选中 M02 时，M01 的解不能用于 SOLUTION 发射 ----
	var sol_res: Dictionary = fcc.commit_solution(tb.track_id, 110.0)
	_assert(fails, bool(sol_res.get("ok", false)), "commit solution for track B ok")
	var gate_b: Dictionary = fcc.solution_for_fire(tb.track_id, 115.0)
	_assert(fails, bool(gate_b.get("ok", false)), "SOLUTION fire allowed for owning track")
	var gate_a: Dictionary = fcc.solution_for_fire(ta.track_id, 115.0)
	_assert(
		fails,
		not bool(gate_a.get("ok", false)) and str(gate_a.get("reason")) == "NO_SOLUTION_FOR_TRACK",
		"other track's solution rejected for SOLUTION fire (A has no own solution)",
	)

	# ---- 验收 6/7（S1-11 §3.3/D-13 修订）：显式选组 = 直接追加命令，不受
	# 8° 自动关联门否决（8° 只留给自动关联评分）；SUGGEST 未 Apply 不改 Track。
	# 用独立空组 tc 验证，避免污染后面 SUGGEST/Apply 用例的 ta/tb 证据。
	var world := World.new()
	var flow := MarkFlow.new()
	flow.tracker = tr
	flow.op = op
	flow.world = world
	flow.association_mode = MarkFlow.ASSOC_LOCKED
	var tc: Track = tr.create_empty_track()
	flow.active_group_id = tc.track_id
	var n_meas: int = world.measurements.size()
	var n_tracks: int = tr.count()
	var first_res: Dictionary = flow.handle_mark(10.0, false, _peak_row(10.0), "")
	_assert(
		fails,
		first_res.get("track") == tc and tc.evidence_count() == 1,
		"explicit empty group accepts its first measurement (no gate)",
	)
	var far_res: Dictionary = flow.handle_mark(150.0, false, _peak_row(150.0), "")
	_assert(
		fails,
		not str(far_res.get("status", "")).begins_with("Mark ignored"),
		"explicit group mark is a command, not gated by auto-association",
	)
	_assert(
		fails,
		far_res.get("track") == tc and tc.evidence_count() == 2,
		"explicit group append lands on the chosen group (no 8-deg gate)",
	)
	_assert(
		fails,
		world.measurements.size() == n_meas + 2 and tr.count() == n_tracks,
		"explicit group append adds exactly one measurement each, no new track",
	)

	flow.association_mode = MarkFlow.ASSOC_SUGGEST
	flow.active_group_id = tb.track_id
	var sug_res: Dictionary = flow.handle_mark(31.0, false, _peak_row(31.0), "")
	var sug_tid: String = flow.pending_suggestion_track_id()
	_assert(
		fails,
		sug_tid == ta.track_id and str(sug_res.get("status", "")).find("Apply") >= 0,
		"SUGGEST only proposes (%s -> propose %s)" % [tb.track_id, sug_tid],
	)
	_assert(fails, tb.evidence_count() == 3, "SUGGEST does not change active track before Apply")
	var ap_res: Dictionary = flow.apply_suggestion(tb.track_id)
	_assert(
		fails,
		bool(ap_res.get("dirty", false)) and tb.evidence_count() == 4 and ta.evidence_count() == 3,
		"Apply rebinds keeping same evidence_id (no duplicate observation)",
	)

	# ---- UI 接线（显式 Mark 组控件 + FIRE MODE 联锁）----
	_assert(fails, ui_src.find("MarkGroupPanel.new()") >= 0, "explicit mark group panel wired")
	# S1-11 D-01：玩家唯一发射方式是地图航线，旧 FIRE MODE 选择器随契约作废。
	_assert(
		fails,
		ui_src.find("fire_mode_changed") < 0,
		"S1-11 D-01: legacy FIRE MODE selector removed"
	)
	_assert(
		fails,
		ui_src.find("MapRouteOverlay") >= 0,
		"S1-11 D-01: map-route drawing layer wired"
	)
	_assert(fails, ui_src.find("FireExecutor.new()") >= 0, "fire executor controller wired")
	_assert(
		fails,
		ui_src.find("_lowq_confirmed") >= 0,
		"low-quality solution needs explicit second confirm",
	)

	# ---- 验收 9：证据修改后旧解 STALE，发射联锁拒绝（放最后避免污染前序）----
	var extra := _mk_meas(153.0, 200.0)
	tb.add_measurement(extra)
	fcc.sync_revision(tb)
	var gate_stale: Dictionary = fcc.solution_for_fire(tb.track_id, 120.0)
	_assert(
		fails,
		not bool(gate_stale.get("ok", false)) and str(gate_stale.get("reason")) == "SOLUTION_STALE",
		"evidence change makes solution STALE and fire interlock rejects",
	)

	_finish(fails)


func _mk_operator() -> RefCounted:
	var own := TruthEntity.new()
	own.position_east_m = 0.0
	own.position_north_m = 0.0
	own.course_deg = 0.0
	own.depth_m = 50.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 90802
	var op: RefCounted = load(OP_SCRIPT).new()
	op.setup({"own": own, "rng": rng})
	return op


func _mk_meas(brg: float, t: float) -> Measurement:
	var m := Measurement.new()
	m.timestamp = t
	m.detected = true
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.0
	m.evidence_id = "ev_t%.0f_%.0f" % [t, brg]
	return m


func _feed_track(tr: Tracker, brg: float, n: int) -> Track:
	var t: Track = null
	for i in range(n):
		var m := _mk_meas(brg + 0.5 * i, 10.0 + i)
		if t == null:
			t = tr.mark(m, "M")
		else:
			t.add_measurement(m)
	return t


func _peak_row(brg: float) -> Dictionary:
	return {
		"array_id": "BOW",
		"t": 12.0,
		"course": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"row_id": "row_scan_%d" % int(brg),
		"peaks": [{"bearing_deg": brg, "peak_id": "p00", "se_db": 12.0, "snr_db": 12.0}],
	}


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("MARK-FIT-CONTEXT TEST PASS")
		quit(0)
	else:
		print("MARK-FIT-CONTEXT TEST FAIL (%d)" % fails.size())
		quit(1)
