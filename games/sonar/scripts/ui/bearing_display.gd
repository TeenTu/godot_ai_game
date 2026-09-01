class_name BearingDisplay
extends Control
## bearing_display.gd — 声呐方位盘（极坐标 LOB 显示）。阶段三 UI 组件。
##
## 以本艇为圆心：
##   - 外圈 + 方位刻度（正北 0°，顺时针）
##   - 每条 ACTIVE Track 的 LOB 线（从圆心沿测量方位发出）
##   - 最近一次测量方位的高亮线
##   - 本艇艏向标记
##
## 数据由外部（main_ui）每帧注入。

var own_course_deg: float = 0.0
var lobs: Array = []  # [{bearing_deg: float, color: Color, id: String}]
var latest_bearing_deg: float = -1.0  # -1 = 无
var latest_color: Color = Color.WHITE

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	var c: Vector2 = size * 0.5
	var r: float = minf(size.x, size.y) * 0.5 - 12.0
	if r < 20.0:
		return

	# 背景
	draw_circle(c, r, Color(0.02, 0.06, 0.08, 1.0))
	# 外圈
	draw_arc(c, r, 0, TAU, 64, Color(0.3, 0.5, 0.55, 0.8), 2.0)
	# 方位刻度（每 30°，标注数字）
	for d in range(0, 360, 30):
		var a: float = deg_to_rad(d)
		var dir: Vector2 = Vector2(sin(a), -cos(a))
		var long: bool = d % 90 == 0
		var r0: float = r - (14.0 if long else 8.0)
		draw_line(c + dir * r0, c + dir * r, Color(0.35, 0.55, 0.6, 0.7), 1.0)
		if long:
			var tpos: Vector2 = c + dir * (r - 24.0)
			draw_string(
				_font,
				tpos - Vector2(7, 5),
				str(d),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				12,
				Color(0.6, 0.8, 0.85, 0.9)
			)
	# 本艇艏向
	var bow: Vector2 = Vector2(sin(deg_to_rad(own_course_deg)), -cos(deg_to_rad(own_course_deg)))
	draw_line(c + bow * 8.0, c + bow * (r - 6.0), Color(0.3, 0.7, 1.0, 0.9), 3.0)
	draw_circle(c + bow * 8.0, 4.0, Color(0.3, 0.7, 1.0, 1.0))

	# LOB 线（半透明）
	for lob in lobs:
		var b: float = lob["bearing_deg"]
		var a: float = deg_to_rad(b)
		var dir2: Vector2 = Vector2(sin(a), -cos(a))
		var col: Color = lob.get("color", Color(1.0, 0.85, 0.3, 0.5))
		draw_line(c + dir2 * 10.0, c + dir2 * (r - 4.0), col, 1.5)
		var id: String = lob.get("id", "")
		if id != "":
			var tpos2: Vector2 = c + dir2 * (r * 0.55)
			draw_string(_font, tpos2 - Vector2(9, 0), id, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

	# 最近测量高亮线
	if latest_bearing_deg >= 0.0:
		var a: float = deg_to_rad(latest_bearing_deg)
		var dir3: Vector2 = Vector2(sin(a), -cos(a))
		draw_line(c + dir3 * 10.0, c + dir3 * (r - 4.0), latest_color, 3.0)
