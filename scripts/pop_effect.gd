class_name PopEffect
extends Node2D

const LIFE: float = 0.34

var _radius: float = 10.0
var _max_radius: float = 60.0
var _color: Color = Color.WHITE
var _elapsed: float = 0.0


static func spawn(parent: Node, pos: Vector2, radius: float, color: Color) -> void:
	var fx := PopEffect.new()
	fx.position = pos
	fx._max_radius = radius * 1.45
	fx._radius = radius * 0.5
	fx._color = color.lightened(0.25)
	parent.add_child(fx)


func _process(delta: float) -> void:
	_elapsed += delta
	var k: float = _elapsed / LIFE
	if k >= 1.0:
		queue_free()
		return
	_radius = lerpf(_max_radius * 0.5, _max_radius, k)
	modulate.a = 1.0 - k
	queue_redraw()


func _draw() -> void:
	draw_arc(Vector2.ZERO, _radius, 0.0, TAU, 40, _color, 7.0, true)
