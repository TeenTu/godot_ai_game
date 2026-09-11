class_name MapRouteOverlay
extends Control
## map_route_overlay.gd — S1-11 Batch 4c/5：地图航线绘制层（D-01 玩家唯一发射方式）。
##
## 覆盖在 ChartView 之上（不侵入 ChartView 的 _draw，控行数）：
##   - 空闲：mouse_filter=IGNORE，完全不挡地图交互；
##   - 绘制：捕获左键 → 世界坐标 → 追加航路点；拖动开机标记。
## 起点吸附本艇**实测**位置（发射前）或鱼雷**当前已知**位置（在线重画），
## 其后最多 MAX_FUTURE_POINTS 个未来航路点。
##
## 主动开机标记（§6.3）：沿航线**累计距离**定位（不按与地图点的直线距离），
## 可拖动；被拖到端点外则清除。
## 信息边界：只持世界 east/north 坐标与自艇/鱼雷已知位置，绝不含真值/目标 ID。

## 航路点集合变化（用于刷新面板文案）。
signal route_changed
## 玩家完成绘制（points 为世界 east/north 的 Array[Vector2]，首点=起点）。
signal route_committed(points: Array)
## 开机点累计距离变化（<0 = 无标记）。
signal trigger_changed(offset_m: float)

## 未来航路点上限（不含起点），与 TorpedoRouteState.MAX_FUTURE_POINTS 一致。
const MAX_FUTURE_POINTS: int = 4
const WAYPOINT_LABEL_PX: int = 12
const MARKER_HIT_PX: float = 12.0
## AT-44：航路点拖动命中半径（起点固定，不参与拖动）。
const WAYPOINT_HIT_PX: float = 14.0
const COL_ROUTE := Color(0.35, 0.95, 0.75, 0.95)
const COL_ROUTE_PREV := Color(0.35, 0.95, 0.75, 0.45)
const COL_ROUTE_FILL := Color(0.35, 0.95, 0.75, 0.28)
const COL_START := Color(0.98, 0.85, 0.25, 0.95)
const COL_TRIGGER := Color(1.0, 0.55, 0.15, 0.95)

## 地图（坐标换算）。
var chart: ChartView = null
## 是否处于绘制态。
var active: bool = false
## 航路点（世界 east/north），首点 = 起点。
var points: Array = []
## 鼠标世界坐标（预览最后一段用；无效时为 INF）。
var cursor_world: Vector2 = Vector2.INF
## 起点是否为在水鱼雷（在线重画；仅影响绘制与文案）。
var in_water: bool = false
## 开机点：沿航线累计距离（m；<0 = 无标记）。
var trigger_offset_m: float = -1.0
## 已走航迹（低亮度显示；世界 east/north 数组）。
var traveled_path: Array = []
var _dragging_trigger: bool = false
var _drag_waypoint: int = -1
var _last_change_was_trigger: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


## 进入绘制态：起点吸附给定实测位置（发射前 = 本艇；在线重画 = 鱼雷）。
func begin(own_e: float, own_n: float, from_torpedo: bool = false) -> void:
	points = [Vector2(own_e, own_n)]
	in_water = from_torpedo
	trigger_offset_m = -1.0
	traveled_path = []
	_dragging_trigger = false
	_drag_waypoint = -1
	active = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()
	route_changed.emit()


## 退出并清空（取消绘制）。
func cancel() -> void:
	points = []
	cursor_world = Vector2.INF
	trigger_offset_m = -1.0
	traveled_path = []
	_dragging_trigger = false
	_drag_waypoint = -1
	active = false
	in_water = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	route_changed.emit()


## 追加一个航路点（世界 east/north）；非绘制态或超出上限返回 false。
func add_point(east: float, north: float) -> bool:
	if not active or future_point_count() >= MAX_FUTURE_POINTS:
		return false
	points.append(Vector2(east, north))
	_last_change_was_trigger = false
	queue_redraw()
	route_changed.emit()
	return true


## 撤销最后一个航路点（起点不可撤）。
func undo_last() -> bool:
	if points.size() <= 1:
		return false
	points.remove_at(points.size() - 1)
	_last_change_was_trigger = false
	queue_redraw()
	route_changed.emit()
	return true


