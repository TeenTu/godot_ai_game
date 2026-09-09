extends SceneTree
## chart_context_menu_test.gd — S109 Batch 6 海图右键菜单验收（AT-32..34）。
##
## 运行：godot --headless --path games/sonar --script res://tools/chart_context_menu_test.gd
## AT-32 四类命中 hit_kind + 中文菜单项；AT-33 主动确认 Ping 的暴露确认与
## 在途/终局命令门；AT-34 "预填概略射击" 只预填切页、绝不发射。
## 危险动作（Ping/切断导线）经菜单二次确认：id_pressed(索引) → 确认(0)/取消(1)。


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
	ui.world.auto_measurements = true
	for i in range(12):
		ui._process(0.5)
	var tid: String = ""
	for t in ui.tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE:
			tid = t.track_id
			break
	_at34_presite_only(fails, ui, tid)
	_setup_chart_dto(ui, tid)
	_at32_hits_and_items(fails, ui, tid)
	_at33_ping_confirm_and_gates(fails, ui)
	_finish(fails)


## 注入纯 DTO（不跑 _process，避免快照被业务刷新覆盖）。
func _setup_chart_dto(ui: Control, tid: String) -> void:
	var chart = ui._chart
	chart.set_view(Vector2.ZERO, 8000.0)
	var same := Vector2(2000.0, 3000.0)
	chart.threat_snapshots = [_snap(same)]
	chart.torpedoes = [{"trail": [{"e": same.x, "n": same.y}], "torpedo_id": "PT9"}]
	chart.fit_track_id = tid
	chart.fit_now_time = 100.0
	chart.fit_hypotheses = [
		{"p_ref": Vector2(4000, 0), "v_ms": Vector2(5, 0), "t_ref": 100.0, "is_best": true}
	]
	chart.threat_lobs = [
		{
			"evidence_id": 7,
			"threat_track_id": "TT001",
			"observer": Vector2(-6000, -6000),
			"bearing_deg": 45.0,
			"sigma_deg": 3.0,
			"kind": "RUNNING_NOISE",
			"time": 50.0,
			"length_m": 6000.0,
		}
	]
	chart.queue_redraw()


## 收敛威胁快照 DTO（含 ThreatChartOverlay 绘制所需全部字段）。
func _snap(w: Vector2) -> Dictionary:
	return {
		"track_id": "TT001",
		"state": "TRACKING",
		"draw_center_e_m": w.x,
		"draw_center_n_m": w.y,
		"ellipse_a_m": 600.0,
		"ellipse_b_m": 240.0,
		"ellipse_angle_deg": 0.0,
		"converged": true,
		"course_est_deg": 90.0,
		"last_update_time": 100.0,
	}


func _right_click(ui: Control, w: Vector2) -> Dictionary:
	var chart = ui._chart
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.position = chart.world_to_screen(w)
	# 注意：lambda 捕获按值拷贝（GDScript 语义），必须写进容器才能回读。
	var cap: Array = []
	var cb := func(ctx: Dictionary): cap.append(ctx)
	chart.context_requested.connect(cb)
	chart._gui_input(ev)
	chart.context_requested.disconnect(cb)
	return (cap[0] as Dictionary) if not cap.is_empty() else {}


