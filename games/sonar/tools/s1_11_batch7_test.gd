extends SceneTree
## s1_11_batch7_test.gd — S1-11 Batch 7：全中文收口 / 人机工效 / 终局与全链 E2E。
##
##   B7-39 (AT-39) 敌雷有效命中本艇 → mission_ended 恰好一次 + 冻结 + 失败（回归）；
##   B7-40 (AT-40) 玩家鱼雷有效命中任务目标 → 恰好一次 + 胜利（Batch 6 回归）；
##   B7-41 (AT-41) 终局后发射 / Ping / 诱饵 / 航线修改 / 主动开关 / 切线全部 MISSION_ENDED；
##   B7-42 (AT-42) 全部可见控件 / 菜单 / 状态文本中文（无裸英文 token）+ 文案目录无缺键；
##   B7-43 (AT-43) 1280×720：右栏无水平滚动；浮动栏 / 航线层不越界、不遮告警条；
##   B7-44 (AT-44) 触摸命中区放大；拖动航路点 / 开机标记不落到海图（不误平移）；
##   B7-45 (AT-45) 全链：画线 → 发射 → 选雷 → 设开机点 → 捕获 → 脱锁 → 重画 → 命中终局。

const SEED: int = 20260910
## 玩家文案中允许保留的技术缩写 / 单位（D-09 只禁止裸状态 token，如 WIRE_ONLY/TRACKING）。
const ALLOWED: Array = [
	"TMA",
	"DEMON",
	"LOFAR",
	"LOB",
	"BT",
	"SE",
	"kHz",
	"dB",
	"km",
	"Hz",
	"Mark",
	"Ping",
	"TK",
]
## 旧英文 UI 残留黑名单（自然语言，绝不允许出现在控件 / 菜单文本）。
const BLACKLIST: Array = [
	"Towed",
	"AGC ",
	"GRAYSCALE",
	"AMBER",
	"Left 5",
	"Right 5",
	"ACT ",
	"MERCHANT",
	"WARNOTHINGSHIP",
	"SUBSONAR",
	"Solution",
	"JAMMER",
	"Pause",
	"Resume",
	"Tubes",
	"Own Ship",
	"Selected",
	"Camera",
	"Layers",
	"Reset View",
	"Auto Frame",
	"Fit Details",
	"Weapon Alerts",
	"Mark Groups",
	"Auto Fit",
	"bias",
	"WIRE_ONLY",
	"REJECTED",
	"TRACKING",
	"STOWED",
	"age=",
	"pred=",
	"extrapolated",
	"Uncertainty",
]

var fails: Array = []


class FakeUI:
	var selected_track_id: String = ""
	var world: World = null


