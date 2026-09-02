class_name BoomSkillFx
extends Node
## M2 弹幕/技能系统的纯视觉特效层，只做画面、不做判定。
## 三种技能各一种视觉语言：爆裂弹幕=枪口闪光、闪电链=黄色抖动电弧、核爆=扩散圆环+金色粒子爆。
## gl_compatibility 限制下零素材：电弧/圆环用 ImmediateMesh 每帧重建，
## 枪口闪光与通用粒子爆用 CPUParticles3D，全部程序化。
## 对象池复用：固定大小数组 + 环形索引，所有节点 _ready 预建，用完置 visible=false。

const MUZZLE_COUNT: int = 4  # 枪口闪光发射器数
const BURST_COUNT: int = 6  # 通用粒子爆发射器数
const MAX_AMOUNT: int = 60  # 单次粒子爆上限
const BOLT_COUNT: int = 6  # 电弧条数（链式 3 跳 + 并发冗余）
const BOLT_LIFE: float = 0.4  # 单段电弧闪现时长
const BOLT_WIDTH: float = 0.09  # 电弧带宽
const BOLT_SEGS_MIN: int = 6
const BOLT_SEGS_MAX: int = 14
const SHOCK_COUNT: int = 3  # 冲击波圆环条数
const SHOCK_LIFE: float = 0.6
const RING_SEGMENTS: int = 44
const RING_START: float = 0.7  # 圆环起始半径（几何半径，节点不做缩放）
const RING_WIDTH: float = 0.6  # 圆环带宽，扩散过程中保持恒定

var _muzzles: Array = []  # 枪口闪光（锥形短促小粒子）
var _bursts: Array = []  # 通用粒子爆（核爆中心金色大爆）
var _muzzle_idx: int = 0
var _burst_idx: int = 0

# 单条电弧 = 1 个主 MeshInstance3D(ImmediateMesh 折带) + 两端火花小球，共用同材质便于整体淡出
var _bolt_nodes: Array = []
var _bolt_meshes: Array = []
var _bolt_mats: Array = []
var _bolt_cap_a: Array = []
var _bolt_cap_b: Array = []
var _bolt_tweens: Array = []
var _bolt_idx: int = 0

# 冲击波圆环：躺平在 XZ 平面、每帧按半径重建保持带宽恒定
var _ring_nodes: Array = []
var _ring_meshes: Array = []
var _ring_mats: Array = []
var _ring_tweens: Array = []
var _ring_idx: int = 0

var _shared_sphere: SphereMesh = null


func _ready() -> void:
	for i in MUZZLE_COUNT:
		_muzzles.append(_build_emitter(16.0, 0.16, 3.0, 6.5, 1.0, 2.2, Vector3(0.0, -1.0, 0.0), 14))
	for i in BURST_COUNT:
		_bursts.append(_build_emitter(170.0, 0.55, 2.5, 7.0, 2.0, 5.0, Vector3(0.0, -2.0, 0.0), 30))
	for i in BOLT_COUNT:
		_build_bolt()
	for i in SHOCK_COUNT:
		_build_ring()


## 粒子发射器：方向发射时按调用方覆盖，这里只管尺寸/速度/寿命等通用参数。
func _build_emitter(
	spread: float,
	life: float,
	vel_min: float,
	vel_max: float,
	scale_min: float,
	scale_max: float,
	gravity: Vector3,
	amount: int,
) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = spread
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.gravity = gravity
	p.initial_velocity_min = vel_min
	p.initial_velocity_max = vel_max
	p.scale_amount_min = scale_min
	p.scale_amount_max = scale_max
	p.mesh = _sphere_mesh()
	p.visible = false
	p.emitting = false
	add_child(p)
	return p


## 预建一条电弧节点：主折带 + 两端火花，材质共享使 alpha 淡出同步。
func _build_bolt() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.95, 0.4, 1.0)
	var n := MeshInstance3D.new()
	n.mesh = ImmediateMesh.new()
	n.material_override = mat
	n.visible = false
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(n)
	var cap_a := _build_cap(mat)
	var cap_b := _build_cap(mat)
	n.add_child(cap_a)
	n.add_child(cap_b)
	_bolt_nodes.append(n)
	_bolt_meshes.append(n.mesh)
	_bolt_mats.append(mat)
	_bolt_cap_a.append(cap_a)
	_bolt_cap_b.append(cap_b)
	_bolt_tweens.append(null)


