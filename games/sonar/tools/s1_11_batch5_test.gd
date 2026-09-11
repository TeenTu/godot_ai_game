extends SceneTree
## s1_11_batch5_test.gd — S1-11 Batch 5：在水鱼雷地图控制与主动开机点。
##
##   B5-01 (§4.1/§4.3) 地图画线 → 浮动栏「发射」→ 唯一 MAP_ROUTE 发射链落地；
##   B5-02 (§6.3/AT-22) 开机点按沿航线**累计距离**触发，且只触发一次；
##   B5-03 (§4.4/AT-17) 导线 BROKEN/CUT 后地图命令（航行/航路点/开机/清航线/
##          重画）全部拒绝并给出中文具体原因，绝不静默失败；
##   B5-04 (§4.3) 右键菜单动态条目：选中鱼雷 → 4 条指令；绘制态 → 航线编辑
##         菜单（完成航线 / 取消本次绘制）优先于命中类型；
##   B5-05 (§6.4/AT-24/25) 武器页无 WAYPOINT/AUTONOMY 下拉；只留主动/切线两个安全动作；
##   B5-06 (§9.3/AT-26) 摘要行点击 → 地图选中该 torpedo_id（数组删减后 ID 不重排）。

const SEED: int = 20260910


class FakeUI:
	var selected_track_id: String = ""
	var world: World = null


func _initialize() -> void:
	var fails: Array = []
	_b5_01_map_launch(fails)
	_b5_02_trigger_distance(fails)
	_b5_03_wire_gates(fails)
	_b5_04_menu_dynamic(fails)
	_b5_05_ui_removed(fails)
	_b5_06_summary_select(fails)
	_b5_07_route_line_once(fails)
	_finish(fails)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	var w := World.new()
	w.load_scenario(sc)
	return w


func _mk_map(w: World):
	var ui := FakeUI.new()
	ui.world = w
	var chart := ChartView.new()
	root.add_child(chart)
	var wmc := WeaponMapControl.new()
	root.add_child(wmc)
	# 玩家唯一发射方式：MAP_ROUTE 必须经 LaunchProgrammer（无编程器一律拒绝）。
	var fe := FireExecutor.new()
	fe.programmer = LaunchProgrammer.new()
	wmc.setup(ui, w, chart, fe)
	return wmc


# ---------------- B5-01：地图画线 → 发射（唯一 MAP_ROUTE） ----------------
func _b5_01_map_launch(fails: Array) -> void:
	var w := _mk_world()
	var wmc = _mk_map(w)
	var own: RefCounted = w.world["own"]
	wmc.begin_draw()
	_assert(fails, "B5-01a draw started", wmc.is_drawing(), true)
	wmc.route_overlay.add_point(0.0, 3000.0)
	_assert(fails, "B5-01b snapshot follows map", wmc.route_snapshot().size() == 2, true)
	_assert(fails, "B5-01c ready to fire", wmc.is_route_ready(), true)
	var start_pt: Vector2 = wmc.route_overlay.points[0]
	_assert(
		fails,
		"B5-01c2 start snapped to own measured position",
		start_pt.is_equal_approx(Vector2(float(own.position_east_m), float(own.position_north_m))),
		true
	)
	var res: Dictionary = wmc.try_fire()
	_assert(fails, "B5-01d fire accepted", bool(res.get("ok", false)), true)
	var tp: Torpedo = res.get("tp", null)
	_assert(fails, "B5-01e torpedo in water", tp != null, true)
	if tp == null:
		return
	# 唯一发射方式：程序收到的就是地图航线（起点=本艇实测位，终点=地图点）。
	_assert(
		fails,
		"B5-01f route carried verbatim",
		(
			tp.route != null
			and tp.route.points.size() == 2
			and (tp.route.points[0] as Vector2).is_equal_approx(start_pt)
			and (tp.route.points[1] as Vector2).is_equal_approx(Vector2(0.0, 3000.0))
		),
		true
	)
	_assert(
		fails,
		"B5-01g initial course = first segment bearing",
		absf(NavUtils.wrap180(tp.course_deg - tp.route.last_course_deg)) < 1e-6,
		true
	)
	wmc.begin_draw()
	_assert(fails, "B5-01h draw restarts after fire", wmc.is_drawing(), true)
	wmc.free()


