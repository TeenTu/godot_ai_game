extends Control

## 主场景：构建全部 UI 并驱动 FoundryGame（移动端竖屏 720x1280·买量美术风）。
##
## 改良落地：PREPARE 单阶段(买卡+放置+选工位一屏完成)、放置实时产出预估、
## 结算飘字+建筑脉冲、动态难度(核心逻辑层)、第一回合新手引导。

const COLOR_TEXT := Color("#2B2B2B")
const COLOR_TEXT_LIGHT := Color("#FFFFFF")
const COLOR_PANEL := Color(0.98, 0.93, 0.82, 0.96)  # 米色面板
const COLOR_PANEL_DARK := Color(0.55, 0.32, 0.16, 0.85)  # 深棕面板
const COLOR_BTN := Color("#FF8A3D")  # 主按钮橙
const COLOR_BTN_ALT := Color("#FFD23F")  # 次按钮黄
const COLOR_GOLD := Color("#FFC93C")
const COLOR_POWER := Color("#FF4D4D")
const COLOR_WORKER := Color("#4CD964")
const COLOR_ENERGY := Color("#4A9DFF")
const COLOR_ACTIVATED := Color("#2B7A3B")
const COLOR_BORDER := Color("#2B2B2B")

const GRID := Vector2i(4, 5)
const CELL := 112
const GAP := 8
const GRID_W := GRID.x * CELL + (GRID.x - 1) * GAP  # 472
const GRID_H := GRID.y * CELL + (GRID.y - 1) * GAP  # 592
const GRID_X := (720 - GRID_W) / 2  # 124
const GRID_Y := 168
const PREVIEW_OFFSET := Vector2(-54, -96)

var game: FoundryGame
var _state: Dictionary = {}
var _nodes: Dictionary = {}
var _dragged_preview: Control
var _icon_textures: Dictionary = {}
var _bg_texture: Texture2D
var _vs_played_round: int = 0  # 本局已播放过 VS 动画的回合号（防重播）
var _vs_animating: bool = false
var _sfx: Dictionary = {}


func _ready() -> void:
	game = FoundryGame.new(0, {})
	_state = game.to_dict()
	_bg_texture = _try_load_tex("res://assets/bg/bg_workshop.png")
	_load_sfx()
	print("[Backpack Foundry v2.0] buy-game art + VS overlay (build=%s)" % _check_art_status())
	_build_ui()
	_rebuild()
	set_process(true)
	_test_hook_connect()


## 加载程序化生成的 8-bit 音效（tools/gen_sfx.py 产出）
func _load_sfx() -> void:
	for n in ["click", "coin", "place", "go", "win", "lose", "vs"]:
		_sfx[n] = _try_load_audio("res://assets/audio/sfx_%s.wav" % n)


func _try_load_audio(path: String) -> AudioStream:
	if not ResourceLoader.exists(path, "AudioStream"):
		return null
	var t = load(path)
	return t as AudioStream


func _play_sfx(sfx_name: String) -> void:
	var stream: AudioStream = _sfx.get(sfx_name)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "Master"
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


## 启动时检查关键素材是否加载成功，输出到 console（F12 可看）方便用户/我们确认。
func _check_art_status() -> String:
	var ok: Array = []
	var missing: Array = []
	if _bg_texture != null:
		ok.append("bg")
	else:
		missing.append("bg")
	for b in CardDB.BUILDINGS:
		if _get_building_icon(b["id"]) != null:
			ok.append(b["id"])
		else:
			missing.append(b["id"])
	for ui_name in ["icon_coin", "icon_power", "icon_round", "icon_worker"]:
		if _ui_tex(ui_name) != null:
			ok.append(ui_name)
		else:
			missing.append(ui_name)
	if missing.is_empty():
		return "ALL OK (" + ",".join(ok) + ")"
	return "MISSING=" + ",".join(missing)


func _process(_delta: float) -> void:
	if _dragged_preview != null:
		_dragged_preview.position = get_global_mouse_position() + PREVIEW_OFFSET
		_update_preview_est()


# ---------- 加载辅助 ----------


func _try_load_tex(path: String) -> Texture2D:
	# FileAccess.file_exists() does NOT follow .import remaps in exported
	# builds (raw .png is stripped from the pck) -> use ResourceLoader.exists.
	if not ResourceLoader.exists(path, "Texture2D"):
		return null
	var t = load(path)
	if t is Texture2D:
		return t
	return null


