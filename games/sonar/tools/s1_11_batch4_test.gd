extends SceneTree
## s1_11_batch4_test.gd — S1-11 Batch 4（数据模型部分）：路线模型与单一地图发射。
##
##   B4-02 (AT-02) 无 System Solution 时，一条有效地图射线即可构成可发射计划；
##   B4-03 (AT-03) 发射初始航向 = 航线第一段方位（误差仅来自建模项）；
##   B4-05 (AT-05) 单段航线到达终点后保持最后航向，不蛇形/不绕圈；
##   B4-06 (AT-06) 多段航线按顺序通过航路点，转弯受 max_turn_rate 限制；
##   B4-18 (AT-18) 重画从当前位置起算、原子替换剩余航路（revision 递增）；
##   B4-24 (AT-24) 未来航路点上限（起点之外最多 4 个）；
##   B4-35 (AT-35) 路线/计划 DTO 无 target_id / 真值字段。
##   B4-C  (AT-01/24/35) MAP_ROUTE 为玩家唯一发射方式：程序链只吃地图航线，
##          缺航线或缺编程器一律拒绝（绝不静默退化为 MANUAL）。


func _initialize() -> void:
	var fails: Array = []
	_b4_02(fails)
	_b4_03(fails)
	_b4_05(fails)
	_b4_06(fails)
	_b4_18(fails)
	_b4_24(fails)
	_b4_35(fails)
	_b4_c(fails)
	_finish(fails)


# ---------------- AT-02：一条射线即可发射 ----------------
func _b4_02(fails: Array) -> void:
	var plan := PlayerTorpedoPlan.from_route("TP1", [Vector2(0, 0), Vector2(0, 3000)], 10.0)
	_assert(fails, plan.has_valid_route(), "B4-02 single-segment route is launchable")
	_assert(
		fails,
		not PlayerTorpedoPlan.from_route("TP0", [Vector2(0, 0)], 0.0).has_valid_route(),
		"B4-02 route with no direction is not launchable"
	)


# ---------------- AT-03：初始航向 = 第一段方位 ----------------
func _b4_03(fails: Array) -> void:
	var plan := PlayerTorpedoPlan.from_route("TP2", [Vector2(0, 0), Vector2(1000, 1000)], 0.0)
	_assert(
		fails,
		absf(NavUtils.wrap180(plan.initial_course_deg - 45.0)) < 1e-6,
		"B4-03 initial course matches first segment bearing (%.1f)" % plan.initial_course_deg
	)


# ---------------- AT-05：单段到达后保持最后航向 ----------------
func _b4_05(fails: Array) -> void:
	var route := TorpedoRouteState.new()
	route.set_route([Vector2(0, 0), Vector2(0, 600)])
	var pos := Vector2(0, 0)
	var course: float = 0.0
	for i in range(20):
		pos += Vector2(0, 40)
		var r: Dictionary = route.steer(pos, course, 40.0, 1.0, 6.0)
		course = float(r["course_deg"])
	var r_end: Dictionary = route.steer(pos, 0.0, 40.0, 1.0, 6.0)
	_assert(fails, bool(r_end["at_end"]), "B4-05 single-segment route reaches its end")
	_assert(
		fails,
		absf(NavUtils.wrap180(float(r_end["course_deg"]) - 0.0)) < 1e-6,
		"B4-05 after end the torpedo keeps its last course (no snake)"
	)


# ---------------- AT-06：多段顺序 + 转向率限制 ----------------
func _b4_06(fails: Array) -> void:
	var route := TorpedoRouteState.new()
	route.set_route([Vector2(0, 0), Vector2(0, 500), Vector2(500, 500)])
	_assert(fails, route.target_point() == Vector2(0, 500), "B4-06 targets the first waypoint")
	# 从起点以 0° 前进到接近第一个航路点。
	var pos := Vector2(0, 0)
	var course: float = 0.0
	pos += Vector2(0, 440)
	var r1: Dictionary = route.steer(pos, course, 40.0, 1.0, 6.0)
	_assert(fails, bool(r1["waypoint_reached"]), "B4-06 accepts waypoint within radius")
	_assert(
		fails,
		route.target_point() == Vector2(500, 500),
		"B4-06 advances to the next waypoint in order"
	)
	course = float(r1["course_deg"])
	var r2: Dictionary = route.steer(pos, course, 40.0, 1.0, 6.0)
	var delta: float = absf(NavUtils.wrap180(float(r2["course_deg"]) - course))
	_assert(
		fails,
		bool(r2["saturated"]) and delta <= 6.0 + 1e-6,
		"B4-06 turn is limited by max_turn_rate (delta=%.2f deg)" % delta
	)


# ---------------- AT-18：重画原子替换 ----------------
func _b4_18(fails: Array) -> void:
	var route := TorpedoRouteState.new()
	route.set_route([Vector2(0, 0), Vector2(0, 1000)])
	var rev0: int = route.revision
	var here := Vector2(0, 400)
	route.replace_from(here, [Vector2(800, 400)])
	_assert(
		fails,
		route.points[0] == here,
		"B4-18 new route starts at the torpedo's current known position"
	)
	_assert(
		fails,
		route.revision == rev0 + 1 and route.remaining_points().size() == 2,
		"B4-18 redraw atomically replaces the remaining route (revision++)"
	)
	_assert(
		fails,
		route.source == TorpedoRouteState.SOURCE_WIRE_UPDATE,
		"B4-18 redraw source is WIRE_UPDATE"
	)


