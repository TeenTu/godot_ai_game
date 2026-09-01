class_name ChartView
extends Control
## chart_view.gd — 海图（俯视图）。阶段三 UI 组件。
##
## 数据源由外部（main_ui）每帧注入，本组件只负责绘制：
##   - 本艇位置（蓝三角）与历史轨迹
##   - 各 ACTIVE Track 的 LOB 线（从测量时刻本艇位置出发，沿测量方位）
##   - TMA 解算出的目标匀速轨迹（若已拟合）
##   - Trial / System Solution 目标符号
##   - Show Truth 时叠加真实目标位置（红色方块，仅调试）
##
## 坐标映射：以本艇当前位置为中心，固定视野半径 _view_radius_m，
## 保证俯视图始终跟随本艇。

var view_radius_m: float = 10000.0  # 视野半径（米），本艇居中

# 注入数据（每帧由 main_ui 更新）
var own_pos: Vector2 = Vector2.ZERO  # 本艇当前位置（世界坐标，东/北）
var own_track: Array = []  # 本艇历史位置点（世界坐标）
var lobs: Array = []  # [{origin: Vector2, bearing_deg: float, color: Color, id: String}]
var tma_track: Array = []  # TMA 解算出的目标轨迹点（世界坐标）
var trial_pos: Vector2 = Vector2.ZERO  # Trial Solution 目标符号位置
var trial_active: bool = false
var trial_velocity: Vector2 = Vector2.ZERO  # Trial Solution 速度向量（米/秒，世界坐标）
var system_pos: Vector2 = Vector2.ZERO  # System Solution 目标符号位置
var system_active: bool = false
var truth_positions: Array = []  # [{pos: Vector2, id: String}] 调试用
var show_truth: bool = false

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


## 世界坐标 → 屏幕坐标（本艇居中）。
func world_to_screen(w: Vector2) -> Vector2:
	var scale: float = minf(size.x, size.y) / (2.0 * view_radius_m)
	var d: Vector2 = w - own_pos
	return Vector2(size.x * 0.5 + d.x * scale, size.y * 0.5 - d.y * scale)


## 屏幕坐标 → 世界坐标（供鼠标点击反算，TMA 尺用）。
func screen_to_world(s: Vector2) -> Vector2:
	var scale: float = minf(size.x, size.y) / (2.0 * view_radius_m)
	var d: Vector2 = (s - Vector2(size.x * 0.5, size.y * 0.5)) / scale
	return own_pos + Vector2(d.x, -d.y)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	# 背景
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.08, 0.10, 1.0))
	# 网格（每 2000m 一格）
	var grid_m: float = 2000.0
	var scale: float = minf(size.x, size.y) / (2.0 * view_radius_m)
	var grid_px: float = grid_m * scale
	if grid_px >= 10.0:
		var col := Color(0.15, 0.25, 0.28, 0.35)
		var x: float = fmod(size.x * 0.5, grid_px)
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
			x += grid_px
		var y: float = fmod(size.y * 0.5, grid_px)
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
			y += grid_px

	_draw_own_track()
	_draw_lobs()
	_draw_tma_track()
	_draw_symbols()
	if show_truth:
		_draw_truth()


func _draw_own_track() -> void:
	# 本艇历史轨迹（淡蓝细线）
	if own_track.size() >= 2:
		var pts: PackedVector2Array = []
		for p in own_track:
			pts.append(world_to_screen(p))
		draw_polyline(pts, Color(0.35, 0.6, 0.95, 0.5), 1.5)
	# 本艇三角符号
	var s: Vector2 = world_to_screen(own_pos)
	var tri := PackedVector2Array([s + Vector2(0, -10), s + Vector2(7, 6), s + Vector2(-7, 6)])
	draw_colored_polygon(tri, Color(0.3, 0.7, 1.0, 1.0))
	draw_string(
		_font,
		s + Vector2(8, -8),
		"OWN",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		Color(0.6, 0.85, 1.0, 0.9)
	)


func _draw_lobs() -> void:
	for lob in lobs:
		var origin: Vector2 = world_to_screen(lob["origin"])
		var bearing: float = lob["bearing_deg"]
		# LOB 延伸到视野边缘
		var end_w: Vector2 = (
			lob["origin"]
			+ Vector2(
				sin(deg_to_rad(bearing)) * view_radius_m, cos(deg_to_rad(bearing)) * view_radius_m
			)
		)
		var end_s: Vector2 = world_to_screen(end_w)
		var col: Color = lob.get("color", Color(1.0, 0.85, 0.3, 0.6))
		draw_line(origin, end_s, col, 1.0)
		# 标注接触编号
		var id: String = lob.get("id", "")
		if id != "":
			var mid: Vector2 = (origin + end_s) * 0.5
			draw_string(_font, mid + Vector2(4, -4), id, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


func _draw_tma_track() -> void:
	if tma_track.size() < 2:
		return
	var pts: PackedVector2Array = []
	for p in tma_track:
		pts.append(world_to_screen(p))
	draw_polyline(pts, Color(0.9, 0.4, 0.2, 0.9), 2.0)
	# 轨迹头符号
	var head: Vector2 = world_to_screen(tma_track[tma_track.size() - 1])
	draw_circle(head, 4.0, Color(1.0, 0.5, 0.2, 1.0))


func _draw_symbols() -> void:
	if trial_active:
		var s: Vector2 = world_to_screen(trial_pos)
		draw_circle(s, 5.0, Color(0.4, 1.0, 0.7, 0.95))
		draw_string(
			_font,
			s + Vector2(8, 4),
			"TRIAL",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			11,
			Color(0.5, 1.0, 0.8, 0.9)
		)
		# 速度向量箭头（按 trial 航向/航速画 60s 预测位移）
		if trial_velocity.length() > 0.01:
			var end_w: Vector2 = trial_pos + trial_velocity * 60.0
			var end_s: Vector2 = world_to_screen(end_w)
			draw_line(s, end_s, Color(0.4, 1.0, 0.7, 0.7), 2.0)
			# 箭头头
			var dir: Vector2 = (end_s - s).normalized()
			if dir.length() > 0.01:
				var perp: Vector2 = Vector2(-dir.y, dir.x) * 5.0
				var head: PackedVector2Array = [
					end_s, end_s - dir * 10.0 + perp, end_s - dir * 10.0 - perp
				]
				draw_colored_polygon(head, Color(0.4, 1.0, 0.7, 0.8))
	if system_active:
		var s2: Vector2 = world_to_screen(system_pos)
		draw_arc(s2, 8.0, 0, TAU, 24, Color(1.0, 1.0, 0.3, 0.95), 2.0)
		draw_string(
			_font,
			s2 + Vector2(10, 4),
			"SYSTEM",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			11,
			Color(1.0, 1.0, 0.5, 0.9)
		)


func _draw_truth() -> void:
	for t in truth_positions:
		var s: Vector2 = world_to_screen(t["pos"])
		var r := Rect2(s - Vector2(5, 5), Vector2(10, 10))
		draw_rect(r, Color(1.0, 0.25, 0.25, 0.9))
		draw_string(
			_font,
			s + Vector2(8, -2),
			t.get("id", "?"),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			11,
			Color(1.0, 0.5, 0.5, 0.9)
		)