func _get_building_icon(id: String) -> Texture2D:
	var key := "building_" + id
	if not _icon_textures.has(key):
		_icon_textures[key] = _try_load_tex(CardDB.building_icon(id))
	return _icon_textures[key]


func _get_action_icon(id: String) -> Texture2D:
	var key := "action_" + id
	if not _icon_textures.has(key):
		_icon_textures[key] = _try_load_tex("res://assets/icons/action_%s.png" % id)
	return _icon_textures[key]


func _family_color(family: String) -> Color:
	var hex: String = CardDB.FAMILY_COLORS.get(family, "#888780")
	return Color(hex)


# ---------- UI 构建 ----------


func _build_ui() -> void:
	if _bg_texture != null:
		var bg := TextureRect.new()
		bg.texture = _bg_texture
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)

	_build_hud()
	_build_opponent()
	_build_grid()
	_build_shop()
	_build_hand()
	_build_action_button()
	_build_guide_label()
	_build_vs_overlay()


func _style_box(fill: Color, radius: int = 16, border_w: int = 3) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _make_panel(parent: Control, pos: Vector2, size: Vector2, dark: bool = false) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = size
	p.add_theme_stylebox_override(
		"panel", _style_box(COLOR_PANEL_DARK if dark else COLOR_PANEL, 18, 2)
	)
	parent.add_child(p)
	return p


func _make_label(
	parent: Control,
	text: String,
	size: int,
	pos: Vector2,
	sz: Vector2,
	color: Color = COLOR_TEXT,
	align: int = HORIZONTAL_ALIGNMENT_LEFT,
) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", COLOR_BORDER)
	l.add_theme_constant_override("outline_size", 2)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l


func _make_btn(
	parent: Control,
	text: String,
	pos: Vector2,
	size: Vector2,
	fill: Color = COLOR_BTN,
	font_size: int = 26,
) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", COLOR_TEXT_LIGHT)
	b.add_theme_color_override("font_outline_color", COLOR_BORDER)
	b.add_theme_constant_override("outline_size", 3)
	b.position = pos
	b.size = size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _style_box(fill, 24, 4))
	b.add_theme_stylebox_override("hover", _style_box(fill.lightened(0.08), 24, 4))
	b.add_theme_stylebox_override("pressed", _style_box(fill.darkened(0.12), 24, 4))
	parent.add_child(b)
	return b


func _ui_tex(name: String) -> Texture2D:
	return _try_load_tex("res://assets/ui/%s.png" % name)


func _build_hud() -> void:
	var bar := _make_panel(self, Vector2(8, 8), Vector2(704, 72), true)
	var items := [
		{"key": "round", "label": "", "icon": "icon_round", "color": COLOR_TEXT_LIGHT},
		{"key": "score", "label": "Score", "icon": "", "color": COLOR_TEXT_LIGHT},
		{"key": "gold", "label": "", "icon": "icon_coin", "color": COLOR_GOLD},
		{"key": "workers", "label": "", "icon": "icon_worker", "color": COLOR_WORKER},
		{"key": "energy", "label": "", "icon": "icon_power", "color": COLOR_ENERGY},
	]
	var x := 12
	for it in items:
		var icon_name: String = it["icon"]
		if icon_name != "":
			var tex := _ui_tex(icon_name)
			if tex != null:
				var tr := TextureRect.new()
				tr.texture = tex
				tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tr.position = Vector2(x, 16)
				tr.size = Vector2(40, 40)
				bar.add_child(tr)
		_nodes["hud_" + it["key"]] = _make_label(
			bar, it["label"] + ": --", 20, Vector2(x + 46, 14), Vector2(90, 44), it["color"]
		)
		x += 136


func _build_opponent() -> void:
	var bar := _make_panel(self, Vector2(8, 88), Vector2(704, 64))
	_nodes["opp_name"] = _make_label(bar, "", 20, Vector2(16, 8), Vector2(220, 48))
	_nodes["opp_type"] = _make_label(bar, "", 16, Vector2(240, 8), Vector2(140, 48))
	_nodes["opp_pow"] = _make_label(
		bar, "", 18, Vector2(390, 8), Vector2(306, 48), COLOR_POWER, HORIZONTAL_ALIGNMENT_RIGHT
	)


