extends Control

## 主场景：构建全部 UI 并驱动 FoundryGame。
##
## 所有 UI 都用代码在 _ready() 中构建（_tscn 最小化只挂一个根节点）。
## 状态变化时 _rebuild() 根据 game.to_dict() 全量刷新显示。

const COLOR_BG := Color("#EDE8DC")
const COLOR_PANEL := Color("#FFFDF5")
const COLOR_GRID_EMPTY := Color("#E0D8C2")
const COLOR_GRID_BORDER := Color("#7A6F55")
const COLOR_BAR := Color("#4A4030")
const COLOR_TEXT := Color("#1A1A1A")
const COLOR_TEXT_DIM := Color("#5A5446")
const COLOR_ACTIVATED := Color("#1D9E75")
const COLOR_ADJ_BONUS := Color("#F0997B")
const COLOR_GOLD := Color("#EF9F27")
const COLOR_POWER := Color("#E24B4A")
const COLOR_WORKER := Color("#3B6D11")

const GRID := Vector2i(4, 5)
const CELL := 96
const GAP := 8
const GRID_W := GRID.x * CELL + (GRID.x - 1) * GAP  # 4*96+3*8 = 408
const GRID_H := GRID.y * CELL + (GRID.y - 1) * GAP  # 5*96+4*8 = 512
const GRID_X := 28
const GRID_Y := 80
const PREVIEW_OFFSET := Vector2(-54, -90)

var game: FoundryGame
var _state: Dictionary = {}
var _nodes: Dictionary = {}  # 名字 -> 节点
var _dragged_preview: Control  # 买卡后跟随鼠标的卡预览

# icon 缓存
var _icon_textures: Dictionary = {}
var _bg_texture: Texture2D


func _ready() -> void:
	game = FoundryGame.new(0, {})
	_state = game.to_dict()
	_bg_texture = _try_load_tex("res://assets/bg/bg_workshop.png")
	_build_ui()
	_rebuild()
	set_process(true)  # 用于 _dragged_preview 跟随鼠标
	_test_hook_connect()


func _process(_delta: float) -> void:
	# 拖拽预览跟随鼠标
	if _dragged_preview != null:
		_dragged_preview.position = get_global_mouse_position() + PREVIEW_OFFSET


# ---------- 加载辅助 ----------


func _try_load_tex(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
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


func _family_color(family: String) -> Color:
	var hex: String = CardDB.FAMILY_COLORS.get(family, "#888780")
	return Color(hex)


# ---------- UI 构建 ----------


func _build_ui() -> void:
	# 背景
	if _bg_texture != null:
		var bg := TextureRect.new()
		bg.texture = _bg_texture
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)
	else:
		pass  # 背景留透明，让 bg 透出或保留默认

	# 顶栏
	var top := Panel.new()
	top.position = Vector2(8, 8)
	top.size = Vector2(1264, 60)
	_nodes["top_panel"] = top
	add_child(top)
	_build_hud(top)

	# 版图（左侧）
	var grid_panel := Panel.new()
	grid_panel.position = Vector2(GRID_X - 8, GRID_Y - 8)
	grid_panel.size = Vector2(GRID_W + 16, GRID_H + 16)
	_nodes["grid_panel"] = grid_panel
	add_child(grid_panel)
	_build_grid(grid_panel)

	# 商店（右中）
	var shop_panel := Panel.new()
	shop_panel.position = Vector2(460, 80)
	shop_panel.size = Vector2(360, 240)
	_nodes["shop_panel"] = shop_panel
	add_child(shop_panel)
	_build_shop(shop_panel)

	# 商店下：消息/结算
	var log_panel := Panel.new()
	log_panel.position = Vector2(460, 332)
	log_panel.size = Vector2(360, 64)
	_nodes["log_panel"] = log_panel
	add_child(log_panel)
	_nodes["log_label"] = _make_label(log_panel, "", 14, Vector2(12, 14), Vector2(336, 36))

	# 对手区（右上）
	var opp_panel := Panel.new()
	opp_panel.position = Vector2(840, 80)
	opp_panel.size = Vector2(420, 240)
	_nodes["opp_panel"] = opp_panel
	add_child(opp_panel)
	_build_opponent(opp_panel)

	# 手牌（底部右侧）
	var hand_panel := Panel.new()
	hand_panel.position = Vector2(460, 408)
	hand_panel.size = Vector2(800, 264)
	_nodes["hand_panel"] = hand_panel
	add_child(hand_panel)
	_build_hand(hand_panel)

	# 控制按钮
	_build_action_buttons()


