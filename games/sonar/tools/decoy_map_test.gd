extends SceneTree
## decoy_map_test.gd — P1-C DC-04/DC-05：海图诱饵图层与右键投放（T29/T30/T31）。
##
## 运行：godot --headless --path games/sonar --script res://tools/decoy_map_test.gd
## 必须输出 "DECOY_MAP_TEST result=PASS"。
##
## 真实节点层级（MainUI → ChartView / WeaponMapControl → MapRouteOverlay）+
## 真实 Viewport 输入分发（root.push_input(ev, true)：headless 根视口带
## content-scale，按"屏幕坐标"投递会被再变换一次，点击落到视口外 —— 假绿陷阱）。
## 不允许只调内部函数：本批次的验收点正是"真实事件链是否接通"。
##
## T29 平移/缩放/改窗口后，本艇、诱饵、鱼雷与航线四个锚点**共用同一个**
##     world_to_screen（仿射关系一致、世界坐标往返无损），且诱饵轨迹只存世界坐标。
## T30 地图右键投放与面板投放产生**等价程序**；打开/关闭菜单不消耗库存；
##     离本艇过近显示"方向不明确"且不发射；库存只扣一次。
## T31 绘制航线时右键仍优先"完成/取消绘制"（不被诱饵条目破坏）；
##     输入框持有焦点时 Enter 属于输入框，不被航线编辑抢走。

var ui: Control = null


func _init() -> void:
	await _run()


func _run() -> void:
	var fails: Array = []
	root.size = Vector2i(1440, 900)
	await process_frame
	ui = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	ui.world.auto_measurements = true
	for i in range(6):
		ui._process(0.5)
	await _t29_shared_mapping(fails)
	_t30_map_equals_panel(fails)
	_t31_route_priority(fails)
	await _t31_enter_not_stolen(fails)
	_finish(fails)


