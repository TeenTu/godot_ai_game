class_name BoomBossRewardPanel
extends Control
## M11 首领宝箱三选一。暂停期间仍接收 UI 输入。

signal reward_chosen(choice: Dictionary)

const CARD_COUNT: int = 3
const COL_MASK: Color = Color(0.094, 0.137, 0.231, 0.78)
const COL_PANEL: Color = Color("18233b")
const COL_CARD: Color = Color("314a78")
const COL_TEXT: Color = Color("f4e8d0")
const COL_GOLD: Color = Color("f2b84b")
const COL_SPIRIT: Color = Color("5fc5ad")

var _choices: Array[Dictionary] = []
var _buttons: Array[Button] = []
var _icons: Array[TextureRect] = []
var _titles: Array[Label] = []
var _descs: Array[Label] = []


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var mask := ColorRect.new()
	mask.color = COL_MASK
	mask.set_anchors_preset(Control.PRESET_FULL_RECT)
	mask.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(mask)
	var panel := Panel.new()
	panel.position = Vector2(34, 238)
	panel.size = Vector2(652, 790)
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL
	style.set_corner_radius_all(28)
	style.set_border_width_all(4)
	style.border_color = COL_GOLD
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var title := Label.new()
	title.text = "首领取宝"
	title.position = Vector2(0, 34)
	title.size = Vector2(652, 58)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", COL_GOLD)
	panel.add_child(title)
	var hint := Label.new()
	hint.text = "择一印"
	hint.position = Vector2(0, 94)
	hint.size = Vector2(652, 34)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", COL_TEXT)
	panel.add_child(hint)
	for index in CARD_COUNT:
		_build_card(panel, index)


func _build_card(panel: Control, index: int) -> void:
	var card := Panel.new()
	card.position = Vector2(30, 150 + index * 196)
	card.size = Vector2(592, 174)
	var style := StyleBoxFlat.new()
	style.bg_color = COL_CARD
	style.set_corner_radius_all(18)
	style.set_border_width_all(2)
	style.border_color = Color(0.95, 0.91, 0.82, 0.35)
	card.add_theme_stylebox_override("panel", style)
	panel.add_child(card)
	var icon := TextureRect.new()
	icon.position = Vector2(20, 23)
	icon.size = Vector2(128, 128)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(icon)
	_icons.append(icon)
	var title := Label.new()
	title.position = Vector2(164, 30)
	title.size = Vector2(400, 42)
	title.add_theme_font_size_override("font_size", 27)
	title.add_theme_color_override("font_color", COL_GOLD if index < 2 else COL_SPIRIT)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(title)
	_titles.append(title)
	var desc := Label.new()
	desc.position = Vector2(164, 78)
	desc.size = Vector2(392, 70)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 19)
	desc.add_theme_color_override("font_color", COL_TEXT)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(desc)
	_descs.append(desc)
	var button := Button.new()
	button.flat = true
	button.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_card_pressed.bind(index))
	card.add_child(button)
	_buttons.append(button)


func open_with(choices: Array[Dictionary]) -> void:
	if choices.size() != CARD_COUNT:
		return
	_choices = choices.duplicate(true)
	for index in CARD_COUNT:
		var choice: Dictionary = _choices[index]
		(_titles[index] as Label).text = String(choice.get("title", ""))
		(_descs[index] as Label).text = String(choice.get("desc", ""))
		var icon_path := String(choice.get("icon", ""))
		(_icons[index] as TextureRect).texture = (
			load(icon_path) as Texture2D if ResourceLoader.exists(icon_path) else null
		)
	visible = true


func current_choices() -> Array[Dictionary]:
	return _choices.duplicate(true)


func choose(index: int) -> void:
	if not visible or index < 0 or index >= _choices.size():
		return
	reward_chosen.emit(_choices[index])


func close() -> void:
	visible = false
	_choices.clear()


func _on_card_pressed(index: int) -> void:
	choose(index)
