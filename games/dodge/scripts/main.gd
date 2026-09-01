extends Node2D
## 太空闪避主控：飞船移动、陨石/护盾生成、碰撞判定、计分与重开。
##
## 输入优先级：game_kit 虚拟摇杆 > auto_move（无头测试钩子）> 键盘方向键。
## 全部图形程序化绘制，无外部素材；碰撞用圆距离手算，无头测试可复现。
##
## 玩法机制：
##   - 护盾道具（绿十字）：拾取后可抵挡一次撞击
##   - 擦身奖励：陨石贴身飞过未命中 +5 分
##   - 屏幕震动 / 光环特效 / 双层视差星空

const VIEW: Vector2 = Vector2(720, 1080)
const PLAYER_RADIUS: float = 22.0
const PLAYER_SPEED: float = 520.0
const BASE_SPAWN_INTERVAL: float = 1.1
const MIN_SPAWN_INTERVAL: float = 0.35
const POWERUP_RADIUS: float = 15.0
const POWERUP_CD_MIN: float = 8.0
const POWERUP_CD_MAX: float = 13.0
const NEAR_MISS_EXTRA: float = 34.0
const NEAR_MISS_BONUS: float = 5.0
const BEST_PATH: String = "user://dodge_best.txt"

var score: float = 0.0
var best: int = 0
var is_over: bool = false
var auto_move: Vector2 = Vector2.ZERO  # 无头测试钩子：非零时覆盖摇杆/键盘
var near_miss_count: int = 0

var asteroids_root: Node2D
var powerups_root: Node2D
var player: Ship
var joystick: GameKitVirtualJoystick
var score_label: Label
var best_label: Label
var over_panel: Control
var over_score_label: Label
var _spawn_cd: float = 0.8
var _powerup_cd: float = 9.0
var _shake_left: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	add_child(Starfield.new())

	player = Ship.new()
	player.name = "Player"
	player.position = Vector2(VIEW.x * 0.5, VIEW.y - 160.0)
	add_child(player)

	asteroids_root = Node2D.new()
	asteroids_root.name = "Asteroids"
	add_child(asteroids_root)

	powerups_root = Node2D.new()
	powerups_root.name = "Powerups"
	add_child(powerups_root)

	_build_ui()
	_load_best()
	_update_hud()


func _process(delta: float) -> void:
	_update_shake(delta)
	if is_over:
		return
	score += delta

	var dir := _read_input()
	player.position += dir * PLAYER_SPEED * delta
	player.position = player.position.clamp(Vector2(28.0, 28.0), VIEW - Vector2(28.0, 28.0))

	_spawn_cd -= delta
	if _spawn_cd <= 0.0:
		_spawn_asteroid()
		var interval: float = maxf(MIN_SPAWN_INTERVAL, BASE_SPAWN_INTERVAL - score * 0.02)
		_spawn_cd = interval * _rng.randf_range(0.7, 1.3)

	# 没护盾且场上没道具时，倒计时投放护盾。
	if not player.shielded and powerups_root.get_child_count() == 0:
		_powerup_cd -= delta
		if _powerup_cd <= 0.0:
			_spawn_powerup()

	_check_pickups()
	_check_collision()
	_update_hud()


func _read_input() -> Vector2:
	if joystick != null and joystick.output.length_squared() > 0.0001:
		return joystick.output
	if auto_move.length_squared() > 0.0001:
		return auto_move
	return Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")


func _spawn_asteroid() -> Asteroid:
	var rock := Asteroid.new()
	rock.position = Vector2(_rng.randf_range(40.0, VIEW.x - 40.0), -50.0)
	asteroids_root.add_child(rock)
	rock.setup(_rng, score)
	return rock


func _spawn_powerup() -> Node2D:
	var p := Powerup.new()
	p.position = Vector2(_rng.randf_range(60.0, VIEW.x - 60.0), -40.0)
	powerups_root.add_child(p)
	_powerup_cd = _rng.randf_range(POWERUP_CD_MIN, POWERUP_CD_MAX)
	return p


func _check_pickups() -> void:
	for child in powerups_root.get_children():
		var p := child as Powerup
		if p == null:
			continue
		if player.position.distance_to(p.position) < POWERUP_RADIUS + PLAYER_RADIUS:
			p.queue_free()
			player.shielded = true
			_ring_burst(player.position, Color(0.4, 1.0, 0.7), 1)
			_float_text("+护盾", player.position + Vector2(0, -60))


func _check_collision() -> void:
	for child in asteroids_root.get_children():
		var rock := child as Asteroid
		if rock == null:
			continue
		var dist := player.position.distance_to(rock.position)
		if dist < rock.radius + PLAYER_RADIUS:
			_hit(rock)
			return
		# 擦身奖励：陨石越过飞船高度且横向贴身（一次性判定）。
		if not rock.near_miss_done and rock.position.y > player.position.y:
			rock.near_miss_done = true
			if (
				absf(rock.position.x - player.position.x)
				< rock.radius + PLAYER_RADIUS + NEAR_MISS_EXTRA
			):
				near_miss_count += 1
				score += NEAR_MISS_BONUS
				_float_text("+%d" % int(NEAR_MISS_BONUS), player.position + Vector2(0, -60))


