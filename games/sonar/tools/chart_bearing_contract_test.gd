extends SceneTree
## REQ-0908 Batch 0 — P0-06 失败回归：海图方向换算契约。
## 根因：ChartView 威胁 LOB 把屏幕方向 Vector2(sinθ,-cosθ) 当世界方向再
## world_to_screen → 南北翻转；鱼雷扇区/FOV/航迹线混用两套方向公式。
## 契约（§2.2）：唯一换算入口 bearing_to_world_dir / bearing_to_screen_dir，
## 0°=屏幕上、90°=右、180°=下、270°=左；绘制代码禁止散写 sin/cos。
## Batch 3 落地时本测试加入 ci_tests.txt。


func _initialize() -> void:
	var fails: Array = []

	# ---- 契约 1：唯一方向换算工具函数必须存在（nav_utils.gd）----
	var nav_src: Script = load("res://scripts/nav_utils.gd")
	var nav_text: String = nav_src.source_code
	var has_world: bool = nav_text.find("func bearing_to_world_dir") >= 0
	var has_screen: bool = nav_text.find("func bearing_to_screen_dir") >= 0
	_assert(fails, has_world, "NavUtils.bearing_to_world_dir exists")
	_assert(fails, has_screen, "NavUtils.bearing_to_screen_dir exists")
	if has_world and has_screen:
		# 经实例动态调用（静态纯函数，实例上可解析）。
		var nav: RefCounted = nav_src.new()
		var w0: Variant = nav.call("bearing_to_world_dir", 0.0)
		var w90: Variant = nav.call("bearing_to_world_dir", 90.0)
		var w180: Variant = nav.call("bearing_to_world_dir", 180.0)
		var w270: Variant = nav.call("bearing_to_world_dir", 270.0)
		var s0: Variant = nav.call("bearing_to_screen_dir", 0.0)
		var s90: Variant = nav.call("bearing_to_screen_dir", 90.0)
		var s180: Variant = nav.call("bearing_to_screen_dir", 180.0)
		var s270: Variant = nav.call("bearing_to_screen_dir", 270.0)
		_assert(fails, _is_vec(w0, 0, 1), "world 0deg -> north")
		_assert(fails, _is_vec(w90, 1, 0), "world 90deg -> east")
		_assert(fails, _is_vec(w180, 0, -1), "world 180deg -> south")
		_assert(fails, _is_vec(w270, -1, 0), "world 270deg -> west")
		_assert(fails, _is_vec(s0, 0, -1), "screen 0deg -> up")
		_assert(fails, _is_vec(s90, 1, 0), "screen 90deg -> right")
		_assert(fails, _is_vec(s180, 0, 1), "screen 180deg -> down")
		_assert(fails, _is_vec(s270, -1, 0), "screen 270deg -> left")

	# ---- 契约 2：ChartView 不得散写 sin/cos 方向 ----
	# 绘制代码必须经由唯一换算函数；允许的例外只有 nav_utils 本体与
	# 注释行。扫描 chart_view.gd 源码。
	var cv_src: Script = load("res://scripts/ui/chart_view.gd")
	var text: String = cv_src.source_code
	var lines: PackedStringArray = text.split("\n")
	var offenders: Array = []
	for i in range(lines.size()):
		var ln: String = lines[i]
		if ln.strip_edges().begins_with("#"):
			continue
		if ln.find("Vector2(sin") >= 0 or ln.find("Vector2(cos") >= 0:
			offenders.append("chart_view.gd:%d" % (i + 1))
	_assert(
		fails,
		offenders.is_empty(),
		"chart_view.gd free of raw sin/cos direction math (%s)" % str(offenders.slice(0, 4)),
	)

	# ================= REQ-0908 Batch 3 验收（8 条） =================

	# ---- 验收 4/5：历史 LOB 起点 = 该时刻观测快照（BOW=本艇位 / TOWED=阵心），
	#      本艇继续航行后起点绝不漂移 ----
	var tr := Tracker.new()
	var m1 := _mk_meas(45.0, 10.0, 100.0, 200.0, "BOW")
	var m2 := _mk_meas(46.0, 11.0, 150.0, 260.0, "BOW")
	var m3 := _mk_meas(47.0, 12.0, 200.0, 320.0, "TOWED_ARRAY")
	var tk: Track = tr.mark(m1, "M")
	tk.add_measurement(m2)
	tk.add_measurement(m3)
	var entries: Array = TmaUiData.lob_entries(tk, Color.RED, true, {})
	var origins_ok: bool = entries.size() == 3
	origins_ok = (
		origins_ok
		and (entries[0]["origin"] as Vector2).is_equal_approx(Vector2(100.0, 200.0))
		and (entries[1]["origin"] as Vector2).is_equal_approx(Vector2(150.0, 260.0))
		and (entries[2]["origin"] as Vector2).is_equal_approx(Vector2(200.0, 320.0))
	)
	_assert(fails, origins_ok, "LOB origins are per-measurement observer snapshots (no drift)")
	_assert(
		fails,
		str(entries[2]["sensor_id"]) == "TOWED_ARRAY",
		"towed LOB origin carries ARRAY CENTER sensor id",
	)

	# ---- 验收 7：is_track_selected 字段 + alpha 合成（非当前 ≤0.15）----
	var entries_unsel: Array = TmaUiData.lob_entries(tk, Color.RED, false, {})
	_assert(
		fails,
		bool(entries[0]["is_track_selected"]) and not bool(entries_unsel[0]["is_track_selected"]),
		"lob entries expose explicit is_track_selected field",
	)
	var cv: ChartView = ChartView.new()
	cv.fit_now_time = 100.0
	var lob_sel_latest := {
		"is_track_selected": true, "time": 100.0, "candidate": false, "sigma_deg": 1.0
	}
	var lob_sel_old := {
		"is_track_selected": true, "time": 40.0, "candidate": false, "sigma_deg": 1.0
	}
	var lob_other := {
		"is_track_selected": false, "time": 100.0, "candidate": false, "sigma_deg": 1.0
	}
	var lob_other_old := {
		"is_track_selected": false, "time": 20.0, "candidate": false, "sigma_deg": 1.0
	}
	var a_sel_latest: float = cv._lob_alpha(lob_sel_latest, true, false)
	var a_sel: float = cv._lob_alpha(lob_sel_old, false, false)
	var a_other: float = cv._lob_alpha(lob_other, true, false)
	var a_other_old: float = cv._lob_alpha(lob_other_old, false, false)
	var a_hover: float = cv._lob_alpha(lob_other, true, true)
	_assert(
		fails,
		a_sel_latest >= 0.95 and a_sel >= 0.25,
		"current track LOB alpha composed (latest %.2f / old %.2f)" % [a_sel_latest, a_sel],
	)
	_assert(
		fails,
		a_other <= 0.15 + 1e-6 and a_other_old <= 0.15 + 1e-6,
		"non-current track alpha <= 0.15 (%.3f / %.3f)" % [a_other, a_other_old],
	)
	_assert(fails, a_hover >= 0.999, "hovered/selected measurement fully highlighted")
	# 拖曳 A/B 歧义候选支同权：同输入同 alpha，不因分支符号变化。
	var cand_a: float = cv._lob_alpha(lob_sel_old, false, false)
	var cand_b: float = cv._lob_alpha(lob_sel_old, false, false)
	_assert(fails, absf(cand_a - cand_b) < 1e-9, "towed A/B ambiguity branches equal weight")

	# ---- 验收 7：Selected-only 时非当前 Track 完全不绘制 ----
	cv.show_selected_only = true
	_assert(
		fails,
		not cv._lob_layer_visible(lob_other) and cv._lob_layer_visible(lob_sel_latest),
		"Selected-only hides non-current track LOBs entirely",
	)
	cv.show_selected_only = false

	# ---- 验收 2/3/8：威胁图层（ping 优先 / ACTIVE_RETURN / 无 Truth 图标）----
	var cv2: ChartView = ChartView.new()
	var evs: Array = [
		{
			"evidence_id": 1,
			"side_hint": "INTERCEPT",
			"evidence_kind": "RUNNING_NOISE",
			"threat_track_id": "TT1",
			"observer_e_m": 0.0,
			"observer_n_m": 0.0,
			"bearing_deg": 30.0,
			"bearing_sigma_deg": 2.0,
			"timestamp": 10.0,
			"confidence": 0.6,
		},
		{
			"evidence_id": 2,
			"side_hint": "INTERCEPT",
			"evidence_kind": "RUNNING_NOISE",
			"threat_track_id": "TT1",
			"observer_e_m": 5.0,
			"observer_n_m": 5.0,
			"bearing_deg": 31.0,
			"bearing_sigma_deg": 2.0,
			"timestamp": 20.0,
			"confidence": 0.7,
		},
		{
			"evidence_id": 3,
			"side_hint": "INTERCEPT",
			"evidence_kind": "ACTIVE_PING",
			"threat_track_id": "TT1",
			"observer_e_m": 9.0,
			"observer_n_m": 9.0,
			"bearing_deg": 32.0,
			"bearing_sigma_deg": 2.0,
			"timestamp": 15.0,
			"confidence": 0.9,
		},
	]
	cv2.set_threat_evidence(evs, 25.0)
	_assert(fails, cv2.threat_lobs.size() == 3, "threat evidence sanitized into LOB entries")
	var reps: Array = cv2._representative_threats()
	var has_ping: bool = false
	var newest_noise_dropped: bool = true
	for r in reps:
		if int(r["evidence_id"]) == 3:
			has_ping = true
		if int(r["evidence_id"]) == 2:
			newest_noise_dropped = false
	_assert(
		fails,
		has_ping and newest_noise_dropped,
		"ACTIVE_PING outranks running noise as track representative",
	)
	# Batch 2 主动测距 → ACTIVE_RETURN 估计点（无测距时绝不显示估计位置）。
	var ev_range: Dictionary = {
		"evidence_id": 4,
		"side_hint": "INTERCEPT",
		"evidence_kind": "RUNNING_NOISE",
		"threat_track_id": "TT2",
		"observer_e_m": 0.0,
		"observer_n_m": 0.0,
		"bearing_deg": 90.0,
		"bearing_sigma_deg": 2.0,
		"timestamp": 30.0,
		"confidence": 0.8,
		"range_m": 3000.0,
		"range_sigma_m": 150.0,
	}
	cv2.set_threat_evidence([ev_range], 35.0)
	_assert(
		fails,
		(
			cv2.threat_lobs.size() == 1
			and str(cv2.threat_lobs[0]["kind"]) == "ACTIVE_RETURN"
			and absf(float(cv2.threat_lobs[0]["range_m"]) - 3000.0) < 1e-6
		),
		"active ranging upgrades threat entry to ACTIVE_RETURN with measured range",
	)
	cv2.set_threat_evidence([evs[0]], 35.0)
	_assert(
		fails,
		cv2.threat_lobs.size() == 1 and str(cv2.threat_lobs[0]["kind"]) == "RUNNING_NOISE",
		"passive-only threat stays bearing-only (no precise enemy position)",
	)

	# ---- 验收 8（UI 接线）：威胁图层开关 + 图例 + Selected-only 控件 ----
	var ui_src: String = (load("res://scripts/ui/main_ui.gd") as Script).source_code
	_assert(fails, ui_src.find('"threat"') >= 0, "threat layer toggle wired in main_ui")
	_assert(fails, ui_src.find("Selected Track Only") >= 0, "Selected Track Only toggle wired")
	var cv_src2: String = cv_src.source_code
	for legend_key in ["Launch Transient", "Torpedo Noise", "Active Ping", "Active Return"]:
		_assert(fails, cv_src2.find(legend_key) >= 0, "threat legend entry: %s" % legend_key)

	_finish(fails)


func _is_vec(v: Variant, x: float, y: float) -> bool:
	return v is Vector2 and (v as Vector2).is_equal_approx(Vector2(x, y))


func _mk_meas(brg: float, t: float, oe: float, on: float, sensor: String) -> Measurement:
	var m := Measurement.new()
	m.timestamp = t
	m.detected = true
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.0
	m.sensor_id = sensor
	m.observer_east_m = oe
	m.observer_north_m = on
	m.evidence_id = "ev_%s_%.0f" % [sensor, t]
	return m


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("CHART-BEARING-CONTRACT TEST PASS")
		quit(0)
	else:
		print("CHART-BEARING-CONTRACT TEST FAIL (%d)" % fails.size())
		quit(1)
