class_name BoomLevelUpPanel
extends Control
## M8 升级三选一卡面板（design_m8_attributes.md §11.3）。
## 获得升级 → 暂停战斗（main 置 get_tree().paused）→ 弹 3 张随机卡 → 玩家选择
## → 经 card_chosen 交给 main 落 BoomGame.apply_level_upgrade → pending 清零后恢复。
## 面板 PROCESS_MODE_ALWAYS：暂停期间卡片仍可点；卡面文案显示固定获得量
## （无"等级 1/2/3"），重复获得直接相加（§11.3）。
## 界面文字用英文（ui_subset.ttf 子集字体不含所需中文字形，与现有 HUD 一致）。

## 玩家点了一张卡（无 sim 绑定的测试路径广播；有 sim 时面板自管消费/续弹/恢复）。
signal card_chosen(kind: String)

# §12.4 面板视觉色板（墨夜蓝 / 石板灰 / 米纸白 / 灯火琥珀 / 朱砂红 / 灵雾青绿）。
const COL_MASK: Color = Color(0.094, 0.137, 0.231, 0.72)
const COL_PANEL: Color = Color("18233b")
const COL_CARD: Color = Color("425064")
const COL_TEXT: Color = Color("f4e8d0")
const COL_VALUE: Color = Color("f2b84b")
const COL_CRIT: Color = Color("b84235")
const COL_SKILL: Color = Color("5fc5ad")

## 升级卡文案表（§11.3 建议文案的英文对应；rare=稀有卡权重同池不特殊处理）。
const CARD_DEFS: Dictionary = {
	"dmg": {"title": "SEAL BREAKER", "desc": "Damage +10%", "color": COL_VALUE},
	"atk_speed": {"title": "LANTERN CHASE", "desc": "Attack Speed +10%", "color": COL_VALUE},
	"crit_rate": {"title": "CINNABAR FLASH", "desc": "Crit Rate +3%", "color": COL_CRIT},
	"crit_dmg": {"title": "EVIL BREAKER", "desc": "Crit Damage +15%", "color": COL_CRIT},
	"haste": {"title": "SPIRIT CYCLE", "desc": "Skill Haste +8%", "color": COL_SKILL},
	"speed": {"title": "LIGHT STEP", "desc": "Move Speed +8%", "color": COL_VALUE},
	"dodge": {"title": "MIST VEIL", "desc": "Dodge +3%", "color": COL_SKILL},
	"heal": {"title": "RELIGHT", "desc": "Restore Full HP", "color": COL_VALUE},
}
const CARD_COUNT: int = 3

## 注入对局后面板自管：选择 → apply_level_upgrade → pending 清零前续弹、清零后恢复战斗。
var sim: BoomGame = null
var _title: Label
var _card_buttons: Array = []  # Button（顺序与 _current_kinds 对应）
var _current_kinds: Array[String] = []


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
	panel.position = Vector2(40, 320)
	panel.size = Vector2(640, 620)
	var style := StyleBoxFlat.new()
	style.bg_color = COL_PANEL
	style.set_corner_radius_all(24)
	style.set_border_width_all(3)
	style.border_color = Color(1.0, 0.97, 0.88, 0.4)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	_title = Label.new()
	_title.text = "LEVEL UP!"
	_title.add_theme_font_size_override("font_size", 44)
	_title.add_theme_color_override("font_color", COL_VALUE)
	_title.position = Vector2(0, 28)
	_title.size = Vector2(640, 56)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(_title)

	var hint := Label.new()
	hint.text = "CHOOSE 1"
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", COL_TEXT)
	hint.position = Vector2(0, 86)
	hint.size = Vector2(640, 30)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(hint)

	for i in CARD_COUNT:
		var btn := Button.new()
		btn.position = Vector2(40, 140 + i * 160)
		btn.size = Vector2(560, 140)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(_on_card_button.bind(i))
		panel.add_child(btn)
		_card_buttons.append(btn)


## 打开/重弹一轮卡片：hp_ratio < 1 时卡池加入"回满生命"（§4.2 满血不生成）。
func open_with(hp_ratio: float) -> void:
	_current_kinds = _draw_kinds(hp_ratio)
	for i in CARD_COUNT:
		var kind: String = _current_kinds[i]
		var def: Dictionary = CARD_DEFS[kind]
		var btn := _card_buttons[i] as Button
		btn.text = "%s\n%s" % [def["title"], def["desc"]]
		btn.add_theme_color_override("font_color", def["color"])
	visible = true


## 本轮 3 张卡的 kind 列表（测试/调试用）。
func current_kinds() -> Array[String]:
	return _current_kinds.duplicate()


## 选择一张卡（按钮回调也走这里）：仅接受本轮展示过的 kind。
func choose(kind: String) -> void:
	if not visible or not _current_kinds.has(kind):
		return
	card_chosen.emit(kind)


func _on_card_button(idx: int) -> void:
	if idx < 0 or idx >= _current_kinds.size():
		return
	var kind: String = _current_kinds[idx]
	if sim == null:
		choose(kind)  # 测试路径：只广播
		return
	sim.apply_level_upgrade(kind)
	if sim.pending_upgrades > 0:
		open_with(float(sim.player.hp) / float(sim.player.max_hp))  # 续弹一轮
		return
	visible = false
	get_tree().paused = false  # 全部消费完，恢复战斗


## 抽 3 张不重复卡：普通池 6 + 稀有闪避 +（受伤时）回灯（§3.1/§4.2）。
func _draw_kinds(hp_ratio: float) -> Array[String]:
	var pool: Array[String] = []
	for kind in CARD_DEFS:
		if kind == BoomStats.KIND_HEAL and hp_ratio >= 1.0:
			continue  # 满血时不生成回灯卡
		pool.append(kind)
	var picked: Array[String] = []
	while picked.size() < CARD_COUNT and not pool.is_empty():
		var idx := randi() % pool.size()
		picked.append(pool[idx])
		pool.remove_at(idx)
	return picked
