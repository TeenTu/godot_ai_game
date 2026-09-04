class_name BoomResultPanel
extends Control
## M3 结算面板（design_boom.md §7.2）：最后一击 0.3× 慢镜头(0.35s) →
## 星级依次过冲弹出 → 金币飞计数器 → 分数数字滚动。
## M5（design_m5_weapons.md §3.3）复用于"再来一局"中转站：retry_pressed 发出后
## 由 main.gd 决定动作（隐藏结算 + 弹选武器 + sim.restart，而非整场景重载）。

signal retry_pressed

var stars: Array = []  # 结算星级 Label（依次弹出）
var counting: bool = false  # 分数滚动期间 hud_refresh 不覆盖 _score_label
var slowmo_deadline_ms: int = 0  # 结算慢镜头结束的真实时刻（ms）

var _final_score: int = 0
var _final_kills: int = 0
var _final_wave: int = 0
var _stats_label: Label
var _score_lbl: Label = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


## main 把顶部分数 Label 注入，结算滚动直接写它（与旧主脚本行为一致）。
func setup_score_label(l: Label) -> void:
	_score_lbl = l


func _ready() -> void:
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(1.0, 0.44, 0.24, 0.30)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var backdrop_path := "res://assets/images/backgrounds/carnival_arena.png"
	if ResourceLoader.exists(backdrop_path):
		var backdrop := TextureRect.new()
		backdrop.texture = load(backdrop_path) as Texture2D
		backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
		backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		backdrop.modulate = Color(1.0, 1.0, 1.0, 0.92)
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(backdrop)
		move_child(backdrop, 0)

	var title := _make_label("BUBBLE BREAK!", 52, Color("ff8a3d"), Vector2(100, 360))
	title.size = Vector2(520, 70)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_stats_label = _make_label("", 24, Color.WHITE, Vector2(0, 430))
	_stats_label.size = Vector2(720, 110)
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# M3 结算星级：初始隐藏，结算序列里按序过冲弹出。
	for i in 3:
		var star := _make_label(
			"\u2605", 64, Color(1.0, 0.85, 0.3), Vector2(238.0 + float(i) * 90.0, 580)
		)
		star.size = Vector2(80, 90)
		star.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		star.pivot_offset = star.size * 0.5
		star.visible = false
		stars.append(star)

	var restart := Button.new()
	restart.text = "TAP TO RETRY"
	restart.add_theme_font_size_override("font_size", 30)
	restart.position = Vector2(190, 720)
	restart.size = Vector2(340, 90)
	restart.pressed.connect(func() -> void: retry_pressed.emit())
	add_child(restart)


func _make_label(text: String, font_size: int, color: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


## main.game_over 入口：显示面板 + 进入 0.3× 慢镜头（真实时钟 0.35s）。
func show_game_over(final_score: int, kills: int, wave: int) -> void:
	_final_score = final_score
	_final_kills = kills
	_final_wave = wave
	_stats_label.text = "SCORE  %d\nKILLS  %d" % [final_score, kills]
	visible = true
	Engine.time_scale = 0.3
	slowmo_deadline_ms = Time.get_ticks_msec() + 350


## main._physics_process 每帧调用：慢镜头到点自动收尾并启动结算序列。
func tick() -> void:
	if not visible or Engine.time_scale >= 1.0:
		return
	if Time.get_ticks_msec() >= slowmo_deadline_ms:
		_finish_slowmo()


## 结束慢镜头并启动结算序列（幂等：非慢镜态直接返回）。
func end_slowmo() -> void:
	if Engine.time_scale >= 1.0 and slowmo_deadline_ms <= 0:
		return
	_finish_slowmo()


func _finish_slowmo() -> void:
	Engine.time_scale = 1.0
	slowmo_deadline_ms = 0
	_start_result_sequence()


## 星级逐个过冲弹出 → 金币飞计数器 → 分数滚动。
func _start_result_sequence() -> void:
	var earned: int = BoomGame.result_stars(_final_wave)
	for i in stars.size():
		var star := stars[i] as Label
		if star == null:
			continue
		star.add_theme_color_override(
			"font_color", Color(1.0, 0.85, 0.3) if i < earned else Color(0.28, 0.3, 0.36)
		)
		var tw := create_tween()
		tw.tween_interval(0.25 * float(i + 1))
		tw.tween_callback(_pop_star.bind(star))
	var coin_tw := create_tween()
	coin_tw.tween_interval(0.25 * float(stars.size()) + 0.15)
	coin_tw.tween_callback(_fly_coins)
	var roll := create_tween()
	roll.tween_interval(0.25 * float(stars.size()) + 0.3)
	roll.tween_callback(_roll_score)


func _pop_star(star: Label) -> void:
	star.visible = true
	star.scale = Vector2(1.8, 1.8)
	star.modulate = Color(1.0, 1.0, 1.0, 0.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(star, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tw.tween_property(star, "modulate:a", 1.0, 0.15)


## 金币粒子从面板中央飞向左上分数计数器。
func _fly_coins() -> void:
	var target: Vector2 = Vector2(60, 60)
	if _score_lbl != null:
		target = _score_lbl.position + Vector2(10.0, 10.0)
	for i in 8:
		var coin := _make_label("\u25cf", 26, Color(1.0, 0.85, 0.3), Vector2.ZERO)
		coin.size = Vector2(32, 32)
		coin.z_index = 10
		coin.position = (
			Vector2(360, 660) + Vector2(randf_range(-130.0, 130.0), randf_range(-90.0, 90.0))
		)
		var tw := create_tween()
		tw.tween_interval(0.06 * float(i))
		tw.tween_property(coin, "position", target, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(
			Tween.EASE_IN
		)
		tw.tween_property(coin, "modulate:a", 0.0, 0.1)
		tw.tween_callback(coin.queue_free)


## 分数数字滚动 0→final（滚动期间 counting=true，hud_refresh 不覆盖）。
func _roll_score() -> void:
	counting = true
	var tw := create_tween()
	tw.tween_method(_set_score_text, 0.0, float(_final_score), 0.9)
	tw.tween_callback(func() -> void: counting = false)


func _set_score_text(v: float) -> void:
	if _score_lbl != null:
		_score_lbl.text = str(int(v))


## main"再来一局"切回选武器前调用：清结算序列残余状态（幂等）。
func reset_for_retry() -> void:
	counting = false
	slowmo_deadline_ms = 0
	for s in stars:
		var l := s as Label
		if l == null:
			continue
		l.visible = false
		l.scale = Vector2.ONE
		l.modulate = Color(1.0, 1.0, 1.0, 1.0)
