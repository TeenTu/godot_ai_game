class_name BoomWeaponSelect
extends Control
## M5 选武器面板（design_m5_weapons.md §3.3）：开局必经的一层轻量界面，
## 也复用为结算"再来一局"的中转站。全代码构建，720×1280 设计空间竖屏 2 卡竖排。
## 交互：点卡高亮选中（不直接开战）→ 按【开战】发 confirmed(weapon_id)。
## M7R：卡片下方为技能配置区，按当前选中武器显示该武器树 6 技能——
## 已解锁可点击勾选（≤3，MAX_EQUIPPED 不变），未解锁显示价格、点击花跨局金币解锁。
## 纯 UI 层：解锁/装备走注入的 BoomSkillSystem，确认动作由 main.gd 订阅后注入 BoomGame。

signal confirmed(weapon_id: String)

const COL_CREAM: Color = Color("fff6e8")
const COL_GOLD: Color = Color("ffc93c")
const COL_CARD: Color = Color(0.99, 0.52, 0.20, 0.98)
const COL_CARD_DEEP: Color = Color(0.55, 0.14, 0.03, 0.34)
const COL_OVERLAY: Color = Color(0.13, 0.07, 0.04, 0.94)
const COL_ROW_LOCKED: Color = Color(0.24, 0.16, 0.12, 0.85)
const COL_ROW_OPEN: Color = Color(0.86, 0.36, 0.10, 0.92)

## 卡片几何（720 宽设计空间居中 620 卡；M7R 压缩高度给技能配置区让位）。
const CARD_W: float = 620.0
const CARD_H: float = 200.0
const CARD_X: float = 50.0
const CARD_Y0: float = 140.0
const CARD_STEP: float = 215.0
const BTN_POS: Vector2 = Vector2(100.0, 912.0)
const BTN_SIZE: Vector2 = Vector2(520.0, 118.0)
## M7R 技能配置区几何。
const SKILL_HEADER_Y: float = 570.0
const SKILL_ROW_Y0: float = 602.0
const SKILL_ROW_H: float = 42.0
const SKILL_ROW_STEP: float = 46.0

var skill_sys: BoomSkillSystem = null  # main.gd 注入；空时技能区只读隐藏

var _weapons: Array = []
var _selected_id: String = ""
var _cards: Dictionary = {}  # weapon_id -> Button
var _name_labels: Dictionary = {}  # weapon_id -> Label
var _fight_btn: Button
var _skill_rows: Dictionary = {}  # skill_id -> Button（当前武器树 6 行）
var _skill_header: Label


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_weapons = BoomWeapons.all()


func _ready() -> void:
	_build_panel()
	set_selected(BoomWeapons.default_id())