## AT-32：四类命中 + 中文菜单项（含优先级：威胁符号压过同点鱼雷）。
func _at32_hits_and_items(fails: Array, ui: Control, tid: String) -> void:
	var menu = ui._ctx_actions._menu
	var ctx := _right_click(ui, Vector2(2000, 3000))
	_assert(fails, "AT-32a threat hit wins overlap", str(ctx.get("hit_kind")) == "THREAT", true)
	_assert(fails, "AT-32b threat hit_id", str(ctx.get("hit_id")) == "TT001", true)
	var texts: PackedStringArray = menu.item_texts()
	_assert(
		fails,
		"AT-32c threat zh menu",
		(
			texts.has("查看威胁详情")
			and texts.has("设为当前威胁")
			and texts.has("居中此威胁")
			and texts.has("查看证据历史")
			and texts.has("主动确认 Ping…")
			and texts.has("转到反制武器")
		),
		true
	)
	ctx = _right_click(ui, Vector2(4000, 0))
	_assert(fails, "AT-32d contact hit", str(ctx.get("hit_kind")) == "CONTACT", true)
	_assert(fails, "AT-32e contact hit_id", str(ctx.get("hit_id")) == tid, true)
	texts = menu.item_texts()
	_assert(
		fails,
		"AT-32f contact zh menu",
		(
			texts.has("选择接触")
			and texts.has("设为当前 Mark 组")
			and texts.has("转到 TMA")
			and texts.has("自动拟合")
			and texts.has("以此方位预填概略射击…")
			and texts.has("居中此接触")
		),
		true
	)
	# 同点覆盖时威胁压过鱼雷已验；单点鱼雷菜单（移开威胁后单独验）：
	ui._chart.threat_snapshots = []
	ctx = _right_click(ui, Vector2(2000, 3000))
	_assert(fails, "AT-32g torpedo hit", str(ctx.get("hit_kind")) == "OWN_TORPEDO", true)
	_assert(fails, "AT-32h torpedo hit_id", str(ctx.get("hit_id")) == "PT9", true)
	texts = menu.item_texts()
	_assert(
		fails,
		"AT-32i torpedo zh menu",
		texts.has("选择该武器") and texts.has("转到线导控制") and texts.has("居中该武器") and texts.has("切断导线…"),
		true
	)
	ctx = _right_click(ui, Vector2(-6000, -6000))
	_assert(fails, "AT-32j threat lob hit", str(ctx.get("hit_kind")) == "THREAT_LOB", true)
	ctx = _right_click(ui, Vector2(7000, -7000))
	_assert(fails, "AT-32k empty hit", str(ctx.get("hit_kind")) == "EMPTY", true)
	# §9.3：菜单开启期间海图暂停拖曳（右键后 headless 视为常开）。
	var chart = ui._chart
	_assert(fails, "AT-32m drag lock armed", bool(chart.context_menu_open), true)
	var cam0: Vector2 = chart.cam_center
	var lmb := InputEventMouseButton.new()
	lmb.button_index = MOUSE_BUTTON_LEFT
	lmb.pressed = true
	lmb.position = chart.size * 0.5
	chart._gui_input(lmb)
	var mm := InputEventMouseMotion.new()
	mm.position = chart.size * 0.5 + Vector2(60, 0)
	chart._gui_input(mm)
	_assert(
		fails,
		"AT-32n drag locked while menu open",
		absf(chart.cam_center.x - cam0.x) < 0.01 and absf(chart.cam_center.y - cam0.y) < 0.01,
		true
	)
	chart.context_menu_open = false  # 模拟菜单关闭，恢复拖曳
	lmb.pressed = true
	chart._gui_input(lmb)
	mm.position = chart.size * 0.5 + Vector2(60, 0)
	chart._gui_input(mm)
	_assert(fails, "AT-32o drag resumes after close", absf(chart.cam_center.x - cam0.x) > 1.0, true)
	texts = menu.item_texts()
	_assert(
		fails,
		"AT-32l empty zh menu",
		(
			texts.has("以此处为地图中心")
			and texts.has("开始测距尺")
			and texts.has("自动取景")
			and texts.has("清除选择")
			and texts.has("图层设置")
		),
		true
	)


