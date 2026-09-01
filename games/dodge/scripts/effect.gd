class_name RingEffect
extends Node2D
## 扩散光环特效：撞击 / 拾取 / 护盾破碎时的反馈。

var max_radius: float = 60.0
var life: float = 0.5
var delay: float = 0.0
var color: Color = Color(1, 1, 1)
var _t: float = 0.0


func setup(p_max_radius: float, p_life: float, p_color: Color, p_delay: float = 0.0) -> void:
	max_radius = p_max_radius
	life = p_life
	color = p_color
	delay = p_delay


func _process(delta: float) -> void:
	if delay > 0.0:
		delay -= delta
		return
	_t += delta
	queue_redraw()
	if _t >= life:
		queue_free()


func _draw() -> void:
	if _t <= 0.0:
		return
	var k: float = _t / life
	var r: float = max_radius * (0.2 + 0.8 * k)
	draw_arc(
		Vector2.ZERO,
		r,
		0,
		TAU,
		40,
		Color(color.r, color.g, color.b, 1.0 - k),
		3.0 + 4.0 * (1.0 - k),
		true
	)
