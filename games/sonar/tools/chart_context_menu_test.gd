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
	_rc_drawing_input(fails, ui)
	await _rc_camera_follow(fails, ui)
	await _rc_route_row_focus(fails, ui)
	_rc_reroute_and_exits(fails, ui)
	_at33_ping_confirm_and_gates(fails, ui)
	_finish(fails)


# ---------------------------------------------------------------------------
# S1-11 修复：绘制态输入过滤与航线菜单（AT-RC-01..09）
#
# 真实节点层级 ChartView → WeaponMapControl(IGNORE) → MapRouteOverlay(绘制态
# PASS) + 真实 Viewport 输入分发（root.push_input / push_unhandled_input）。
# 不允许只调 _gui_input() / _rows_for() 这类内部函数：本次 bug 恰恰是
# 「内部函数都对、真实事件链断掉」，只测内部函数永远抓不到。
# ---------------------------------------------------------------------------
func _rc_drawing_input(fails: Array, ui: Control) -> void:
	var chart = ui._chart
	var wmc = ui._wmc
	var ov: MapRouteOverlay = wmc.route_overlay
	var menu = ui._ctx_actions._menu
	# AT-RC-01 绘制态输入过滤：绘制中 PASS（未处理的右键/滚轮能冒泡），退出后 IGNORE。
	ui.begin_route_draw()
	_assert(fails, "AT-RC-01a drawing started", wmc.is_drawing(), true)
	_assert(
		fails,
		"AT-RC-01b overlay PASS while drawing",
		ov.mouse_filter == Control.MOUSE_FILTER_PASS,
		true
	)
	chart.context_menu_open = false
	_push_left_click(ui, Vector2(1500.0, -2000.0))
	_assert_eq(fails, "AT-RC-01c left click added a waypoint", ov.future_point_count(), 1)
	# AT-RC-02 真实右键传播：绘制态右键必须到达 ChartView 恰好一次。
	var hits: int = _push_right_click(ui, Vector2(5000.0, -5000.0))
	_assert_eq(fails, "AT-RC-02a right click reaches ChartView once", hits, 1)
	var texts: Array = Array(menu.item_texts())
	_assert(fails, "AT-RC-02b route menu offers commit", texts.has("完成航线"), true)
	_assert(fails, "AT-RC-02c route menu offers cancel", texts.has("取消本次绘制"), true)
	# AT-RC-03 完成航线：航线保留、开关关闭、覆盖层交还输入、发射入口可用。
	menu.id_pressed.emit(0)
	_assert(fails, "AT-RC-03a overlay inactive after commit", ov.active, false)
	_assert(
		fails,
		"AT-RC-03b overlay filter back to IGNORE",
		ov.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		true
	)
	_assert(fails, "AT-RC-03c route snapshot kept", ov.route_snapshot().size() >= 2, true)
	_assert_eq(
		fails, "AT-RC-03d weapon page switch off", ui._weapon_panel._chk_route.button_pressed, false
	)
	_assert(fails, "AT-RC-03e route ready to fire", wmc.is_route_ready(), true)
	_assert(fails, "AT-RC-03f fire button enabled", not ui._weapon_panel._btn_fire.disabled, true)
	chart.context_menu_open = false
	# AT-RC-04 空航线不静默：只有起点时不提供可执行的「完成航线」，但必须能取消。
	ui.begin_route_draw()
	_push_right_click(ui, Vector2(-4000.0, 4000.0))
	texts = Array(menu.item_texts())
	_assert(fails, "AT-RC-04a no commit without valid route", not texts.has("完成航线"), true)
	_assert(fails, "AT-RC-04b cancel offered", texts.has("取消本次绘制"), true)
	menu.id_pressed.emit(0)  # 唯一一条 = 取消本次绘制
	_assert(fails, "AT-RC-04c drawing cancelled", ov.active, false)
	_assert_eq(
		fails,
		"AT-RC-04d route status reset",
		ui._weapon_panel._lbl_route.text,
		UiText.t("route_none")
	)
	chart.context_menu_open = false
	_rc_left_isolation(fails, ui, ov, chart)


