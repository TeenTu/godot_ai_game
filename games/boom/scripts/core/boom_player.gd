class_name BoomPlayer
extends Node3D
## 玩家：自动泡泡枪手。移动由 BoomGame 驱动（读摇杆向量），本类只管
## 视觉（身体/头/枪管/眼睛朝向）与朝向、受击无敌闪烁状态。

const MAX_HP: int = 5
const RADIUS: float = 0.55
const MOVE_SPEED: float = 5.4
const INVULN_TIME: float = 0.9

var hp: int = MAX_HP
var max_hp: int = MAX_HP
var radius: float = RADIUS
var invuln_left: float = 0.0
var move_vec: Vector2 = Vector2.ZERO
var facing: Vector3 = Vector3.FORWARD
var muzzle: Node3D = null
var bob_t: float = 0.0

var _body: MeshInstance3D
var _body_mat: StandardMaterial3D
var _flicker_t: float = 0.0
var _flash_energy: float = 0.0


func _init() -> void:
	_build_visuals()


func _build_visuals() -> void:
	# 身体：半透明的圆润舱体。
	var body_sphere := SphereMesh.new()
	body_sphere.radius = 0.42
	body_sphere.height = 0.9
	body_sphere.radial_segments = 14
	body_sphere.rings = 8
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.30, 0.75, 0.95)
	_body_mat.emission_enabled = true
	_body_mat.emission = Color(0.35, 0.85, 1.0)
	_body_mat.emission_energy_multiplier = 0.35
	_body_mat.roughness = 0.3
	_body = MeshInstance3D.new()
	_body.mesh = body_sphere
	_body.material_override = _body_mat
	_body.position.y = 0.52
	add_child(_body)

	# 头顶小圆球（区分头向的可读装饰）。
	var cap_sphere := SphereMesh.new()
	cap_sphere.radius = 0.16
	cap_sphere.height = 0.32
	cap_sphere.radial_segments = 10
	cap_sphere.rings = 6
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.95, 0.98, 1.0)
	cap_mat.roughness = 0.25
	var cap := MeshInstance3D.new()
	cap.mesh = cap_sphere
	cap.material_override = cap_mat
	cap.position.y = 1.02
	add_child(cap)

	# 泡泡枪管：朝向 +Z，玩家整体 rotation.y 指向瞄准方向。
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.07
	barrel_mesh.bottom_radius = 0.09
	barrel_mesh.height = 0.85
	barrel_mesh.radial_segments = 8
	var gun_mat := StandardMaterial3D.new()
	gun_mat.albedo_color = Color(0.16, 0.20, 0.30)
	gun_mat.roughness = 0.5
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.material_override = gun_mat
	barrel.position = Vector3(0.0, 0.5, 0.45)
	barrel.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	add_child(barrel)

	# 眼睛：朝 +Z（脸朝向）。
	_add_eye(Vector3(-0.15, 0.7, 0.34), 0.06)
	_add_eye(Vector3(0.15, 0.7, 0.34), 0.06)

	# 枪口锚点。
	muzzle = Node3D.new()
	muzzle.position = Vector3(0.0, 0.5, 0.9)
	add_child(muzzle)


func _add_eye(local_pos: Vector3, radius: float) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.08, 0.12)
	mat.roughness = 0.2
	var eye := MeshInstance3D.new()
	eye.mesh = sphere
	eye.material_override = mat
	eye.position = local_pos
	add_child(eye)


## 设定移动输入（来自摇杆的 -1..1 向量）。
func set_move(v: Vector2) -> void:
	move_vec = v


## 每物理帧由 BoomGame 调用：执行移动并做小幅度呼吸动画。
## 摇杆屏幕向量 → 世界 XZ：x 直通，屏幕下(y+)对应世界 +z（相机在 +z 侧俯瞰）。
func physics_update(delta: float, bounds_half_x: float, bounds_half_z: float) -> void:
	bob_t += delta * 6.0
	var dir := Vector3(move_vec.x, 0.0, move_vec.y)
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	position += dir * MOVE_SPEED * delta
	position.x = clampf(position.x, -bounds_half_x, bounds_half_x)
	position.z = clampf(position.z, -bounds_half_z, bounds_half_z)

	# 受击无敌闪烁。
	if invuln_left > 0.0:
		invuln_left -= delta
		_flicker_t -= delta
		if _flicker_t <= 0.0:
			_flicker_t = 0.06
			_body.visible = not _body.visible
	else:
		_body.visible = true

	# 受击闪白能量衰减回常态。
	if _flash_energy > 0.0:
		_flash_energy = maxf(0.0, _flash_energy - delta * 9.0)
		_body_mat.emission_energy_multiplier = 0.35 + _flash_energy

	# 呼吸起伏。
	_body.position.y = 0.52 + sin(bob_t) * 0.03


## 让枪口朝向某方向（XZ 平面，用于自动瞄准的可视反馈）。
func face_toward(world_dir: Vector3) -> void:
	if world_dir.length_squared() < 0.0001:
		return
	facing = Vector3(world_dir.x, 0.0, world_dir.z).normalized()
	rotation.y = atan2(facing.x, facing.z)


func take_damage() -> void:
	if invuln_left > 0.0:
		return
	hp -= 1
	invuln_left = INVULN_TIME
	_flash_energy = 2.0
