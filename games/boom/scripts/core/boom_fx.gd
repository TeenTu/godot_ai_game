class_name BoomFx
extends Node
## 手感粒子：击杀/受击的小爆发 + 击杀地面焦痕（渐进烧焦渐隐）。
## gl_compatibility 渲染器无 Decal，用躺平的半透明 CylinderMesh 模拟焦痕。
## 全部对象池复用：只改位置/颜色/数量，不即时 instantiate。

const PUFF_COUNT: int = 8
const GOO_COUNT: int = 6
const SCORCH_COUNT: int = 10
const MAX_AMOUNT: int = 40

var _puffs: Array = []  # 小泡泡/火星
var _goos: Array = []  # 击杀爆浆
var _puff_idx: int = 0
var _goo_idx: int = 0
var _scorches: Array = []
var _scorch_mats: Array = []
var _scorch_tweens: Array = []
var _scorch_idx: int = 0
var _shared_sphere: SphereMesh = null


func _ready() -> void:
	for i in PUFF_COUNT:
		_puffs.append(_build_particles(0.06, 0.14, 0.18, Color.WHITE))
	for i in GOO_COUNT:
		_goos.append(_build_particles(0.12, 0.34, 0.42, Color.WHITE))
	for i in SCORCH_COUNT:
		var m := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.55
		cyl.bottom_radius = 0.55
		cyl.height = 0.02
		cyl.radial_segments = 16
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.10, 0.07, 0.06, 0.5)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = false
		m.mesh = cyl
		m.material_override = mat
		m.visible = false
		_scorch_mats.append(mat)
		_scorch_tweens.append(null)
		add_child(m)
		_scorches.append(m)


func _build_particles(min_s: float, max_s: float, life: float, _c: Color) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	p.direction = Vector3(1.0, 0.2, 0.0)
	p.spread = 160.0
	p.amount = 10
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.gravity = Vector3(0.0, -3.5, 0.0)
	p.initial_velocity_min = min_s * 7.0
	p.initial_velocity_max = max_s * 9.0
	p.scale_amount_min = min_s * 2.2
	p.scale_amount_max = max_s * 2.6
	p.orbit_velocity_min = 0.0
	p.orbit_velocity_max = 0.0
	p.mesh = _sphere_mesh()
	p.visible = false
	p.emitting = false
	add_child(p)
	return p


func _sphere_mesh() -> SphereMesh:
	if _shared_sphere == null:
		_shared_sphere = SphereMesh.new()
		_shared_sphere.radius = 0.05
		_shared_sphere.height = 0.1
		_shared_sphere.radial_segments = 6
		_shared_sphere.rings = 3
	return _shared_sphere


## 小爆发（命中/开火音画点）。
func puff(pos: Vector3, color: Color, amount: int) -> void:
	if amount <= 0:
		return
	var p := _puffs[_puff_idx] as CPUParticles3D
	_puff_idx = (_puff_idx + 1) % _puffs.size()
	_fire(p, pos, color, amount)


## 击杀大爆发。
func goo_burst(pos: Vector3, color: Color) -> void:
	var p := _goos[_goo_idx] as CPUParticles3D
	_goo_idx = (_goo_idx + 1) % _goos.size()
	_fire(p, pos, color, 22)


func _fire(p: CPUParticles3D, pos: Vector3, color: Color, amount: int) -> void:
	p.emitting = false
	p.amount = mini(amount, MAX_AMOUNT)
	p.color = color
	p.global_position = pos
	p.global_rotation = Vector3.ZERO
	p.visible = true
	p.emitting = true


## 击杀焦痕：中心随机旋转，逐渐烧黑再隐退。
func scorch(pos: Vector3, radius: float) -> void:
	var idx := _scorch_idx
	_scorch_idx = (_scorch_idx + 1) % _scorches.size()
	var m := _scorches[idx] as MeshInstance3D
	var mat := _scorch_mats[idx] as StandardMaterial3D
	var old := _scorch_tweens[idx] as Tween
	if old != null and old.is_valid():
		old.kill()
	m.global_position = pos + Vector3(0.0, 0.012, 0.0)
	m.global_rotation = Vector3(0.0, randf() * TAU, 0.0)
	m.scale = Vector3.ONE * maxf(0.6, radius * 1.4)
	m.visible = true
	mat.albedo_color = Color(0.10, 0.07, 0.06, 0.55)
	var tw := create_tween()
	tw.tween_method(_fade_scorch.bind(mat), 0.55, 0.0, 3.4)
	tw.tween_callback(func() -> void: m.visible = false)
	_scorch_tweens[idx] = tw


func _fade_scorch(mat: StandardMaterial3D, alpha: float) -> void:
	mat.albedo_color.a = alpha
