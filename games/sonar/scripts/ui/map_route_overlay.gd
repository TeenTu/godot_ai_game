class_name MapRouteOverlay
extends Control
## map_route_overlay.gd — S1-11 Batch 4c：地图航线绘制层（D-01 玩家唯一发射方式）。
##
## 覆盖在 ChartView 之上（不侵入 ChartView 的 _draw，控行数）：
##   - 空闲：mouse_filter=IGNORE，完全不挡地图交互；
##   - 绘制：捕获左键 → 世界坐标 → 追加航路点。
## 起点吸附本艇**实测**位置，其后最多 MAX_FUTURE_POINTS 个未来航路点。
## 信息边界：只持世界 east/north 坐标与自艇实测位置，绝不含真值/目标 ID。

## 航路点集合变化（用于刷新面板文案）。
signal route_changed
## 玩家完成绘制（points 为世界 east/north 的 Array[Vector2]，首点=本艇位置）。
signal route_committed(points: Array)

## 未来航路点上限（不含起点），与 TorpedoRouteState.MAX_FUTURE_POINTS 一致。
const MAX_FUTURE_POINTS: int = 4
const WAYPOINT_LABEL_PX: int = 12
const COL_ROUTE := Color(0.35, 0.95, 0.75, 0.95)
const COL_ROUTE_FILL := Color(0.35, 0.95, 0.75, 0.28)
const COL_START := Color(0.98, 0.85, 0.25, 0.95)

## 地图（坐标换算）。
var chart: ChartView = null
## 是否处于绘制态。
var active: bool = false
## 航路点（世界 east/north），首点 = 本艇实测位置。
var points: Array = []
## 鼠标世界坐标（预览最后一段用；无效时为 INF）。
var cursor_world: Vector2 = Vector2.INF


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


## 进入绘制态：起点吸附本艇实测位置（own_e/own_n）。
func begin(own_e: float, own_n: float) -> void:
	points = [Vector2(own_e, own_n)]
	active = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()
	route_changed.emit()


## 退出并清空（取消绘制）。
func cancel() -> void:
	points = []
	cursor_world = Vector2.INF
	active = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	route_changed.emit()


## 追加一个航路点（世界 east/north）；非绘制态或超出上限返回 false。
func add_point(east: float, north: float) -> bool:
	if not active or future_point_count() >= MAX_FUTURE_POINTS:
		return false
	points.append(Vector2(east, north))
	queue_redraw()
	route_changed.emit()
	return true


## 撤销最后一个航路点（起点不可撤）。
func undo_last() -> bool:
	if points.size() <= 1:
		return false
	points.remove_at(points.size() - 1)
	queue_redraw()
	route_changed.emit()
	return true


## 是否已构成可发射航线（起点 + ≥1 个未来航路点）。
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


func _gui_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		cursor_world = _to_world(mm.position)
		queue_redraw()
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var w: Vector2 = _to_world(mb.position)
			add_point(w.x, w.y)
			accept_event()


func _to_world(local_pos: Vector2) -> Vector2:
	if chart == null:
		return Vector2.ZERO
	return chart.screen_to_world(global_position + local_pos)


func _draw() -> void:
	if points.is_empty():
		return
	var font: Font = get_theme_default_font()
	var pts: Array = []
	for p in points:
		pts.append(chart.world_to_screen(p) - global_position)
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