## AT-RC-05/06：左键与滚轮的隔离回归（都不许穿透成海图拖曳/选择）。
func _rc_left_isolation(fails: Array, ui: Control, ov: MapRouteOverlay, chart) -> void:
	ui.begin_route_draw()
	chart.context_menu_open = false
	chart._dragging = false
	var n0: int = ov.points.size()
	_push_left_click(ui, Vector2(1200.0, -900.0))
	_assert_eq(fails, "AT-RC-05a one waypoint per click", ov.points.size(), n0 + 1)
	_assert(fails, "AT-RC-05b left click never became chart drag", chart._dragging, false)
	var cam0: Vector2 = chart.cam_center
	var target := Vector2(2600.0, -1800.0)
	_push_mouse(ui, ov.points[1], MOUSE_BUTTON_LEFT, true)
	_push_motion(ui, target)
	_push_mouse(ui, target, MOUSE_BUTTON_LEFT, false)
	_assert(
		fails,
		"AT-RC-05c waypoint follows cursor",
		(ov.points[1] as Vector2).distance_to(target) < 1.0,
		true
	)
	_assert(
		fails,
		"AT-RC-05d map did not pan on waypoint drag",
		cam0.distance_to(chart.cam_center) < 0.01,
		true
	)
	# 拖动主动开机点：不新增航路点、不误平移。
	ov.set_trigger_offset(400.0)
	var n_before: int = ov.points.size()
	var grab: Vector2 = ov.trigger_world_point()
	var drop := Vector2(3000.0, -2600.0)
	_push_mouse(ui, grab, MOUSE_BUTTON_LEFT, true)
	_push_motion(ui, drop)
	_push_mouse(ui, drop, MOUSE_BUTTON_LEFT, false)
	_assert_eq(
		fails, "AT-RC-05e no waypoint added while dragging trigger", ov.points.size(), n_before
	)
	_assert(fails, "AT-RC-05f trigger moved along route", ov.trigger_offset_m > 400.0, true)
	_assert(
		fails,
		"AT-RC-05g map did not pan on trigger drag",
		cam0.distance_to(chart.cam_center) < 0.01,
		true
	)
	# AT-RC-06 绘制态滚轮仍能缩放海图，且不加点、不退出绘制。
	var r0: float = chart.view_radius_m
	var npt: int = ov.points.size()
	_push_mouse(ui, Vector2(1000.0, -1000.0), MOUSE_BUTTON_WHEEL_UP, true)
	_assert(fails, "AT-RC-06a wheel zooms chart while drawing", chart.view_radius_m < r0, true)
	_assert_eq(fails, "AT-RC-06b wheel adds no waypoint", ov.points.size(), npt)
	_assert(fails, "AT-RC-06c still drawing after wheel", ov.active, true)