func _build_grid() -> void:
	var panel := _make_panel(
		self, Vector2(GRID_X - 10, GRID_Y - 10), Vector2(GRID_W + 20, GRID_H + 20)
	)
	for y in GRID.y:
		for x in GRID.x:
			var cell := Button.new()
			cell.position = Vector2(10 + x * (CELL + GAP), 10 + y * (CELL + GAP))
			cell.size = Vector2(CELL, CELL)
			cell.focus_mode = Control.FOCUS_NONE
			cell.add_theme_stylebox_override("normal", _style_box(Color("#F5E6C8"), 14, 2))
			cell.pressed.connect(_on_grid_pressed.bind(Vector2i(x, y)))
			panel.add_child(cell)
			_nodes["cell_%d_%d" % [x, y]] = cell


func _build_shop() -> void:
	var panel := _make_panel(self, Vector2(8, 792), Vector2(704, 196), true)
	_nodes["shop_panel"] = panel
	_nodes["shop_title"] = _make_label(
		panel, "Shop", 22, Vector2(16, 10), Vector2(100, 36), COLOR_GOLD
	)
	for i in 3:
		var card := Button.new()
		card.position = Vector2(16 + i * 228, 56)
		card.size = Vector2(212, 128)
		card.focus_mode = Control.FOCUS_NONE
		card.add_theme_stylebox_override("normal", _style_box(Color("#FFF3D6"), 16, 3))
		card.pressed.connect(_on_shop_pressed.bind(i))
		panel.add_child(card)
		_nodes["shop_%d" % i] = card


func _build_hand() -> void:
	var panel := _make_panel(self, Vector2(8, 996), Vector2(704, 188), true)
	_nodes["hand_panel"] = panel
	_nodes["hand_title"] = _make_label(
		panel, "Hand", 22, Vector2(16, 8), Vector2(100, 32), COLOR_TEXT_LIGHT
	)
	for i in 5:
		var card := Button.new()
		card.position = Vector2(16 + i * 136, 44)
		card.size = Vector2(128, 132)
		card.focus_mode = Control.FOCUS_NONE
		card.add_theme_stylebox_override("normal", _style_box(Color("#FFF3D6"), 12, 2))
		card.pressed.connect(_on_hand_pressed.bind(i))
		panel.add_child(card)
		_nodes["hand_%d" % i] = card


func _build_action_button() -> void:
	var btn := _make_btn(self, "Go!", Vector2(150, 1204), Vector2(420, 64), COLOR_BTN)
	btn.pressed.connect(_on_action_pressed)
	_nodes["btn_action"] = btn


func _build_guide_label() -> void:
	_nodes["guide"] = _make_label(
		self,
		"",
		18,
		Vector2(40, 158),
		Vector2(640, 34),
		COLOR_TEXT_LIGHT,
		HORIZONTAL_ALIGNMENT_CENTER
	)


# ---------- 状态刷新 ----------


func _rebuild() -> void:
	_state = game.to_dict()
	_refresh_hud()
	_refresh_opponent()
	_refresh_grid()
	_refresh_shop()
	_refresh_hand()
	_refresh_action_button()
	_refresh_guide()
	_refresh_vs_overlay()
	if game.taken_card.is_empty():
		_hide_dragged_preview()
	elif _dragged_preview == null:
		_show_dragged_preview()


func _refresh_hud() -> void:
	_set_text("hud_round", "R%d/%d" % [_state["round"], _state["total_rounds"]])
	_set_text("hud_score", "%d:%d" % [_state["my_score"], _state["ghost_score"]])
	_set_text("hud_gold", "%d" % _state["gold"])
	_set_text("hud_workers", "%d/%d" % [_state["used_workers"], _state["workers"]])
	_set_text("hud_energy", "%d" % _state["energy"])


func _refresh_opponent() -> void:
	_set_text("opp_name", "%s D%d" % [_state["ghost_name"], _state["ghost_diff"]])
	_set_text("opp_type", "Style: " + str(_state["ghost_build"]))
	if game.phase == FoundryGame.Phase.VS or game.phase == FoundryGame.Phase.GAME_OVER:
		_set_text(
			"opp_pow", "You %d  vs  Ghost %d" % [_state["round_power"], _state["ghost_round_power"]]
		)
	else:
		_set_text("opp_pow", "Ghost mirrors your power")