func _build_cap(mat: StandardMaterial3D) -> MeshInstance3D:
	var cap := MeshInstance3D.new()
	cap.mesh = _sphere_mesh()
	cap.material_override = mat
	cap.visible = false
	cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return cap


## 预建冲击波圆环节点。
func _build_ring() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.8, 0.2, 0.0)
	var n := MeshInstance3D.new()
	n.mesh = ImmediateMesh.new()
	n.material_override = mat
	n.visible = false
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(n)
	_ring_nodes.append(n)
	_ring_meshes.append(n.mesh)
	_ring_mats.append(mat)
	_ring_tweens.append(null)


func _sphere_mesh() -> SphereMesh:
	if _shared_sphere == null:
		_shared_sphere = SphereMesh.new()
		_shared_sphere.radius = 0.05
		_shared_sphere.height = 0.1
		_shared_sphere.radial_segments = 6
		_shared_sphere.rings = 3
	return _shared_sphere


## 爆裂弹幕枪口闪光：一撮沿 dir 方向的小粒子（白偏当前色），短促 one-shot。
func muzzle_flash(pos: Vector3, dir: Vector3, color: Color) -> void:
	if dir.length_squared() < 0.0001:
		return
	var p := _muzzles[_muzzle_idx] as CPUParticles3D
	_muzzle_idx = (_muzzle_idx + 1) % _muzzles.size()
	p.emitting = false
	p.amount = 14
	p.direction = dir.normalized()
	p.color = color.lerp(Color.WHITE, 0.55)
	p.global_position = pos
	p.global_rotation = Vector3.ZERO
	p.visible = true
	p.emitting = true


## 闪电链单段：a→b 一条黄色抖动电弧。闪烁用 alpha 高配比重复抖动后淡出，
## 不做逐帧顶点动画；链式多段由调用方循环本函数。
func arc_bolt(a: Vector3, b: Vector3, color: Color) -> void:
	var delta := b - a
	var span := delta.length()
	if span < 0.05:
		return
	var idx := _bolt_idx
	_bolt_idx = (_bolt_idx + 1) % _bolt_nodes.size()
	var n := _bolt_nodes[idx] as MeshInstance3D
	var im := _bolt_meshes[idx] as ImmediateMesh
	var mat := _bolt_mats[idx] as StandardMaterial3D
	var old := _bolt_tweens[idx] as Tween
	if old != null and old.is_valid():
		old.kill()
	# 端点火花：链跳触点的亮点
	var cap_a := _bolt_cap_a[idx] as MeshInstance3D
	var cap_b := _bolt_cap_b[idx] as MeshInstance3D
	n.global_position = a
	n.global_rotation = Vector3.ZERO
	mat.albedo_color = color
	# 折线中心点：两端固定，中段横向抖动（bulge=sin 使端点为 0）+ 轻微上抛
	var segs := clampi(int(ceilf(span / 1.4)) + 3, BOLT_SEGS_MIN, BOLT_SEGS_MAX)
	var amp := randf_range(0.16, 0.45)
	var pts := _bolt_points(delta / span, span, segs, amp)
	_bolt_draw(im, pts, BOLT_WIDTH)
	cap_a.position = Vector3.ZERO
	cap_a.scale = Vector3.ONE * randf_range(1.2, 1.8)
	cap_b.position = delta
	cap_b.scale = Vector3.ONE * randf_range(1.6, 2.4)
	cap_a.visible = true
	cap_b.visible = true
	n.visible = true
	var phase := randf_range(0.0, TAU)
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void: _flicker_bolt(mat, v, phase), 1.0, 0.0, BOLT_LIFE)
	tw.tween_callback(func() -> void: n.visible = false)
	_bolt_tweens[idx] = tw


## 核爆冲击波：自 center 扩散到 radius 的躺平圆环，带宽恒定、渐大渐隐一次。
func shockwave(center: Vector3, radius: float, color: Color) -> void:
	var idx := _ring_idx
	_ring_idx = (_ring_idx + 1) % _ring_nodes.size()
	var n := _ring_nodes[idx] as MeshInstance3D
	var im := _ring_meshes[idx] as ImmediateMesh
	var mat := _ring_mats[idx] as StandardMaterial3D
	var old := _ring_tweens[idx] as Tween
	if old != null and old.is_valid():
		old.kill()
	n.global_position = center + Vector3(0.0, 0.08, 0.0)
	n.global_rotation = Vector3.ZERO
	mat.albedo_color = color
	var target := maxf(radius, RING_START + 0.1)
	n.visible = true
	var tw := create_tween()
	tw.tween_method(func(p: float) -> void: _grow_ring(im, mat, p, target), 0.0, 1.0, SHOCK_LIFE)
	tw.tween_callback(func() -> void: n.visible = false)
	_ring_tweens[idx] = tw