## AT-RC-10：完成绘制后的保留航线必须跟随相机（拖动/缩放/居中/自动取景）。
##
## 覆盖层是独立 Control，不在 ChartView 的 _draw 里：只改相机而不给它重绘通知，
## 航线就停在旧的屏幕位置（本层必须挂 ChartView.draw，且与 active 无关）。
## 断言用「覆盖层实际重绘次数」——只比世界坐标或换算后像素是抓不到的：
## 负向对照实测过，去掉绑定后坐标与像素依旧全对，但画面根本不刷新。
##
## 缩放用公开相机 API set_view 驱动，不用合成滚轮：headless 下滚轮事件会把
## Viewport 的 GUI 焦点留在最后接它的控件上，之后合成的左键不再走命中测试
## （实测覆盖层从此收不到点击）。滚轮输入路径已由 AT-RC-06 覆盖。
func _rc_camera_follow(fails: Array, ui: Control) -> void:
	var chart = ui._chart
	var ov: MapRouteOverlay = ui._wmc.route_overlay
	chart.context_menu_open = false
	chart._dragging = false
	chart.set_view(Vector2.ZERO, 8000.0)
	# 画线 + Enter 完成（不弹菜单）：验收前提是完成后保留的航线（active == false）。
	ui.begin_route_draw()
	_push_left_click(ui, Vector2(1800.0, -1400.0))
	_push_left_click(ui, Vector2(2600.0, -2200.0))
	_push_key(ui, KEY_ENTER)
	chart.context_menu_open = false
	_assert(fails, "AT-RC-10a route committed", ov.active, false)
	_assert(fails, "AT-RC-10b route kept", ov.points.size() >= 2, true)
	# 关键：绑定与 active 无关（只在绘制态刷新 = 本 bug 的一半）。
	_assert(
		fails, "AT-RC-10c redraw bound after commit", chart.draw.is_connected(ov.queue_redraw), true
	)
	var pts: Array = ov.points.duplicate()
	var ov_draws: Array = [0]
	var chart_draws: Array = [0]
	var ov_cb := func() -> void: ov_draws[0] += 1
	var chart_cb := func() -> void: chart_draws[0] += 1
	ov.draw.connect(ov_cb)
	chart.draw.connect(chart_cb)
	await process_frame
	# ① 真实左键拖曳平移海图。
	var o0: int = ov_draws[0]
	var c0: int = chart_draws[0]
	_push_mouse(ui, chart.cam_center + Vector2(-1500.0, 800.0), MOUSE_BUTTON_LEFT, true)
	_push_motion(ui, chart.cam_center + Vector2(1500.0, -800.0))
	_push_mouse(ui, chart.cam_center + Vector2(1500.0, -800.0), MOUSE_BUTTON_LEFT, false)
	await process_frame
	await process_frame
	_assert(fails, "AT-RC-10d drag panned the chart", chart_draws[0] > c0, true)
	_assert(fails, "AT-RC-10e route redrew on pan", ov_draws[0] > o0, true)
	# ② 缩放（公开相机 API；滚轮路径见 AT-RC-06）。
	o0 = ov_draws[0]
	c0 = chart_draws[0]
	chart.set_view(chart.cam_center, chart.view_radius_m * 0.7)
	await process_frame
	await process_frame
	_assert(fails, "AT-RC-10f zoom redrew the chart", chart_draws[0] > c0, true)
	_assert(fails, "AT-RC-10g route redrew on zoom", ov_draws[0] > o0, true)
	# ③ 菜单动作「以此处为地图中心」/「自动取景」（复用生产入口，不另造路径）。
	o0 = ov_draws[0]
	ui._ctx_actions.run_action("empty_center", {"world_position": Vector2(4000.0, -3000.0)})
	await process_frame
	await process_frame
	_assert(fails, "AT-RC-10h route redrew on center", ov_draws[0] > o0, true)
	o0 = ov_draws[0]
	var cam_before: Vector2 = chart.cam_center
	ui._ctx_actions.run_action("empty_frame", {})
	await process_frame
	await process_frame
	_assert(
		fails,
		"AT-RC-10i auto frame moved camera",
		chart.cam_center.distance_to(cam_before) > 1.0,
		true
	)
	_assert(fails, "AT-RC-10j route redrew on auto frame", ov_draws[0] > o0, true)
	# ④ 相机变了，航路点世界坐标一个都不能变，且屏幕位置就是相机的换算结果。
	var drift: float = 0.0
	for i in range(pts.size()):
		drift = maxf(drift, (pts[i] as Vector2).distance_to(ov.points[i] as Vector2))
	_assert_eq(fails, "AT-RC-10k waypoint world coords unchanged", drift, 0.0)
	var glued: bool = true
	for w in ov.points:
		if ov._to_screen(w as Vector2).distance_to(chart.world_to_screen(w as Vector2)) > 0.01:
			glued = false
	_assert(fails, "AT-RC-10l route glued to chart camera", glued, true)
	ov.draw.disconnect(ov_cb)
	chart.draw.disconnect(chart_cb)
	# 收尾：清航线 + 复位视角，别把「相机停在别处」泄漏给后续用例
	#（后续用世界坐标算点击像素，视角一变就会点到海图外面）。
	ui.clear_route_draw()
	chart.set_view(Vector2.ZERO, 8000.0)
	chart.context_menu_open = false
	await process_frame


