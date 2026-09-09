class_name BoomSkillButton
extends Control
## 战斗 HUD 的技能槽位按钮：位图图标（缺失时用缩写大字）+ 程序化 CD 圆环 + 手势标签。
## 纯展示、不抢手势输入（点按由 main.gd 全局触摸按槽位分发）。
## D6(design_m7_progression §228)：HUD 圆钮展示当前 equipped 槽位技能；空槽灰显占位。

var slot: int = -1  # 手势槽：0=tap / 1=←swipe / 2=→swipe（与 equipped 索引对齐）
var skill_id: String = ""
var total_cooldown: float = 1.0
var cooldown_left: float = 0.0
var accent: Color = Color.WHITE
var is_empty_slot: bool = false  # 空槽（该手势未装备技能）：灰显占位，无冷却/不可施放
var is_passive: bool = false  # 被动技能：占槽提供常驻加成，不进入施放/冷却管线

var _icon: TextureRect
var _title_label: Label
var _cd_label: Label
var _gesture_label: Label


## 布局公共件（normal/empty 两态共用）；重复调用会重置 modulate 等显示态。
func _build_common(gesture: String) -> void:
	size = Vector2(104.0, 122.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if _icon == null:
		_icon = TextureRect.new()
		_icon.position = Vector2(10.0, 6.0)
		_icon.size = Vector2(84.0, 84.0)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
	_icon.modulate = Color.WHITE

	if _title_label == null:
		# 无位图技能的缩写大字/空槽"—"占位（圆心区，与 icon 二选一）。
		_title_label = Label.new()
		_title_label.position = Vector2(0.0, 14.0)
		_title_label.size = Vector2(104.0, 68.0)
		_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_title_label.add_theme_font_size_override("font_size", 30)
		_title_label.add_theme_color_override("font_shadow_color", Color(0.35, 0.12, 0.05, 0.8))
		_title_label.add_theme_constant_override("shadow_offset_x", 2)
		_title_label.add_theme_constant_override("shadow_offset_y", 2)
		_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_title_label)
	_title_label.modulate = Color.WHITE

	if _cd_label == null:
		# CD 秒数/冷却提示，叠在圆心区（就绪时不占用，亮环即就绪语义）。
		_cd_label = Label.new()
		_cd_label.position = Vector2(0.0, 20.0)
		_cd_label.size = Vector2(104.0, 56.0)
		_cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_cd_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_cd_label.add_theme_font_size_override("font_size", 24)
		_cd_label.add_theme_color_override("font_color", Color(1.0, 0.97, 0.91))
		_cd_label.add_theme_color_override("font_shadow_color", Color(0.35, 0.12, 0.05, 0.8))
		_cd_label.add_theme_constant_override("shadow_offset_x", 2)
		_cd_label.add_theme_constant_override("shadow_offset_y", 2)
		_cd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_cd_label)
	_cd_label.text = ""

	if _gesture_label == null:
		_gesture_label = Label.new()
		_gesture_label.text = gesture
		_gesture_label.position = Vector2(0.0, 94.0)
		_gesture_label.size = Vector2(104.0, 24.0)
		_gesture_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_gesture_label.add_theme_font_size_override("font_size", 15)
		_gesture_label.add_theme_color_override("font_color", Color(1.0, 0.97, 0.91, 0.9))
		_gesture_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_gesture_label)
	else:
		_gesture_label.text = gesture
		_gesture_label.modulate = Color.WHITE
	queue_redraw()


## 正常槽位：id 为技能；texture_path 空/资源缺失时用 abbrev 大字标识技能。
func setup(
	id: String,
	texture_path: String,
	cooldown: float,
	color: Color,
	gesture: String,
	abbrev: String = "",
	passive: bool = false
) -> void:
	skill_id = id
	total_cooldown = cooldown
	accent = color
	is_passive = passive
	is_empty_slot = false
	_build_common(gesture)
	var has_art: bool = texture_path != "" and ResourceLoader.exists(texture_path)
	_icon.visible = has_art
	_title_label.visible = not has_art
	if has_art:
		_icon.texture = load(texture_path) as Texture2D
	else:
		_title_label.text = abbrev
		_title_label.add_theme_color_override("font_color", accent)


## 空槽占位：灰显"—" + 手势标签压暗（提示该手势尚未装备技能）。
func configure_empty(gesture: String) -> void:
	is_empty_slot = true
	skill_id = ""
	total_cooldown = 1.0
	accent = Color(0.66, 0.64, 0.60, 0.55)
	is_passive = false
	_build_common(gesture)
	_icon.visible = false
	_title_label.visible = true
	_title_label.text = "—"
	_title_label.modulate = Color(1.0, 1.0, 1.0, 0.4)
	if _gesture_label != null:
		_gesture_label.modulate = Color(1.0, 1.0, 1.0, 0.4)
	queue_redraw()


func set_cooldown(left: float) -> void:
	cooldown_left = maxf(0.0, left)
	if is_empty_slot:
		return
	if _cd_label != null:
		_cd_label.text = str(ceili(cooldown_left)) if cooldown_left > 0.05 else ""
	var dimmed: bool = cooldown_left > 0.05
	if _icon != null:
		_icon.modulate = Color(0.55, 0.58, 0.62, 0.58) if dimmed else Color.WHITE
	if _title_label != null:
		_title_label.modulate = Color(0.55, 0.58, 0.62, 0.58) if dimmed else Color.WHITE
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