func _build_hud(parent: Control) -> void:
	var items := [
		{"key": "round", "label": "回合", "color": COLOR_BAR},
		{"key": "score", "label": "比分", "color": COLOR_BAR},
		{"key": "gold", "label": "金币", "color": COLOR_GOLD},
		{"key": "workers", "label": "工人", "color": COLOR_WORKER},
		{"key": "energy", "label": "能量", "color": COLOR_POWER},
	]
	var x := 16
	for it in items:
		var lbl := Label.new()
		lbl.text = it["label"] + ": --"
		lbl.add_theme_color_override("font_color", COLOR_TEXT)
		lbl.add_theme_color_override("font_outline_color", COLOR_BG)
		lbl.add_theme_constant_override("outline_size", 4)
		lbl.position = Vector2(x, 16)
		lbl.size = Vector2(160, 28)
		_nodes["hud_" + it["key"]] = lbl
		parent.add_child(lbl)
		x += 200


func _build_grid(parent: Control) -> void:
	for y in GRID.y:
		for x in GRID.x:
			var cell := Button.new()
			cell.position = Vector2(8 + x * (CELL + GAP), 8 + y * (CELL + GAP))
			cell.size = Vector2(CELL, CELL)
			cell.focus_mode = Control.FOCUS_NONE
			cell.pressed.connect(_on_grid_pressed.bind(Vector2i(x, y)))
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			parent.add_child(cell)
			_nodes["cell_%d_%d" % [x, y]] = cell


func _build_shop(parent: Control) -> void:
	var title := _make_label(parent, "商店 (BUILD)", 16, Vector2(12, 8), Vector2(160, 24))
	title.add_theme_color_override("font_color", COLOR_BAR)
	for i in 3:
		var card := Button.new()
		card.position = Vector2(12 + i * 114, 40)
		card.size = Vector2(108, 188)
		card.focus_mode = Control.FOCUS_NONE
		card.pressed.connect(_on_shop_pressed.bind(i))
		parent.add_child(card)
		_nodes["shop_%d" % i] = card


func _build_opponent(parent: Control) -> void:
	var title := _make_label(parent, "对手", 16, Vector2(12, 8), Vector2(200, 24))
	title.add_theme_color_override("font_color", COLOR_BAR)
	_nodes["opp_name"] = _make_label(parent, "", 20, Vector2(12, 36), Vector2(300, 28))
	_nodes["opp_type"] = _make_label(parent, "", 13, Vector2(12, 66), Vector2(200, 20))
	_nodes["opp_pow"] = _make_label(parent, "", 13, Vector2(12, 92), Vector2(380, 20))
	# 战力曲线（条形）背景框
	var chart_bg := ColorRect.new()
	chart_bg.color = Color("#F0E8D2")
	chart_bg.position = Vector2(12, 124)
	chart_bg.size = Vector2(396, 104)
	parent.add_child(chart_bg)
	_nodes["opp_chart_bg"] = chart_bg


func _build_hand(parent: Control) -> void:
	var title := _make_label(parent, "出牌 (PLAY)", 16, Vector2(12, 8), Vector2(200, 24))
	title.add_theme_color_override("font_color", COLOR_BAR)
	for i in 5:
		var card := Button.new()
		card.position = Vector2(12 + i * 152, 40)
		card.size = Vector2(144, 200)
		card.focus_mode = Control.FOCUS_NONE
		card.pressed.connect(_on_hand_pressed.bind(i))
		parent.add_child(card)
		_nodes["hand_%d" % i] = card