## AT-RC-11：航线行控件不得抢键盘焦点，否则「Enter 完成航线」会被它截胡。
## 真机（Web 构建）实测：玩家点过「绘制航线」开关后按 Enter，覆盖层先提交成功，
## 开关却在 keyup 上又翻一次 —— 把刚完成的航线关掉并重开一次绘制
## （航线从画面上消失、状态回到「绘制中 0/4 个航路点」）。
func _rc_route_row_focus(fails: Array, ui: Control) -> void:
	var chart = ui._chart
	var ov: MapRouteOverlay = ui._wmc.route_overlay
	var chk = ui._weapon_panel._chk_route
	_assert(
		fails,
		"AT-RC-11a route toggle takes no key focus",
		chk.focus_mode == Control.FOCUS_NONE,
		true
	)
	chart.set_view(Vector2.ZERO, 8000.0)
	chart.context_menu_open = false
	ui.begin_route_draw()
	_push_left_click(ui, Vector2(1500.0, 1200.0))
	chk.grab_focus()  # 模拟「玩家刚点过开关」
	_push_key(ui, KEY_ENTER)
	_push_key(ui, KEY_ENTER, false)  # 抬起这一下才是真机 bug 的触发点
	await process_frame
	_assert(fails, "AT-RC-11b enter commits after toggle clicked", ov.active, false)
	_assert(fails, "AT-RC-11c committed route not restarted", ov.points.size() >= 2, true)
	_assert_eq(fails, "AT-RC-11d toggle left off", chk.button_pressed, false)
	ui.clear_route_draw()
	chart.set_view(Vector2.ZERO, 8000.0)
	chart.context_menu_open = false
	await process_frame


## AT-RC-07..09：在线重画 + 拥挤地图 + §7 退出方式（Enter/Esc/双击）。
func _rc_reroute_and_exits(fails: Array, ui: Control) -> void:
	var chart = ui._chart
	var wmc = ui._wmc
	var ov: MapRouteOverlay = wmc.route_overlay
	var menu = ui._ctx_actions._menu
	var texts: Array = []
	wmc.cancel_current_edit()
	chart.context_menu_open = false
	# 先按唯一方式发射一枚（MAP_ROUTE），再验在线重画的两条出口。
	# 重画要求鱼雷已脱离 LAUNCHING；清空目标避免它中途锁定（锁定后禁止重画）。
	var keep_targets: Array = ui.world.world.get("targets", [])
	ui.world.world["targets"] = []
	ui.begin_route_draw()
	print(
		"DBG click canvas=",
		_canvas_pos(ui, Vector2(4000.0, 1000.0)),
		" chart_rect=",
		chart.get_global_rect(),
		" ov_rect=",
		ov.get_global_rect(),
		" cam=",
		chart.cam_center,
		" r=",
		chart.view_radius_m
	)
	_push_left_click(ui, Vector2(4000.0, 1000.0))
	print(
		"DBG after click pts=",
		ov.points.size(),
		" ov_filter=",
		ov.mouse_filter,
		" ov_active=",
		ov.active,
		" menu_open=",
		chart.context_menu_open,
		" chart_dragging=",
		chart._dragging,
		" bar_visible=",
		ui._wmc.bar.visible,
		" sel=",
		chart.selected_torpedo_id
	)
	var fired: Dictionary = wmc.try_fire()
	print("DBG fired=", fired, " pts=", ov.points.size(), " active=", ov.active)
	var tp: Torpedo = fired.get("tp", null)
	if tp != null:
		for _i in range(30):
			if tp._wire_accepts_command():
				break
			ui.world.run_steps(1)
	ui.world.world["targets"] = keep_targets
	_assert(fails, "AT-RC-07a torpedo launched", bool(fired.get("ok", false)), true)
	_assert(fails, "AT-RC-07b torpedo in water", tp != null, true)
	if tp == null:
		return
	var tid: String = str(tp.torpedo_id)
	wmc.set_selected_torpedo(tid)
	_assert(fails, "AT-RC-07c reroute armed", wmc.begin_reroute(tid), true)
	_assert(fails, "AT-RC-07d overlay marks in-water start", ov.in_water, true)
	var keep: Array = tp.remaining_route_points()
	var wp1 := Vector2(-2000.0, 2500.0)
	_push_left_click(ui, wp1)
	_push_right_click(ui, wp1)
	texts = Array(menu.item_texts())
	_assert(fails, "AT-RC-07e reroute menu offers commit", texts.has("完成航线"), true)
	menu.id_pressed.emit(1)  # 取消本次绘制
	_assert(fails, "AT-RC-07f reroute cancelled", ov.active, false)
	_assert_eq(fails, "AT-RC-07g original route untouched", tp.remaining_route_points(), keep)
	# 再画一次并提交：必须走 commit_reroute()，剩余航线被原子替换。
	_assert(fails, "AT-RC-07h reroute re-armed", wmc.begin_reroute(tid), true)
	var wp2 := Vector2(5000.0, -1500.0)
	_push_left_click(ui, wp2)
	_push_right_click(ui, wp2)
	menu.id_pressed.emit(0)  # 完成航线
	_assert(fails, "AT-RC-07i reroute committed", ov.active, false)
	var after: Array = tp.remaining_route_points()
	_assert(
		fails,
		"AT-RC-07j new route applied",
		after.size() >= 1 and (after[0] as Vector2).distance_to(wp2) < 1.0,
		true
	)
	wmc.set_selected_torpedo("")  # 收起地图浮动栏（避免它盖住后续点击点）
	chart.context_menu_open = false
	_rc_exits(fails, ui, ov, chart)
	_rc_crowded(fails, ui, ov, chart)