func _refresh_grid() -> void:
	var cells: Array = _state["board_cells"]
	for y in GRID.y:
		for x in GRID.x:
			var btn: Button = _nodes["cell_%d_%d" % [x, y]]
			btn.icon = null
			btn.text = ""
			btn.add_theme_stylebox_override("normal", _style_box(Color("#F5E6C8"), 14, 2))
	var active_arr: Array = _state["active"]
	for i in cells.size():
		if cells[i] == null:
			continue
		var b: Dictionary = cells[i]
		var origin: Vector2i = b["pos"]
		var btn: Button = _nodes["cell_%d_%d" % [origin.x, origin.y]]
		var tex := _get_building_icon(b["id"])
		if tex != null:
			btn.icon = tex
			btn.expand_icon = true
		var card: Dictionary = CardDB.get_building(b["id"])
		var fill := _family_color(card["family"])
		if active_arr.has("%d,%d" % [origin.x, origin.y]):
			btn.add_theme_stylebox_override(
				"normal", _style_box(fill, 14, 5).with_border_color(COLOR_ACTIVATED)
			)
			var w_idx := active_arr.find("%d,%d" % [origin.x, origin.y])
			var badge := _make_label(
				btn,
				str(w_idx + 1),
				20,
				Vector2(6, 6),
				Vector2(28, 28),
				COLOR_TEXT_LIGHT,
				HORIZONTAL_ALIGNMENT_CENTER
			)
			badge.modulate = Color(1, 1, 1, 0.9)
		else:
			btn.add_theme_stylebox_override("normal", _style_box(fill.darkened(0.18), 14, 2))


func _refresh_shop() -> void:
	if game.phase != FoundryGame.Phase.PREPARE:
		(_nodes["shop_panel"]).visible = false
		return
	(_nodes["shop_panel"]).visible = true
	for i in 3:
		var btn: Button = _nodes["shop_%d" % i]
		btn.icon = null
		btn.text = ""
		btn.modulate = Color.WHITE
		for c in btn.get_children():
			c.queue_free()
		if i >= _state["shop"].size():
			continue
		var card: Dictionary = _state["shop"][i]
		var tex := _get_building_icon(card["id"])
		if tex != null:
			btn.icon = tex
			btn.expand_icon = true
		btn.add_theme_stylebox_override("normal", _style_box(_family_color(card["family"]), 16, 3))
		var price := _make_label(
			btn,
			str(card["cost"]) + "G",
			18,
			Vector2(6, 6),
			Vector2(60, 30),
			COLOR_TEXT_LIGHT,
			HORIZONTAL_ALIGNMENT_CENTER
		)
		price.add_theme_stylebox_override("normal", _style_box(COLOR_GOLD, 12, 2))
		if _state["gold"] < int(card["cost"]) or not game.taken_card.is_empty():
			btn.modulate = Color(1, 1, 1, 0.45)


func _refresh_hand() -> void:
	if game.phase != FoundryGame.Phase.PLAY:
		(_nodes["hand_panel"]).visible = false
		return
	(_nodes["hand_panel"]).visible = true
	for i in 5:
		var btn: Button = _nodes["hand_%d" % i]
		btn.icon = null
		btn.text = ""
		btn.modulate = Color.WHITE
		for c in btn.get_children():
			c.queue_free()
		if i >= _state["hand"].size():
			continue
		var aid: String = _state["hand"][i]
		var card: Dictionary = CardDB.get_action(aid)
		btn.add_theme_stylebox_override("normal", _style_box(Color("#FFF3D6"), 12, 2))
		# 动作卡图标：右上角小图（加载不到就跳过，不影响布局）
		var atex := _get_action_icon(aid)
		if atex != null:
			var tr := TextureRect.new()
			tr.texture = atex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.position = Vector2(76, 6)
			tr.size = Vector2(44, 44)
			btn.add_child(tr)
		var name_lbl := _make_label(
			btn,
			card["name"],
			16,
			Vector2(4, 6),
			Vector2(72, 44),
			COLOR_TEXT,
			HORIZONTAL_ALIGNMENT_CENTER
		)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		var effect := ""
		var fx_color := COLOR_POWER
		if card["flat_power"] > 0:
			effect = "+%d PWR" % card["flat_power"]
		elif card["mult"] > 1.0:
			effect = "x%.1f" % card["mult"]
		elif card["flat_gold"] > 0:
			effect = "+%d G" % card["flat_gold"]
			fx_color = COLOR_GOLD
		_make_label(
			btn, effect, 22, Vector2(4, 52), Vector2(116, 38), fx_color, HORIZONTAL_ALIGNMENT_CENTER
		)
		_make_label(
			btn,
			"Cost " + str(card["cost"]),
			14,
			Vector2(6, 100),
			Vector2(116, 26),
			COLOR_TEXT.darkened(0.2),
			HORIZONTAL_ALIGNMENT_CENTER
		)
		if _state["energy"] < int(card["cost"]):
			btn.modulate = Color(1, 1, 1, 0.4)


