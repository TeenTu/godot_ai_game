class_name BoomBossProjectile
extends Node3D
## M11 首领鬼火弹：固定池复用，避免 Boss 扇形弹幕在 Web 怪海中频繁分配节点。

const RADIUS: float = 0.34
const LIFE: float = 2.4

var active: bool = false
var velocity: Vector3 = Vector3.ZERO
var damage: int = 0
var life_left: float = 0.0

var _orb: MeshInstance3D


func _init() -> void:
	_orb = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.18
	mesh.height = 0.36
	mesh.radial_segments = 8
	mesh.rings = 4
	_orb.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("5fc5ad")
	mat.emission_enabled = true
	mat.emission = Color("5fc5ad")
	mat.emission_energy_multiplier = 2.4
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_orb.material_override = mat
	_orb.visible = false
	add_child(_orb)


func launch(origin: Vector3, direction: Vector3, p_damage: int, speed: float) -> void:
	position = origin
	velocity = direction.normalized() * speed
	damage = p_damage
	life_left = LIFE
	active = true
	_orb.visible = true


func tick(delta: float) -> void:
	if not active:
		return
	position += velocity * delta
	life_left -= delta
	_orb.rotation.y += delta * 8.0
	var pulse := 1.0 + sin(life_left * 18.0) * 0.12
	_orb.scale = Vector3.ONE * pulse
	if life_left <= 0.0:
		recycle()


func recycle() -> void:
	active = false
	velocity = Vector3.ZERO
	damage = 0
	life_left = 0.0
	_orb.visible = false
