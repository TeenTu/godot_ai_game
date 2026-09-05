class_name StartMenu
extends Control
## start_menu.gd — 网页内入口（REQ-AI-01）：教学/战斗 + seed 控制 + 简报。
##
## 教学（stage1_basic_passive）：无 enemy_spawn/doctrine，纯被动探测流程；
## 战斗（s1_combat）：随机出生敌方 + doctrine 反击闭环。seed 决定敌方出生
## 与声学随机流——同 seed 重玩复现同一局面（AI-1 验收锚点）。
##
## 选择结果经 UiContract.set_startup_override 写 SceneTree meta（无 static
## var），main.gd 据此装配/重建 SonarUI。

signal start_requested(scenario: String, seed_val: int)

var _btn_replay: Button = null
var _lbl_seed: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.06, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(620, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	var title := Label.new()
	title.text = "SONAR — 阶段一"
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	var brief := Label.new()
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.custom_minimum_size = Vector2(620, 0)
	brief.text = (
		"简报：教学局为被动探测流程（无敌方接触）；战斗局由声呐定位随机出生"
		+ "的敌方潜艇并防其反击。seed 决定敌方出生位置与声学随机流："
		+ "「新一局」抽随机 seed，「重玩同 seed」复现上一局完全相同的局面。"
		+ "游戏内按 M 返回本菜单。"
	)
	box.add_child(brief)
	box.add_child(
		_mk_btn("教学 · 被动探测（无敌方）", func() -> void: _start(UiContract.DEFAULT_SCENARIO, -1))
	)
	box.add_child(
		_mk_btn(
			"战斗 · 新一局（随机 seed）", func() -> void: _start(UiContract.COMBAT_SCENARIO, _random_seed())
		)
	)
	_btn_replay = _mk_btn(
		"战斗 · 重玩同 seed", func() -> void: _start(UiContract.COMBAT_SCENARIO, UiContract.last_seed())
	)
	box.add_child(_btn_replay)
	_lbl_seed = Label.new()
	box.add_child(_lbl_seed)
	_refresh_replay()


## 每次显示时刷新重玩按钮可用性与 seed 显示（重玩上一局）。
func refresh_state() -> void:
	if _btn_replay != null:
		_refresh_replay()


func _refresh_replay() -> void:
	var last: int = UiContract.last_seed()
	_btn_replay.disabled = last < 0
	_lbl_seed.text = "上一局战斗 seed：%s" % (str(last) if last >= 0 else "—（先开一局战斗）")


func _mk_btn(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(on_pressed)
	return b


func _start(scenario: String, seed_val: int) -> void:
	start_requested.emit(scenario, seed_val)


func _random_seed() -> int:
	return randi() % 2147483647
