extends SceneTree
## s1_11_batch3_test.gd — S1-11 Batch 3 验收：三页 UI、接触卡与地图减载。
##
##   B3-62 (AT-62) 中央地图在声呐/战术/武器三页常驻；切页不改镜头/选中/Mark 组；
##                 不存在第四个顶级"本艇"页；
##   B3-63 (AT-63) 普通接触卡常用层只出现四个直接动作；
##   B3-64 (AT-64) Mark 改绑/原始回波/残差/分支/审计只在详情中展开；
##   B3-61 (AT-61) 未选中目标只画最新一条 LOA；选中后展开历史；
##                 多鱼雷告警只详展最高威胁，其余合并为数量+方位摘要；
##   B3-60 (AT-60) 接触卡显示分类标签与依据。
## headless --script 不自动调 _process：显式 ui._process()；布局需 await 帧。


func _init() -> void:
	await _run()


func _run() -> void:
	var fails: Array = []
	root.size = Vector2i(1440, 900)
	await process_frame
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	_at62_three_pages(fails, ui)
	_at63_contact_card(fails, ui)
	_at64_details(fails, ui)
	_at61_lob_load(fails, ui)
	_at61_threat_summary(fails, ui)
	_at60_classification(fails, ui)
	ui.queue_free()
	await process_frame
	_finish(fails)


# ---------------- AT-62：三页 + 地图常驻 ----------------
func _at62_three_pages(fails: Array, ui: Control) -> void:
	var pager = ui._pager
	var ids: Array = pager.page_ids()
	_assert(fails, ids == ["sonar", "tactics", "weapons"], "B3-62 three pages, no 'own' page")
	_assert(fails, not ids.has("own"), "B3-62 no fourth top-level own page")
	_assert(fails, not ids.has("tracks"), "B3-62 old tracks page id retired")
	# 切页逐一切换，断言地图常驻且状态不变。
	var chart_id: int = ui._chart.get_instance_id()
	var cam := Vector2(ui._chart.cam_center)
	ui.selected_track_id = "S99"
	ui.mark_flow.active_group_id = "M07"
	for pid in ["tactics", "weapons", "sonar"]:
		pager.select(pid)
		await process_frame
		_assert(fails, ui._chart.visible, "B3-62 chart visible on page %s" % pid)
		_assert(
			fails,
			ui._chart.get_instance_id() == chart_id,
			"B3-62 chart instance kept on page %s" % pid
		)
		_assert(fails, ui._chart.cam_center == cam, "B3-62 camera unchanged on page %s" % pid)
		_assert(fails, ui.selected_track_id == "S99", "B3-62 selection kept on page %s" % pid)
		_assert(
			fails, ui.mark_flow.active_group_id == "M07", "B3-62 mark group kept on page %s" % pid
		)
	ui.selected_track_id = ""
	ui.mark_flow.active_group_id = ""


# ---------------- AT-63：接触卡四个动作 ----------------
func _at63_contact_card(fails: Array, ui: Control) -> void:
	var card: ContactCard = _find_card(ui)
	_assert(fails, card != null, "B3-63 contact card exists in tactics page")
	if card == null:
		return
	_assert(fails, card.action_button_count() == 4, "B3-63 card has exactly four actions")
	var labels: Array = []
	for aid in ["view", "track", "confirm", "target"]:
		var b: Button = card.action_button(aid)
		labels.append(b.text if b != null else "")
	_assert(
		fails,
		labels == ["查看", "优先跟踪", "主动确认", "设为攻击目标"],
		"B3-63 action labels are the four direct actions (%s)" % str(labels)
	)


# ---------------- AT-64：详情折叠 ----------------
func _at64_details(fails: Array, ui: Control) -> void:
	var card: ContactCard = _find_card(ui)
	if card == null:
		_assert(fails, false, "B3-64 contact card exists")
		return
	_assert(fails, not card.details_visible(), "B3-64 details collapsed by default")
	var names: Array = card.detail_control_names()
	_assert(fails, not names.is_empty(), "B3-64 detail drawer holds advanced content")
	# 常用层不得出现改绑/原始回波/残差/分支/审计等高级控件。
	var common: Array = []
	for c in card.action_row.get_children():
		common.append(str(c.text))
	var joined: String = " ".join(common)
	_assert(
		fails,
		(
			joined.find("改绑") < 0
			and joined.find("残差") < 0
			and joined.find("分支") < 0
			and joined.find("审计") < 0
		),
		"B3-64 advanced controls never occupy the common action layer"
	)


