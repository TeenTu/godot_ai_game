class_name BoomStatsPanel
extends Control
## M8 属性查看面板（design_m8_attributes.md §12）：
## "查看面板"——只展示实际战斗结算函数产出的属性快照，不承担构筑展示、
## 武器装备管理、技能树管理或升级选择。
## 打开时 main 置 get_tree().paused = true，本面板 PROCESS_MODE_ALWAYS 保证
## 暂停期间关闭/返回按钮可用；关闭后恢复战斗。
## 界面文字用英文（ui_subset.ttf 子集字体不含所需中文字形，与现有 HUD 一致）。

signal closed

# §12.4 面板视觉色板。
const COL_MASK: Color = Color(0.094, 0.137, 0.231, 0.72)
const COL_PANEL: Color = Color("18233b")
const COL_CARD: Color = Color("425064")
const COL_TEXT: Color = Color("f4e8d0")
const COL_VALUE: Color = Color("f2b84b")
const COL_CRIT: Color = Color("b84235")
const COL_SKILL: Color = Color("5fc5ad")
const COL_HP_LOW: Color = Color("b84235")  # 朱砂红
const COL_HP_FULL: Color = Color("f4e8d0")  # 米纸白

const PANEL_SIZE: Vector2 = Vector2(640, 980)

## 属性快照提供方（main 注入 BoomGame.stats_snapshot）。
var provider: Callable = Callable()

var _hp_fill: ColorRect
var _hp_text: Label
## 字段 key → 数值 Label（refresh 统一刷新）。
var _value_labels: Dictionary = {}
var _back_btn: Button


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
	panel.position = Vector2(40, 150)
	panel.size = PANEL_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL
	style.set_corner_radius_all(24)
	style.set_border_width_all(3)
	style.border_color = Color(1.0, 0.97, 0.88, 0.4)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var title := Label.new()
	title.text = "KEEPER STATS"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", COL_TEXT)
	title.position = Vector2(40, 28)
	title.size = Vector2(400, 52)
	panel.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Night Patrol Lantern Keeper"
	subtitle.add_theme_font_size_override("font_size", 20)
	subtitle.add_theme_color_override("font_color", Color(COL_TEXT, 0.6))
	subtitle.position = Vector2(40, 76)
	subtitle.size = Vector2(400, 28)
	panel.add_child(subtitle)

	# 右上角关闭按钮：触控区域 ≥64×64（§12.2/§12.4）。
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.position = Vector2(PANEL_SIZE.x - 88, 24)
	close_btn.size = Vector2(64, 64)
	close_btn.add_theme_font_size_override("font_size", 30)
	close_btn.pressed.connect(close)
	panel.add_child(close_btn)

	var y := 124.0
	y = _add_section(panel, "GROWTH", y)
	y = _add_row(panel, "level", "Level", y, COL_VALUE, "%s")
	y = _add_row(panel, "xp", "XP", y, COL_TEXT, "%s / %s")
	y = _add_section(panel, "LIFE", y + 6.0)
	y = _add_row(panel, "hp", "HP", y, COL_VALUE, "%s / %s")
	# 连续血条（§4.3）：米纸白 → 朱砂红 随比例渐变，与 HUD 同数值源。
	var bar_bg := ColorRect.new()
	bar_bg.position = Vector2(40, y + 6.0)
	bar_bg.size = Vector2(560, 26)
	bar_bg.color = Color(0.16, 0.10, 0.10, 0.9)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bar_bg)
	_hp_fill = ColorRect.new()
	_hp_fill.position = Vector2(2, 2)
	_hp_fill.size = Vector2(556, 22)
	_hp_fill.color = COL_HP_FULL
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.add_child(_hp_fill)
	y += 42.0
	y = _add_section(panel, "COMBAT", y + 6.0)
	y = _add_row(panel, "base_attack", "Base Attack", y, COL_TEXT, "%s")
	y = _add_row(panel, "final_attack", "Final Attack", y, COL_VALUE, "%s")
	y = _add_row(panel, "attack_speed", "Attack Speed", y, COL_TEXT, "%s/s")
	y = _add_row(panel, "crit_rate_pct", "Crit Rate", y, COL_CRIT, "%s%%")
	y = _add_row(panel, "crit_dmg_pct", "Crit Damage", y, COL_CRIT, "%s%%")
	y = _add_row(panel, "haste_pct", "Skill Haste", y, COL_SKILL, "+%s%%")
	y = _add_section(panel, "SURVIVAL", y + 6.0)
	y = _add_row(panel, "max_hp", "Max HP", y, COL_TEXT, "%s")
	y = _add_row(panel, "defense", "Defense", y, COL_TEXT, "%s")
	y = _add_row(panel, "mitigation_pct", "Damage Reduction", y, COL_SKILL, "%s%%")
	y = _add_row(panel, "dodge_pct", "Dodge", y, COL_SKILL, "%s%%")
	y = _add_row(panel, "move_speed", "Move Speed", y, COL_TEXT, "%s")

	# 底部"返回战斗"（§12.2 关闭方式之一）。
	_back_btn = Button.new()
	_back_btn.text = "BACK TO BATTLE"
	_back_btn.position = Vector2(120, PANEL_SIZE.y - 92)
	_back_btn.size = Vector2(400, 68)
	_back_btn.add_theme_font_size_override("font_size", 28)
	_back_btn.pressed.connect(close)
	panel.add_child(_back_btn)