# ============================================================== T29 映射一致
func _t29_shared_mapping(fails: Array) -> void:
	var chart = ui._chart
	var ov: MapRouteOverlay = ui._wmc.route_overlay
	var own: TruthEntity = ui.world.world["own"]
	# 真实投放一枚诱饵（走 World 命令门 → OwnAssetRegistry → 海图图层）。
	var prog: DecoyProgram = DecoyLaunchBuilder.build(
		ui.world.countermeasures, DecoyProgram.TYPE_MOBILE, 90.0, own
	)
	_assert(fails, "T29 launch accepted", ui.world._launch_decoy(prog), true)
	# 本艇停车 → 诱饵独自向东航行，位置与本艇明显分离（不是本艇位置顶替）。
	own.command_speed(0.0)
	own.speed_kn = 0.0
	own.acceleration_kn_s = 6.0
	for i in range(24):
		ui._process(0.5)
	var rows: Array = chart.decoy_layer.active
	_assert(fails, "T29 decoy icon on map", rows.size(), 1)
	if rows.is_empty():
		return
	var dcy = ui.world.decoys[0]
	var row: Dictionary = rows[0]
	# DC-04：图标位置 = 诱饵**自身**世界坐标（不是本艇位置，也不是激活事件 LOA）。
	_assert(fails, "T29 decoy id stable", str(row["id"]), str(dcy.id))
	_assert(
		fails,
		"T29 decoy pos equals decoy truth pos",
		(
			absf(float(row["e"]) - float(dcy.position_east_m)) < 0.01
			and absf(float(row["n"]) - float(dcy.position_north_m)) < 0.01
		),
		true
	)
	var dec_world := Vector2(float(row["e"]), float(row["n"]))
	var own_world: Vector2 = chart.own_pos
	_assert(fails, "T29 decoy separated from own", own_world.distance_to(dec_world) > 30.0, true)
	_assert(fails, "T29 decoy marked measured", bool(row.get("measured", false)), true)
	_assert(fails, "T29 decoy has type", str(row.get("type", "")) != "", true)
	_assert(fails, "T29 decoy has lifetime", float(row.get("lifetime_s", 0.0)) > 0.0, true)
	# 鱼雷 DTO + 航线点：喂真实输入（不调内部换算函数）。
	chart.torpedoes = [{"trail": [{"e": -3000.0, "n": 1200.0}], "torpedo_id": "PT-T29"}]
	ui.begin_route_draw()
	ov.add_point(2500.0, -1800.0)
	chart.set_view(Vector2(1000.0, -2000.0), 8000.0)
	var route_world: Vector2 = ov.points[-1]
	var cam0: Vector2 = chart.cam_center
	var r0: float = chart.view_radius_m
	var size0: Vector2 = chart.size
	var probes: Array = _probes(chart, own_world, dec_world, route_world)
	var names: Array = _names(probes)
	_assert(fails, "T29 four anchors mapped", probes.size(), 4)
	# 往返无损：screen_to_world(world_to_screen(w)) == w（四个锚点同一映射）。
	for pr in probes:
		var back: Vector2 = chart.screen_to_world(pr["screen"])
		_assert(
			fails, "T29 roundtrip %s" % str(pr["name"]), back.distance_to(pr["world"]) < 0.01, true
		)
	# 平移：cam_center 改变 → 四个锚点屏移完全一致（每次重算生产屏幕点）。
	var s0: Array = _screens(probes)
	var sc0: float = chart._scale_px()
	var dcam := Vector2(1200.0, -900.0)
	chart.cam_center += dcam
	var s1: Array = _screens(_probes(chart, own_world, dec_world, route_world))
	var want := Vector2(-dcam.x * sc0, dcam.y * sc0)
	_assert(fails, "T29 pan keeps four anchors", s1.size(), 4)
	for i in range(s1.size()):
		var dlt: Vector2 = s1[i] - s0[i]
		_assert(
			fails,
			"T29 pan delta %s" % str(names[i]),
			absf(dlt.x - want.x) < 0.01 and absf(dlt.y - want.y) < 0.01,
			true
		)
	# 缩放：view_radius 翻倍 → 四个锚点对中心的偏移按同一比例缩放。
	var c: Vector2 = chart.size * 0.5
	chart.view_radius_m *= 2.0
	var s2: Array = _screens(_probes(chart, own_world, dec_world, route_world))
	var ratio: float = chart._scale_px() / sc0
	_assert(fails, "T29 zoom keeps four anchors", s2.size(), 4)
	for i in range(s2.size()):
		var want2: Vector2 = c + (s1[i] - c) * ratio
		_assert(fails, "T29 zoom ratio %s" % str(names[i]), s2[i].distance_to(want2) < 0.01, true)
	# 改窗口尺寸：中心与比例同时变，四个锚点仍服从同一仿射关系。
	var sc2: float = chart._scale_px()
	chart.size = Vector2(900.0, 760.0)
	var c3: Vector2 = chart.size * 0.5
	var s3: Array = _screens(_probes(chart, own_world, dec_world, route_world))
	var ratio2: float = chart._scale_px() / sc2
	_assert(fails, "T29 resize keeps four anchors", s3.size(), 4)
	for i in range(s3.size()):
		var want3: Vector2 = c3 + (s2[i] - c) * ratio2
		_assert(fails, "T29 resize ratio %s" % str(names[i]), s3[i].distance_to(want3) < 0.01, true)
	# 还原相机与尺寸（后续阶段要用真实布局做真实点击）。
	chart.cam_center = cam0
	chart.view_radius_m = r0
	chart.size = size0
	# 轨迹只存世界坐标：以上平移/缩放/改窗口都不改变轨迹本身。
	var tr: Array = chart.decoy_layer.track_of(str(dcy.id))
	var tr_ok: bool = tr.size() >= 2
	var prev: Vector2 = tr[0] if tr_ok else Vector2.ZERO
	for p in tr:
		if (p as Vector2).distance_to(prev) > 200.0:
			tr_ok = false
		prev = p
	_assert(fails, "T29 track is world coords", tr_ok, true)
	# 世界尺度检查：轨迹总长必须是真实米数（屏幕坐标/缩放坐标会差几个数量级）。
	var tr_len: float = 0.0
	for i in range(1, tr.size()):
		tr_len += (tr[i] as Vector2).distance_to(tr[i - 1])
	_assert(fails, "T29 track world-scale length", tr_len > 20.0 and tr_len < 5000.0, true)
	_assert(
		fails,
		"T29 track head equals decoy pos",
		(tr[-1] as Vector2).distance_to(dec_world) < 1.0,
		true
	)
	ui._wmc.cancel_current_edit()
	await process_frame


