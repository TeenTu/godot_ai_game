class_name FoundryVsOverlay
extends RefCounted
## VS 结算覆盖层：半透明遮罩 + 战力对撞动画 + 大字结果 + 幽灵台词。
## 从 main.gd 拆出（gdlint max-file-lines=1000），通过回调解耦：
## - on_next: 玩家点 "Next Round"/"Play Again" 时回调 main 处理游戏逻辑
## - sfx_cb: 播放音效（"vs"/"win"/"lose"），由 main 的 FoundryAudio 处理

const COLOR_TEXT := Color("#2B2B2B")
const COLOR_TEXT_LIGHT := Color("#FFFFFF")
const COLOR_PANEL := Color(0.98, 0.93, 0.82, 0.96)  # 米色面板
const COLOR_BTN_ALT := Color("#FFD23F")  # 次按钮黄
const COLOR_GOLD := Color("#FFC93C")
const COLOR_POWER := Color("#FF4D4D")
const COLOR_ENERGY := Color("#4A9DFF")
const COLOR_BORDER := Color("#2B2B2B")

var _root: Control
var _nodes: Dictionary = {}
var _played_round: int = 0  # 已播放过对撞动画的回合号（防重播）
var _animating: bool = false
var _on_next: Callable
var _sfx: Callable


func setup(root: Control, on_next: Callable, sfx_cb: Callable) -> void:
	_root = root
	_on_next = on_next
	_sfx = sfx_cb
	_build()


func refresh(state: Dictionary, phase: int, round_no: int) -> void:
	var cover: ColorRect = _nodes["cover"]
	var panel: Panel = _nodes["panel"]
	if phase != FoundryGame.Phase.VS and phase != FoundryGame.Phase.GAME_OVER:
		cover.visible = false
		panel.visible = false
		return
	cover.visible = true
	panel.visible = true

	var result: String = str(state["last_result"])
	if phase == FoundryGame.Phase.GAME_OVER:
		var ms: int = int(state["my_score"])
		var gs: int = int(state["ghost_score"])
		if ms > gs:
			_label_color("title", "VICTORY!", COLOR_GOLD)
		elif ms < gs:
			_label_color("title", "DEFEAT", COLOR_POWER)
		else:
			_label_color("title", "DRAW", COLOR_TEXT)
		_txt("score", "Final  %d : %d" % [ms, gs])
		_txt("quote", _quote_of(state))
		(_nodes["btn"] as Button).text = "Play Again"
		# GAME_OVER 直接静态显示最终值
		_set_bars(int(state["round_power"]), int(state["ghost_round_power"]), result)
	else:
		_label_color(
			"title",
			"Win!" if result == "win" else ("Lose!" if result == "lose" else "DRAW"),
			COLOR_GOLD if result == "win" else (COLOR_POWER if result == "lose" else COLOR_TEXT),
		)
		_txt(
			"score",
			"This Round  You %d  vs  Ghost %d" % [state["round_power"], state["ghost_round_power"]]
		)
		_txt("quote", _quote_of(state))
		(_nodes["btn"] as Button).text = "Next Round"
		if _played_round != round_no:
			_played_round = round_no
			_play_anim(int(state["round_power"]), int(state["ghost_round_power"]), result)
		else:
			_set_bars(int(state["round_power"]), int(state["ghost_round_power"]), result)


func _quote_of(state: Dictionary) -> String:
	return '"%s"  - %s' % [state.get("ghost_quote", ""), state["ghost_name"]]


func _build() -> void:
	var cover := ColorRect.new()
	cover.color = Color(0, 0, 0, 0.55)
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.name = "VSCover"
	_root.add_child(cover)
	_nodes["cover"] = cover

	var panel := Panel.new()
	panel.position = Vector2(80, 380)
	panel.size = Vector2(560, 440)
	panel.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(panel)
	_nodes["panel"] = panel

	_nodes["title"] = _label(panel, "", 64, Vector2(20, 16), Vector2(520, 92))

	_bar("you", COLOR_POWER, 142)
	_bar("ghost", COLOR_ENERGY, 200)

	_nodes["score"] = _label(panel, "", 22, Vector2(20, 248), Vector2(520, 36))
	# 幽灵人格台词：让对手"像个人"，输给谁记得住
	_nodes["quote"] = _label(
		panel, "", 19, Vector2(30, 290), Vector2(500, 52), COLOR_TEXT.darkened(0.25)
	)

	var btn := _button(panel, "Next Round", Vector2(180, 352), Vector2(200, 68))
	btn.pressed.connect(_on_btn)
	_nodes["btn"] = btn

	cover.visible = false
	panel.visible = false


## 一条战力条：轨道 + 填充 + 名称 + 数字（key 前缀区分 you/ghost）
func _bar(key: String, fill_color: Color, y: float) -> void:
	var panel: Panel = _nodes["panel"]
	var track := ColorRect.new()
	track.color = Color("#3A1D0F")
	track.position = Vector2(90, y)
	track.size = Vector2(380, 32)
	panel.add_child(track)
	_nodes[key + "_track"] = track
	var fill := ColorRect.new()
	fill.color = fill_color
	fill.position = Vector2(90, y)
	fill.size = Vector2(0, 32)
	panel.add_child(fill)
	_nodes[key + "_fill"] = fill
	_label(
		panel,
		"You" if key == "you" else "Ghost",
		26,
		Vector2(20, y - 4),
		Vector2(60, 44),
		COLOR_TEXT,
		HORIZONTAL_ALIGNMENT_LEFT
	)
	_nodes[key + "_num"] = _label(panel, "0", 30, Vector2(478, y - 4), Vector2(60, 44), COLOR_TEXT)