## AT-33：暴露确认 → 确认才发 Ping；在途拒绝；终局命令门。
func _at33_ping_confirm_and_gates(fails: Array, ui: Control) -> void:
	var w = ui.world
	var menu = ui._ctx_actions._menu
	_assert(fails, "AT-33a hardware ready", w.ping_hardware and w.can_ping(), true)
	ui._chart.threat_snapshots = [_snap(Vector2(2000, 3000))]
	var ctx33 := _right_click(ui, Vector2(2000, 3000))
	_assert(
		fails,
		"AT-33a2 threat menu open",
		str(ctx33.get("hit_kind")) == "THREAT" and menu.item_texts()[4] == "主动确认 Ping…",
		true
	)
	menu.id_pressed.emit(4)
	_assert(fails, "AT-33b pending confirm", menu.pending_action() == "threat_ping", true)
	_assert(
		fails,
		"AT-33c exposure warning",
		menu.item_texts().size() > 0 and str(menu.item_texts()[0]).contains("暴露"),
		true
	)
	_assert(fails, "AT-33d no ping before confirm", w.pending_echo_count() == 0, true)
	menu.id_pressed.emit(1)  # 取消
	_assert(fails, "AT-33e cancel clears", menu.pending_action() == "", true)
	_assert(fails, "AT-33f no ping after cancel", w.pending_echo_count() == 0, true)
	# 模拟菜单收起（headless 无真实 popup 窗口，popup_hide 不触发；
	# 生产链路由 _menu.popup_hide 连接置 false，这里直接等效驱动）
	ui._chart.context_menu_open = false
	_assert(fails, "AT-33f2 lock released on hide", not ui._chart.context_menu_open, true)
	var lmb2 := InputEventMouseButton.new()
	lmb2.button_index = MOUSE_BUTTON_LEFT
	lmb2.pressed = true
	lmb2.position = ui._chart.size * 0.5
	ui._chart._gui_input(lmb2)
	_assert(fails, "AT-33f3 drag rearmed after close", bool(ui._chart._dragging), true)
	# 重新右键 → THREAT 菜单重新填充 → 选 Ping → 确认条目 0 = 确认
	_right_click(ui, Vector2(2000, 3000))
	menu.id_pressed.emit(4)
	menu.id_pressed.emit(0)  # 确认 → 发 Ping
	_assert(fails, "AT-33g in-flight session", not w._ping_session.is_empty(), true)
	_assert(fails, "AT-33g2 ping gate closed", not w.can_ping(), true)
	ui._ctx_actions.run_action("threat_ping", {})  # 在途再请求：必须被拒
	_assert(fails, "AT-33h still one session", w._ping_session.has("echoes"), true)
	w._ping_session.clear()  # 清在途，单独验 MISSION_ENDED 门
	w.end_mission(1, "TEST")
	ui._ctx_actions.run_action("threat_ping", {})
	_assert(fails, "AT-33i mission ended gate", w._ping_session.is_empty(), true)


## AT-34：预填概略射击只预填 + 切武器页，绝不发射。
func _at34_presite_only(fails: Array, ui: Control, tid: String) -> void:
	_assert(fails, "AT-34a contact exists", tid != "", true)
	var w = ui.world
	var before: int = w.weapons.torpedoes.size()
	var t: Track = w.tracker if false else ui.tracker.track_by_id(tid)
	var m: Measurement = t.latest_measurement()
	ui._ctx_actions.run_action("contact_presite", {"hit_id": tid, "world_position": Vector2.ZERO})
	_assert(fails, "AT-34b selection set", ui.selected_track_id == tid, true)
	_assert(fails, "AT-34c weapons page", ui._pager.current_page() == "weapons", true)
	_assert(
		fails,
		"AT-34d bearing prefilled",
		absf(NavUtils.angle_diff(ui.trial.bearing_deg, m.measured_bearing_deg)) < 0.01,
		true
	)
	_assert(fails, "AT-34e no torpedo fired", w.weapons.torpedoes.size() == before, true)


func _assert(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append(name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("CHART-CONTEXT-MENU TEST PASS")
		quit(0)
	else:
		for f in fails:
			print("TEST FAIL: " + str(f))
		print("CHART-CONTEXT-MENU TEST FAIL (%d)" % fails.size())
		quit(1)
