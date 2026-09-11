class_name BoomBossPresenter
extends Node
## M11 首领表现协调器：Boss HUD、招式播报、宝箱三选一与暂停生命周期。

const COL_CREAM: Color = Color("f4e8d0")
const COL_GOLD: Color = Color("f2b84b")
const COL_DANGER: Color = Color("b84235")

var game: BoomGame
var skill_system: BoomSkillSystem
var audio: BoomAudio
var cam: BoomCam
var hitnum: BoomHitNum
var auto_choose: bool = false
var reward_choices: Array[Dictionary] = []

var _rebuild_skill_hud: Callable
var _show_toast: Callable
var _show_announce: Callable
var _boss_hud: Control
var _hp_fill: ColorRect
var _hp_text: Label
var _phase_label: Label
var _attack_label: Label
var _reward_panel: BoomBossRewardPanel


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(
	hud: Control,
	p_game: BoomGame,
	p_skill_system: BoomSkillSystem,
	p_audio: BoomAudio,
	p_cam: BoomCam,
	p_hitnum: BoomHitNum,
	p_auto_choose: bool,
	rebuild_skill_hud: Callable,
	show_toast: Callable,
	show_announce: Callable
) -> void:
	game = p_game
	skill_system = p_skill_system
	audio = p_audio
	cam = p_cam
	hitnum = p_hitnum
	auto_choose = p_auto_choose
	_rebuild_skill_hud = rebuild_skill_hud
	_show_toast = show_toast
	_show_announce = show_announce
	_build_hud(hud)
	_connect_game()


func _connect_game() -> void:
	game.boss_spawned.connect(_on_boss_spawned)
	game.boss_attack_telegraphed.connect(_on_attack_telegraphed)
	game.boss_attack_released.connect(_on_attack_released)
	game.boss_phase_changed.connect(_on_phase_changed)
	game.boss_defeated.connect(_on_boss_defeated)


func _build_hud(hud: Control) -> void:
	_boss_hud = Control.new()
	_boss_hud.position = Vector2(40, 190)
	_boss_hud.size = Vector2(640, 116)
	_boss_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_hud.visible = false
	hud.add_child(_boss_hud)
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.08, 0.14, 0.92)
	style.set_corner_radius_all(18)
	style.set_border_width_all(3)
	style.border_color = COL_DANGER
	panel.add_theme_stylebox_override("panel", style)
	_boss_hud.add_child(panel)
	_hp_text = _make_label(panel, BoomBoss.DISPLAY_NAME, 22, COL_CREAM, Vector2(18, 9))
	_hp_text.size = Vector2(454, 30)
	_phase_label = _make_label(panel, "第 1 阶段", 18, COL_GOLD, Vector2(492, 11))
	_phase_label.size = Vector2(128, 26)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var bar_bg := ColorRect.new()
	bar_bg.position = Vector2(18, 44)
	bar_bg.size = Vector2(604, 24)
	bar_bg.color = Color("425064")
	panel.add_child(bar_bg)
	_hp_fill = ColorRect.new()
	_hp_fill.position = Vector2(3, 3)
	_hp_fill.size = Vector2(598, 18)
	_hp_fill.color = COL_DANGER
	bar_bg.add_child(_hp_fill)
	_attack_label = _make_label(panel, "", 20, COL_DANGER, Vector2(0, 76))
	_attack_label.size = Vector2(640, 30)
	_attack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reward_panel = BoomBossRewardPanel.new()
	_reward_panel.reward_chosen.connect(_on_reward_chosen)
	hud.add_child(_reward_panel)


func _make_label(
	parent: Node, text: String, font_size: int, color: Color, position: Vector2
) -> Label:
	var label := Label.new()
	label.text = text
	label.position = position
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _process(_delta: float) -> void:
	refresh()