## 是否已构成可发射/可下发航线（起点 + ≥1 个未来航路点）。
func can_commit() -> bool:
	return points.size() >= 2


func future_point_count() -> int:
	return maxi(0, points.size() - 1)


## 完成绘制：冻结当前航路点并退出绘制态。
func commit() -> Array:
	var out: Array = points.duplicate()
	if out.size() >= 2:
		active = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		cursor_world = Vector2.INF
		queue_redraw()
		route_changed.emit()
		route_committed.emit(out.duplicate())
	return out


## 供发射链消费的航线快照（不暴露内部数组引用）。
func route_snapshot() -> Array:
	return points.duplicate()


## 已提交航线的预览（外部更新，如在地鱼雷重画）——不改变绘制态。
func set_route_preview(pts: Array) -> void:
	points = pts.duplicate()
	queue_redraw()


## ---- 主动开机标记（沿航线累计距离，§6.3）----
func set_trigger_offset(offset_m: float) -> bool:
	if not can_commit():
		return false
	var total: float = route_length_m()
	trigger_offset_m = clampf(offset_m, 0.0, total)
	_last_change_was_trigger = true
	queue_redraw()
	trigger_changed.emit(trigger_offset_m)
	return true


func clear_trigger() -> void:
	if trigger_offset_m < 0.0:
		return
	trigger_offset_m = -1.0
	_last_change_was_trigger = true
	queue_redraw()
	trigger_changed.emit(-1.0)


func has_trigger() -> bool:
	return trigger_offset_m >= 0.0 and can_commit()


## 航线总长（m）。
func route_length_m() -> float:
	var total: float = 0.0
	for i in range(1, points.size()):
		total += (points[i] as Vector2).distance_to(points[i - 1])
	return total


