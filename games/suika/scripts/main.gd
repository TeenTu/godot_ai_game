extends Node2D

## 合成大西瓜 —— 鼠标 / 触屏 / 键盘都能玩。
## 同级水果相撞会合并成更大的一级，堆过死亡线就算输。

const LEFT_X: float = 40.0
const RIGHT_X: float = 680.0
const WALL_THICK: float = 40.0
const WALL_TOP: float = 120.0
const FLOOR_Y: float = 1010.0
const BASE_H: float = 70.0
const DROP_Y: float = 195.0
const DEATH_Y: float = 280.0

const DROP_COOLDOWN: float = 0.45
const OVER_HOLD: float = 2.0
const SETTLE_AGE: float = 1.2
const SETTLE_SPEED: float = 45.0
const KEY_SPEED: float = 420.0

const SAVE_PATH: String = "user://suika_best.save"

var score: int = 0
var best: int = 0
var held: Fruit = null
var next_level: int = 0
var cooldown: float = 0.0
var is_over: bool = false
var over_timer: float = 0.0
var pointer_x: float = 360.0
var pending: Array = []

@onready var walls_root: Node2D = $Walls
@onready var fruits_root: Node2D = $Fruits
@onready var effects_root: Node2D = $Effects
@onready var score_label: Label = $HUD/ScoreLabel
@onready var best_label: Label = $HUD/BestLabel
@onready var over_panel: ColorRect = $HUD/GameOver
@onready var final_label: Label = $HUD/GameOver/FinalLabel
@onready var restart_button: Button = $HUD/GameOver/RestartButton


func _ready() -> void:
	# vision-e2e 测试模式：test_hook autoload 已在 _ready 之前 seed(n) 固定随机数，
	# 这里跳过 randomize()，否则 randomize 会用系统熵覆盖钩子设的 seed。
	if not _is_test_mode():
		randomize()
	_ensure_actions()
	best = _load_best()
	_build_container()
	restart_button.pressed.connect(_on_restart_pressed)
	next_level = _random_level()
	_update_hud()
	_spawn_held()
	queue_redraw()


## 测试模式判定：URL ?test=1 时返回 true。供 _ready 决定是否跳过 randomize。
## 注意：逻辑与 test_hook.gd::_detect_test_mode 一致——二者必须同时为 true，
## 否则 seed 固定会失效（test_hook 设了 seed 但 main 仍 randomize 覆盖）。
func _is_test_mode() -> bool:
	if not OS.has_feature("web"):
		return false
	if not Engine.has_singleton("JavaScriptBridge"):
		return false
	var v: Variant = Engine.get_singleton("JavaScriptBridge").call(
		"eval", "new URLSearchParams(location.search).get('test')"
	)
	if typeof(v) != TYPE_STRING:
		return false
	return (v as String) == "1"


func _unhandled_input(event: InputEvent) -> void:
	if is_over:
		return
	if event is InputEventMouseMotion:
		pointer_x = (event as InputEventMouseMotion).position.x
	elif event is InputEventScreenDrag:
		pointer_x = (event as InputEventScreenDrag).position.x
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			pointer_x = mb.position.x
			_drop_held()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			pointer_x = st.position.x
			_drop_held()
	elif event.is_action_pressed("drop"):
		_drop_held()


func _process(delta: float) -> void:
	if is_over or held == null:
		return
	if Input.is_action_pressed("move_left"):
		pointer_x -= KEY_SPEED * delta
	if Input.is_action_pressed("move_right"):
		pointer_x += KEY_SPEED * delta
	var r: float = held.radius
	held.position = Vector2(clampf(pointer_x, LEFT_X + r, RIGHT_X - r), DROP_Y)
	# 瞄准辅助线跟着手上的水果跑，需要每帧重画
	queue_redraw()


func _physics_process(delta: float) -> void:
	_process_merges()
	for child in fruits_root.get_children():
		var f := child as Fruit
		if f != null:
			f.age += delta
	if is_over:
		return
	if held == null:
		cooldown -= delta
		if cooldown <= 0.0:
			_spawn_held()
	_check_over(delta)
	if over_timer > 0.0:
		queue_redraw()


func _draw() -> void:
	var wall_col := Color(0.48, 0.34, 0.24)
	draw_rect(
		Rect2(LEFT_X - WALL_THICK, WALL_TOP, WALL_THICK, FLOOR_Y + BASE_H - WALL_TOP), wall_col
	)
	draw_rect(Rect2(RIGHT_X, WALL_TOP, WALL_THICK, FLOOR_Y + BASE_H - WALL_TOP), wall_col)
	draw_rect(Rect2(0.0, FLOOR_Y, 720.0, BASE_H), wall_col.darkened(0.12))
	draw_rect(Rect2(0.0, FLOOR_Y, 720.0, 6.0), Color(1.0, 1.0, 1.0, 0.10))

	var danger: bool = over_timer > 0.0
	var line_col: Color = Color(0.92, 0.26, 0.22, 0.95) if danger else Color(0.55, 0.45, 0.35, 0.30)
	_draw_dashed_line(Vector2(LEFT_X, DEATH_Y), Vector2(RIGHT_X, DEATH_Y), line_col)
	_draw_aim_guide()
	_draw_next_preview()


# ------------------------------------------------------------------ 玩法


func _spawn_held() -> void:
	held = Fruit.create(next_level)
	held.is_held = true
	held.freeze = true
	held.pair_collided.connect(_on_pair_collided)
	held.position = Vector2(360.0, DROP_Y)
	fruits_root.add_child(held)
	next_level = _random_level()
	queue_redraw()