func refresh() -> void:
	if game == null:
		return
	if BoomBossSystem.is_active(game):
		var active_boss := game.boss
		_boss_hud.visible = true
		var ratio := clampf(float(active_boss.hp) / float(active_boss.max_hp), 0.0, 1.0)
		_hp_fill.size.x = 598.0 * ratio
		_hp_text.text = "%s  %d / %d" % [BoomBoss.DISPLAY_NAME, active_boss.hp, active_boss.max_hp]
		_phase_label.text = "第 %d 阶段" % active_boss.boss_phase
		if active_boss.telegraph_left <= 0.0:
			_attack_label.text = ""
	elif not game.boss_reward_pending:
		_boss_hud.visible = false


func reset() -> void:
	reward_choices.clear()
	if _reward_panel != null:
		_reward_panel.close()
	if _boss_hud != null:
		_boss_hud.visible = false


func debug_state() -> Dictionary:
	var active_boss := game.boss if game != null else null
	var reward_ids: Array[String] = []
	for choice in reward_choices:
		reward_ids.append(String(choice.get("type", "")))
	return {
		"boss_active": game != null and BoomBossSystem.is_active(game),
		"boss_hp": active_boss.hp if active_boss != null else 0,
		"boss_max_hp": active_boss.max_hp if active_boss != null else 0,
		"boss_phase": active_boss.boss_phase if active_boss != null else 0,
		"boss_attack": active_boss.current_attack if active_boss != null else "",
		"boss_telegraph": active_boss.telegraph_left if active_boss != null else 0.0,
		"boss_reward_pending": game != null and game.boss_reward_pending,
		"boss_reward_choices": reward_ids,
	}


func _on_boss_spawned(_boss: BoomBoss) -> void:
	_boss_hud.visible = true
	_show_announce.call(BoomBoss.DISPLAY_NAME, COL_DANGER)
	cam.add_trauma(0.45)


func _on_attack_telegraphed(kind: String, _duration: float) -> void:
	var labels: Dictionary = {
		BoomBoss.ATTACK_GHOSTFIRE: "鬼火扇",
		BoomBoss.ATTACK_DASH: "魂掠",
		BoomBoss.ATTACK_LANTERN_ARRAY: "灯阵",
	}
	_attack_label.text = "!  %s  !" % String(labels.get(kind, kind.to_upper()))
	_attack_label.add_theme_color_override("font_color", COL_DANGER)


func _on_attack_released(kind: String, pos: Vector3) -> void:
	if kind == BoomBoss.ATTACK_GHOSTFIRE:
		audio.play("shoot", -6.0)
		cam.add_trauma(0.22)
	elif kind == BoomBoss.ATTACK_DASH:
		audio.play("graze", -5.0)
		cam.add_trauma(0.38)
	else:
		audio.play("wave", -7.0)
		cam.add_trauma(0.30)
	if hitnum != null:
		hitnum.spawn(pos + Vector3(0.0, 1.6, 0.0), "!", COL_DANGER, 1.35)


func _on_phase_changed(phase_index: int) -> void:
	_show_announce.call("无常 · 第 %d 阶段" % phase_index, COL_DANGER)
	cam.add_trauma(0.55)


func _on_boss_defeated(encounter_index: int, _pos: Vector3) -> void:
	_boss_hud.visible = false
	reward_choices = BoomBossRewards.build_choices(skill_system, encounter_index)
	if auto_choose:
		_on_reward_chosen(reward_choices[0])
		return
	get_tree().paused = true
	_reward_panel.open_with(reward_choices)


func _on_reward_chosen(choice: Dictionary) -> void:
	if game == null or not game.boss_reward_pending:
		return
	if not BoomBossRewards.apply(choice, game, skill_system):
		return
	var title := String(choice.get("title", "首领奖励"))
	_reward_panel.close()
	BoomBossSystem.complete_reward(game, String(choice.get("type", "")))
	reward_choices.clear()
	_rebuild_skill_hud.call()
	get_tree().paused = false
	_show_toast.call("奖励 · %s" % title)
