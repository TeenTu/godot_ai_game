class_name BoomProp
extends Node3D
## 嘉年华场内可破坏物：木箱/泡泡桶。逻辑轻量，视觉完全程序化并遵循 boom-3d 色板。

const HIT_RADIUS: float = 0.72

var kind: String
var hp: int = 2
var coin_value: int = 1
var broken: bool = false
var _visual: Node3D
var _bounce := 0.0


func _init(prop_kind: String = "crate") -> void:
	kind = prop_kind
	_build_visual()


func take_damage() -> bool:
	if broken:
		return false
	hp -= 1
	_bounce = 1.0
	if hp <= 0:
		broken = true
		visible = false
		return true
	return false


func tick(delta: float) -> void:
	_bounce = maxf(0.0, _bounce - delta * 5.0)
	if _visual != null:
		var squash := sin(_bounce * PI) * 0.16
		_visual.scale = Vector3(1.0 + squash, 1.0 - squash, 1.0 + squash)


func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	if kind == "barrel":
		_build_barrel()
	else:
		_build_crate()


func _build_crate() -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.9, 1.0)
	body.mesh = box
	body.position.y = 0.45
	body.material_override = _mat(Color("c98a4e"), 0.78)
	_visual.add_child(body)
	var tape := MeshInstance3D.new()
	var tape_box := BoxMesh.new()
	tape_box.size = Vector3(1.04, 0.16, 1.04)
	tape.mesh = tape_box
	tape.position.y = 0.48
	tape.material_override = _mat(Color("2bd9ff"), 0.25, true)
	_visual.add_child(tape)


func _build_barrel() -> void:
	var body := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.42
	cylinder.bottom_radius = 0.48
	cylinder.height = 1.0
	cylinder.radial_segments = 16
	body.mesh = cylinder
	body.position.y = 0.5
	body.material_override = _mat(Color("35a9e0"), 0.32)
	_visual.add_child(body)
	for y in [0.18, 0.82]:
		var band := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.38
		ring.outer_radius = 0.50
		ring.rings = 16
		ring.ring_segments = 8
		band.mesh = ring
		band.position.y = y
		band.material_override = _mat(Color("fff6e8"), 0.45)
		_visual.add_child(band)


func _mat(color: Color, roughness: float, glow: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	if glow:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.35
	return mat