## 锚点名字列表（与 _probes 同序）。
func _names(probes: Array) -> Array:
	var out: Array = []
	for pr in probes:
		out.append(str(pr["name"]))
	return out


## 四个锚点的（世界点 → 生产用屏幕点）。
func _probes(chart, own_world: Vector2, dec_world: Vector2, route_world: Vector2) -> Array:
	var out: Array = []
	out.append({"name": "own", "world": own_world, "screen": chart.own_pos_screen()})
	var dc: Array = chart.decoy_click_points()
	if not dc.is_empty():
		out.append({"name": "decoy", "world": dec_world, "screen": dc[0]["pos"]})
	var tc: Array = chart.torpedo_click_points()
	if not tc.is_empty():
		out.append({"name": "torpedo", "world": Vector2(-3000.0, 1200.0), "screen": tc[0]["pos"]})
	out.append(
		{"name": "route", "world": route_world, "screen": chart.world_to_screen(route_world)}
	)
	return out


func _screens(probes: Array) -> Array:
	var out: Array = []
	for pr in probes:
		out.append(pr["screen"])
	return out


# ====================================================== T30 地图 = 面板等价
func _t30_map_equals_panel(fails: Array) -> void:
	var chart = ui._chart
	var cm: CountermeasureSystem = ui.world.countermeasures
	cm.ready_rounds = 2
	cm.inventory = 4
	cm.launcher_capacity = 2
	cm.launch_cooldown_s = 0.0
	cm._cooldown_until = -1.0
	var own: TruthEntity = ui.world.world["own"]
	var own_world := Vector2(own.position_east_m, own.position_north_m)
	# 面板路径：方位 90°（正东）。
	var panel := CountermeasurePanel.new()
	panel.bind(ui.world)
	panel._spin_brg.value = 90.0
	var n0: int = ui.world.decoys.size()
	var inv0: int = cm.inventory
	panel._launch(DecoyProgram.TYPE_MOBILE)
	_assert(fails, "T30 panel launched one", ui.world.decoys.size() - n0, 1)
	_assert(fails, "T30 panel cost one round", inv0 - cm.inventory, 1)
	var d_panel = ui.world.decoys[-1]
	panel.free()
	# 菜单打开/关闭本身不消耗库存、不发射。
	var map_pt: Vector2 = own_world + Vector2(3000.0, 400.0)
	var inv1: int = cm.inventory
	var n1: int = ui.world.decoys.size()
	var idx: int = _open_emptymenu_and_find(fails, map_pt, "投放机动诱饵")
	_assert(fails, "T30 menu offers mobile decoy", idx >= 0, true)
	_assert(fails, "T30 open menu costs nothing", cm.inventory == inv1, true)
	_assert(fails, "T30 open menu launches nothing", ui.world.decoys.size() == n1, true)
	# 通过菜单条目动作真实投放（与面板同一 builder / 同一 CountermeasureSystem）。
	ui._ctx_actions._menu.id_pressed.emit(idx)
	_assert(fails, "T30 map launched one", ui.world.decoys.size() - n1, 1)
	_assert(fails, "T30 map cost one round", inv1 - cm.inventory, 1)
	if ui.world.decoys.size() <= n1:
		return
	var d_map = ui.world.decoys[-1]
	# 地图方向 = bearing_to_true(own, 菜单世界点)（菜单世界点只定义方向）。
	var offer_pt: Dictionary = DecoyLaunchBuilder.offer(
		cm, own, map_pt, float(ui.world.sim_time), true
	)
	_assert(
		fails,
		"T30 map bearing is bearing_to_true",
		absf(float(d_map.launch_bearing_deg) - float(offer_pt["bearing_deg"])) < 0.2,
		true
	)
	_assert(
		fails,
		"T30 map bearing from click east",
		absf(float(offer_pt["bearing_deg"]) - 82.4) < 1.0,
		true
	)
	# 除方向（玩家选的投放方向）外，程序字段与面板**完全等价**（同一 builder/物理）。
	_assert(fails, "T30 equivalent type", str(d_map.decoy_type), str(d_panel.decoy_type))
	_assert(
		fails,
		"T30 panel course follows its bearing",
		absf(float(d_panel.commanded_course_deg) - 90.0) < 0.2,
		true
	)
	_assert(
		fails,
		"T30 map course follows its bearing",
		absf(float(d_map.commanded_course_deg) - float(d_map.launch_bearing_deg)) < 0.2,
		true
	)
	_assert(
		fails,
		"T30 equivalent lifetime",
		absf(float(d_map.lifetime_s) - float(d_panel.lifetime_s)) < 0.01,
		true
	)
	_assert(
		fails,
		"T30 equivalent activation delay",
		absf(float(d_map.activation_delay_s) - float(d_panel.activation_delay_s)) < 0.01,
		true
	)
	_assert(
		fails,
		"T30 equivalent cruise speed",
		float(d_map.cruise_speed_kn),
		float(d_panel.cruise_speed_kn)
	)
	_assert(
		fails,
		"T30 equivalent separation",
		(
			float(d_map.separation_speed_kn) == float(d_panel.separation_speed_kn)
			and float(d_map.separation_duration_s) == float(d_panel.separation_duration_s)
		),
		true
	)
	_assert(
		fails,
		"T30 equivalent signature band",
		(
			(
				absf(
					float(d_map.signature_ac.band_min_hz) - float(d_panel.signature_ac.band_min_hz)
				)
				< 0.5
			)
			and (
				absf(
					float(d_map.signature_ac.band_max_hz) - float(d_panel.signature_ac.band_max_hz)
				)
				< 0.5
			)
		),
		true
	)
	# 离本艇过近 → "方向不明确"，不发射（不默认偷偷发射）。
	cm._cooldown_until = -1.0
	var n2: int = ui.world.decoys.size()
	var near: Vector2 = own_world + Vector2(40.0, 0.0)
	var idx_near: int = _open_emptymenu_and_find(fails, near, "投放机动诱饵")
	_assert(fails, "T30 too-close row present", idx_near >= 0, true)
	var label_near: String = ""
	if idx_near >= 0:
		label_near = ui._ctx_actions._menu.item_texts()[idx_near]
	_assert(fails, "T30 too-close reason on row", label_near.contains("方向不明确"), true)
	_assert(
		fails, "T30 too-close row disabled", ui._ctx_actions._menu.is_item_disabled(idx_near), true
	)
	ui._ctx_actions.run_action("empty_decoy_mobile", {"world_position": near})
	_assert(fails, "T30 too-close not launched", ui.world.decoys.size() == n2, true)
	_assert(fails, "T30 too-close status", ui._lbl_status.text.contains("方向不明确"), true)