# ---------------- B5-02：开机点沿航线累计距离，只触发一次 ----------------
func _b5_02_trigger_distance(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	var t0: float = float(tp.traveled_m)
	_assert(fails, "B5-02a torpedo running", t0 > 0.0, true)
	_assert(
		fails, "B5-02b trigger point accepted", tp.command_active_trigger_distance(t0 + 400.0), true
	)
	_assert(fails, "B5-02c waiting trigger state", tp.has_active_trigger_point(), true)
	_assert(
		fails,
		"B5-02c2 armed waiting for distance",
		int(tp.active_tx_state) == Torpedo.ActiveTxState.WAITING_TRIGGER,
		true
	)
	var fired_at: float = -1.0
	for i in range(400):
		w.run_steps(1)
		var st: int = int(tp.active_tx_state)
		if st == Torpedo.ActiveTxState.PINGING or st == Torpedo.ActiveTxState.COOLDOWN:
			fired_at = float(tp.traveled_m)
			break
	_assert(fails, "B5-02d auto-triggered after distance", fired_at >= 0.0, true)
	_assert(
		fails,
		"B5-02e not earlier than commanded distance (%.0f >= %.0f)" % [fired_at, t0 + 400.0],
		fired_at >= t0 + 400.0 - 1e-6,
		true
	)
	# 只触发一次：已开机后再下发开机点必须被拒（ALREADY ACTIVE）。
	_assert(
		fails,
		"B5-02f second trigger point rejected",
		tp.command_active_trigger_distance(float(tp.traveled_m) + 100.0),
		false
	)
	_assert(fails, "B5-02g reject reason", str(tp.last_cmd_reject_reason) == "ALREADY ACTIVE", true)
	# 开机点不改变航向/制导权限（AT-23：解耦）。
	tp.set_active_tx(false)
	_assert(
		fails,
		"B5-02h active tx does not grant autonomy",
		(
			int(tp.guidance_authority) != Torpedo.GuidanceAuthority.AUTONOMOUS
			or tp.program.fire_mode != WeaponProgram.FireMode.MANUAL
		),
		true
	)


# ---------------- B5-03：导线门控 + 中文拒绝原因 ----------------
func _b5_03_wire_gates(fails: Array) -> void:
	var w := _mk_world()
	var wmc = _mk_map(w)
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	var tid: String = str(tp.torpedo_id)
	wmc.set_selected_torpedo(tid)
	var msgs: Array = []
	wmc.status.connect(func(m: String): msgs.append(m))
	tp.wire_link.cut()
	wmc.map_goto_point(Vector2(1000.0, 1000.0))
	_assert(fails, "B5-03a goto rejected after cut", _last_has(msgs, "已切断"), true)
	msgs.clear()
	wmc.map_append_waypoint(Vector2(1200.0, 1200.0))
	_assert(fails, "B5-03b waypoint rejected after cut", _last_has(msgs, "已切断"), true)
	msgs.clear()
	wmc.map_active_at(Vector2(1200.0, 1200.0))
	_assert(fails, "B5-03c active-at rejected after cut", _last_has(msgs, "已切断"), true)
	msgs.clear()
	wmc.map_clear_remaining_route()
	_assert(fails, "B5-03d clear route rejected after cut", _last_has(msgs, "已切断"), true)
	msgs.clear()
	_assert(fails, "B5-03e reroute rejected after cut", wmc.begin_reroute(tid), false)
	_assert(fails, "B5-03f reroute reason shown", _last_has(msgs, "已切断"), true)
	# 拒绝必须是可见中文提示（绝不静默失败）。
	_assert(fails, "B5-03g never silent", msgs.size() > 0, true)


func _last_has(msgs: Array, token: String) -> bool:
	if msgs.is_empty():
		return false
	return str(msgs[msgs.size() - 1]).contains(token)


# ---------------- B5-04：右键菜单动态条目 ----------------
func _b5_04_menu_dynamic(fails: Array) -> void:
	var menu := ChartContextMenu.new()
	menu.open_at(Vector2.ZERO, {"hit_kind": "OWN_TORPEDO"})
	var texts: Array = Array(menu.item_texts())
	_assert(fails, "B5-04a torpedo menu items", texts.size() >= 5, true)
	_assert(fails, "B5-04b torpedo menu chinese", texts.has("重画剩余航线"), true)
	menu.open_at(
		Vector2.ZERO, {"hit_kind": "EMPTY", "selected_torpedo_id": "", "route_drawing": false}
	)
	texts = Array(menu.item_texts())
	_assert(fails, "B5-04c empty base menu", texts.has("绘制鱼雷航线"), true)
	_assert(
		fails, "B5-04d no torpedo commands without selection", not _has_prefix(texts, "令 "), true
	)
	(
		menu
		. open_at(
			Vector2.ZERO,
			{
				"hit_kind": "EMPTY",
				"selected_torpedo_id": "TK02",
				"route_drawing": true,
				"route_can_commit": true,
			}
		)
	)
	texts = Array(menu.item_texts())
	_assert(fails, "B5-04e drawing menu is route-only", texts.size(), 2)
	_assert(fails, "B5-04f done-drawing entry", texts.has("完成航线"), true)
	_assert(fails, "B5-04g cancel-drawing entry", texts.has("取消本次绘制"), true)
	_assert(fails, "B5-04h no torpedo commands while drawing", _has_prefix(texts, "令 "), false)
	# 命中鱼雷也不改变：绘制态菜单优先于命中类型（否则「完成航线」不可达）。
	menu.open_at(
		Vector2.ZERO,
		{"hit_kind": "OWN_TORPEDO", "selected_torpedo_id": "TK02", "route_drawing": true}
	)
	texts = Array(menu.item_texts())
	_assert(fails, "B5-04i drawing beats hit kind", texts.has("重画剩余航线"), false)
	# 无有效航线：不提供「完成航线」，但必须仍能取消（绝不出现点了没反应的死条目）。
	menu.open_at(
		Vector2.ZERO, {"hit_kind": "EMPTY", "route_drawing": true, "route_can_commit": false}
	)
	texts = Array(menu.item_texts())
	_assert(fails, "B5-04j no done without valid route", texts.has("完成航线"), false)
	_assert(fails, "B5-04k cancel still available", texts.has("取消本次绘制"), true)
	menu.free()


func _has_prefix(texts: Array, prefix: String) -> bool:
	for t in texts:
		if str(t).begins_with(prefix):
			return true
	return false


# ---------------- B5-05：旧控件删除（AT-24/25） ----------------
func _b5_05_ui_removed(fails: Array) -> void:
	var wp_src := _read("res://scripts/ui/weapon_panel.gd")
	var iw_src := _read("res://scripts/ui/in_water_weapon_panel.gd")
	_assert(
		fails,
		"B5-05a no autonomy/waypoint dropdown in weapon page",
		(
			wp_src.find("AutonomyEnableMode") < 0
			and wp_src.find("SearchDepthPreset") < 0
			and wp_src.find("ActiveEnableMode") < 0
		),
		true
	)
	_assert(
		fails, "B5-05b per-program editor removed", wp_src.find("_build_program_editor") < 0, true
	)
	for key in ["iw_btn_left", "iw_btn_right", "iw_btn_speed", "iw_btn_autonomy", "iw_btn_return"]:
		_assert(fails, "B5-05c removed in-water control %s" % key, iw_src.find(key) < 0, true)
	# 保留两个安全动作（主动开关 / 切断导线）。
	_assert(
		fails,
		"B5-05d safety actions kept",
		iw_src.find("iw_btn_active_on") >= 0 and iw_src.find("iw_btn_cut") >= 0,
		true
	)


# ---------------- B5-06：摘要行 → 地图选中（AT-26） ----------------
func _b5_06_summary_select(fails: Array) -> void:
	var w := _mk_world()
	var p := InWaterWeaponPanel.new()
	root.add_child(p)
	p.bind(w)
	var t1: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	var t2: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	p.sync()
	var id1: String = str(t1.torpedo_id)
	var id2: String = str(t2.torpedo_id)
	_assert(fails, "B5-06a distinct torpedo ids", id1 != id2, true)
	var clicked: Array = []
	p.row_clicked.connect(func(tid: String): clicked.append(tid))
	var btn: Button = p._sections[id2]["btns"]["active"]
	# 点击摘要行按钮（标题按钮）→ 发出该行自己的 id。
	var head: Button = _title_button(p, id2)
	_assert(fails, "B5-06b title button exists", head != null, true)
	if head != null:
		head.pressed.emit()
	_assert(fails, "B5-06c row click emits own id", clicked.has(id2), true)
	# 数组删减（一枚死亡移除）后另一枚 id 不变（绝不重排）。
	t1.detonate({"min_distance_m": 1.0})
	p.sync()
	_assert(fails, "B5-06d remaining id stable", p._sections.has(id2), true)
	_assert(fails, "B5-06e button still bound", btn != null, true)
	p.free()


# ---------------- B5-07：武器页「航线状态」只出现一行（回归：曾重复两行） ----------------
func _b5_07_route_line_once(fails: Array) -> void:
	var p := WeaponPanelUI.new()
	root.add_child(p)
	_assert(
		fails, "B5-07a route state line present", str(p._lbl_route.text), UiText.t("route_none")
	)
	# 发射上下文行是「建议航线就绪 / 已在水中」等**增量**提示，初值必须为空，
	# 否则与航线状态行重复成两行同文案（真实 Web 导出中可见）。
	_assert(fails, "B5-07b fire hint empty by default", str(p._lbl_fire_hint.text), "")
	var src := _read("res://scripts/ui/main_ui.gd")
	_assert(
		fails,
		"B5-07c main_ui never copies route_none into fire hint",
		src.find('set_fire_context(UiText.t("route_none"))') < 0,
		true
	)
	p.queue_free()


func _title_button(p, tid: String) -> Button:
	var sec: Dictionary = p._sections.get(tid, {})
	if sec.is_empty():
		return null
	for c in p._cards.get_children():
		for child in c.get_children():
			if child is HBoxContainer:
				for b in child.get_children():
					if b is Button and str(b.text).contains(tid):
						return b
	return null


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _assert(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH5 TEST PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("S1-11 BATCH5 TEST FAIL (%d)" % fails.size())
	quit(1)
