extends SceneTree
## sidebar_pager_test.gd — S109 Batch 5 右栏四页验收（AT-28..31）。
##
## 运行：godot --headless --path games/sonar --script res://tools/sidebar_pager_test.gd
## 必须输出 "SIDEBAR_PAGER_TEST result=PASS"。
## AT-28 四个主分页按钮 / 任意时刻恰好一页可见；AT-29 切页保留选择、表单与
## 各页滚动位置；AT-30 页面隐藏期间新鱼雷证据仍更新告警条与按钮红点；
## AT-31 1280x720 / 1440x900 / 1920x1080 无越界、无水平滚动。
## headless --script 不自动调 _process：显式 ui._process()；布局需 await 帧。


func _init() -> void:
	await _run()


func _run() -> void:
	var fails: Array = []
	var ui: Control = await _mk_ui(1440, 900)
	_at28_structure(fails, ui)
	await _at29_preserve(fails, ui)
	_at30_alert_while_hidden(fails, ui)
	ui.queue_free()
	await process_frame
	await _at31_resolutions(fails)
	_finish(fails)


func _mk_ui(w: int, h: int) -> Control:
	root.size = Vector2i(w, h)
	await process_frame  # headless 下先让窗口尺寸生效（_ready 读 viewport）
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	return ui


## AT-28：右栏只有四个主分页按钮；任意时刻只有一个页面内容可见。
func _at28_structure(fails: Array, ui: Control) -> void:
	var pager = ui._pager
	_assert_bool(fails, "AT-28a pager exists", pager != null, true)
	if pager == null:
		return
	var ids: Array = pager.page_ids()
	_assert_bool(fails, "AT-28b four pages", ids.size() == 4, true)
	_assert_bool(fails, "AT-28c page ids", ids == ["sonar", "tracks", "weapons", "own"], true)
	_assert_bool(fails, "AT-28d four buttons", pager._group.get_buttons().size() == 4, true)
	_assert_bool(fails, "AT-28e one visible page", pager.visible_page_count() == 1, true)
	_assert_bool(fails, "AT-28f default page", pager.current_page() == "sonar", true)
	pager._btns["weapons"].pressed.emit()  # 模拟点击分页按钮
	_assert_bool(fails, "AT-28g click switches", pager.current_page() == "weapons", true)
	_assert_bool(fails, "AT-28h still one page", pager.visible_page_count() == 1, true)
	_assert_bool(fails, "AT-28i selected unchanged by paging", ui.selected_track_id == "", true)
	# §8.1 固定顶栏：任务时间 + 暂停 + 倍速都在顶栏内。
	_assert_bool(
		fails, "AT-28j pause in top bar", pager.time_row.is_ancestor_of(ui._btn_pause), true
	)
	_assert_bool(
		fails, "AT-28k time label in top bar", pager.time_row.is_ancestor_of(ui._lbl_time), true
	)
	# 选中摘要 + 告警条也在固定顶栏（§8.3）。
	_assert_bool(
		fails,
		"AT-28l summary+alert in top bar",
		(
			pager.top_bar.is_ancestor_of(ui._lbl_selected)
			and pager.top_bar.is_ancestor_of(ui._threat_hud)
		),
		true
	)


## AT-29：切页后 Contact/Threat 选择、表单和各页滚动位置保持。
func _at29_preserve(fails: Array, ui: Control) -> void:
	var pager = ui._pager
	ui.world.auto_measurements = true
	for i in range(12):
		ui._process(0.5)
	var tid: String = ""
	for t in ui.tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE:
			tid = t.track_id
			break
	_assert_bool(fails, "AT-29a contact exists", tid != "", true)
	ui._on_contact_selected(tid)
	ui._spin_bearing.value = 137.0
	var op_id: int = ui._op_panel.get_instance_id()
	var btn_id: int = (ui._contact_rows[tid] as Button).get_instance_id()
	# 强制滚动：临时加高内容，验证 tracks 页可滚动。
	var body = pager.page_body("tracks")
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 1600)
	body.add_child(spacer)
	await process_frame
	pager.select("tracks")
	await process_frame
	var sb = pager.page_scroll("tracks").get_v_scroll_bar()
	_assert_bool(fails, "AT-29b page scrollable", sb.max_value > 50.0, true)
	sb.value = 120.0
	pager.select("weapons")
	await process_frame
	pager.select("own")
	await process_frame
	pager.select("tracks")
	await process_frame
	_assert_bool(fails, "AT-29c scroll restored", absf(float(sb.value) - 120.0) < 1.0, true)
	spacer.queue_free()
	await process_frame
	_assert_bool(fails, "AT-29d selection kept", ui.selected_track_id == tid, true)
	_assert_bool(fails, "AT-29e form kept", absf(ui._spin_bearing.value - 137.0) < 0.01, true)
	_assert_bool(
		fails, "AT-29f business object not rebuilt", ui._op_panel.get_instance_id() == op_id, true
	)
	_assert_bool(
		fails,
		"AT-29g contact button not rebuilt",
		(ui._contact_rows[tid] as Button).get_instance_id() == btn_id,
		true
	)