func _refresh_action_button() -> void:
	var btn: Button = _nodes["btn_action"]
	match game.phase:
		FoundryGame.Phase.PREPARE:
			btn.text = "Go!"
			btn.visible = true
			btn.add_theme_stylebox_override("normal", _style_box(COLOR_BTN, 24, 4))
		FoundryGame.Phase.PLAY:
			btn.text = "End Turn"
			btn.visible = true
			btn.add_theme_stylebox_override("normal", _style_box(COLOR_BTN_ALT, 24, 4))
		FoundryGame.Phase.VS, FoundryGame.Phase.GAME_OVER:
			btn.visible = false  # VS / GAME_OVER 阶段由 overlay 接管按钮


func _refresh_guide() -> void:
	var msg := ""
	if game.phase == FoundryGame.Phase.GAME_OVER:
		var ms: int = int(_state["my_score"])
		var gs: int = int(_state["ghost_score"])
		if ms > gs:
			msg = "VICTORY! %d : %d" % [ms, gs]
		elif ms < gs:
			msg = "DEFEAT %d : %d" % [ms, gs]
		else:
			msg = "DRAW %d : %d" % [ms, gs]
	elif game.round == 1 and game.phase == FoundryGame.Phase.PREPARE:
		msg = "Step 1: tap Shop to buy a card -> tap grid to place -> tap Go!"
	elif game.phase == FoundryGame.Phase.PREPARE:
		msg = "Buy/place cards, tap buildings to toggle workers (green = on)"
	elif game.phase == FoundryGame.Phase.PLAY:
		msg = "Play cards (blue = enough energy), then End Turn"
	elif game.phase == FoundryGame.Phase.VS:
		var r: String = str(_state["last_result"])
		if r == "win":
			msg = "Win! %d > %d" % [_state["round_power"], _state["ghost_round_power"]]
		elif r == "lose":
			msg = "Lose! %d < %d" % [_state["round_power"], _state["ghost_round_power"]]
		else:
			msg = "DRAW %d = %d" % [_state["round_power"], _state["ghost_round_power"]]
	_set_text("guide", msg)


func _set_text(key: String, text: String) -> void:
	if _nodes.has(key):
		(_nodes[key] as Label).text = text


# ---------- 拖拽预览 ----------


func _show_dragged_preview() -> void:
	if _dragged_preview != null:
		_dragged_preview.queue_free()
	var card: Dictionary = game.taken_card
	if card.is_empty():
		return
	var preview := Panel.new()
	preview.custom_minimum_size = Vector2(108, 150)
	preview.size = Vector2(108, 150)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_theme_stylebox_override("panel", _style_box(_family_color(card["family"]), 14, 3))
	var tex := _get_building_icon(card["id"])
	if tex != null:
		var icon := TextureRect.new()
		icon.texture = tex
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(6, 6)
		icon.size = Vector2(96, 96)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		preview.add_child(icon)
	var name_lbl := _make_label(
		preview,
		card["name"],
		14,
		Vector2(0, 104),
		Vector2(108, 22),
		COLOR_TEXT_LIGHT,
		HORIZONTAL_ALIGNMENT_CENTER
	)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var est := _make_label(
		preview, "", 13, Vector2(0, 126), Vector2(108, 22), COLOR_GOLD, HORIZONTAL_ALIGNMENT_CENTER
	)
	est.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_nodes["preview_est"] = est
	preview.z_index = 100
	add_child(preview)
	_dragged_preview = preview


func _hide_dragged_preview() -> void:
	if _dragged_preview != null:
		_dragged_preview.queue_free()
		_dragged_preview = null


## 放置实时预估：悬停时计算该位置产出并显示
func _update_preview_est() -> void:
	if _dragged_preview == null or game.taken_card.is_empty():
		return
	var mouse := get_global_mouse_position()
	var cx := int((mouse.x - float(GRID_X)) / float(CELL + GAP))
	var cy := int((mouse.y - float(GRID_Y)) / float(CELL + GAP))
	var out := _preview_output(game.taken_card, Vector2i(cx, cy))
	if _nodes.has("preview_est"):
		var lbl: Label = _nodes["preview_est"]
		if out["gold"] > 0 or out["power"] > 0:
			lbl.text = "+%dG +%dPWR" % [out["gold"], out["power"]]
		else:
			lbl.text = "Cannot place here"


