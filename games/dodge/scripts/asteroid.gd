extends Node2D
## 陨石：随机多边形轮廓，下落 + 自旋，出屏自毁。

const FALL_SPEED_BASE: float = 300.0
const DESPAWN_Y: float = 1250.0

var radius: float = 26.0
var fall_speed: float = 300.0
var _rot_speed: float = 1.0
var _verts: PackedVector2Array = PackedVector2Array()
var _shade: Color = Color(0.55, 0.55, 0.62)


func setup(rng: RandomNumberGenerator, score: float) -> void:
	radius = rng.randf_range(18.0, 38.0)
	fall_speed = FALL_SPEED_BASE + score * 12.0 + rng.randf_range(-40.0, 80.0)
	_rot_speed = rng.randf_range(-2.2, 2.2)
	var n := rng.randi_range(7, 9)
	_verts = PackedVector2Array()
	for i in n:
		var angle: float = TAU * float(i) / float(n)
		var r: float = radius * rng.randf_range(0.72, 1.12)
		_verts.append(Vector2.from_angle(angle) * r)
	var tone := rng.randf_range(0.45, 0.65)
	_shade = Color(tone, tone, tone + 0.06)
	queue_redraw()


func _process(delta: float) -> void:
	position.y += fall_speed * delta
	rotation += _rot_speed * delta
	if position.y > DESPAWN_Y:
		queue_free()
	queue_redraw()


func _draw() -> void:
	if _verts.is_empty():
		draw_circle(Vector2.ZERO, radius, _shade)
	else:
		draw_colored_polygon(_verts, _shade)
	draw_arc(Vector2.ZERO, radius * 0.94, 0, TAU, 24, Color(1, 1, 1, 0.14), 2.0, true)