func _notification(what: int) -> void:
	# 移动端系统返回键（§12.2）：等价 ESC 关闭。
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and visible:
		close()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()


## 打开面板并按快照刷新全部数值。
func open() -> void:
	visible = true
	refresh()


func close() -> void:
	visible = false
	closed.emit()


## 按 provider 快照刷新（暂停中数值不变，打开/关闭时刷新即可）。
func refresh() -> void:
	if not provider.is_valid():
		return
	var snap: Dictionary = provider.call()
	for key in _value_labels:
		var label := _value_labels[key] as Label
		if not snap.has(key):
			label.text = "-"
			continue
		var fmt: String = label.get_meta("fmt")
		var args: Array = []
		var raw: Variant = snap[key]
		if key == "xp":
			args = [raw, snap.get("xp_next", "-")]
		elif key == "hp":
			args = [raw, snap.get("max_hp", "-")]
		else:
			args = [raw]
		label.text = fmt % args
	var max_hp: float = maxf(1.0, float(snap.get("max_hp", 1)))
	var ratio: float = clampf(float(snap.get("hp", 0)) / max_hp, 0.0, 1.0)
	_hp_fill.size.x = 556.0 * ratio
	_hp_fill.color = COL_HP_LOW.lerp(COL_HP_FULL, ratio)


## 段标题行，返回下一行 y。
func _add_section(parent: Control, text: String, y: float) -> float:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", COL_VALUE)
	l.position = Vector2(40, y)
	l.size = Vector2(560, 34)
	parent.add_child(l)
	# 石板灰分隔线。
	var line := ColorRect.new()
	line.position = Vector2(40, y + 34)
	line.size = Vector2(560, 2)
	line.color = Color(COL_CARD, 0.9)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(line)
	return y + 46.0


## 名值行：名字左对齐、数值右对齐；fmt 存 meta 供 refresh 复用。返回下一行 y。
func _add_row(
	parent: Control, key: String, display: String, y: float, value_color: Color, fmt: String
) -> float:
	var name_label := Label.new()
	name_label.text = display
	name_label.add_theme_font_size_override("font_size", 26)
	name_label.add_theme_color_override("font_color", COL_TEXT)
	name_label.position = Vector2(48, y)
	name_label.size = Vector2(320, 36)
	parent.add_child(name_label)
	var value_label := Label.new()
	value_label.add_theme_font_size_override("font_size", 26)
	value_label.add_theme_color_override("font_color", value_color)
	value_label.position = Vector2(300, y)
	value_label.size = Vector2(292, 36)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.set_meta("fmt", fmt)
	parent.add_child(value_label)
	_value_labels[key] = value_label
	return y + 42.0