# ========================================================= T31 绘制态优先级
func _t31_route_priority(fails: Array) -> void:
	var ov: MapRouteOverlay = ui._wmc.route_overlay
	# headless 下 popup_hide 不会触发：上一阶段打开过菜单后必须显式清标记，
	# 否则航线覆盖层按"菜单开着"过滤输入（与 chart_context_menu_test 同一约定）。
	ui._chart.context_menu_open = false
	ui.begin_route_draw()
	_push_left_click(Vector2(4000.0, -2500.0))
	_assert(fails, "T31 waypoint added", ov.future_point_count() >= 1, true)
	_push_right_click(Vector2(5200.0, -3200.0))
	var texts: Array = Array(ui._ctx_actions._menu.item_texts())
	_assert(fails, "T31 route commit offered", texts.has("完成航线"), true)
	_assert(fails, "T31 route cancel offered", texts.has("取消本次绘制"), true)
	var has_decoy: bool = false
	for s in texts:
		if str(s).begins_with("向此方向投放"):
			has_decoy = true
	_assert(fails, "T31 no decoy rows while drawing", has_decoy, false)
	# 完成航线：绘制态关闭、覆盖层交还输入。
	ui._ctx_actions._menu.id_pressed.emit(0)
	_assert(fails, "T31 commit closes drawing", ui._wmc.is_drawing(), false)
	# 取消：再次进入绘制态并取消。
	ui._chart.context_menu_open = false
	ui.begin_route_draw()
	_push_left_click(Vector2(4000.0, -2500.0))
	_push_right_click(Vector2(5200.0, -3200.0))
	var texts2: Array = Array(ui._ctx_actions._menu.item_texts())
	var cancel_idx: int = texts2.find("取消本次绘制")
	_assert(fails, "T31 cancel row present", cancel_idx >= 0, true)
	if cancel_idx >= 0:
		ui._ctx_actions._menu.id_pressed.emit(cancel_idx)
	_assert(fails, "T31 cancel closes drawing", ui._wmc.is_drawing(), false)


