class_name BearingDisplay
extends Control
## bearing_display.gd — 声呐方位盘（极坐标 LOB 显示）+ 本艇命令航向操纵（UI-02）。
##
## 以本艇为圆心：
##   - 外圈 + 方位刻度（正北 0°，顺时针）
##   - 每条 ACTIVE Track 的 LOB 线（从圆心沿测量方位发出）
##   - 最近一次测量方位的高亮线
##   - 本艇**实际**艏向（实线）/ **命令**艏向（虚线 + 预计转向时间）
##   - 拖动中的**预览**（黄色虚线 + 数值，未提交）
##
## UI-02 操纵约定：
##   - 外圈环带（半径 ≥ DEAD_R_PX）左键点击/拖动 → 预览命令箭头；**松开才提交一次**
##     （拖动不瞬改实际 course，也不写命令）；
##   - 角度 = wrap360(rad_to_deg(atan2(mouse_x - cx, -(mouse_y - cy))))，用控件局部
##     坐标：北 0°、东 90°、南 180°、西 270°；
##   - 中心死区（半径 < DEAD_R_PX）不参与操纵——留给后续接触选择，避免把"选敌方位"
##     误当转向命令；
##   - 右键 / Esc 取消未提交预览（并吃掉事件，不连带打开地图菜单）；控件外释放由
##     Viewport 的 mouse_focus 保证送达，正常提交；
##   - 终局（interactive=false）不启动拖动，并把已有预览清掉（T26）。
##
## 数据由外部（main_ui / OwnCommandGate）每帧注入；本类不持有任何世界状态。

signal course_commanded(deg: float)

## 中心死区半径（逻辑像素）：小于此半径的按下不进入操纵。
const DEAD_R_PX: float = 18.0
const RING_MARGIN_PX: float = 8.0
const COL_ACTUAL := Color(0.3, 0.7, 1.0, 0.9)
const COL_CMD := Color(1.0, 0.75, 0.3, 0.95)
const COL_PREVIEW := Color(1.0, 0.95, 0.4, 1.0)

var own_course_deg: float = 0.0
var lobs: Array = []  # [{bearing_deg: float, color: Color, id: String}]
var latest_bearing_deg: float = -1.0  # -1 = 无
var latest_color: Color = Color.WHITE
## UI-02：命令航向（-1 = 无命令）、预计剩余转向时间、最大转向率（仅显示用）。
var cmd_course_deg: float = -1.0
var cmd_eta_s: float = -1.0
var turn_rate_deg_s: float = 3.0
## UI-02：未提交预览（-1 = 无）与是否允许操纵（终局后 false）。
var preview_deg: float = -1.0
var interactive: bool = true

var _font: Font = null
var _dragging: bool = false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP


## 预览是否处于活动状态（测试/仲裁用）。
func preview_active() -> bool:
	return preview_deg >= 0.0 or _dragging


## 取消未提交预览：**不写命令**、不残留拖动状态（UI-04 统一清理）。
func cancel_preview() -> void:
	if not preview_active():
		return
	preview_deg = -1.0
	_dragging = false
	queue_redraw()


## 局部坐标 → 真方位（北 0 / 东 90，顺时针）。
static func angle_of(local_pos: Vector2, center: Vector2) -> float:
	return NavUtils.wrap360(rad_to_deg(atan2(local_pos.x - center.x, -(local_pos.y - center.y))))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _dragging:
		_update_preview((event as InputEventMouseMotion).position)
		accept_event()


func _unhandled_key_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo or k.keycode != KEY_ESCAPE:
		return
	# 仅在预览活动时吃掉 Esc：否则让 Esc 照常传给（例如）航线绘制层。
	if not preview_active():
		return
	cancel_preview()
	get_viewport().set_input_as_handled()