## 试探式计算某位置放置后的产出（不改动棋盘）
func _preview_output(card: Dictionary, pos: Vector2i) -> Dictionary:
	var out := {"gold": 0, "power": 0}
	if not game.board.can_place(card, pos):
		return out
	if game.board.place(card, pos):
		var b: Dictionary = game.board.get_building_at(pos)
		var adj := game.board.count_adjacent(b)
		game.board.remove_at(pos)
		var c: Dictionary = CardDB.get_building(card["id"])
		out["gold"] = int(c["gold"]) + int(c["adj_gold"]) * adj
		out["power"] = int(c["power"]) + int(c["adj_power"]) * adj
	return out


# ---------- 事件 ----------


func _on_grid_pressed(pos: Vector2i) -> void:
	if game.phase == FoundryGame.Phase.PREPARE and not game.taken_card.is_empty():
		if game.place_card(pos):
			_play_sfx("place")
			_pulse_grid(pos)
			_rebuild()
	elif game.phase == FoundryGame.Phase.PREPARE:
		if game.toggle_active(pos):
			_play_sfx("click")
			_rebuild()


func _on_shop_pressed(idx: int) -> void:
	if game.phase != FoundryGame.Phase.PREPARE:
		return
	if game.buy_card(idx):
		_play_sfx("coin")
		_show_dragged_preview()
		_rebuild()


func _on_hand_pressed(idx: int) -> void:
	if game.phase != FoundryGame.Phase.PLAY:
		return
	if game.play_card(idx):
		_play_sfx("vs")
		_spawn_float_text(get_global_mouse_position(), "Played", COLOR_ENERGY)
		_rebuild()


func _on_action_pressed() -> void:
	match game.phase:
		FoundryGame.Phase.PREPARE:
			var before: int = game.gold
			if game.finish_prepare():
				var gain: int = game.gold - before
				_play_sfx("go")
				_pulse_buildings()
				if gain > 0:
					_spawn_float_text(Vector2(360, 860), "Gold +%d" % gain, COLOR_GOLD)
				_rebuild()
		FoundryGame.Phase.PLAY:
			if game.finish_play():
				_play_sfx("go")
				_spawn_float_text(
					Vector2(360, 480), "Power %d" % _state["round_power"], COLOR_POWER
				)
				_rebuild()
		FoundryGame.Phase.VS:
			_play_sfx("click")
			if game.next_round():
				_rebuild()
		FoundryGame.Phase.GAME_OVER:
			_play_sfx("click")
			game = FoundryGame.new(0, {})
			_rebuild()


# ---------- 视觉反馈 ----------


func _pulse_buildings() -> void:
	for b in game.board.get_all_buildings():
		var key := "cell_%d_%d" % [b["pos"].x, b["pos"].y]
		if _nodes.has(key):
			var cell: Button = _nodes[key]
			var tw := create_tween()
			tw.tween_property(cell, "scale", Vector2(1.12, 1.12), 0.12)
			tw.tween_property(cell, "scale", Vector2.ONE, 0.15)


func _pulse_grid(pos: Vector2i) -> void:
	var key := "cell_%d_%d" % [pos.x, pos.y]
	if _nodes.has(key):
		var cell: Button = _nodes[key]
		var tw := create_tween()
		tw.tween_property(cell, "scale", Vector2(1.18, 1.18), 0.1)
		tw.tween_property(cell, "scale", Vector2.ONE, 0.18)


func _spawn_float_text(pos: Vector2, text: String, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", COLOR_BORDER)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = pos
	lbl.size = Vector2(220, 40)
	lbl.z_index = 200
	add_child(lbl)
	var tw := create_tween()
	tw.tween_property(lbl, "position:y", pos.y - 70, 1.0)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, 1.0)
	tw.tween_callback(lbl.queue_free)


# ---------- Test hook ----------


func _test_hook_connect() -> void:
	pass


func _test_hook_get_state() -> Dictionary:
	var s := game.to_dict() if game != null else {}
	return {
		"phase": int(s.get("phase", 0)),
		"round": s.get("round", 0),
		"gold": s.get("gold", 0),
		"my_score": s.get("my_score", 0),
		"ghost_score": s.get("ghost_score", 0),
		"round_power": s.get("round_power", 0),
		"ghost_round_power": s.get("ghost_round_power", 0),
		"is_over": s.get("is_over", false),
		"last_result": s.get("last_result", ""),
		"used_workers": s.get("used_workers", 0),
		"energy": s.get("energy", 0),
		"hand_size": (s.get("hand", []) as Array).size(),
	}