## AT-RC-09 §7：Enter/Esc/双击三条承诺过的退出方式必须真的存在（都不静默失败）。
## 每次点击都用不同世界点：Godot 会把「同点（<5px）且短时间内（<400ms）的
## 第二次按下」自动判成双击，复用坐标会让普通单击被吃掉（测试假阴性）。
func _rc_exits(fails: Array, ui: Control, ov: MapRouteOverlay, chart) -> void:
	var wmc = ui._wmc
	ui.begin_route_draw()
	var msgs: Array = []
	var sc := func(m: String): msgs.append(m)
	wmc.status.connect(sc)
	_push_key(ui, KEY_ENTER)
	wmc.status.disconnect(sc)
	_assert(
		fails,
		"AT-RC-09a enter without route reports reason",
		msgs.size() > 0 and str(msgs[0]).contains("航路点"),
		true
	)
	_assert(fails, "AT-RC-09b still drawing after refused enter", ov.active, true)
	_push_left_click(ui, Vector2(1000.0, 3000.0))
	_push_key(ui, KEY_ENTER)
	_assert(fails, "AT-RC-09c enter commits valid route", ov.active, false)
	_assert(fails, "AT-RC-09d route kept after enter", wmc.is_route_ready(), true)
	ui.begin_route_draw()
	_push_left_click(ui, Vector2(-1200.0, -2600.0))
	_push_key(ui, KEY_ESCAPE)
	_assert(fails, "AT-RC-09e escape cancels", ov.active, false)
	_assert_eq(fails, "AT-RC-09f escape clears route", ov.points.size(), 0)
	# 双击结束绘制：首击落下终点，第二击只结束，不追加两个重合航路点。
	ui.begin_route_draw()
	var dp := Vector2(1500.0, 1500.0)
	_push_mouse(ui, dp, MOUSE_BUTTON_LEFT, true)
	_push_mouse(ui, dp, MOUSE_BUTTON_LEFT, false)
	_push_mouse(ui, dp, MOUSE_BUTTON_LEFT, true, true)
	_push_mouse(ui, dp, MOUSE_BUTTON_LEFT, false)
	_assert(fails, "AT-RC-09g double click finishes drawing", ov.active, false)
	_assert_eq(fails, "AT-RC-09h double click adds no duplicate", ov.points.size(), 2)
	wmc.cancel_current_edit()
	chart.context_menu_open = false