func _drop_held() -> void:
	if held == null or is_over:
		return
	held.is_held = false
	held.freeze = false
	held.linear_velocity = Vector2(0.0, 80.0)
	held = null
	cooldown = DROP_COOLDOWN
	queue_redraw()


func _on_pair_collided(a: Fruit, b: Fruit) -> void:
	pending.append([a, b])


func _process_merges() -> void:
	if pending.is_empty():
		return
	for pair in pending:
		var a := pair[0] as Fruit
		var b := pair[1] as Fruit
		if not is_instance_valid(a) or not is_instance_valid(b):
			continue
		if a.is_merged or b.is_merged or a.is_held or b.is_held:
			continue
		if a.level != b.level:
			continue
		_merge(a, b)
	pending.clear()


func _merge(a: Fruit, b: Fruit) -> void:
	a.is_merged = true
	b.is_merged = true
	var level: int = a.level
	var mid: Vector2 = (a.position + b.position) * 0.5
	var gain: int = FruitData.TOP_MERGE_BONUS
	if level + 1 < FruitData.COUNT:
		gain = int(FruitData.SCORE[level + 1])
	PopEffect.spawn(effects_root, mid, FruitData.radius_of(level), FruitData.color_of(level), gain)
	a.queue_free()
	b.queue_free()

	score += gain
	if level + 1 < FruitData.COUNT:
		_spawn_fruit(level + 1, mid)
	_update_hud()


func _spawn_fruit(level: int, pos: Vector2) -> void:
	var f := Fruit.create(level)
	f.position = pos
	f.pair_collided.connect(_on_pair_collided)
	fruits_root.add_child(f)


func _check_over(delta: float) -> void:
	var danger := false
	for child in fruits_root.get_children():
		var f := child as Fruit
		if f == null or f.is_held or f.age < SETTLE_AGE:
			continue
		if f.linear_velocity.length() > SETTLE_SPEED:
			continue
		if f.position.y - f.radius < DEATH_Y:
			danger = true
			break
	if danger:
		over_timer += delta
		if over_timer >= OVER_HOLD:
			_game_over()
	else:
		over_timer = 0.0


func _game_over() -> void:
	is_over = true
	if score > best:
		best = score
		_save_best(best)
	_update_hud()
	final_label.text = "本局  %d\n最高  %d" % [score, best]
	over_panel.visible = true


func _on_restart_pressed() -> void:
	get_tree().reload_current_scene()


# ------------------------------------------------------------------ 辅助


func _random_level() -> int:
	return randi() % (FruitData.MAX_SPAWN_LEVEL + 1)


func _update_hud() -> void:
	score_label.text = str(score)
	best_label.text = "最高  %d" % best


func _build_container() -> void:
	_add_wall(Vector2(LEFT_X - WALL_THICK * 0.5, 400.0), Vector2(WALL_THICK, 2200.0))
	_add_wall(Vector2(RIGHT_X + WALL_THICK * 0.5, 400.0), Vector2(WALL_THICK, 2200.0))
	_add_wall(Vector2(360.0, FLOOR_Y + WALL_THICK * 0.5), Vector2(1000.0, WALL_THICK))


func _add_wall(pos: Vector2, size: Vector2) -> void:
	var body := StaticBody2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	var cs := CollisionShape2D.new()
	cs.shape = rect
	body.add_child(cs)
	body.position = pos
	walls_root.add_child(body)


func _draw_aim_guide() -> void:
	if held == null or is_over:
		return
	var gx: float = held.position.x
	_draw_dashed_line(
		Vector2(gx, DROP_Y + held.radius + 8.0),
		Vector2(gx, FLOOR_Y),
		Color(0.35, 0.28, 0.22, 0.22),
		9.0,
		13.0
	)


func _draw_next_preview() -> void:
	var color := FruitData.color_of(next_level)
	var center := Vector2(614.0, 60.0)
	draw_circle(center, 26.0, color)
	draw_arc(center, 24.5, 0.0, TAU, 32, color.darkened(0.35), 3.0, true)
	draw_circle(center + Vector2(-8.0, -9.0), 5.5, Color(1.0, 1.0, 1.0, 0.30))


func _draw_dashed_line(
	a: Vector2, b: Vector2, color: Color, dash: float = 16.0, gap: float = 12.0
) -> void:
	var total: float = a.distance_to(b)
	var dir: Vector2 = (b - a).normalized()
	var t: float = 0.0
	while t < total:
		var seg: float = minf(dash, total - t)
		draw_line(a + dir * t, a + dir * (t + seg), color, 4.0, true)
		t += dash + gap


func _ensure_actions() -> void:
	_register_action("drop", KEY_SPACE)
	_register_action("move_left", KEY_LEFT)
	_register_action("move_right", KEY_RIGHT)


func _register_action(action: String, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.keycode = keycode
	# 不同平台下生效的可能是 physical_keycode，两个都写上更稳。
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


func _load_best() -> int:
	if not FileAccess.file_exists(SAVE_PATH):
		return 0
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return 0
	var value: int = f.get_32()
	f.close()
	return value


func _save_best(value: int) -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_32(value)
	f.close()


# —— vision-e2e 测试钩子用：返回当前游戏状态字典 ——
# 仅在 URL 含 ?test=1 时由 test_hook autoload 调用。无副作用、纯 getter。
func _test_hook_get_state() -> Dictionary:
	return {
		"score": score,
		"best": best,
		"is_over": is_over,
		"fruit_count": fruits_root.get_child_count(),
		"held_level": held.level if held != null else -1,
		"next_level": next_level,
	}
