class_name Fruit
extends RigidBody2D

## 两颗同级水果碰到一起，交给 Main 处理合成。
signal pair_collided(a: Fruit, b: Fruit)

const FONT_PATH: String = "res://assets/fonts/ui_subset.ttf"

var level: int = 0
var radius: float = 20.0
var fruit_color: Color = Color.WHITE
var fruit_name: String = ""
var is_merged: bool = false
var is_held: bool = false
var age: float = 0.0

var _font: Font = null


static func create(lv: int) -> Fruit:
	var fruit := Fruit.new()
	fruit.level = lv
	return fruit


func _ready() -> void:
	var data: Dictionary = FruitData.LEVELS[level]
	radius = data["radius"]
	fruit_color = data["color"]
	fruit_name = data["name"]

	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)

	physics_material_override = _make_material()
	mass = radius * radius * 0.001
	linear_damp = 0.05
	angular_damp = 2.5

	var shape := CircleShape2D.new()
	shape.radius = radius
	var cs := CollisionShape2D.new()
	cs.shape = shape
	add_child(cs)

	queue_redraw()


func _draw() -> void:
	var r := radius
	draw_circle(Vector2.ZERO, r, fruit_color)
	draw_arc(Vector2.ZERO, r - 1.5, 0.0, TAU, 40, fruit_color.darkened(0.38), 3.5, true)
	draw_circle(Vector2(-r * 0.30, -r * 0.34), r * 0.20, Color(1.0, 1.0, 1.0, 0.30))
	_draw_name(r)


func _on_body_entered(body: Node2D) -> void:
	var other := body as Fruit
	if other == null or is_merged or other.is_merged:
		return
	if is_held or other.is_held:
		return
	if other.level != level:
		return
	pair_collided.emit(self, other)


func _make_material() -> PhysicsMaterial:
	var mat := PhysicsMaterial.new()
	mat.friction = 0.35
	mat.bounce = 0.08
	mat.rough = true
	return mat


func _draw_name(r: float) -> void:
	var font := _resolve_font()
	if font == null:
		return
	var fsize := int(maxf(r * 0.52, 12.0))
	var size := font.get_string_size(fruit_name, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
	var baseline := Vector2(-size.x * 0.5, size.y * 0.34)
	draw_string(
		font,
		baseline,
		fruit_name,
		HORIZONTAL_ALIGNMENT_CENTER,
		-1,
		fsize,
		Color(0.13, 0.10, 0.12, 0.82)
	)


func _resolve_font() -> Font:
	if _font == null:
		if ResourceLoader.exists(FONT_PATH):
			_font = load(FONT_PATH)
		else:
			_font = ThemeDB.fallback_font
	return _font
