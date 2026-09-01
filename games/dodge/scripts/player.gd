class_name Ship
extends Node2D
## 玩家飞船：程序化绘制的三角战机，可携带一层护盾。

var shielded: bool = false
var _thrust: float = 0.0


func _process(_delta: float) -> void:
	# 尾焰用时间抖动，看起来像在喷气。
	_thrust = sin(Time.get_ticks_msec() * 0.02) * 4.0
	queue_redraw()


func _draw() -> void:
	var body := PackedVector2Array(
		[Vector2(0, -26), Vector2(17, 18), Vector2(0, 10), Vector2(-17, 18)]
	)
	draw_colored_polygon(body, Color(0.45, 0.85, 1.0))
	draw_circle(Vector2(0, -6), 6.0, Color(0.12, 0.2, 0.35))
	var flame := PackedVector2Array([Vector2(-8, 18), Vector2(8, 18), Vector2(0, 34 + _thrust)])
	draw_colored_polygon(flame, Color(1.0, 0.65, 0.2, 0.9))
	if shielded:
		# 护盾：呼吸节奏的青绿色圆环。
		var r := 30.0 + sin(Time.get_ticks_msec() * 0.006) * 2.5
		draw_arc(Vector2.ZERO, r, 0, TAU, 32, Color(0.4, 1.0, 0.75, 0.9), 2.5, true)
		draw_arc(Vector2.ZERO, r, 0, TAU, 32, Color(0.4, 1.0, 0.75, 0.25), 6.0, true)