func _handle_button(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		# 右键取消预览：吃掉事件，不连带打开地图右键菜单。
		if preview_active():
			cancel_preview()
			accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		if not interactive or not _ring_hit(mb.position):
			return
		_dragging = true
		_update_preview(mb.position)
		accept_event()
		return
	if not _dragging:
		return
	# 松开 → 只提交一次（预览不清零前先取值）。
	_dragging = false
	var deg: float = preview_deg
	preview_deg = -1.0
	queue_redraw()
	accept_event()
	if deg >= 0.0 and interactive:
		course_commanded.emit(deg)


## 环带命中（中心死区留给接触选择，不与操舵混用）。
func _ring_hit(pos: Vector2) -> bool:
	var c: Vector2 = size * 0.5
	var r: float = _radius()
	if r < 20.0:
		return false
	var d: float = (pos - c).length()
	return d >= DEAD_R_PX and d <= r + RING_MARGIN_PX


func _update_preview(pos: Vector2) -> void:
	var c: Vector2 = size * 0.5
	# 拖到死区内保持上一个角度（避免角度乱跳），不写任何命令。
	if (pos - c).length() < DEAD_R_PX:
		return
	preview_deg = angle_of(pos, c)
	queue_redraw()


func _radius() -> float:
	return minf(size.x, size.y) * 0.5 - 12.0


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	var c: Vector2 = size * 0.5
	var r: float = _radius()
	if r < 20.0:
		return

	# 背景
	draw_circle(c, r, Color(0.02, 0.06, 0.08, 1.0))
	# 操纵环带（外圈向内 26px）与中心死区提示（不同半径分区，视觉可辨）。
	draw_arc(c, r, 0, TAU, 64, Color(0.3, 0.5, 0.55, 0.8), 2.0)
	draw_arc(c, r - 26.0, 0, TAU, 64, Color(0.35, 0.55, 0.6, 0.25), 1.0)
	draw_arc(c, DEAD_R_PX, 0, TAU, 32, Color(0.35, 0.55, 0.6, 0.25), 1.0)
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

	# 命令艏向（虚线 + 预计转向时间）与拖动预览（黄色虚线）；实际艏向实线。
	if cmd_course_deg >= 0.0:
		_draw_arrow(c, r, cmd_course_deg, COL_CMD, true, _cmd_label())
	if preview_deg >= 0.0:
		_draw_arrow(
			c,
			r,
			preview_deg,
			COL_PREVIEW,
			true,
			UiText.t("own_course_preview_fmt") % preview_deg,
			4.0
		)
	var bow: Vector2 = Vector2(sin(deg_to_rad(own_course_deg)), -cos(deg_to_rad(own_course_deg)))
	draw_line(c + bow * 8.0, c + bow * (r - 6.0), COL_ACTUAL, 3.0)
	draw_circle(c + bow * 8.0, 4.0, COL_ACTUAL)
	draw_string(
		_font,
		c + bow * (r - 34.0) + Vector2(4, -4),
		UiText.t("own_course_actual_fmt") % own_course_deg,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		COL_ACTUAL
	)


## 命令/预览箭头：实线=实际艏向之外一律虚线；文字放在箭头中段旁边。
func _draw_arrow(
	c: Vector2, r: float, deg: float, col: Color, dashed: bool, label: String, width: float = 2.0
) -> void:
	var dir: Vector2 = Vector2(sin(deg_to_rad(deg)), -cos(deg_to_rad(deg)))
	if dashed:
		draw_dashed_line(c + dir * 12.0, c + dir * (r - 8.0), col, width, 5.0)
	else:
		draw_line(c + dir * 12.0, c + dir * (r - 8.0), col, width)
	draw_circle(c + dir * (r - 8.0), 3.0, col)
	draw_string(
		_font, c + dir * (r * 0.72) + Vector2(4, -3), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col
	)


func _cmd_label() -> String:
	if cmd_eta_s >= 0.0:
		return UiText.t("own_course_cmd_eta_fmt") % [cmd_course_deg, cmd_eta_s]
	return UiText.t("own_course_cmd_fmt") % cmd_course_deg