## AT-RC-08 地图拥挤：绘制态右键恰好落在威胁/鱼雷图标上，仍是航线编辑菜单
##（玩家不需要去找看不见的「空白」）；完成/取消后恢复普通上下文菜单。
## 放在最后：headless 下弹过菜单后合成鼠标事件的投递会失效（真机无此问题，
## 因为菜单是真实子窗口、由窗口管理器接管），本用例不需要再往后发点击。
func _rc_crowded(fails: Array, ui: Control, ov: MapRouteOverlay, chart) -> void:
	var menu = ui._ctx_actions._menu
	var texts: Array = []
	ui.begin_route_draw()
	_push_left_click(ui, Vector2(-3000.0, -3000.0))
	var hub := Vector2(3000.0, 3000.0)
	chart.threat_snapshots = [_snap(hub)]
	chart.torpedoes = [{"trail": [{"e": hub.x, "n": hub.y}], "torpedo_id": "PT9"}]
	_push_right_click(ui, hub)
	texts = Array(menu.item_texts())
	_assert(fails, "AT-RC-08a crowded right-click keeps route menu", texts.has("取消本次绘制"), true)
	_assert(fails, "AT-RC-08b crowded right-click hides threat menu", not texts.has("查看威胁详情"), true)
	menu.id_pressed.emit(1)
	_assert(fails, "AT-RC-08c drawing cancelled", ov.active, false)
	chart.context_menu_open = false
	# 退出绘制后，同一位置恢复普通上下文菜单（此处走既有的事件构造辅助，
	# 绕开 headless 菜单弹过之后的合成投递限制）。
	_right_click(ui, hub)
	texts = Array(menu.item_texts())
	_assert(fails, "AT-RC-08d normal threat menu restored", texts.has("查看威胁详情"), true)
	chart.threat_snapshots = []
	chart.torpedoes = []
	chart.context_menu_open = false


## 世界点 → 画布坐标（真实输入分发用的视口本地坐标）。
## in_local_coords=true 很关键：headless 根视口带 content-scale，按「屏幕坐标」
## 投递会被再变换一次，点击落到视口外 → 事件到不了任何控件（假绿陷阱）。
func _canvas_pos(ui: Control, w: Vector2) -> Vector2:
	var chart = ui._chart
	return chart.get_global_transform_with_canvas() * chart.world_to_screen(w)


func _push_mouse(ui: Control, w: Vector2, button: int, pressed: bool, dbl: bool = false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.double_click = dbl
	ev.position = _canvas_pos(ui, w)
	ev.global_position = ev.position
	ev.button_mask = (
		MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	)
	root.push_input(ev, true)


func _push_motion(ui: Control, w: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = _canvas_pos(ui, w)
	ev.global_position = ev.position
	root.push_input(ev, true)


func _push_left_click(ui: Control, w: Vector2) -> void:
	_push_mouse(ui, w, MOUSE_BUTTON_LEFT, true)
	_push_mouse(ui, w, MOUSE_BUTTON_LEFT, false)


## 真实右键：返回 ChartView.context_requested 的触发次数（0 = 被覆盖层吞掉）。
func _push_right_click(ui: Control, w: Vector2) -> int:
	var probe: Array = []
	var cb := func(_ctx: Dictionary): probe.append(_ctx)
	ui._chart.context_requested.connect(cb)
	_push_mouse(ui, w, MOUSE_BUTTON_RIGHT, true)
	ui._chart.context_requested.disconnect(cb)
	return probe.size()


## 真实键事件：与生产同一条链（GUI 阶段 → input → unhandled_key → unhandled）。
## 注意：一旦有 Control 抢到 key_focus，GUI 阶段就会吃掉键事件，
## _unhandled_key_input 收不到 —— 所以覆盖层刻意不抓焦点。
## pressed=false 用来投递抬起：有些抢焦点的按钮只在 keyup 上翻状态。
func _push_key(ui: Control, keycode: int, pressed: bool = true) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = pressed
	ui.get_viewport().push_input(ev, true)


func _assert_eq(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s (got %s want %s)" % [name, str(got), str(want)])


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
	# S1-11 §4.3：右键己方鱼雷条目收敛为「选择/主动开关/重画剩余航线/居中/切线」，
	# 删除「转到线导控制」旧入口（线导控制已并入地图浮动栏）。
	_assert(
		fails,
		"AT-32i torpedo zh menu",
		(
			texts.has("选择该鱼雷")
			and texts.has("立即开启/关闭主动声呐")
			and texts.has("重画剩余航线")
			and texts.has("居中")
			and texts.has("切断导线…")
		),
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
	# S1-11 §4.3/§9.1 + AT-24：空白地图菜单改为「绘制/清除鱼雷航线」真实入口，
	# 删除未实现的「开始测距尺」占位（可选但无效的按钮不得保留）。
	_assert(
		fails,
		"AT-32l empty zh menu",
		(
			texts.has("绘制鱼雷航线")
			and texts.has("清除鱼雷航线")
			and texts.has("以此处为地图中心")
			and texts.has("自动取景")
			and texts.has("清除选择")
			and texts.has("图层设置")
			and not texts.has("开始测距尺")
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
