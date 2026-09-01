class_name Powerup
extends Node2D
## 护盾道具：缓慢下落的绿色十字圆牌，拾取后飞船获得一次性护盾。

const FALL_SPEED: float = 130.0
const DESPAWN_Y: float = 1250.0
const RADIUS: float = 15.0


func _process(delta: float) -> void:
	position.y += FALL_SPEED * delta
	if position.y > DESPAWN_Y:
		queue_free()
	queue_redraw()


func _draw() -> void:
	var pulse: float = sin(Time.get_ticks_msec() * 0.006) * 2.0
	draw_circle(Vector2.ZERO, RADIUS + pulse, Color(0.2, 0.9, 0.55, 0.28))
	draw_circle(Vector2.ZERO, RADIUS, Color(0.2, 0.9, 0.55, 0.9))
	draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 24, Color(1, 1, 1, 0.7), 2.0, true)
	draw_rect(Rect2(-3.5, -9, 7, 18), Color.WHITE)
	draw_rect(Rect2(-9, -3.5, 18, 7), Color.WHITE)
