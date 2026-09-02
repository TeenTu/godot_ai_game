class_name BoomBullet
extends Node3D
## 泡泡子弹：飞行距离固定寿命，命中敌人后由 BoomGame 回收进对象池。
## 纯数据 + 程序化小球，零外部素材。

const SPEED: float = 15.0
const LIFETIME: float = 1.6
const RADIUS: float = 0.18

var vel: Vector3 = Vector3.ZERO
var life: float = 0.0
var active: bool = false
## 弹道变体归属：straight=普通弹 / fan=爆裂弹幕（§4.2 每命中飘字按此判定）。
var variant: String = "straight"


func _init() -> void:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.88, 1.0, 0.92)
	mat.emission_enabled = true
	mat.emission = Color(0.75, 0.95, 1.0)
	mat.emission_energy_multiplier = 1.4
	mat.roughness = 0.15
	mesh.mesh = sphere
	mesh.material_override = mat
	add_child(mesh)
	visible = false


## 从对象池取出开火：重置位置/速度/寿命并显示。
func fire(from: Vector3, dir: Vector3) -> void:
	position = from
	vel = dir * SPEED
	life = LIFETIME
	active = true
	variant = "straight"
	visible = true


## 命中/出界/寿命耗尽后回收（由池主调用）。
func recycle() -> void:
	active = false
	visible = false