## 战力条对撞动画：双条增长 + 数字滚动 + 胜负反馈（音效/震屏/撒花）
func _play_anim(you: int, ghost: int, result: String) -> void:
	if _animating:
		return
	_animating = true
	if _sfx.is_valid():
		_sfx.call("vs")
	FoundryJuice.shake(_root, 6.0, 0.5)
	var you_fill: ColorRect = _nodes["you_fill"]
	var ghost_fill: ColorRect = _nodes["ghost_fill"]
	you_fill.size.x = 0
	ghost_fill.size.x = 0
	_txt("you_num", "0")
	_txt("ghost_num", "0")
	var max_v: int = maxi(maxi(you, ghost), 1)
	var track_w: float = (_nodes["you_track"] as ColorRect).size.x
	var tw := _root.create_tween().set_parallel(true)
	tw.tween_property(you_fill, "size:x", track_w * float(you) / float(max_v), 0.6)
	tw.tween_property(ghost_fill, "size:x", track_w * float(ghost) / float(max_v), 0.6)
	tw.tween_method(_roll_you, 0.0, float(you), 0.6)
	tw.tween_method(_roll_ghost, 0.0, float(ghost), 0.6)
	tw.chain().tween_callback(func() -> void: _animating = false)
	if result == "win":
		tw.tween_property(you_fill, "modulate", COLOR_GOLD, 0.1)
		tw.tween_property(you_fill, "modulate", Color.WHITE, 0.25)
		tw.tween_property(ghost_fill, "modulate", Color(0.55, 0.55, 0.55), 0.3)
		tw.tween_callback(_finish.bind(true))
	elif result == "lose":
		tw.tween_property(ghost_fill, "modulate", COLOR_GOLD, 0.1)
		tw.tween_property(ghost_fill, "modulate", Color.WHITE, 0.25)
		tw.tween_property(you_fill, "modulate", Color(0.55, 0.55, 0.55), 0.3)
		tw.tween_callback(_finish.bind(false))


## 对撞落幕：胜负音 + 赢家撒花 / 输家重震
func _finish(won: bool) -> void:
	if _sfx.is_valid():
		_sfx.call("win" if won else "lose")
	if won:
		FoundryJuice.confetti(_root, Vector2(360, 380))
	else:
		FoundryJuice.shake(_root, 11.0, 0.45)


func _set_bars(you: int, ghost: int, result: String) -> void:
	var max_v: int = maxi(maxi(you, ghost), 1)
	var track_w: float = (_nodes["you_track"] as ColorRect).size.x
	(_nodes["you_fill"] as ColorRect).size.x = track_w * float(you) / float(max_v)
	(_nodes["ghost_fill"] as ColorRect).size.x = track_w * float(ghost) / float(max_v)
	_txt("you_num", str(you))
	_txt("ghost_num", str(ghost))
	if result == "win":
		(_nodes["you_fill"] as ColorRect).color = COLOR_GOLD
	elif result == "lose":
		(_nodes["ghost_fill"] as ColorRect).color = COLOR_GOLD


func _on_btn() -> void:
	_played_round = 0
	if _on_next.is_valid():
		_on_next.call()


func _roll_you(v: float) -> void:
	_txt("you_num", str(int(round(v))))


func _roll_ghost(v: float) -> void:
	_txt("ghost_num", str(int(round(v))))


func _txt(key: String, text: String) -> void:
	if _nodes.has(key):
		(_nodes[key] as Label).text = text


func _label_color(key: String, text: String, color: Color) -> void:
	if _nodes.has(key):
		var l: Label = _nodes[key]
		l.text = text
		l.add_theme_color_override("font_color", color)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(5)
	sb.set_corner_radius_all(28)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _label(
	parent: Control,
	text: String,
	font_size: int,
	pos: Vector2,
	sz: Vector2,
	color: Color = COLOR_TEXT,
	align: int = HORIZONTAL_ALIGNMENT_CENTER,
) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", COLOR_BORDER)
	l.add_theme_constant_override("outline_size", 2)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l


func _btn_style(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(24)
	return sb


func _button(parent: Control, text: String, pos: Vector2, size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", COLOR_TEXT_LIGHT)
	b.add_theme_color_override("font_outline_color", COLOR_BORDER)
	b.add_theme_constant_override("outline_size", 3)
	b.position = pos
	b.size = size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _btn_style(COLOR_BTN_ALT))
	b.add_theme_stylebox_override("hover", _btn_style(COLOR_BTN_ALT.lightened(0.08)))
	b.add_theme_stylebox_override("pressed", _btn_style(COLOR_BTN_ALT.darkened(0.12)))
	parent.add_child(b)
	return b