## 把世界点投影到航线上，返回沿航线的累计距离（m）。
func project_offset(world_pos: Vector2) -> float:
	if points.size() < 2:
		return 0.0
	var best: float = 0.0
	var best_d: float = INF
	var acc: float = 0.0
	for i in range(1, points.size()):
		var a: Vector2 = points[i - 1]
		var b: Vector2 = points[i]
		var seg: Vector2 = b - a
		var seg_len: float = seg.length()
		if seg_len < 0.001:
			continue
		var t: float = clampf((world_pos - a).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var proj: Vector2 = a + seg * t
		var d: float = proj.distance_to(world_pos)
		if d < best_d:
			best_d = d
			best = acc + seg_len * t
		acc += seg_len
	return best


## 开机点世界坐标（无标记返回 INF）。
func trigger_world_point() -> Vector2:
	if not has_trigger():
		return Vector2.INF
	var acc: float = 0.0
	for i in range(1, points.size()):
		var a: Vector2 = points[i - 1]
		var b: Vector2 = points[i]
		var seg_len: float = a.distance_to(b)
		if acc + seg_len >= trigger_offset_m:
			var t: float = 0.0 if seg_len < 0.001 else (trigger_offset_m - acc) / seg_len
			return a.lerp(b, clampf(t, 0.0, 1.0))
		acc += seg_len
	return points[-1]


## AT-44：命中半径——触摸模式统一放大到 UiContract.TOUCH_HIT_PX。
static func hit_px(touch: bool) -> float:
	return UiContract.TOUCH_HIT_PX if touch else MARKER_HIT_PX


## AT-44：本地坐标下命中哪个航路点（返回索引；<1 表示未命中或仅起点）。
## 起点是本艇/鱼雷实测位置，不可拖动，故只允许 index >= 1。
func waypoint_hit_index(local_pos: Vector2, radius: float) -> int:
	var best: int = -1
	var best_d: float = radius
	for i in range(points.size()):
		var d: float = _to_screen(points[i]).distance_to(local_pos)
		if d <= best_d:
			best_d = d
			best = i
	return best


func _gui_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseButton:
		_handle_click(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_drag(event as InputEventMouseMotion)


## 左键按下：优先拖动开机标记，其次拖动已有航路点，否则追加新航路点。
func _handle_click(mb: InputEventMouseButton) -> void:
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if not mb.pressed:
		_dragging_trigger = false
		_drag_waypoint = -1
		return
	var hit: float = hit_px(UiContract.touch_mode())
	if has_trigger() and _to_screen(trigger_world_point()).distance_to(mb.position) <= hit:
		_dragging_trigger = true
		accept_event()
		return
	var wi: int = waypoint_hit_index(mb.position, hit)
	if wi >= 1:
		_drag_waypoint = wi
		accept_event()
		return
	var w: Vector2 = _to_world(mb.position)
	add_point(w.x, w.y)
	accept_event()


## 拖动：开机标记沿航线滑动；航路点跟随光标（两者都 accept_event，
## 因此不会落到海图变成相机平移——AT-44）。
func _handle_drag(mm: InputEventMouseMotion) -> void:
	if _dragging_trigger:
		var off: float = project_offset(_to_world(mm.position))
		trigger_offset_m = clampf(off, 0.0, route_length_m())
		queue_redraw()
		trigger_changed.emit(trigger_offset_m)
		accept_event()
		return
	if _drag_waypoint >= 1 and _drag_waypoint < points.size():
		points[_drag_waypoint] = _to_world(mm.position)
		_last_change_was_trigger = false
		queue_redraw()
		route_changed.emit()
		accept_event()
		return
	cursor_world = _to_world(mm.position)
	queue_redraw()
	accept_event()


func _to_world(local_pos: Vector2) -> Vector2:
	if chart == null:
		return Vector2.ZERO
	return chart.screen_to_world(global_position + local_pos)


func _to_screen(world_pos: Vector2) -> Vector2:
	return chart.world_to_screen(world_pos) - global_position


func _draw() -> void:
	if chart == null:
		return
	# 已走航迹：低亮度实线（§4.5）。
	if traveled_path.size() >= 2:
		var tp: Array = []
		for p in traveled_path:
			tp.append(_to_screen(p))
		draw_polyline(tp, COL_ROUTE_PREV, 2.0, true)
	if points.is_empty():
		return
	var font: Font = get_theme_default_font()
	var pts: Array = []
	for p in points:
		pts.append(_to_screen(p))
	if active and cursor_world != Vector2.INF and future_point_count() < MAX_FUTURE_POINTS:
		pts.append(chart.world_to_screen(cursor_world) - global_position)
	if pts.size() >= 2:
		draw_polyline(pts, COL_ROUTE, 2.0, true)
	# 起点与航路点标记（起点用暖色区分，编号从 1 起指未来航路点）。
	for i in range(pts.size()):
		var is_start: bool = i == 0 and i < points.size()
		var r: float = 6.0 if is_start else 4.0
		draw_circle(pts[i], r, COL_START if is_start else COL_ROUTE_FILL)
		draw_arc(pts[i], r, 0.0, TAU, 20, COL_ROUTE, 1.5, true)
		if not is_start and i < points.size():
			draw_string(
				font,
				pts[i] + Vector2(8, -8),
				str(i),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				WAYPOINT_LABEL_PX,
				COL_ROUTE
			)
	if is_start_label_needed():
		draw_string(
			font,
			pts[0] + Vector2(8, 16),
			"鱼雷" if in_water else "本艇",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			WAYPOINT_LABEL_PX,
			COL_START
		)
	# 开机标记：脉冲图标（同心圈闪烁感由半径区分，不依赖动画）。
	if has_trigger():
		var mw: Vector2 = _to_screen(trigger_world_point())
		draw_circle(mw, 7.0, Color(COL_TRIGGER.r, COL_TRIGGER.g, COL_TRIGGER.b, 0.28))
		draw_arc(mw, 5.0, 0.0, TAU, 20, COL_TRIGGER, 2.0)
		draw_arc(
			mw, 9.0, 0.0, TAU, 24, Color(COL_TRIGGER.r, COL_TRIGGER.g, COL_TRIGGER.b, 0.5), 1.0
		)
		draw_string(
			font,
			mw + Vector2(10, -8),
			"主动开机",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			WAYPOINT_LABEL_PX,
			COL_TRIGGER
		)


func is_start_label_needed() -> bool:
	return not points.is_empty() and (in_water or active)