func _build_panel() -> void:
	var bg := ColorRect.new()
	bg.color = COL_OVERLAY
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := _make_label("CHOOSE WEAPON", 46, COL_CREAM)
	title.position = Vector2(0.0, 32.0)
	title.size = Vector2(720.0, 60.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var subtitle := _make_label("New weapon, new playstyle", 20, Color(1.0, 0.94, 0.85, 0.72))
	subtitle.position = Vector2(0.0, 96.0)
	subtitle.size = Vector2(720.0, 30.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	for i in _weapons.size():
		var def := _weapons[i] as BoomWeaponDef
		var card := _build_card(def, Vector2(CARD_X, CARD_Y0 + float(i) * CARD_STEP))
		_cards[def.id] = card
		if i > 0:
			_build_new_badge(card)

	_fight_btn = _build_fight_button()
	_build_skill_panel()
	var note := _make_label("Each weapon has its own 6-skill tree", 17, Color(1.0, 1.0, 1.0, 0.55))
	note.position = Vector2(0.0, 1056.0)
	note.size = Vector2(720.0, 30.0)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _rounded(bg: Color, border: Color, border_w: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	return sb


func _build_card(def: BoomWeaponDef, pos: Vector2) -> Button:
	var btn := Button.new()
	btn.position = pos
	btn.size = Vector2(CARD_W, CARD_H)
	btn.pivot_offset = btn.size * 0.5
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_stylebox_override("normal", _rounded(COL_CARD, Color(1.0, 1.0, 1.0, 0.9), 3, 28))
	btn.add_theme_stylebox_override("hover", btn.get_theme_stylebox("normal").duplicate())
	btn.add_theme_stylebox_override("pressed", btn.get_theme_stylebox("normal").duplicate())
	btn.add_theme_stylebox_override("focus", btn.get_theme_stylebox("normal").duplicate())
	btn.pressed.connect(_on_card_pressed.bind(def.id))
	add_child(btn)

	# 深橙底叠层，模拟"暖橙→深橙"纵向渐变（半透明，不挡点击）。
	var shade := ColorRect.new()
	shade.color = COL_CARD_DEEP
	shade.position = Vector2(0.0, CARD_H - 104.0)
	shade.size = Vector2(CARD_W, 104.0)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(shade)

	# 缩略图：直接用玩家动画 idle 帧 / 图标（§3.3：零额外立绘成本）。
	var thumb := TextureRect.new()
	thumb.position = Vector2(28.0, 30.0)
	thumb.size = Vector2(140.0, 140.0)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(def.icon_path):
		thumb.texture = load(def.icon_path) as Texture2D
	btn.add_child(thumb)

	var name_l := Label.new()
	var fs := 38 if def.display_name.length() <= 10 else 30
	name_l.text = def.display_name
	name_l.add_theme_font_size_override("font_size", fs)
	name_l.add_theme_color_override("font_color", COL_CREAM)
	name_l.position = Vector2(196.0, 26.0)
	name_l.size = Vector2(400.0, 50.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(name_l)
	_name_labels[def.id] = name_l

	var blurb := Label.new()
	blurb.text = def.blurb
	blurb.add_theme_font_size_override("font_size", 20)
	blurb.add_theme_color_override("font_color", Color(1.0, 0.97, 0.9, 0.88))
	blurb.position = Vector2(196.0, 80.0)
	blurb.size = Vector2(400.0, 30.0)
	blurb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(blurb)

	var chips := Label.new()
	chips.text = _stat_text(def)
	chips.add_theme_font_size_override("font_size", 17)
	chips.add_theme_color_override("font_color", Color(0.30, 0.12, 0.04, 0.9))
	chips.position = Vector2(196.0, 118.0)
	chips.size = Vector2(410.0, 70.0)
	chips.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(chips)
	return btn


func _build_new_badge(card: Button) -> void:
	var badge := Label.new()
	badge.text = "NEW"
	badge.add_theme_font_size_override("font_size", 22)
	badge.add_theme_color_override("font_color", Color(0.5, 0.18, 0.0, 1.0))
	badge.position = Vector2(CARD_W - 96.0, 14.0)
	badge.size = Vector2(80.0, 40.0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_theme_color_override("font_outline_color", COL_GOLD)
	badge.add_theme_constant_override("outline_size", 6)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(badge)


func _stat_text(def: BoomWeaponDef) -> String:
	var parts: Array = []
	if def.kind == BoomWeaponDef.AttackKind.RANGED:
		parts.append("RATE %d/s" % int(round(1.0 / maxf(def.fire_cd, 0.001))))
		parts.append("DMG %d" % def.proj_dmg)
	else:
		parts.append("DMG %d" % def.swing_dmg)
		parts.append("ARC %d" % int(def.swing_arc_deg))
	parts.append("SPD %d%%" % int(round(def.move_mult * 100.0)))
	parts.append("HP +%d" % def.max_hp_bonus)
	return " ".join(parts)


func _build_fight_button() -> Button:
	var btn := Button.new()
	btn.position = BTN_POS
	btn.size = BTN_SIZE
	btn.pivot_offset = btn.size * 0.5
	btn.text = "FIGHT!"
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 42)
	btn.add_theme_color_override("font_color", Color(0.42, 0.18, 0.02, 1.0))
	var normal := _rounded(COL_GOLD, Color(1.0, 0.98, 0.9, 0.95), 3, 40)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", normal)
	btn.add_theme_stylebox_override("pressed", normal)
	btn.add_theme_stylebox_override("focus", normal)
	btn.pressed.connect(_on_fight_pressed)
	add_child(btn)
	return btn


func _on_card_pressed(weapon_id: String) -> void:
	set_selected(weapon_id)


## M7R 技能配置区：标题 + 当前武器树 6 行（按钮文本随解锁/装备状态刷新）。
func _build_skill_panel() -> void:
	_skill_header = _make_label("SKILL TREE", 26, COL_GOLD)
	_skill_header.position = Vector2(50.0, SKILL_HEADER_Y)
	_skill_header.size = Vector2(620.0, 32.0)
	for i in BoomSkillSystem.MAX_EQUIPPED * 2:  # 预建 6 行占位，随树刷新
		var row := Button.new()
		row.position = Vector2(50.0, SKILL_ROW_Y0 + float(i) * SKILL_ROW_STEP)
		row.size = Vector2(620.0, SKILL_ROW_H)
		row.focus_mode = Control.FOCUS_NONE
		row.add_theme_font_size_override("font_size", 20)
		row.add_theme_color_override("font_color", COL_CREAM)
		row.add_theme_stylebox_override(
			"normal", _rounded(COL_ROW_OPEN, Color(1.0, 1.0, 1.0, 0.35), 2, 12)
		)
		row.pressed.connect(_on_skill_row_pressed.bind(i))
		add_child(row)
		_skill_rows[i] = row


## 刷新技能行：按当前选中武器的树渲染（解锁态/价格/勾选）。
func _refresh_skill_rows() -> void:
	var ids: Array[String] = []
	if skill_sys != null:
		skill_sys.set_weapon_tree(_selected_id)
		ids = skill_sys.tree_ids()
	for i in _skill_rows:
		var row := _skill_rows[i] as Button
		if row == null:
			continue
		if i >= ids.size():
			row.visible = false
			continue
		row.visible = true
		row.text = _skill_row_text(ids[i])
		var locked: bool = skill_sys != null and not skill_sys.is_unlocked(ids[i])
		var style := _rounded(
			COL_ROW_LOCKED if locked else COL_ROW_OPEN, Color(1.0, 1.0, 1.0, 0.35), 2, 12
		)
		row.add_theme_stylebox_override("normal", style)
		row.add_theme_stylebox_override("hover", style)
		row.add_theme_stylebox_override("pressed", style)
		row.add_theme_stylebox_override("focus", style)


## 单行文案：树序. 名称 + [EQUIPPED]（已勾选）/ 无标记（已解锁）/ [UNLOCK n]（未解锁）。
func _skill_row_text(skill_id: String) -> String:
	if skill_sys == null:
		return skill_id
	var idx := skill_sys.tree_ids().find(skill_id)
	var skill := skill_sys.get_skill(skill_id)
	var name_txt: String = skill.display_name if skill != null else skill_id
	var tag := ""
	if skill_sys.is_unlocked(skill_id):
		if skill_sys.equipped.has(skill_id):
			tag = "  [EQUIPPED]"
	elif skill_sys.unlock_cost(skill_id) > 0:
		tag = "  [UNLOCK %d]" % skill_sys.unlock_cost(skill_id)
	var passive := " (PASSIVE)" if skill != null and skill.is_passive else ""
	return "%d. %s%s%s" % [idx + 1, name_txt, passive, tag]


## 技能行点击：未解锁 → 花跨局金币解锁；已解锁 → 勾选/取消勾选（≤3）。
func _on_skill_row_pressed(index: int) -> void:
	if skill_sys == null or index >= skill_sys.tree_ids().size():
		return
	var skill_id := skill_sys.tree_ids()[index]
	if not skill_sys.is_unlocked(skill_id):
		skill_sys.try_unlock(skill_id)
	elif skill_sys.equipped.has(skill_id):
		skill_sys.unequip(skill_id)
	else:
		skill_sys.equip(skill_id)
	_refresh_skill_rows()


## 当前武器树技能行（play_test / vision-e2e 查询）：skill_id -> Button。
func skill_rows() -> Dictionary:
	return _skill_rows.duplicate()


## 切换选中卡（高亮金色描边 + 放大 1.02；点卡不直接开战，需再按【开战】）。
func set_selected(weapon_id: String) -> void:
	if not _cards.has(weapon_id):
		return
	_selected_id = weapon_id
	for id in _cards:
		var card := _cards[id] as Button
		if card == null:
			continue
		var is_sel: bool = id == weapon_id
		var style := _rounded(
			COL_CARD, COL_GOLD if is_sel else Color(1.0, 1.0, 1.0, 0.55), 5 if is_sel else 3, 28
		)
		card.add_theme_stylebox_override("normal", style)
		card.add_theme_stylebox_override("hover", style)
		card.add_theme_stylebox_override("pressed", style)
		card.add_theme_stylebox_override("focus", style)
		card.modulate = Color(1.0, 1.0, 1.0, 1.0) if is_sel else Color(1.0, 1.0, 1.0, 0.62)
		var tw := create_tween()
		(
			tw
			. tween_property(card, "scale", Vector2(1.02, 1.02) if is_sel else Vector2.ONE, 0.12)
			. set_trans(Tween.TRANS_QUAD)
			. set_ease(Tween.EASE_OUT)
		)
	_refresh_skill_rows()


func _on_fight_pressed() -> void:
	if _selected_id != "":
		confirmed.emit(_selected_id)


## 当前选中的武器 id（main/play_test 可查询）。
func selected_weapon() -> String:
	return _selected_id