## AT-30：页面隐藏期间，新鱼雷证据仍更新固定告警条和按钮红点。
func _at30_alert_while_hidden(fails: Array, ui: Control) -> void:
	var pager = ui._pager
	pager.select("weapons")  # 航迹页隐藏
	var w = ui.world
	(
		w
		. threat_tracks
		. ingest(
			{
				"evidence_id": 95001,
				"evidence_kind": "RUNNING_NOISE",
				"timestamp": w.sim_time,
				"bearing_deg": 100.0,
				"bearing_sigma_deg": 3.0,
				"p_torpedo": 0.9,
				"class_state": "PROBABLE_TORPEDO",
			},
			w.sim_time
		)
	)
	ui._process(0.5)  # → _update_displays_light（业务更新不依赖页面 visible）
	_assert_bool(fails, "AT-30a banner updated", ui._threat_hud.banner_text().contains("TT"), true)
	_assert_bool(fails, "AT-30b badge count", pager.badge("tracks") >= 1, true)
	_assert_bool(
		fails, "AT-30c badge dot on button", str(pager._btns["tracks"].text).contains("●"), true
	)
	_assert_bool(fails, "AT-30d no forced switch", pager.current_page() == "weapons", true)
	_assert_bool(fails, "AT-30e hidden list updated too", ui._threat_list.row_count() >= 1, true)


## AT-31：三种分辨率下无控件越界、无水平滚动。
func _at31_resolutions(fails: Array) -> void:
	for res in [[1280, 720], [1440, 900], [1920, 1080]]:
		var tag: String = str(res[0]) + "x" + str(res[1])
		var ui: Control = await _mk_ui(int(res[0]), int(res[1]))
		ui._process(0.1)  # 触发 P1-03.1 宽度钳制
		var pager = ui._pager
		# 实际宽 = max(契约鈐制下限, 页面内容固有宽)；横向滚动始终禁用。
		_assert_bool(
			fails,
			"AT-31 %s sidebar width" % tag,
			pager.size.x >= UiContract.SIDEBAR_MIN_W - 0.5 and pager.size.x <= 520.0,
			true
		)
		for pid in pager.page_ids():
			var sc = pager.page_scroll(pid)
			_assert_bool(
				fails,
				"AT-31 %s no h-scroll %s" % [tag, pid],
				not sc.get_h_scroll_bar().visible,
				true
			)
			# 页面内容完整容得下（无裁剪/越界）。
			var bmin: float = (pager.page_body(pid) as Control).get_combined_minimum_size().x
			_assert_bool(
				fails, "AT-31 %s content fits %s" % [tag, pid], bmin <= pager.size.x + 1.0, true
			)
		var pr := Rect2(pager.global_position, pager.size)
		for pid in pager.page_ids():
			var b = pager._btns[pid]
			var inside: bool = (
				b.global_position.x >= pr.position.x - 1.0
				and b.global_position.y >= pr.position.y - 1.0
				and b.global_position.x + b.size.x <= pr.end.x + 1.0
				and b.global_position.y + b.size.y <= pr.end.y + 1.0
			)
			_assert_bool(fails, "AT-31 %s btn inside %s" % [tag, pid], inside, true)
		var vs: Control = pager.page_scroll(str(pager.current_page()))
		_assert_bool(
			fails,
			"AT-31 %s page fits" % tag,
			vs.size.x <= pager.size.x + 1.0 and vs.size.y <= pager.size.y + 1.0,
			true
		)
		# 侧栏不挤压海图（P1-03.1 不变量）。
		_assert_bool(fails, "AT-31 %s chart kept" % tag, ui._chart.size.x > 100.0, true)
		_assert_bool(
			fails, "AT-31 %s grid fits" % tag, pager._btn_grid.size.x <= pager.size.x + 1.0, true
		)
		var want_cols: int = 4 if pager.size.x >= 440.0 else 2
		_assert_bool(
			fails, "AT-31 %s adaptive columns" % tag, pager._btn_grid.columns == want_cols, true
		)
		ui.queue_free()
		await process_frame


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append(name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("SIDEBAR_PAGER_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("TEST FAIL: " + str(f))
		print("SIDEBAR_PAGER_TEST result=FAIL (%d)" % fails.size())
		quit(1)
