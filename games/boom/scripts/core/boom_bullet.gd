class_name BoomBullet
extends Node3D
## 灵印投射物：飞行距离固定寿命，命中敌人后由 BoomGame 回收进对象池。
## 运行时优先显示灯火灵印雪碧条，缺图时回退到程序化琥珀光球。

const SPEED: float = 15.0
const LIFETIME: float = 1.6
const RADIUS: float = 0.18
const SEAL_DIR: String = "res://assets/images/projectiles/candidates/"
const SEAL_STRIP_PATH: String = SEAL_DIR + "projectile_lantern_seal.png"
const FRAME_PX: int = 256

var vel: Vector3 = Vector3.ZERO
var life: float = 0.0
var active: bool = false
var origin: Vector3 = Vector3.ZERO
var max_distance: float = INF
## 弹道变体归属：straight=普通灵印 / fan=爆裂灵印（§4.2 每命中飘字按此判定）。
var variant: String = "straight"
var _mesh: MeshInstance3D
var _anim: AnimatedSprite3D = null


func _init() -> void:
	_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("f2b84b")
	mat.emission_enabled = true
	mat.emission = Color("ffe6a1")
	mat.emission_energy_multiplier = 1.4
	mat.roughness = 0.15
	_mesh.mesh = sphere
	_mesh.material_override = mat
	add_child(_mesh)
	_build_seal_sprite()
	visible = false


func _build_seal_sprite() -> void:
	if not ResourceLoader.exists(SEAL_STRIP_PATH):
		return
	var tex := load(SEAL_STRIP_PATH) as Texture2D
	if tex == null:
		return
	var frames := SpriteFrames.new()
	frames.add_animation("travel")
	frames.set_animation_loop("travel", false)
	frames.set_animation_speed("travel", 12.0)
	for i in 5:
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(float(i) * FRAME_PX, 0.0, FRAME_PX, FRAME_PX)
		frames.add_frame("travel", atlas)
	_anim = AnimatedSprite3D.new()
	_anim.name = "SpiritSealAnim"
	_anim.sprite_frames = frames
	_anim.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_anim.pixel_size = 0.0032
	_anim.render_priority = 4
	add_child(_anim)
	_mesh.visible = false


## 从对象池取出开火：重置位置/速度/寿命并显示。
func fire(from: Vector3, dir: Vector3, p_max_distance: float = INF) -> void:
	position = from
	origin = from
	max_distance = p_max_distance
	vel = dir * SPEED
	life = LIFETIME
	active = true
	variant = "straight"
	if _anim != null:
		_anim.frame = 0
		_anim.frame_progress = 0.0
		_anim.play("travel")
	visible = true


## 命中/出界/寿命耗尽后回收（由池主调用）。
func recycle() -> void:
	active = false
	max_distance = INF
	visible = false
