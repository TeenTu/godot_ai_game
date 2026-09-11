extends SceneTree
## chart_declutter_test.gd — P1-A（PG-06）地图输出与减载验收。
##
##   C-01 每个接触显示短 ID + 概率分类 + 估计点 + 更新时间；未选中只有简洁标记
##        （1 行），选中才展开误差区/历史/运动向量所需的字段。
##   C-02 同一观测驱动多个视图时只画一份物体（mirror 条目被丢弃）。
##   C-03 最高威胁鱼雷保留详情 + 自动标注；其余告警合并为数量/扇区摘要
##        （不再把红色 LOA/椭圆铺满地图）。
##   C-04 不强制"每 Ping 一次固定缩圈"：误差区按证据（σ/量程）如实呈现，
##        大误差不被静默缩到固定值。
##
## 运行：godot --headless --path games/sonar --script res://tools/chart_declutter_test.gd

const DT: float = 0.5


func _initialize() -> void:
	var fails: Array = []
	_c01_contact_marker_fields(fails)
	_c02_single_object(fails)
	_c03_threat_declutter(fails)
	_c04_no_forced_shrink(fails)
	_c05_wiring(fails)
	if fails.is_empty():
		print("CHART-DECLUTTER TEST PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("CHART-DECLUTTER TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ---------------- C-01：接触标记字段与选中展开 ----------------
func _c01_contact_marker_fields(fails: Array) -> void:
	var rows: Array = _rows()
	_assert_eq(fails, "C-01 one marker per active contact", str(rows.size()), "2")
	if rows.size() < 2:
		return
	var r0: Dictionary = rows[0]
	_assert_true(fails, "C-01 marker carries short id (%s)" % r0["track_id"], r0.has("track_id"))
	_assert_true(
		fails,
		"C-01 short id is short (%s)" % ContactChartOverlay.short_id(str(r0["track_id"])),
		ContactChartOverlay.short_id(str(r0["track_id"])).length() <= 5
	)
	_assert_true(fails, "C-01 marker carries classification", str(r0["class_label"]) != "")
	_assert_true(fails, "C-01 marker carries update time", float(r0["updated_time"]) > 0.0)
	_assert_true(fails, "C-01 marker carries estimate point", bool(r0["has_estimate"]))
	_assert_true(fails, "C-01 marker carries history", (r0["history"] as Array).size() >= 1)
	# 未选中 = 1 行简洁标记；选中 = 展开多行（含距离与运动）。
	var simple: Array = ContactChartOverlay.label_lines(r0, 30.0)
	_assert_eq(fails, "C-01 unselected marker is one line", str(simple.size()), "1")
	_assert_true(fails, "C-01 未选中行含更新时间 (%s)" % str(simple[0]), str(simple[0]).contains("更新"))
	var sel: Array = ContactChartOverlay.label_lines(rows[1], 30.0)
	_assert_true(fails, "C-01 selected marker expands (%d lines)" % sel.size(), sel.size() >= 4)
	var joined: String = " | ".join(sel)
	_assert_true(fails, "C-01 selected shows distance", joined.contains("距离"))
	_assert_true(fails, "C-01 selected shows motion", joined.contains("运动"))
	# 减载分组：选中进 expanded，其余进 simple。
	var groups: Dictionary = ContactChartOverlay.declutter(rows)
	_assert_eq(
		fails, "C-01 selected goes to expanded", str((groups["expanded"] as Array).size()), "1"
	)
	_assert_eq(fails, "C-01 others stay simple", str((groups["simple"] as Array).size()), "1")


# ---------------- C-02：同一观测只画一份物体 ----------------
func _c02_single_object(fails: Array) -> void:
	var rows: Array = _rows()
	rows[0]["mirror_of"] = "TT001"
	var groups: Dictionary = ContactChartOverlay.declutter(rows)
	_assert_eq(fails, "C-02 mirror marker dropped", str(int(groups["dropped"])), "1")
	_assert_eq(
		fails, "C-02 mirrored object not drawn twice", str((groups["simple"] as Array).size()), "0"
	)
	# 真实装配：接触 id 与威胁航迹同名时自动标记 mirror（由 PG-05 起不该出现，
	# 但视图侧仍必须自我防护）。
	var w := World.new()
	w.load_scenario(_mk_scenario())
	var tracker := Tracker.new()
	var m := _meas(0.0, 10.0, 3000.0)
	var t: Track = tracker.mark(m, "P")
	var pc := ActivePingController.new()
	var real: Array = UiChartData.marker_rows(tracker, "", pc, [{"track_id": t.track_id}], 10.0)
	_assert_true(
		fails,
		"C-02 data assembly flags mirrored contacts",
		real.size() == 1 and str(real[0].get("mirror_of", "")) == t.track_id
	)


# ---------------- C-03：威胁减载 + 自动标注 ----------------
func _c03_threat_declutter(fails: Array) -> void:
	var snaps: Array = [
		_snap("TT001", 20.0, 0.9, 0.95, 12, 100.0),
		_snap("TT002", 22.0, 0.5, 0.6, 5, 100.0),
		_snap("TT003", 200.0, 0.4, 0.5, 4, 100.0),
	]
	var groups: Dictionary = ThreatChartOverlay.declutter(snaps, 100.0)
	_assert_eq(
		fails,
		"C-03 最高威胁保留详情",
		str(str((groups["primary"] as Dictionary).get("track_id", ""))),
		"TT001"
	)
	_assert_eq(fails, "C-03 others merged (2)", str((groups["merged"] as Array).size()), "2")
	var summary: Dictionary = groups["summary"]
	_assert_eq(fails, "C-03 summary counts merged", str(int(summary["count"])), "2")
	var sectors: Array = summary["sectors"]
	_assert_eq(fails, "C-03 sectors grouped (2 groups)", str(sectors.size()), "2")
	_assert_true(
		fails,
		"C-03 合并摘要含数量与扇区 (%s)" % ThreatChartOverlay.summary_text(summary),
		(
			ThreatChartOverlay.summary_text(summary).contains("2")
			and ThreatChartOverlay.summary_text(summary).contains("°")
		)
	)
	# 自动建立的威胁航迹标注"自动"。
	var lab: String = ThreatChartOverlay.primary_label(groups["primary"], "RANGE_AIDED")
	_assert_true(fails, "C-03 auto torpedo labelled (%s)" % lab, lab.contains("自动"))
	var manual: Dictionary = _snap("TT009", 10.0, 0.9, 0.9, 9, 100.0)
	manual["auto_created"] = false
	_assert_true(
		fails,
		"C-03 已确认目标不标自动",
		not ThreatChartOverlay.primary_label(manual, "RANGE_AIDED").contains("自动")
	)
	# 无合并项时不显示摘要。
	_assert_eq(
		fails,
		"C-03 no summary when single target",
		ThreatChartOverlay.summary_text({"count": 0, "sectors": []}),
		""
	)
	# LOST 超时项不再参与（避免地图长期残留）。
	var ghost: Array = [_snap("TT010", 10.0, 0.9, 0.9, 9, 100.0)]
	ghost[0]["state"] = "LOST"
	_assert_eq(
		fails,
		"C-03 LOST 过期项不再绘制",
		str(int(ThreatChartOverlay.declutter(ghost, 100.0 + 1000.0)["summary"]["count"])),
		"0"
	)
	_assert_eq(
		fails,
		"C-03 LOST 保留期内仍可绘制",
		str(str(ThreatChartOverlay.declutter(ghost, 100.0 + 5.0)["primary"].get("track_id", ""))),
		"TT010"
	)


# ---------------- C-04：误差区按证据如实呈现 ----------------
func _c04_no_forced_shrink(fails: Array) -> void:
	# 后验可以变宽：大 σ 必须原样出现在展开文案里（不做"每 Ping 固定缩圈"）。
	var wide: Dictionary = _rows()[1]
	wide["range_sigma_m"] = 900.0
	wide["sigma_m"] = 2500.0
	var lines: Array = ContactChartOverlay.label_lines(wide, 30.0)
	var joined: String = " | ".join(lines)
	_assert_true(
		fails, "C-04 wide posterior shown verbatim (%s)" % joined, joined.contains("±900 米")
	)
	# 只有"绘制上限"防止糊屏，且必须是上限（不小于典型误差）。
	_assert_true(
		fails,
		"C-04 draw cap is an upper bound (%.0f m)" % ContactChartOverlay.MAX_SEL_SIGMA_M,
		ContactChartOverlay.MAX_SEL_SIGMA_M >= 1000.0
	)
	# 无距离证据 → 明说"仅方位"，绝不给假估计点。
	var bearing_only: Dictionary = _rows()[0]
	bearing_only["has_estimate"] = false
	bearing_only["selected"] = true
	var b_lines: Array = ContactChartOverlay.label_lines(bearing_only, 30.0)
	_assert_true(fails, "C-04 无测距时明示仅方位", " | ".join(b_lines).contains("仅方位"))


# ---------------- C-05：接线（绘制入口 + 数据装配） ----------------
func _c05_wiring(fails: Array) -> void:
	var cv: String = FileAccess.get_file_as_string("res://scripts/ui/chart_view.gd")
	_assert_true(fails, "C-05 chart draws contact markers", cv.contains("ContactChartOverlay.draw"))
	_assert_true(
		fails,
		"C-05 chart delegates camera overlays",
		cv.contains("ChartCameraOverlay.draw_camera_overlays")
	)
	var tc: String = FileAccess.get_file_as_string("res://scripts/ui/threat_chart_overlay.gd")
	_assert_true(fails, "C-05 threat overlay declutters", tc.contains("declutter(snaps, sim_now)"))
	var cd: String = FileAccess.get_file_as_string("res://scripts/ui/ui_chart_data.gd")
	_assert_true(fails, "C-05 chart data assembles markers", cd.contains("contact_markers(ui)"))
	var body: String = _fn_body(cd, "marker_rows")
	_assert_true(fails, "C-05 marker assembly exists", body.length() > 200)
	_assert_true(fails, "C-05 markers never read truth", not body.contains("truth"))


func _fn_body(src: String, fname: String) -> String:
	var i0: int = src.find("func " + fname)
	if i0 < 0:
		return ""
	var i1: int = src.find("\nfunc ", i0 + 5)
	return src.substr(i0, (i1 if i1 > 0 else src.length()) - i0)


# ---------------- helpers ----------------
func _rows() -> Array:
	var tracker := Tracker.new()
	var m0 := _meas(10.0, 10.0, 3000.0)
	var t0: Track = tracker.mark(m0, "P")
	var m1 := _meas(15.0, 40.0, 6000.0)
	m1.measured_range_m = 6000.0
	m1.range_sigma_m = 120.0
	var t1: Track = tracker.mark(m1, "P")
	t0.set_classification({"label": "潜艇（疑似）", "state": "SUSPECT", "probabilities": {}})
	t1.set_classification({"label": "水面舰（已分类）", "state": "CLASSIFIED", "probabilities": {}})
	var pc := ActivePingController.new()
	pc.position_estimates[t0.track_id] = _est(1000.0, 2000.0, 300.0, 3000.0, 150.0, false)
	pc.position_estimates[t1.track_id] = _est(3000.0, 5000.0, 250.0, 6000.0, 120.0, true)
	return UiChartData.marker_rows(tracker, t1.track_id, pc, [], 30.0)


func _est(e: float, n: float, sig: float, rng: float, rsig: float, motion: bool) -> Dictionary:
	var d: Dictionary = {
		"has_position": true,
		"east_m": e,
		"north_m": n,
		"major_m": sig,
		"sigma_m": sig,
		"is_sector": false,
		"range_m": rng,
		"range_sigma_m": rsig,
		"has_motion": motion,
	}
	if motion:
		d["course_deg"] = 45.0
		d["speed_kn"] = 8.0
	return d


func _meas(t: float, brg: float, rng: float) -> Measurement:
	var m := Measurement.new()
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.5
	m.measured_range_m = rng
	m.range_sigma_m = 100.0
	m.timestamp = t
	m.observer_east_m = 0.0
	m.observer_north_m = 0.0
	m.reference_time_s = t
	return m


func _snap(id: String, brg: float, p: float, conf: float, ev: int, now: float) -> Dictionary:
	return {
		"track_id": id,
		"state": "RANGE_AIDED",
		"p_torpedo": p,
		"confidence": conf,
		"evidence_count": ev,
		"last_update_time": now,
		"bearing_est_deg": brg,
		"bearing_sigma_deg": 1.5,
		"range_est_m": 4000.0,
		"range_sigma_m": 300.0,
		"converged": true,
		"course_est_deg": 180.0,
		"speed_est_kn": 40.0,
		"ellipse_a_m": 500.0,
		"ellipse_b_m": 200.0,
		"ellipse_angle_deg": 0.0,
		"draw_center_e_m": 0.0,
		"draw_center_n_m": 4000.0,
		"auto_created": true,
	}


func _mk_scenario() -> Dictionary:
	return {
		"name": "chart_declutter",
		"seed": 20260911,
		"dt": DT,
		"duration": 60.0,
		"environment": {"environment_type": "shallow", "sea_state": 2},
		"own_ship":
		{
			"id": "own",
			"class_id": "attack_sub",
			"side": "blue",
			"platform_type": "submarine",
			"position_east_m": 0.0,
			"position_north_m": 0.0,
			"depth_m": 50.0,
			"course_deg": 0.0,
			"speed_kn": 0.0,
		},
		"targets": [],
		"sensors": [],
	}


func _assert_true(fails: Array, name: String, cond: bool) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _assert_eq(fails: Array, name: String, got: String, want: String) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, got, want])
		print("FAIL %s: got=%s want=%s" % [name, got, want])
	else:
		print("ok   ", name)
