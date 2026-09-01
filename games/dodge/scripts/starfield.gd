class_name Starfield
extends Node2D
## 双层视差星空：远景慢而暗、近景快而亮，营造飞行纵深感。

const VIEW: Vector2 = Vector2(720, 1080)
const DEEP_COUNT: int = 45
const NEAR_COUNT: int = 25

var _stars: Array[Dictionary] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260902
	for i in DEEP_COUNT + NEAR_COUNT:
		var deep: bool = i < DEEP_COUNT
		(
			_stars
			. append(
				{
					"pos": Vector2(_rng.randf_range(0, VIEW.x), _rng.randf_range(0, VIEW.y)),
					"speed": _rng.randf_range(18, 34) if deep else _rng.randf_range(70, 110),
					"size": _rng.randf_range(1.2, 2.0) if deep else _rng.randf_range(2.2, 3.0),
					"alpha": _rng.randf_range(0.22, 0.45) if deep else _rng.randf_range(0.55, 0.9),
				}
			)
		)


func _process(delta: float) -> void:
	for s in _stars:
		var pos: Vector2 = s["pos"]
		pos.y += float(s["speed"]) * delta
		if pos.y > VIEW.y + 4.0:
			pos.y = -4.0
			pos.x = _rng.randf_range(0, VIEW.x)
		s["pos"] = pos
	queue_redraw()


func _draw() -> void:
	for s in _stars:
		draw_circle(s["pos"], float(s["size"]), Color(1, 1, 1, float(s["alpha"])))
