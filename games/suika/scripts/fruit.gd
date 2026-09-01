class_name Fruit
extends RigidBody2D

## 两颗同级水果碰到一起，交给 Main 处理合成。
signal pair_collided(a: Fruit, b: Fruit)

var level: int = 0
var radius: float = 20.0
var fruit_color: Color = Color.WHITE
var fruit_name: String = ""
var is_merged: bool = false
var is_held: bool = false
var age: float = 0.0


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
	# 只有最终的大西瓜画条纹，其余保持干净的纯色球
	if level == FruitData.COUNT - 1:
		_draw_stripes(r)
	draw_circle(Vector2(-r * 0.30, -r * 0.34), r * 0.20, Color(1.0, 1.0, 1.0, 0.30))
	draw_arc(Vector2.ZERO, r - 1.5, 0.0, TAU, 40, fruit_color.darkened(0.38), 3.5, true)
	_draw_leaf(r)
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


func _draw_stripes(r: float) -> void:
	var col := fruit_color.darkened(0.32)
	for i in range(6):
		var a: float = float(i) * TAU / 6.0
		var dir := Vector2(cos(a), sin(a))
		draw_line(dir * r * 0.20, dir * r * 0.90, col, r * 0.11, true)


func _draw_leaf(r: float) -> void:
	draw_set_transform(Vector2(r * 0.10, -r * 0.90), -0.55, Vector2.ONE)
	draw_colored_polygon(_leaf_points(r * 0.50, r * 0.22), Color(0.29, 0.60, 0.23))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _leaf_points(length: float, width: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := 12
	for i in range(steps + 1):
		var a: float = lerpf(-PI * 0.5, PI * 0.5, float(i) / float(steps))
		pts.append(Vector2(cos(a) * length, -sin(a) * width))
	for i in range(steps + 1):
		var a: float = lerpf(PI * 0.5, PI * 1.5, float(i) / float(steps))
		pts.append(Vector2(cos(a) * length, -sin(a) * width))
	return pts


func _draw_name(r: float) -> void:
	var font := UiFont.get_font()
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