# ---------- VS 结算覆盖层（战力对撞 + 大字结果） ----------


func _build_vs_overlay() -> void:
	var cover := ColorRect.new()
	cover.color = Color(0, 0, 0, 0.55)
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.name = "VSCover"
	add_child(cover)
	_nodes["vs_cover"] = cover

	var panel := Panel.new()
	panel.position = Vector2(80, 380)
	panel.size = Vector2(560, 440)
	panel.add_theme_stylebox_override("panel", _style_box(COLOR_PANEL, 28, 5))
	add_child(panel)
	_nodes["vs_panel"] = panel

	var title := _make_label(
		panel, "", 64, Vector2(20, 16), Vector2(520, 92), COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_nodes["vs_title"] = title

	var you_track := ColorRect.new()
	you_track.color = Color("#3A1D0F")
	you_track.position = Vector2(90, 142)
	you_track.size = Vector2(380, 32)
	panel.add_child(you_track)
	_nodes["vs_you_track"] = you_track
	var you_fill := ColorRect.new()
	you_fill.color = COLOR_POWER
	you_fill.position = Vector2(90, 142)
	you_fill.size = Vector2(0, 32)
	panel.add_child(you_fill)
	_nodes["vs_you_fill"] = you_fill
	_make_label(panel, "You", 26, Vector2(20, 138), Vector2(60, 44))
	var you_num_lbl: Label = _make_label(
		panel, "0", 30, Vector2(478, 138), Vector2(60, 44), COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_nodes["vs_you_num"] = you_num_lbl

	var g_track := ColorRect.new()
	g_track.color = Color("#3A1D0F")
	g_track.position = Vector2(90, 200)
	g_track.size = Vector2(380, 32)
	panel.add_child(g_track)
	_nodes["vs_ghost_track"] = g_track
	var g_fill := ColorRect.new()
	g_fill.color = COLOR_ENERGY
	g_fill.position = Vector2(90, 200)
	g_fill.size = Vector2(0, 32)
	panel.add_child(g_fill)
	_nodes["vs_ghost_fill"] = g_fill
	_make_label(panel, "Ghost", 26, Vector2(20, 196), Vector2(60, 44))
	var ghost_num_lbl: Label = _make_label(
		panel, "0", 30, Vector2(478, 196), Vector2(60, 44), COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	_nodes["vs_ghost_num"] = ghost_num_lbl

	_nodes["vs_score"] = _make_label(
		panel, "", 22, Vector2(20, 248), Vector2(520, 36), COLOR_TEXT, HORIZONTAL_ALIGNMENT_CENTER
	)
	# 幽灵人格台词：让对手"像个人"，输给谁记得住
	_nodes["vs_quote"] = _make_label(
		panel,
		"",
		19,
		Vector2(30, 290),
		Vector2(500, 52),
		COLOR_TEXT.darkened(0.25),
		HORIZONTAL_ALIGNMENT_CENTER
	)

	var btn := _make_btn(
		panel, "Next Round", Vector2(180, 352), Vector2(200, 68), COLOR_BTN_ALT, 30
	)
	btn.pressed.connect(_on_vs_btn)
	_nodes["vs_btn"] = btn

	cover.visible = false
	panel.visible = false


func _refresh_vs_overlay() -> void:
	var cover: ColorRect = _nodes["vs_cover"]
	var panel: Panel = _nodes["vs_panel"]
	if game.phase != FoundryGame.Phase.VS and game.phase != FoundryGame.Phase.GAME_OVER:
		cover.visible = false
		panel.visible = false
		return
	cover.visible = true
	panel.visible = true

	var result: String = str(_state["last_result"])
	var is_final: bool = game.phase == FoundryGame.Phase.GAME_OVER

	if is_final:
		var ms: int = int(_state["my_score"])
		var gs: int = int(_state["ghost_score"])
		if ms > gs:
			_set_text_color("vs_title", "VICTORY!", COLOR_GOLD)
		elif ms < gs:
			_set_text_color("vs_title", "DEFEAT", COLOR_POWER)
		else:
			_set_text_color("vs_title", "DRAW", COLOR_TEXT)
		_set_text("vs_score", "Final  %d : %d" % [ms, gs])
		_set_text("vs_quote", '"%s"  - %s' % [_state.get("ghost_quote", ""), _state["ghost_name"]])
		(_nodes["vs_btn"] as Button).text = "Play Again"
		# GAME_OVER 直接静态显示最终值
		_set_vs_bars(int(_state["round_power"]), int(_state["ghost_round_power"]), result)
	else:
		_set_text_color(
			"vs_title",
			"Win!" if result == "win" else ("Lose!" if result == "lose" else "DRAW"),
			COLOR_GOLD if result == "win" else (COLOR_POWER if result == "lose" else COLOR_TEXT),
		)
		_set_text(
			"vs_score",
			(
				"This Round  You %d  vs  Ghost %d"
				% [_state["round_power"], _state["ghost_round_power"]]
			)
		)
		_set_text("vs_quote", '"%s"  - %s' % [_state.get("ghost_quote", ""), _state["ghost_name"]])
		(_nodes["vs_btn"] as Button).text = "Next Round"
		if _vs_played_round != game.round:
			_vs_played_round = game.round
			_play_vs_anim(int(_state["round_power"]), int(_state["ghost_round_power"]), result)
		else:
			_set_vs_bars(int(_state["round_power"]), int(_state["ghost_round_power"]), result)


## 战力条对撞动画
func _play_vs_anim(you: int, ghost: int, result: String) -> void:
	if _vs_animating:
		return
	_vs_animating = true
	_play_sfx("vs")
	var you_fill: ColorRect = _nodes["vs_you_fill"]
	var ghost_fill: ColorRect = _nodes["vs_ghost_fill"]
	you_fill.size.x = 0
	ghost_fill.size.x = 0
	_set_text("vs_you_num", "0")
	_set_text("vs_ghost_num", "0")
	var max_v: int = maxi(maxi(you, ghost), 1)
	var track_w: float = (_nodes["vs_you_track"] as ColorRect).size.x
	var tw := create_tween().set_parallel(true)
	tw.tween_property(you_fill, "size:x", track_w * float(you) / float(max_v), 0.6)
	tw.tween_property(ghost_fill, "size:x", track_w * float(ghost) / float(max_v), 0.6)
	tw.tween_method(_tween_you_num, 0.0, float(you), 0.6)
	tw.tween_method(_tween_ghost_num, 0.0, float(ghost), 0.6)
	tw.chain().tween_callback(func() -> void: _vs_animating = false)
	if result == "win":
		tw.tween_property(you_fill, "modulate", COLOR_GOLD, 0.1)
		tw.tween_property(you_fill, "modulate", Color.WHITE, 0.25)
		tw.tween_property(ghost_fill, "modulate", Color(0.55, 0.55, 0.55), 0.3)
		tw.tween_callback(func() -> void: _play_sfx("win"))
	elif result == "lose":
		tw.tween_property(ghost_fill, "modulate", COLOR_GOLD, 0.1)
		tw.tween_property(ghost_fill, "modulate", Color.WHITE, 0.25)
		tw.tween_property(you_fill, "modulate", Color(0.55, 0.55, 0.55), 0.3)
		tw.tween_callback(func() -> void: _play_sfx("lose"))


func _tween_you_num(v: float) -> void:
	_set_text("vs_you_num", str(int(round(v))))


func _tween_ghost_num(v: float) -> void:
	_set_text("vs_ghost_num", str(int(round(v))))


func _set_vs_bars(you: int, ghost: int, result: String) -> void:
	var max_v: int = maxi(maxi(you, ghost), 1)
	var track_w: float = (_nodes["vs_you_track"] as ColorRect).size.x
	(_nodes["vs_you_fill"] as ColorRect).size.x = track_w * float(you) / float(max_v)
	(_nodes["vs_ghost_fill"] as ColorRect).size.x = track_w * float(ghost) / float(max_v)
	_set_text("vs_you_num", str(you))
	_set_text("vs_ghost_num", str(ghost))
	if result == "win":
		(_nodes["vs_you_fill"] as ColorRect).color = COLOR_GOLD
	elif result == "lose":
		(_nodes["vs_ghost_fill"] as ColorRect).color = COLOR_GOLD


func _set_text_color(key: String, text: String, color: Color) -> void:
	if _nodes.has(key):
		var l: Label = _nodes[key]
		l.text = text
		l.add_theme_color_override("font_color", color)


func _on_vs_btn() -> void:
	if game.phase == FoundryGame.Phase.VS:
		_vs_played_round = 0
		if game.next_round():
			_rebuild()
	elif game.phase == FoundryGame.Phase.GAME_OVER:
		_vs_played_round = 0
		game = FoundryGame.new(0, {})
		_rebuild()