func _t31_enter_not_stolen(fails: Array) -> void:
	var ov: MapRouteOverlay = ui._wmc.route_overlay
	# 输入框持焦：Enter 属于输入框（GUI 阶段消费），航线绘制不得抢走。
	var le := LineEdit.new()
	root.add_child(le)
	await process_frame
	le.grab_focus()
	await process_frame
	var submitted: Array = []
	var finished: Array = []
	le.text_submitted.connect(func(_t: String): submitted.append(true))
	ov.finish_requested.connect(func(): finished.append(true))
	ui._chart.context_menu_open = false
	ui.begin_route_draw()
	le.text = "42"
	_push_key(ui, KEY_ENTER, true)
	_push_key(ui, KEY_ENTER, false)
	await process_frame
	_assert(fails, "T31 lineedit received enter", submitted.size() >= 1, true)
	_assert(fails, "T31 route not finished by enter", finished.size(), 0)
	# 正对照：没有输入框抢焦点时，Enter 才到达航线编辑器（说明上一断言不是
	# "Enter 到处失灵"，而是焦点确实被输入框消费）。
	le.release_focus()
	le.queue_free()
	await process_frame
	if not ui._wmc.is_drawing():
		ui.begin_route_draw()
	_push_key(ui, KEY_ENTER, true)
	_push_key(ui, KEY_ENTER, false)
	await process_frame
	_assert(fails, "T31 enter reaches route when free", finished.size(), 1)
	ui._wmc.cancel_current_edit()


# ============================================================== 输入辅助
## 真实右键打开空白菜单并返回含指定子串的条目索引（-1 = 未找到）。
func _open_emptymenu_and_find(fails: Array, w: Vector2, needle: String) -> int:
	_clear_hit_dto()
	var hits: int = _push_right_click(w)
	_assert(fails, "T30 right click reaches chart", hits, 1)
	if hits == 0:
		return -1
	var texts: Array = Array(ui._ctx_actions._menu.item_texts())
	for i in range(texts.size()):
		if str(texts[i]).contains(needle):
			return i
	return -1


## 清掉可能挡住"空白"命中的注入 DTO（不跑 _process，避免被业务刷新覆盖）。
func _clear_hit_dto() -> void:
	var chart = ui._chart
	chart.threat_snapshots = []
	chart.torpedoes = []
	chart.fit_hypotheses = []
	chart.system_active = false
	chart.trial_active = false
	chart.threat_lobs = []
	chart.contact_markers = []


func _canvas_pos(ui_node: Control, w: Vector2) -> Vector2:
	var chart = ui_node._chart
	return chart.get_global_transform_with_canvas() * chart.world_to_screen(w)


func _push_mouse(w: Vector2, button: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = _canvas_pos(ui, w)
	ev.global_position = ev.position
	ev.button_mask = (
		MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	)
	root.push_input(ev, true)


func _push_left_click(w: Vector2) -> void:
	_push_mouse(w, MOUSE_BUTTON_LEFT, true)
	_push_mouse(w, MOUSE_BUTTON_LEFT, false)


## 真实右键（按下 + 抬起）。必须成对：只发按下会让 Viewport 把 mouse_focus
## 留在 ChartView 上，后续鼠标事件全部投递给它 → 覆盖层再也收不到（假绿/假红陷阱）。
func _push_right_click(w: Vector2) -> int:
	var probe: Array = []
	var cb := func(_ctx: Dictionary): probe.append(_ctx)
	ui._chart.context_requested.connect(cb)
	_push_mouse(w, MOUSE_BUTTON_RIGHT, true)
	_push_mouse(w, MOUSE_BUTTON_RIGHT, false)
	ui._chart.context_requested.disconnect(cb)
	return probe.size()


func _push_key(node: Control, keycode: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = pressed
	node.get_viewport().push_input(ev, true)


func _assert(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s (got %s want %s)" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	for f in fails:
		print("MAP_FAIL ", f)
	if fails.is_empty():
		print("DECOY_MAP_TEST result=PASS")
	else:
		print("DECOY_MAP_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