func _hit(rock: Asteroid) -> void:
	if player.shielded:
		player.shielded = false
		rock.queue_free()
		_ring_burst(player.position, Color(0.4, 1.0, 0.7), 2)
		_shake(0.3)
	else:
		_ring_burst(player.position, Color(1.0, 0.5, 0.3), 3)
		_shake(0.55)
		_game_over()


func _ring_burst(pos: Vector2, color: Color, count: int) -> void:
	for i in count:
		var fx := RingEffect.new()
		fx.position = pos
		fx.setup(50.0 + 26.0 * i, 0.45, color, 0.12 * i)
		add_child(fx)


func _float_text(text: String, pos: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = pos - Vector2(60, 0)
	label.size = Vector2(120, 32)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 50
	add_child(label)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "position:y", pos.y - 50.0, 0.8)
	tw.tween_property(label, "modulate:a", 0.0, 0.8)
	tw.chain().tween_callback(label.queue_free)


func _shake(duration: float) -> void:
	_shake_left = duration


func _update_shake(delta: float) -> void:
	if _shake_left > 0.0:
		_shake_left -= delta
		var strength: float = 14.0 * maxf(_shake_left, 0.0)
		position = Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * strength
		if _shake_left <= 0.0:
			position = Vector2.ZERO
	elif position != Vector2.ZERO:
		position = Vector2.ZERO


func _game_over() -> void:
	is_over = true
	if int(score) > best:
		best = int(score)
		_save_best()
	over_score_label.text = "得分 %d" % int(score)
	over_panel.visible = true


func restart() -> void:
	for child in asteroids_root.get_children():
		child.queue_free()
	for child in powerups_root.get_children():
		child.queue_free()
	score = 0.0
	is_over = false
	auto_move = Vector2.ZERO
	near_miss_count = 0
	player.shielded = false
	player.position = Vector2(VIEW.x * 0.5, VIEW.y - 160.0)
	over_panel.visible = false
	_spawn_cd = 0.8
	_powerup_cd = 9.0
	_shake_left = 0.0
	position = Vector2.ZERO
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not is_over:
		return
	var tapped := false
	if event is InputEventScreenTouch and event.pressed:
		tapped = true
	if tapped or event.is_action_pressed("ui_accept"):
		restart()


func _update_hud() -> void:
	score_label.text = "得分 %d" % int(score)
	best_label.text = "最高分 %d" % best


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	# game_kit 安全区容器：刘海/手势条屏上自动把 UI 挤进安全区。
	var safe := GameKitSafeArea.new()
	safe.name = "SafeArea"
	layer.add_child(safe)

	score_label = _make_label(safe, 26)
	score_label.position = Vector2(0, 24)
	score_label.size = Vector2(VIEW.x, 40)

	best_label = _make_label(safe, 20, Color(1, 1, 1, 0.65))
	best_label.position = Vector2(0, 64)
	best_label.size = Vector2(VIEW.x, 30)

	var hint := _make_label(safe, 18, Color(1, 1, 1, 0.5))
	hint.text = "摇杆 / 方向键移动，躲开陨石！"
	hint.position = Vector2(0, VIEW.y - 290.0)
	hint.size = Vector2(VIEW.x, 28)

	over_panel = Control.new()
	over_panel.name = "OverPanel"
	over_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_panel.visible = false
	safe.add_child(over_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.05, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_panel.add_child(dim)

	var title := _make_label(over_panel, 52)
	title.text = "游戏结束"
	title.position = Vector2(0, VIEW.y * 0.36)
	title.size = Vector2(VIEW.x, 70)
	over_score_label = _make_label(over_panel, 30)
	over_score_label.position = Vector2(0, VIEW.y * 0.36 + 90)
	over_score_label.size = Vector2(VIEW.x, 44)
	var again := _make_label(over_panel, 20, Color(1, 1, 1, 0.75))
	again.text = "点击或按空格重新开始"
	again.position = Vector2(0, VIEW.y * 0.36 + 160)
	again.size = Vector2(VIEW.x, 32)

	# game_kit 虚拟摇杆：真机触屏操控，桌面端靠方向键。
	joystick = GameKitVirtualJoystick.new()
	joystick.name = "Joystick"
	joystick.position = Vector2(36.0, VIEW.y - 266.0)
	joystick.size = Vector2(200.0, 200.0)
	safe.add_child(joystick)


func _make_label(parent: Node, font_size: int, color: Color = Color.WHITE) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _load_best() -> void:
	if not FileAccess.file_exists(BEST_PATH):
		return
	var f := FileAccess.open(BEST_PATH, FileAccess.READ)
	if f:
		best = f.get_as_text().to_int()


func _save_best() -> void:
	var f := FileAccess.open(BEST_PATH, FileAccess.WRITE)
	if f:
		f.store_string(str(best))