func _build_action_buttons() -> void:
	# 4 个阶段按钮叠在底部
	var btn_data := [
		{"key": "build", "label": "完成布局", "y": 690, "color": COLOR_WORKER},
		{"key": "assign", "label": "开动!  ", "y": 690, "color": COLOR_POWER},
		{"key": "play", "label": "结束回合", "y": 690, "color": COLOR_POWER},
		{"key": "next", "label": "下一回合", "y": 690, "color": COLOR_BAR},
		{"key": "again", "label": "再来一局", "y": 690, "color": COLOR_BAR},
	]
	for b in btn_data:
		var btn := Button.new()
		btn.text = b["label"]
		btn.position = Vector2(0, 0)  # 下面统一 set
		btn.size = Vector2(140, 36)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_action_pressed.bind(b["key"]))
		add_child(btn)
		_nodes["btn_" + b["key"]] = btn


func _make_label(parent: Control, text: String, size: int, pos: Vector2, sz: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l


# ---------- 状态刷新 ----------


func _rebuild() -> void:
	_state = game.to_dict()
	_refresh_hud()
	_refresh_grid()
	_refresh_shop()
	_refresh_hand()
	_refresh_opponent()
	_refresh_buttons()
	_refresh_log()
	# 同步拖拽预览
	if game.taken_card.is_empty():
		_hide_dragged_preview()
	elif _dragged_preview == null:
		_show_dragged_preview()


func _refresh_hud() -> void:
	_set_text("hud_round", "回合 %d / %d" % [_state["round"], _state["total_rounds"]])
	_set_text("hud_score", "比分 %d : %d" % [_state["my_score"], _state["ghost_score"]])
	_set_text("hud_gold", "金币 %d" % _state["gold"])
	_set_text("hud_workers", "工人 %d / %d" % [_state["used_workers"], _state["workers"]])
	_set_text("hud_energy", "能量 %d" % _state["energy"])


func _refresh_grid() -> void:
	for y in GRID.y:
		for x in GRID.x:
			var btn: Button = _nodes["cell_%d_%d" % [x, y]]
			btn.icon = null
			btn.text = ""
			# 重置 StyleBox
			var sb := StyleBoxFlat.new()
			sb.bg_color = COLOR_GRID_EMPTY
			sb.border_color = COLOR_GRID_BORDER
			sb.set_border_width_all(1)
			sb.set_corner_radius_all(4)
			btn.add_theme_stylebox_override("normal", sb)
	var cells: Array = _state["board_cells"]
	for i in cells.size():
		if cells[i] == null:
			continue
		var x := i % GRID.x
		var y := i / GRID.x
		# 用格子的"origin"格作为显示锚点
		var b: Dictionary = cells[i]
		var origin: Vector2i = b["origin"]
		var key_cell := "cell_%d_%d" % [origin.x, origin.y]
		var btn: Button = _nodes[key_cell]
		btn.icon = _get_building_icon(b["id"])
		btn.expand_icon = true
		# 跨度占位：用 StyleBox 标识
		var sb := StyleBoxFlat.new()
		sb.bg_color = _family_color(CardDB.get_building(b["id"])["family"])
		sb.border_color = COLOR_TEXT
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		btn.add_theme_stylebox_override("normal", sb)
		var sb_h := sb.duplicate()
		sb_h.bg_color = _family_color(CardDB.get_building(b["id"])["family"]).darkened(0.15)
		btn.add_theme_stylebox_override("hover", sb_h)
		# 激活标记（高亮边框 + 工人圆点 + 相邻加成）
		var active_arr: Array = _state["active"]
		if active_arr.has("%d,%d" % [origin.x, origin.y]):
			var sb_a := sb.duplicate()
			sb_a.border_color = COLOR_ACTIVATED
			sb_a.set_border_width_all(4)
			btn.add_theme_stylebox_override("normal", sb_a)
		# 工人数字
		var worker_idx := active_arr.find("%d,%d" % [origin.x, origin.y])
		if worker_idx >= 0:
			var lbl := Label.new()
			lbl.text = str(worker_idx + 1)
			lbl.add_theme_color_override("font_color", Color.WHITE)
			lbl.add_theme_color_override("font_outline_color", COLOR_TEXT)
			lbl.add_theme_constant_override("outline_size", 4)
			lbl.add_theme_font_size_override("font_size", 22)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lbl.position = btn.position + Vector2(CELL - 32, 4)
			lbl.size = Vector2(28, 28)
			btn.get_parent().add_child(lbl)
			_nodes["worker_badge_%d_%d" % [origin.x, origin.y]] = lbl
		# 相邻加成 badge
		var adj := game.board.count_adjacent({"id": b["id"], "pos": origin, "size": b["size"]})
		if adj > 0:
			var bdg := Label.new()
			bdg.text = "+" + str(adj)
			bdg.add_theme_color_override("font_color", Color.WHITE)
			bdg.add_theme_color_override("font_outline_color", COLOR_TEXT)
			bdg.add_theme_constant_override("outline_size", 4)
			bdg.add_theme_font_size_override("font_size", 14)
			bdg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			bdg.position = btn.position + Vector2(4, CELL - 22)
			bdg.size = Vector2(24, 18)
			btn.get_parent().add_child(bdg)
			_nodes["adj_badge_%d_%d" % [origin.x, origin.y]] = bdg


func _refresh_shop() -> void:
	for i in 3:
		var btn: Button = _nodes["shop_%d" % i]
		btn.icon = null
		btn.text = ""
		var sb := StyleBoxFlat.new()
		sb.bg_color = COLOR_PANEL
		sb.border_color = COLOR_GRID_BORDER
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(6)
		btn.add_theme_stylebox_override("normal", sb)
	if game.phase != FoundryGame.Phase.BUILD:
		# 隐藏商店
		for i in 3:
			(_nodes["shop_%d" % i]).modulate = Color(1, 1, 1, 0.3)
		return
	for i in 3:
		var btn: Button = _nodes["shop_%d" % i]
		btn.modulate = Color.WHITE
		if i >= _state["shop"].size():
			continue
		var card: Dictionary = _state["shop"][i]
		var tex := _get_building_icon(card["id"])
		if tex != null:
			btn.icon = tex
			btn.expand_icon = true
		var sb := StyleBoxFlat.new()
		sb.bg_color = _family_color(card["family"])
		sb.border_color = COLOR_TEXT
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		btn.add_theme_stylebox_override("normal", sb)
		# 价格标签
		var price := Label.new()
		price.text = str(card["cost"]) + "G"
		price.add_theme_color_override("font_color", COLOR_TEXT)
		price.add_theme_font_size_override("font_size", 12)
		price.position = Vector2(4, 4)
		btn.add_child(price)
		# 可用性（买不起则置灰）
		if _state["gold"] < int(card["cost"]):
			btn.modulate = Color(1, 1, 1, 0.45)
		_nodes["shop_label_%d" % i] = price


func _refresh_hand() -> void:
	for i in 5:
		var btn: Button = _nodes["hand_%d" % i]
		btn.icon = null
		btn.text = ""
		var sb := StyleBoxFlat.new()
		sb.bg_color = COLOR_PANEL
		sb.border_color = COLOR_GRID_BORDER
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(6)
		btn.add_theme_stylebox_override("normal", sb)
	if game.phase != FoundryGame.Phase.PLAY:
		for i in 5:
			(_nodes["hand_%d" % i]).modulate = Color(1, 1, 1, 0.3)
		return
	for i in 5:
		var btn: Button = _nodes["hand_%d" % i]
		btn.modulate = Color.WHITE
		if i >= _state["hand"].size():
			continue
		var aid: String = _state["hand"][i]
		var card: Dictionary = CardDB.get_action(aid)
		var sb := StyleBoxFlat.new()
		sb.bg_color = COLOR_GOLD if card["cost"] == 0 else Color("#FFE4A8")
		sb.border_color = COLOR_TEXT
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		btn.add_theme_stylebox_override("normal", sb)
		# 名称
		var name_lbl := Label.new()
		name_lbl.text = card["name"]
		name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
		name_lbl.add_theme_font_size_override("font_size", 16)
		name_lbl.position = Vector2(8, 8)
		name_lbl.size = Vector2(128, 24)
		btn.add_child(name_lbl)
		# 费用
		var cost_lbl := Label.new()
		cost_lbl.text = "费用 " + str(card["cost"])
		cost_lbl.add_theme_color_override("font_color", COLOR_TEXT_DIM)
		cost_lbl.add_theme_font_size_override("font_size", 12)
		cost_lbl.position = Vector2(8, 36)
		btn.add_child(cost_lbl)
		# 效果
		var effect := ""
		if card["flat_power"] > 0:
			effect = "+%d 战" % card["flat_power"]
		elif card["mult"] > 1.0:
			effect = "x%.1f 战" % card["mult"]
		elif card["flat_gold"] > 0:
			effect = "+%d 金" % card["flat_gold"]
		var fx_lbl := Label.new()
		fx_lbl.text = effect
		fx_lbl.add_theme_color_override(
			"font_color", COLOR_POWER if card["flat_power"] > 0 else COLOR_GOLD
		)
		fx_lbl.add_theme_font_size_override("font_size", 22)
		fx_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fx_lbl.position = Vector2(8, 100)
		fx_lbl.size = Vector2(128, 40)
		btn.add_child(fx_lbl)
		# 不可用（能量不够）置灰
		if _state["energy"] < int(card["cost"]):
			btn.modulate = Color(1, 1, 1, 0.4)


func _refresh_opponent() -> void:
	_set_text("opp_name", _state["ghost_name"] + "  D" + str(_state["ghost_diff"]))
	_set_text("opp_type", "流派: " + str(_state["ghost_build"]))
	var my_p: int = int(_state["round_power"])
	var gp: int = int(_state["ghost_round_power"])
	if game.phase == FoundryGame.Phase.VS or game.phase == FoundryGame.Phase.GAME_OVER:
		_set_text("opp_pow", "本回合: 你 %d  vs  幽灵 %d" % [my_p, gp])
	else:
		_set_text("opp_pow", "本回合预期: 幽灵 %d" % gp)
	_redraw_opp_chart()


func _redraw_opp_chart() -> void:
	# 简单的 8 回合条形
	var bg: ColorRect = _nodes["opp_chart_bg"]
	for c in bg.get_children():
		c.queue_free()
	var ghost: Dictionary = game.ghost
	var curve: Array = ghost.get("curve", [])
	if curve.is_empty():
		return
	var maxv := 1
	for v in curve:
		if v > maxv:
			maxv = v
	var bar_w := (bg.size.x - 24) / 8.0
	for r in 8:
		var v: int = curve[r]
		var h := bg.size.y - 24
		var bar_h := h * float(v) / float(maxv)
		var bar := ColorRect.new()
		bar.color = (
			COLOR_POWER
			if r < _state["round"] - 1
			else (COLOR_ADJ_BONUS if r == _state["round"] - 1 else Color("#D8D0BE"))
		)
		bar.position = Vector2(12 + r * bar_w, 12 + (h - bar_h))
		bar.size = Vector2(bar_w * 0.7, bar_h)
		bg.add_child(bar)
		# 标签
		var lbl := Label.new()
		lbl.text = str(v)
		lbl.add_theme_color_override("font_color", COLOR_TEXT_DIM)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.position = Vector2(12 + r * bar_w, 12 + h + 2)
		lbl.size = Vector2(bar_w, 14)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bg.add_child(lbl)


func _refresh_buttons() -> void:
	# 全部隐藏
	for k in ["build", "assign", "play", "next", "again"]:
		(_nodes["btn_" + k]).visible = false
	match game.phase:
		FoundryGame.Phase.BUILD:
			(_nodes["btn_build"]).visible = true
			(_nodes["btn_build"]).position = Vector2(GRID_X + GRID_W + 24, GRID_Y + GRID_H + 12)
		FoundryGame.Phase.ASSIGN:
			(_nodes["btn_assign"]).visible = true
			(_nodes["btn_assign"]).position = Vector2(GRID_X + GRID_W + 24, GRID_Y + GRID_H + 12)
		FoundryGame.Phase.PLAY:
			(_nodes["btn_play"]).visible = true
			(_nodes["btn_play"]).position = Vector2(GRID_X + GRID_W + 24, GRID_Y + GRID_H + 12)
		FoundryGame.Phase.VS:
			(_nodes["btn_next"]).visible = true
			(_nodes["btn_next"]).position = Vector2(440, 690)
		FoundryGame.Phase.GAME_OVER:
			(_nodes["btn_again"]).visible = true
			(_nodes["btn_again"]).position = Vector2(560, 690)


func _refresh_log() -> void:
	var msg := ""
	match game.phase:
		FoundryGame.Phase.BUILD:
			msg = "三选一买 1 张卡，拖入网格放好。"
		FoundryGame.Phase.ASSIGN:
			msg = "点击 3 栋建筑分配工人（最多 3 个）。"
		FoundryGame.Phase.PLAY:
			msg = "点击手牌打出（能量 %d）" % _state["energy"]
		FoundryGame.Phase.VS:
			var result: String = str(_state["last_result"])
			if result == "win":
				msg = "胜! 你的 %d > 幽灵 %d" % [_state["round_power"], _state["ghost_round_power"]]
			elif result == "lose":
				msg = "败! 你的 %d < 幽灵 %d" % [_state["round_power"], _state["ghost_round_power"]]
			else:
				msg = "平局 %d = %d" % [_state["round_power"], _state["ghost_round_power"]]
		FoundryGame.Phase.GAME_OVER:
			var ms: int = int(_state["my_score"])
			var gs: int = int(_state["ghost_score"])
			if ms > gs:
				msg = "胜出! %d : %d" % [ms, gs]
			elif ms < gs:
				msg = "惜败  %d : %d" % [ms, gs]
			else:
				msg = "平局  %d : %d" % [ms, gs]
	_set_text("log_label", msg)


func _set_text(key: String, text: String) -> void:
	if _nodes.has(key):
		(_nodes[key] as Label).text = text


# ---------- 事件 ----------


func _on_grid_pressed(pos: Vector2i) -> void:
	if game.phase == FoundryGame.Phase.BUILD and not game.taken_card.is_empty():
		if game.place_card(pos):
			_rebuild()
	elif game.phase == FoundryGame.Phase.ASSIGN:
		var b: Dictionary = game.board.get_building_at(pos)
		if b.is_empty():
			return
		var origin: Vector2i = b["origin"]
		if game.active_positions.has(origin):
			game.unassign_worker(origin)
		else:
			game.assign_worker(origin)
		_rebuild()


func _on_shop_pressed(idx: int) -> void:
	if game.phase != FoundryGame.Phase.BUILD:
		return
	if game.buy_card(idx):
		_show_dragged_preview()
		_rebuild()


func _show_dragged_preview() -> void:
	if _dragged_preview != null:
		_dragged_preview.queue_free()
	var card: Dictionary = game.taken_card
	if card.is_empty():
		return
	var preview := Panel.new()
	preview.custom_minimum_size = Vector2(108, 140)
	preview.size = Vector2(108, 140)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 用 StyleBoxFlat 模拟卡面
	var sb := StyleBoxFlat.new()
	sb.bg_color = _family_color(card["family"])
	sb.border_color = COLOR_TEXT
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	preview.add_theme_stylebox_override("panel", sb)
	# 内嵌图标
	var icon_tex := _get_building_icon(card["id"])
	if icon_tex != null:
		var icon := TextureRect.new()
		icon.texture = icon_tex
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.position = Vector2(8, 8)
		icon.size = Vector2(92, 92)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		preview.add_child(icon)
	# 名称（用 _make_label 不行因为 parent 已 add，复制一份简化）
	var name_lbl := Label.new()
	name_lbl.text = card["name"]
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.position = Vector2(0, 104)
	name_lbl.size = Vector2(108, 22)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_child(name_lbl)
	preview.z_index = 100
	add_child(preview)
	_dragged_preview = preview


func _hide_dragged_preview() -> void:
	if _dragged_preview != null:
		_dragged_preview.queue_free()
		_dragged_preview = null


func _on_hand_pressed(idx: int) -> void:
	if game.phase != FoundryGame.Phase.PLAY:
		return
	if game.play_card(idx):
		_rebuild()


func _on_action_pressed(key: String) -> void:
	match key:
		"build":
			if game.finish_build():
				_rebuild()
		"assign":
			if game.finish_assign():
				_rebuild()
		"play":
			if game.finish_play():
				_rebuild()
		"next":
			if game.next_round():
				_rebuild()
		"again":
			game = FoundryGame.new(0, {})
			_rebuild()


# ---------- Test hook ----------


func _test_hook_connect() -> void:
	# 注册到 TestHook autoload（若可用）
	if Engine.has_singleton("TestHook"):
		pass  # TestHook 会通过 _test_hook_get_state 拉取


func _test_hook_get_state() -> Dictionary:
	var s := game.to_dict() if game != null else {}
	# 简化为测试 hook 期望的字段
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
