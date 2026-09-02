class_name BoomSkillButton
extends Control
## 战斗 HUD 的技能状态：位图图标 + 程序化 CD 圆环，纯展示、不抢手势输入。

var skill_id: String
var total_cooldown: float = 1.0
var cooldown_left: float = 0.0
var accent: Color = Color.WHITE

var _icon: TextureRect
var _cd_label: Label
var _gesture_label: Label


func setup(
	id: String, texture_path: String, cooldown: float, color: Color, gesture: String
) -> void:
	skill_id = id
	total_cooldown = cooldown
	accent = color
	size = Vector2(104.0, 122.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_icon = TextureRect.new()
	_icon.position = Vector2(10.0, 6.0)
	_icon.size = Vector2(84.0, 84.0)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(texture_path):
		_icon.texture = load(texture_path) as Texture2D
	add_child(_icon)

	_cd_label = Label.new()
	_cd_label.position = Vector2(0.0, 27.0)
	_cd_label.size = Vector2(104.0, 40.0)
	_cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cd_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cd_label.add_theme_font_size_override("font_size", 24)
	_cd_label.add_theme_color_override("font_color", Color(1.0, 0.97, 0.91))
	_cd_label.add_theme_color_override("font_shadow_color", Color(0.35, 0.12, 0.05, 0.8))
	_cd_label.add_theme_constant_override("shadow_offset_x", 2)
	_cd_label.add_theme_constant_override("shadow_offset_y", 2)
	_cd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cd_label)

	_gesture_label = Label.new()
	_gesture_label.text = gesture
	_gesture_label.position = Vector2(0.0, 94.0)
	_gesture_label.size = Vector2(104.0, 24.0)
	_gesture_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gesture_label.add_theme_font_size_override("font_size", 15)
	_gesture_label.add_theme_color_override("font_color", Color(1.0, 0.97, 0.91, 0.9))
	_gesture_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gesture_label)
	queue_redraw()


func set_cooldown(left: float) -> void:
	cooldown_left = maxf(0.0, left)
	if _cd_label != null:
		_cd_label.text = str(ceili(cooldown_left)) if cooldown_left > 0.05 else "READY"
		_cd_label.add_theme_font_size_override("font_size", 18 if cooldown_left <= 0.05 else 24)
	if _icon != null:
		_icon.modulate = Color(0.55, 0.58, 0.62, 0.58) if cooldown_left > 0.05 else Color.WHITE
	queue_redraw()


func _draw() -> void:
	var center := Vector2(52.0, 48.0)
	draw_circle(center, 48.0, Color(0.18, 0.09, 0.12, 0.68))
	draw_arc(center, 46.0, 0.0, TAU, 64, Color(1.0, 0.97, 0.9, 0.45), 5.0, true)
	if cooldown_left <= 0.05:
		draw_arc(center, 47.0, 0.0, TAU, 64, accent, 7.0, true)
		return
	var ready_ratio := 1.0 - clampf(cooldown_left / total_cooldown, 0.0, 1.0)
	var start := -PI * 0.5
	draw_arc(center, 47.0, start, start + TAU * ready_ratio, 64, accent, 7.0, true)