## 通用粒子爆（核爆中心金色大爆用），count≈40。
func burst(pos: Vector3, color: Color, count: int) -> void:
	if count <= 0:
		return
	var p := _bursts[_burst_idx] as CPUParticles3D
	_burst_idx = (_burst_idx + 1) % _bursts.size()
	p.emitting = false
	p.amount = mini(count, MAX_AMOUNT)
	p.color = color
	p.global_position = pos
	p.global_rotation = Vector3.ZERO
	p.visible = true
	p.emitting = true


## 电弧折带路径：两端固定 + 横向抖动 + 轻微上抛，让短弧有"跳跃"感。
func _bolt_points(dir: Vector3, span: float, segs: int, amp: float) -> Array[Vector3]:
	var side := _side_of(dir)
	var pts: Array[Vector3] = []
	for i in segs:
		var t := float(i) / float(segs - 1)
		var bulge := sin(PI * t)
		var jitter := (randf() - 0.5) * 2.0 * amp * bulge
		var lift := randf_range(0.0, amp) * bulge * 0.5
		pts.append(dir * (span * t) + side * jitter + Vector3(0.0, lift, 0.0))
	return pts


## 用三角形折带画折线，带宽固定，gl_compatibility 下足够亮足够粗。
func _bolt_draw(im: ImmediateMesh, pts: Array[Vector3], width: float) -> void:
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var half_w := width * 0.5
	for j in pts.size():
		var off := _side_of(_tangent_at(pts, j))
		var c: Vector3 = pts[j]
		im.surface_add_normal(off)
		im.surface_add_vertex(c + off * half_w)
		im.surface_add_normal(-off)
		im.surface_add_vertex(c - off * half_w)
	im.surface_end()


func _tangent_at(pts: Array[Vector3], j: int) -> Vector3:
	if j == 0:
		return (pts[1] - pts[0]).normalized()
	if j == pts.size() - 1:
		return (pts[j] - pts[j - 1]).normalized()
	return (pts[j + 1] - pts[j - 1]).normalized()


## 与 dir 垂直的横向单位向量，dir 接近竖直时退化为水平向。
func _side_of(dir: Vector3) -> Vector3:
	var ref := Vector3.UP if absf(dir.y) < 0.92 else Vector3.RIGHT
	var side := dir.cross(ref)
	if side.length_squared() < 1.0e-6:
		side = dir.cross(Vector3.RIGHT)
	return side.normalized()


## 电弧闪烁：v 从 1 线性走到 0，内部乘高频余弦做两三次明暗跳动再淡出。
func _flicker_bolt(mat: StandardMaterial3D, v: float, phase: float) -> void:
	var p := 1.0 - v
	var flicker := 0.35 + 0.65 * absf(cos(p * TAU * 3.0 + phase))
	var c := mat.albedo_color
	c.a = v * flicker
	mat.albedo_color = c


## 圆环生长：p 0→1，前缘半径扩散（先快后慢），alpha 逐渐归零。
func _grow_ring(im: ImmediateMesh, mat: StandardMaterial3D, p: float, target: float) -> void:
	var front := lerpf(RING_START, target, pow(p, 0.75))
	_ring_draw(im, front)
	var c := mat.albedo_color
	c.a = 0.95 * pow(1.0 - p, 0.85)
	mat.albedo_color = c


## 重建一条 XZ 平面的环带：外圈 front、内圈 front-RING_WIDTH（下限夹住避免负半径）。
func _ring_draw(im: ImmediateMesh, front: float) -> void:
	im.clear_surfaces()
	var inner := maxf(front - RING_WIDTH, 0.02)
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in RING_SEGMENTS + 1:
		var a := TAU * float(i) / float(RING_SEGMENTS)
		var c := cos(a)
		var s := sin(a)
		im.surface_add_normal(Vector3.UP)
		im.surface_add_vertex(Vector3(front * c, 0.0, front * s))
		im.surface_add_normal(Vector3.UP)
		im.surface_add_vertex(Vector3(inner * c, 0.0, inner * s))
	im.surface_end()