# ---------------- AT-61：地图减载（未选中只画最新 LOA） ----------------
func _at61_lob_load(fails: Array, ui: Control) -> void:
	var tr := Tracker.new()
	var t: Track = tr.mark(_mk_meas("L1", 20.0, 0.0), "S")
	for i in range(2, 6):
		t.add_measurement(_mk_meas("L%d" % i, 20.0 + float(i), float(i) * 30.0))
	var all: Array = TmaUiData.lob_entries(t, Color.WHITE, false, {})
	_assert(fails, all.size() == 5, "B3-61 selected/all shows every LOA")
	var one: Array = TmaUiData.lob_entries(t, Color.WHITE, false, {}, 1)
	_assert(
		fails,
		one.size() == 1 and float(one[0]["time"]) == 150.0,
		"B3-61 unselected shows only the latest LOA"
	)
	# 地图实际装载：另一个未选中航迹只能贡献一条 LOA。
	ui.tracker.mark(_mk_meas("Z1", 100.0, 0.0), "S")
	var other: Track = ui.tracker.all_tracks()[ui.tracker.count() - 1]
	for i in range(2, 5):
		other.add_measurement(_mk_meas("Z%d" % i, 100.0, float(i) * 30.0))
	ui.selected_track_id = ""
	ui._dirty = true
	ui._rebuild_display_data()
	var n_other: int = 0
	for lob in ui._chart.lobs:
		if str(lob.get("track_id", "")) == other.track_id:
			n_other += 1
	_assert(fails, n_other == 1, "B3-61 map draws one LOA for unselected track (got %d)" % n_other)


# ---------------- AT-61：多威胁合并摘要 ----------------
func _at61_threat_summary(fails: Array, ui: Control) -> void:
	var w = ui.world
	for i in range(3):
		(
			w
			. threat_tracks
			. ingest(
				{
					"evidence_id": 70000 + i,
					"evidence_kind": "RUNNING_NOISE",
					"timestamp": w.sim_time,
					"bearing_deg": 40.0 + float(i) * 60.0,
					"bearing_sigma_deg": 3.0,
					"p_torpedo": 0.9,
					"class_state": "PROBABLE_TORPEDO",
				},
				w.sim_time
			)
		)
	ui._process(0.5)
	_assert(fails, ui._threat_list.row_count() == 2, "B3-61 list = 1 detail + 1 merged summary")
	var texts: Array = []
	for c in ui._threat_list._rows.get_children():
		texts.append(_deep_text(c))
	var joined: String = " ".join(texts)
	_assert(fails, joined.find("另有") >= 0, "B3-61 others collapsed into a count+bearing summary")


# ---------------- AT-60：分类可见 ----------------
func _at60_classification(fails: Array, ui: Control) -> void:
	var t: Track = ui.tracker.all_tracks()[0]
	t.set_classification(
		TrackClassification.assess(
			t, 0.0, [{"evidence_id": "c1", "evidence_kind": "RUNNING_NOISE"}]
		)
	)
	ui.selected_track_id = t.track_id
	var card: ContactCard = _find_card(ui)
	if card == null:
		_assert(fails, false, "B3-60 contact card exists")
		return
	card.sync()
	var title: String = card.title_text()
	_assert(
		fails,
		title.find(t.track_id) >= 0 and (title.find("疑似") >= 0 or title.find("未知") >= 0),
		"B3-60 card shows track id + progressive classification label (%s)" % title
	)
	ui.selected_track_id = ""


# ---------------- helpers ----------------
func _find_card(node: Node) -> ContactCard:
	for c in node.get_children():
		if c is ContactCard:
			return c
		var r: ContactCard = _find_card(c)
		if r != null:
			return r
	return null


func _deep_text(n: Node) -> String:
	if n is Label:
		return (n as Label).text
	var out: String = ""
	for c in n.get_children():
		out += _deep_text(c) + " "
	return out


func _mk_meas(eid: String, brg: float, t: float) -> Measurement:
	var m := Measurement.new()
	m.evidence_id = eid
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.5
	m.timestamp = t
	m.detected = true
	return m


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH3 TEST PASS")
		quit(0)
	else:
		print("S1-11 BATCH3 TEST FAIL (%d)" % fails.size())
		quit(1)
