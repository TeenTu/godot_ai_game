class_name PopEffect
extends Node2D

## 合成时的一圈扩散光环 + 往上飘的加分数字。纯视觉，不参与物理。

const LIFE: float = 0.55

var _radius: float = 10.0
var _max_radius: float = 60.0
var _color: Color = Color.WHITE
var _gain: int = 0
var _elapsed: float = 0.0


static func spawn(parent: Node, pos: Vector2, radius: float, color: Color, gain: int) -> void:
	var fx := PopEffect.new()
	fx.position = pos
	fx._max_radius = radius * 1.45
	fx._radius = radius * 0.5
	fx._color = color.lightened(0.25)
	fx._gain = gain
	fx.z_index = 5
	parent.add_child(fx)


func _process(delta: float) -> void:
	_elapsed += delta
	var k: float = _elapsed / LIFE
	if k >= 1.0:
		queue_free()
		return
	_radius = lerpf(_max_radius * 0.5, _max_radius, minf(k * 2.0, 1.0))
	modulate.a = 1.0 - k * k
	queue_redraw()


func _draw() -> void:
	var ring_k: float = _elapsed / (LIFE * 0.6)
	if ring_k < 1.0:
		draw_arc(Vector2.ZERO, _radius, 0.0, TAU, 40, Color(_color, 1.0 - ring_k), 7.0, true)
	if _gain > 0:
		_draw_gain_text()


func _draw_gain_text() -> void:
	var font := UiFont.get_font()
	if font == null:
		return
	var text := "+%d" % _gain
	var fsize: int = int(clampf(_max_radius * 0.42, 18.0, 40.0))
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
	var baseline := Vector2(-size.x * 0.5, -_max_radius * 0.45 - _elapsed * 42.0)
	draw_string(
		font, baseline, text, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize, Color(0.98, 0.85, 0.32)
	)