func _init() -> void:
	await _run()
	if fails.is_empty():
		print("S1-11 BATCH7 TEST PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % str(f))
	print("S1-11 BATCH7 TEST FAIL (%d)" % fails.size())
	quit(1)


func _run() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	for i in range(6):
		ui._process(0.5)
	_b7_42_all_chinese(ui)
	_b7_46_event_kinds_localized(fails)
	_b7_43_layout(ui)
	_b7_44_touch()
	_b7_41_endgame_gate()
	_b7_39_exactly_once()
	_b7_40_victory_once()
	_b7_45_full_chain()
	ui.free()


# ---------------- B7-42：全中文收口（AT-42） ----------------
func _b7_42_all_chinese(ui: Control) -> void:
	var texts: Array = []
	_collect_texts(ui, texts)
	_assert(fails, "B7-42a collected ui texts", texts.size() > 30, true)
	var rx := RegEx.new()
	rx.compile("[A-Za-z]{2,}")
	var all: Array = []
	var bad: Array = []
	for t in texts:
		_scan_text(str(t), rx, all, bad)
	var menu := ChartContextMenu.new()
	for kind in ["OWN_TORPEDO", "CONTACT", "THREAT", "EMPTY"]:
		menu.open_at(
			Vector2.ZERO, {"hit_kind": kind, "selected_torpedo_id": "TK01", "route_drawing": true}
		)
		for t in menu.item_texts():
			_scan_text(str(t), rx, all, bad)
	menu.free()
	if not bad.is_empty():
		fails.append("B7-42b bare english token: %s" % str(bad.slice(0, mini(6, bad.size()))))
	else:
		print("  [ok] B7-42b no bare english token")
	_assert(fails, "B7-42b2 no residue", bad.is_empty(), true)
	var joined: String = "\n".join(PackedStringArray(all))
	for want in ["声呐", "战术", "武器", "本艇", "任务失败", "拖曳阵", "自动增益", "主动声呐"]:
		_assert(fails, "B7-42c chinese key %s" % want, joined.contains(want), true)
	_assert(
		fails,
		"B7-42d no missing catalog keys %s" % str(UiText.missing_keys),
		UiText.missing_keys.is_empty(),
		true
	)


func _scan_text(s: String, rx: RegEx, all: Array, bad: Array) -> void:
	if s == "":
		return
	all.append(s)
	for b in BLACKLIST:
		if s.contains(str(b)):
			bad.append("残留[%s]@[%s]" % [str(b), s])
	for m in rx.search_all(s):
		var w: String = m.get_string()
		if not ALLOWED.has(w):
			bad.append("英文词[%s]@[%s]" % [w, s])


func _collect_texts(node: Node, out: Array) -> void:
	if node is Label or node is Button or node is CheckBox or node is CheckButton:
		out.append(str((node as Control).get("text")))
		var tip: String = str((node as Control).tooltip_text)
		if tip != "":
			out.append(tip)
	elif node is OptionButton:
		var ob := node as OptionButton
		for i in range(ob.item_count):
			out.append(ob.get_item_text(i))
	elif node is PopupMenu:
		var pm := node as PopupMenu
		for i in range(pm.item_count):
			out.append(pm.get_item_text(i))
	for c in node.get_children():
		_collect_texts(c, out)


# ---------------- B7-43：1280×720 人机工效（AT-43） ----------------
func _b7_43_layout(ui: Control) -> void:
	var pager: RightSidebarPager = ui._pager
	_assert(
		fails,
		"B7-43a pager width in contract (%.0f)" % pager.size.x,
		pager.size.x >= UiContract.SIDEBAR_MIN_W and pager.size.x <= UiContract.SIDEBAR_MAX_W + 1.0,
		true
	)
	for pid in pager.page_ids():
		var sc: ScrollContainer = pager.page_scroll(pid)
		_assert(
			fails,
			"B7-43b no h-scroll %s" % str(pid),
			sc.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
			true
		)
		_assert(fails, "B7-43c h-bar hidden %s" % str(pid), sc.get_h_scroll_bar().visible, false)
	var chart: ChartView = ui._chart
	var row: Control = pager.get_parent()
	var span: float = chart.size.x + pager.size.x
	_assert(
		fails,
		"B7-43d chart+sidebar fits window (span=%.0f row=%.0f)" % [span, row.size.x],
		span <= float(row.size.x) + 2.0,
		true
	)
	# 选中一枚鱼雷 → 浮动栏出现在海图内，且不与右栏告警列交叠。
	var w: World = ui.world
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	ui._on_map_torpedo_selected(str(tp.torpedo_id))
	ui._process(0.5)
	var bar: TorpedoControlBar = ui._wmc.bar
	_assert(fails, "B7-43e bar visible", bar.visible, true)
	var bar_r := Rect2(bar.global_position, bar.size)
	var ch_r := Rect2(chart.global_position, chart.size)
	var inside: bool = (
		bar_r.position.x >= ch_r.position.x - 1.0
		and bar_r.end.x <= ch_r.end.x + 1.0
		and bar_r.position.y >= ch_r.position.y - 1.0
		and bar_r.end.y <= ch_r.end.y + 1.0
	)
	_assert(fails, "B7-43f bar inside chart %s" % str(bar_r), inside, true)
	_assert(
		fails,
		(
			"B7-43g bar clear of alert column (bar_end=%.1f chart_end=%.1f)"
			% [bar_r.end.x, ch_r.end.x]
		),
		bar_r.end.x <= ch_r.end.x + 1.0,
		true
	)
	var ov: MapRouteOverlay = ui._wmc.route_overlay
	_assert(
		fails,
		"B7-43h overlay within chart %s" % str(ov.size),
		ov.size.x <= chart.size.x + 1.0 and ov.size.y <= chart.size.y + 1.0,
		true
	)
	_b7_43_coord_mapping(chart, ov)


# ---------------- B7-43i/j：地图坐标换算（布局级，AT-24/AT-44 回归） ----------------
## 只比世界坐标抓不到这个 bug：航线数据一直是正确的，错的是覆盖层把
## 「海图在 UI 里的布局偏移」当成海图内部像素参与换算。因此这里一律比
## **最终画布像素**：地图点击 → 世界坐标、航线起点 → 本艇图标像素。
func _b7_43_coord_mapping(chart: ChartView, ov: MapRouteOverlay) -> void:
	var probe_world: Vector2 = chart.own_pos + Vector2(1375.0, -825.0)
	var probe_canvas: Vector2 = (
		chart.get_global_transform_with_canvas() * chart.world_to_screen(probe_world)
	)
	var probe_overlay_local: Vector2 = (
		ov.get_global_transform_with_canvas().affine_inverse() * probe_canvas
	)
	_assert(
		fails,
		"B7-43i route click maps to chart world position",
		ov._to_world(probe_overlay_local).distance_to(probe_world) <= 0.01,
		true
	)
	ov.begin(chart.own_pos.x, chart.own_pos.y)
	var route_start_canvas: Vector2 = (
		ov.get_global_transform_with_canvas() * ov._to_screen(ov.points[0])
	)
	var own_canvas: Vector2 = (
		chart.get_global_transform_with_canvas() * chart.world_to_screen(chart.own_pos)
	)
	_assert(
		fails,
		"B7-43j route start overlaps own ship",
		route_start_canvas.distance_to(own_canvas) <= 0.01,
		true
	)
	ov.cancel()


# ---------------- B7-44：触摸命中区与拖动（AT-44） ----------------
func _b7_44_touch() -> void:
	_assert(
		fails,
		"B7-44a touch hit radius >= 22px (%.0f)" % UiContract.TOUCH_HIT_PX,
		UiContract.TOUCH_HIT_PX >= 22.0,
		true
	)
	_assert(
		fails,
		"B7-44b route marker radius switches",
		MapRouteOverlay.hit_px(true) > MapRouteOverlay.hit_px(false),
		true
	)
	var chart := ChartView.new()
	root.add_child(chart)
	chart.size = Vector2(800.0, 600.0)
	chart.view_radius_m = 10000.0
	chart.cam_center = Vector2.ZERO
	chart.torpedoes = [{"trail": [{"e": 0.0, "n": 0.0}], "torpedo_id": "TK01"}]
	var head: Vector2 = chart.world_to_screen(Vector2.ZERO)
	var near := head + Vector2(18.0, 0.0)
	_assert(
		fails,
		"B7-44c mouse radius misses at 18px",
		str(ChartHitTest.pick(chart, near).get("hit_kind", "")),
		"EMPTY"
	)
	_assert(
		fails,
		"B7-44d touch radius hits torpedo at 18px",
		str(ChartHitTest.pick(chart, near, true).get("hit_kind", "")),
		"OWN_TORPEDO"
	)
	# 航路点拖动：命中已有航路点 → 拖动改位；命中起点（index 0）不拖动。
	var ov := MapRouteOverlay.new()
	ov.chart = chart
	root.add_child(ov)
	ov.position = Vector2.ZERO
	ov.begin(0.0, 0.0)
	ov.add_point(0.0, 1000.0)
	var wp_local: Vector2 = chart.world_to_screen(Vector2(0.0, 1000.0))
	_assert(fails, "B7-44e waypoint hit index", ov.waypoint_hit_index(wp_local, 14.0), 1)
	_assert(
		fails,
		"B7-44f start point not draggable",
		ov.waypoint_hit_index(chart.world_to_screen(Vector2.ZERO), 14.0) < 1,
		true
	)
	_press(ov, wp_local)
	_assert(fails, "B7-44g waypoint drag engaged", ov._drag_waypoint, 1)
	var before: Vector2 = ov.points[1]
	var cam_before: Vector2 = chart.cam_center
	_motion(ov, wp_local + Vector2(0.0, -60.0))
	_assert(fails, "B7-44h waypoint moved", ov.points[1] != before, true)
	_assert(fails, "B7-44i map did not pan", chart.cam_center == cam_before, true)
	_release(ov, wp_local)
	# 开机标记：触摸半径下 18px 也可抓住（不误落点）。
	ov.set_trigger_offset(1000.0)
	var mk_local: Vector2 = ov._to_screen(ov.trigger_world_point()) + Vector2(18.0, 0.0)
	var tcount: int = ov.points.size()
	UiContract.set_touch_override(true)
	_press(ov, mk_local)
	_assert(fails, "B7-44j trigger drag engaged (touch)", ov._dragging_trigger, true)
	_assert(fails, "B7-44k no stray waypoint added", ov.points.size(), tcount)
	_release(ov, mk_local)
	UiContract.set_touch_override(null)
	ov.free()
	chart.free()


func _press(ov: MapRouteOverlay, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	ov._gui_input(ev)


func _release(ov: MapRouteOverlay, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = pos
	ov._gui_input(ev)


func _motion(ov: MapRouteOverlay, pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ov._gui_input(ev)


# ---------------- B7-41：终局命令门（AT-41） ----------------
func _b7_41_endgame_gate() -> void:
	var w := _mk_world()
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	var fe := FireExecutor.new()
	fe.programmer = LaunchProgrammer.new()
	_assert(fails, "B7-41a mission running", w.command_reject_reason(), "")
	_assert(
		fails,
		"B7-41b end mission",
		w.end_mission(w.MissionState.PLAYER_DEFEATED, "TORPEDO_HIT"),
		true
	)
	_assert(fails, "B7-41c gate reason", w.command_reject_reason(), "MISSION_ENDED")
	var fire_res: Dictionary = fe.execute(w.weapons, w, "MAP_ROUTE", "")
	_assert(fails, "B7-41d fire rejected", str(fire_res.get("reason", "")), "MISSION_ENDED")
	_assert(fails, "B7-41e ping rejected", w.issue_ping(), false)
	_assert(fails, "B7-41f decoy rejected", w._launch_decoy(null), false)
	_assert(fails, "B7-41g decoy reason", w.last_decoy_reject_reason, "MISSION_ENDED")
	_assert(fails, "B7-41h active switch rejected", tp.set_active_tx(true), false)
	_assert(fails, "B7-41i active reason", tp.last_cmd_reject_reason, "MISSION_ENDED")
	_assert(fails, "B7-41j cut wire rejected", tp.cut_wire(), false)
	_assert(fails, "B7-41k cut reason", tp.last_cmd_reject_reason, "MISSION_ENDED")
	var state := TorpedoRouteState.new()
	state.replace_from(Vector2.ZERO, [Vector2(0.0, 500.0)])
	_assert(fails, "B7-41l reroute rejected", tp.update_route(state), false)
	_assert(fails, "B7-41m reroute reason", tp.last_cmd_reject_reason, "MISSION_ENDED")
	_assert(fails, "B7-41n trigger rejected", tp.command_active_trigger_distance(100.0), false)
	_assert(fails, "B7-41o depth policy rejected", tp.command_depth_policy("UPPER"), false)
	_assert(fails, "B7-41p course rejected", tp.command_course(90.0), false)
	_assert(fails, "B7-41q second end rejected", w.end_mission(2, "OVERWRITE"), false)


# ---------------- B7-39：敌雷命中恰好一次（AT-39 回归） ----------------
func _b7_39_exactly_once() -> void:
	var w := _mk_world()
	var ends: Array = []
	w.mission_ended.connect(func(r: Dictionary): ends.append(r))
	# 两枚敌雷同 tick 命中本艇：只允许一次终局，首个原因不被覆盖。
	_assert(
		fails,
		"B7-39a first end",
		w.end_mission(w.MissionState.PLAYER_DEFEATED, "TORPEDO_HIT"),
		true
	)
	_assert(
		fails,
		"B7-39b dup end rejected",
		w.end_mission(w.MissionState.PLAYER_DEFEATED, "OTHER"),
		false
	)
	_assert(fails, "B7-39c exactly once", ends.size(), 1)
	_assert(fails, "B7-39d failure state", w.mission_state_name(), "PLAYER_DEFEATED")
	_assert(fails, "B7-39e reason kept", w.mission_end_reason, "TORPEDO_HIT")
	_assert(fails, "B7-39f end time frozen", w.mission_end_time <= w.sim_time, true)


# ---------------- B7-40：玩家命中任务目标恰好一次（AT-40 回归） ----------------
func _b7_40_victory_once() -> void:
	var w := _mk_world()
	var tgt := TruthEntity.new()
	tgt.id = "mission_target"
	tgt.side = "red"
	tgt.platform_type = "submarine"
	tgt.position_east_m = 0.0
	tgt.position_north_m = 900.0
	tgt.depth_m = 70.0
	tgt.speed_kn = 0.0
	w.world["targets"].append(tgt)
	w._weapon_contacts.append(tgt)
	w.world["target_acs"][tgt.id] = AcousticProfile.new()
	var ends: Array = []
	w.mission_ended.connect(func(r: Dictionary): ends.append(r))
	var prog := WeaponProgram.make_manual(0.0)
	prog.speed_mode = WeaponProgram.SpeedMode.HIGH
	prog.warhead_arm_distance_m = 50.0
	var tp: Torpedo = w.weapons.fire_program(prog, 0.0, 0.0, 0.0, 70.0)
	_assert(fails, "B7-40a launched", tp != null, true)
	if tp == null:
		return
	for i in range(400):
		w.run_steps(1)
		if not w.is_mission_running():
			break
	_assert(fails, "B7-40b exactly once", ends.size(), 1)
	_assert(fails, "B7-40c victory", w.mission_state_name(), "PLAYER_VICTORY")
	_assert(fails, "B7-40d reason", w.mission_end_reason, "TARGET_DESTROYED")


# ---------------- B7-45：全链 E2E（AT-45，headless 部分） ----------------
func _b7_45_full_chain() -> void:
	var w := _mk_world()
	var tgt := TruthEntity.new()
	tgt.id = "chain_target"
	tgt.side = "red"
	tgt.platform_type = "submarine"
	tgt.position_east_m = 0.0
	tgt.position_north_m = 1500.0
	tgt.depth_m = 70.0
	tgt.speed_kn = 0.0
	w.world["targets"].append(tgt)
	w._weapon_contacts.append(tgt)
	w.world["target_acs"][tgt.id] = AcousticProfile.new()
	var wmc := _mk_map(w)
	var prog: LaunchProgrammer = wmc.fire_exec.programmer
	prog.speed_mode = WeaponProgram.SpeedMode.HIGH
	prog.warhead_arm_distance_m = 50.0
	# 1) 画线（起点吸附本艇实测位置）。
	wmc.begin_draw()
	wmc.route_overlay.add_point(0.0, 3000.0)
	_assert(fails, "B7-45a route ready", wmc.is_route_ready(), true)
	# 2) 设开机点（沿航线累计距离，发射前写入程序）。
	wmc.route_overlay.set_trigger_offset(600.0)
	_assert(fails, "B7-45b trigger recorded", wmc.prelaunch_trigger_offset_m, 600.0)
	wmc.finish_draw()
	var fire_res: Dictionary = wmc.try_fire()
	_assert(fails, "B7-45c fired via map route", bool(fire_res.get("ok", false)), true)
	if not bool(fire_res.get("ok", false)):
		return
	var tp: Torpedo = fire_res["tp"]
	_assert(fails, "B7-45d route programmed", tp.route.points.size() >= 2, true)
	_assert(fails, "B7-45e autonomous authority", tp.guidance_authority_name(), "AUTONOMOUS")
	w.run_steps(4)
	# 3) 选雷 → 浮动栏出现。
	wmc.set_selected_torpedo(str(tp.torpedo_id))
	_assert(fails, "B7-45f bar visible", wmc.bar.visible, true)
	# 4) 捕获 → 自动锁定。
	_drive(tp, 8, 1.0, 0.0, 22.0)
	_assert(fails, "B7-45g auto locked", tp.mission_state_name(), "LOCKED_ATTACK")
	# 5) 脱锁：确认 LOST → LOST_REACQUIRE（围绕最后估计方位重搜）。
	tp._seeker.phase = TorpedoSeeker.Phase.LOST
	tp._advance_lock_state()
	_assert(fails, "B7-45h lost reacquire", tp.mission_state_name(), "LOST_REACQUIRE")
	# 6) 重画航线 → 回 TRANSIT（继续监听）。
	_assert(fails, "B7-45i reroute started", wmc.begin_reroute(str(tp.torpedo_id)), true)
	wmc.route_overlay.add_point(0.0, 5000.0)
	_assert(fails, "B7-45j reroute committed", wmc.commit_reroute(), true)
	_assert(fails, "B7-45k back to transit", tp.mission_state_name(), "TRANSIT")
	# 7) 命中终局：清掉注入的回波（无候选 → 不再操舵），弹沿航线直行命中任务目标。
	tp._seeker.tracks.clear()
	tp._seeker.phase = TorpedoSeeker.Phase.SEARCH
	var ends: Array = []
	w.mission_ended.connect(func(r: Dictionary): ends.append(r))
	for i in range(600):
		w.run_steps(1)
		if not w.is_mission_running():
			break
	_assert(fails, "B7-45l mission ended", w.is_mission_running(), false)
	_assert(fails, "B7-45m ended exactly once", ends.size(), 1)
	_assert(fails, "B7-45n victory", w.mission_state_name(), "PLAYER_VICTORY")


# ---------------- 公共构造 ----------------
func _b7_46_event_kinds_localized(fails: Array) -> void:
	# AT-42：武器页事件流按 kind 直显；任何 Emit 出去的 kind 都必须有中文词条，
	# 否则真实运行时（发射后才出现的航渡/捕获/锁定等行）会漏英文（真机回归发现）。
	var files: Array = []
	_gd_files("res://scripts", files)
	var kinds: Dictionary = {}
	var rx_emit := RegEx.new()
	rx_emit.compile('event_occurred\\.emit\\(\\s*[^,]+,\\s*"([^"]+)"')
	var rx_mission := RegEx.new()
	rx_mission.compile('_try_mission\\([^,]+,\\s*"([^"]+)"')
	for p in files:
		var src: String = _read(p)
		for m in rx_emit.search_all(src):
			kinds[m.get_string(1)] = true
		for m in rx_mission.search_all(src):
			kinds[m.get_string(1)] = true
	var bad: Array = []
	for k in kinds:
		if UiText.event(str(k)) == str(k):
			bad.append(k)
	bad.sort()
	_assert(fails, "B7-46 all emitted event kinds localized %s" % str(bad), bad.is_empty(), true)


func _gd_files(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		var p: String = dir.path_join(n)
		if d.current_is_dir():
			if not n.begins_with("."):
				_gd_files(p, out)
		elif n.ends_with(".gd"):
			out.append(p)
		n = d.get_next()
	d.list_dir_end()


func _read(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	var w := World.new()
	w.load_scenario(sc)
	return w


func _mk_map(w: World) -> WeaponMapControl:
	var ui := FakeUI.new()
	ui.world = w
	var chart := ChartView.new()
	root.add_child(chart)
	var wmc := WeaponMapControl.new()
	root.add_child(wmc)
	var fe := FireExecutor.new()
	fe.programmer = LaunchProgrammer.new()
	wmc.setup(ui, w, chart, fe)
	return wmc


## 逐秒喂回波并推进相位机 / 任务态（自动锁定走真实路径）。
func _drive(tp: Torpedo, n: int, t0: float, brg: float, se: float) -> void:
	var rid: int = 5000
	for i in range(n):
		var now: float = t0 + float(i) * 1.0
		tp._seeker.process_returns([_mk_return(rid, now, brg, se)], now)
		tp._seeker.update(now)
		tp._advance_lock_state()
		tp._advance_guidance(now)
		rid += 1


func _mk_return(id: int, t: float, brg: float, se: float) -> SeekerReturn:
	var r := SeekerReturn.new()
	r.return_id = id
	r.timestamp = t
	r.available_time = t
	r.sensor_mode = "PASSIVE"
	r.detected = true
	r.bearing_deg = brg
	r.bearing_sigma_deg = 1.0
	r.signal_excess_db = se
	r.detection_probability = 1.0
	r.depth_relation = "SAME_LAYER"
	return r


func _assert(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)