# ---------------- AT-24：航路点上限 ----------------
func _b4_24(fails: Array) -> void:
	var route := TorpedoRouteState.new()
	var pts: Array = []
	for i in range(10):
		pts.append(Vector2(0, float(i) * 100.0))
	_assert(
		fails,
		not route.set_route(pts) and not route.has_route(),
		"B4-24 rejects route exceeding the future-waypoint cap"
	)
	var ok: Array = []
	for i in range(TorpedoRouteState.MAX_FUTURE_POINTS + 1):
		ok.append(Vector2(0, float(i) * 100.0))
	_assert(
		fails,
		route.set_route(ok),
		"B4-24 accepts start + up to %d waypoints" % TorpedoRouteState.MAX_FUTURE_POINTS
	)


# ---------------- AT-35：信息边界 ----------------
func _b4_35(fails: Array) -> void:
	var plan := PlayerTorpedoPlan.from_route("TP9", [Vector2(0, 0), Vector2(0, 900)], 0.0)
	var d: Dictionary = plan.to_dict()
	var leaked: bool = false
	for k in PlayerTorpedoPlan.forbidden_keys():
		if d.has(k):
			leaked = true
	_assert(fails, not leaked, "B4-35 plan DTO carries no forbidden truth keys")
	for p in ["res://scripts/weapon/torpedo_route_state.gd"]:
		var f := FileAccess.open(p, FileAccess.READ)
		var txt: String = f.get_as_text() if f != null else ""
		_assert(fails, txt.find("target_id") < 0, "B4-35 %s references no target_id" % p.get_file())


# ---------------- AT-01/24/35：MAP_ROUTE 为玩家唯一发射方式 ----------------
func _b4_c(fails: Array) -> void:
	var prog: WeaponProgram = WeaponProgram.make_route(
		[Vector2(0, 0), Vector2(0, 500), Vector2(500, 500)], 0.0
	)
	_assert(
		fails,
		prog.fire_mode == WeaponProgram.FireMode.MAP_ROUTE,
		"B4-C map-route program carries FireMode.MAP_ROUTE"
	)
	_assert(fails, prog.route_points.size() == 3, "B4-C route points are preserved")
	_assert(
		fails,
		absf(NavUtils.wrap180(prog.initial_course_deg - 0.0)) < 1e-6,
		"B4-C map-route initial course follows the first segment"
	)
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	var w := World.new()
	w.load_scenario(sc)
	var lc := LaunchProgrammer.new()
	var none: Dictionary = lc.build_program(
		"MAP_ROUTE", w.weapons, w, FireControlContext.new(), null, ""
	)
	_assert(
		fails,
		not bool(none.get("ok", false)),
		"B4-C MAP_ROUTE without a route is rejected (no silent MANUAL)"
	)
	lc.route_points = [Vector2(0, 0), Vector2(0, 800)]
	var built: Dictionary = lc.build_program(
		"MAP_ROUTE", w.weapons, w, FireControlContext.new(), null, ""
	)
	_assert(
		fails,
		(
			bool(built.get("ok", false))
			and built["program"].fire_mode == WeaponProgram.FireMode.MAP_ROUTE
		),
		"B4-C MAP_ROUTE builds from the player's route"
	)
	var fe := FireExecutor.new()
	var no_prog: Dictionary = fe.execute(w.weapons, w, "MAP_ROUTE", "")
	_assert(
		fails,
		not bool(no_prog.get("ok", false)),
		"B4-C FireExecutor rejects MAP_ROUTE without a programmer"
	)
	_b4_c2(fails)


# ---------------- AT-01/05/24：地图航线绘制层与 UI 契约 ----------------
func _b4_c2(fails: Array) -> void:
	var ov := MapRouteOverlay.new()
	ov.begin(100.0, 200.0)
	_assert(
		fails,
		ov.active and ov.points.size() == 1 and ov.points[0] == Vector2(100, 200),
		"B4-C2 draw mode starts at the own ship's measured position"
	)
	_assert(fails, not ov.can_commit(), "B4-C2 a lone start point is not launchable")
	var added: int = 0
	for i in range(MapRouteOverlay.MAX_FUTURE_POINTS + 3):
		if ov.add_point(100.0 + float(i) * 100.0, 200.0):
			added += 1
	_assert(
		fails,
		(
			added == MapRouteOverlay.MAX_FUTURE_POINTS
			and ov.future_point_count() == MapRouteOverlay.MAX_FUTURE_POINTS
		),
		"B4-C2 future waypoints are capped at %d" % MapRouteOverlay.MAX_FUTURE_POINTS
	)
	_assert(fails, ov.can_commit(), "B4-C2 route with waypoints is launchable")
	_assert(
		fails, ov.undo_last() and ov.future_point_count() == 3, "B4-C2 undo drops the last point"
	)
	var frozen: Array = ov.commit()
	_assert(
		fails,
		not ov.active and frozen.size() == 4 and ov.route_snapshot().size() == 4,
		"B4-C2 commit freezes the route and leaves draw mode"
	)
	ov.cancel()
	_assert(
		fails,
		not ov.active and ov.points.is_empty() and not ov.can_commit(),
		"B4-C2 cancel clears the route"
	)
	var wp_src: String = (load("res://scripts/ui/weapon_panel.gd") as Script).source_code
	var ui_src: String = (load("res://scripts/ui/main_ui.gd") as Script).source_code
	_assert(
		fails,
		wp_src.find("fire_mode_changed") < 0 and wp_src.find("route_draw_toggled") >= 0,
		"B4-C2 weapon panel drops the fire-mode selector for route controls"
	)
	_assert(
		fails,
		ui_src.find("MapRouteOverlay") >= 0 and ui_src.find("_fire_mode") < 0,
		"B4-C2 main UI fires MAP_ROUTE through the map route layer"
	)


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH4 TEST PASS")
		quit(0)
	else:
		print("S1-11 BATCH4 TEST FAIL (%d)" % fails.size())
		quit(1)
