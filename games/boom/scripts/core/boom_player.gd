class_name BoomPlayer
extends Node3D
## 玩家：可换武器（泡泡枪/大剑）。移动由 BoomGame 驱动（读摇杆向量），本类只管
## 视觉与朝向、受击无敌闪烁状态、武器形态（2D 雪碧图动画 vs 程序化回退）。
## M5（design_m5_weapons.md §6/§7）：形态 = 泡泡队长·远程/近战双形态，同一角色。

const BASE_MAX_HP: int = 5
const RADIUS: float = 0.55
const MOVE_SPEED: float = 5.4
const INVULN_TIME: float = 0.9

## 2D 帧条规格（design §6.0）：单帧 256×256、横向无缝拼接、透明底。
const FRAME_PX: int = 256
const STRIP_DIR: String = "res://assets/images/characters/"
const _ANIM_FPS: Dictionary = {
	"idle": 6.0,  # ≈6fps 呼吸起伏
	"move": 12.0,  # ≈12fps 小步快挪
	"recoil": 24.0,  # 3 帧单次 ≈0.125s
	"swing": 30.0,  # 8 帧单次 ≈0.27s 攻帧
	"hurt": 12.0,  # 2 帧受击
}
## 每形态可用的帧条（前缀→文件名；帧数见 design §6.1）。
const FORM_STRIPS: Dictionary = {
	"bubble":
	{
		"idle": ["player_bubble_idle", 4],
		"move": ["player_bubble_move", 6],
		"recoil": ["player_bubble_recoil", 3],
	},
	"sword":
	{
		"idle": ["player_sword_idle", 4],
		"move": ["player_sword_move", 6],
		"swing": ["player_sword_swing", 8],
	},
}
const HURT_STRIP: String = "player_hurt"
const HURT_FRAMES: int = 2

## 有效机体数值（由 BoomGame.apply_weapon 注入当前武器 def，见 design §3.3）。
var max_hp: int = BASE_MAX_HP
var hp: int = BASE_MAX_HP
var radius: float = RADIUS
var move_speed: float = MOVE_SPEED
var weapon_id: String = ""
var anim_form: String = "bubble"  # 当前形态：bubble / sword

var invuln_left: float = 0.0
var move_vec: Vector2 = Vector2.ZERO
var facing: Vector3 = Vector3.FORWARD
var muzzle: Node3D = null
var bob_t: float = 0.0
## 锁移动窗口（大剑挥斩 active 段，由 BoomGame 写入，design §4.2）。
var lock_move_left: float = 0.0

var _procedural_root: Node3D
var _body_mat: StandardMaterial3D
var _anim: AnimatedSprite3D = null
var _sprite_frames: SpriteFrames = null
var _transient_anim: bool = false
var _flicker_t: float = 0.0
var _flash_energy: float = 0.0


func _init() -> void:
	_build_visuals()
	_build_form_art()


## 程序化基础造型（保留作 2D 素材缺失时的回退）：圆舱体 + 头球 + 枪管 + 眼睛 + 枪口。
func _build_visuals() -> void:
	_procedural_root = Node3D.new()
	_procedural_root.name = "ProceduralBody"
	add_child(_procedural_root)

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
	var body := MeshInstance3D.new()
	body.mesh = body_sphere
	body.material_override = _body_mat
	body.position.y = 0.52
	_procedural_root.add_child(body)

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
	_procedural_root.add_child(cap)

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
	_procedural_root.add_child(barrel)

	# 眼睛：朝 +Z（脸朝向）。
	_add_eye(Vector3(-0.15, 0.7, 0.34), 0.06)
	_add_eye(Vector3(0.15, 0.7, 0.34), 0.06)

	# 枪口锚点。
	muzzle = Node3D.new()
	muzzle.position = Vector3(0.0, 0.5, 0.9)
	add_child(muzzle)


func _add_eye(local_pos: Vector3, radius_value: float) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = radius_value
	sphere.height = radius_value * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.08, 0.12)
	mat.roughness = 0.2
	var eye := MeshInstance3D.new()
	eye.mesh = sphere
	eye.material_override = mat
	eye.position = local_pos
	_procedural_root.add_child(eye)


## 按当前 anim_form 构建 2D 形态动画（AnimatedSprite3D + SpriteFrames，横条切帧）。
## 无素材（文件不存在）则保持程序化造型回退（R4/R6 兜底）。
func _build_form_art() -> void:
	var idle_sheet: Array = FORM_STRIPS[anim_form]["idle"]
	var idle_path: String = STRIP_DIR + (idle_sheet[0] as String) + ".png"
	if not ResourceLoader.exists(idle_path):
		_anim = null
		_sprite_frames = null
		_sync_visual_layers()
		return
	_sprite_frames = _build_sprite_frames()
	if _sprite_frames == null:
		_anim = null
		_sync_visual_layers()
		return
	_anim = AnimatedSprite3D.new()
	_anim.name = "PlayerAnim2D"
	_anim.sprite_frames = _sprite_frames
	_anim.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_anim.pixel_size = 0.0076  # 256px 画布 ≈1.95 世界单位高（≈1.9 含呆毛，§6.0 换算）
	_anim.position = Vector3(0.0, 0.92, 0.0)
	_anim.render_priority = 2
	add_child(_anim)
	_anim.play("idle")
	_anim.animation_finished.connect(_on_anim_finished)
	_sync_visual_layers()


## 单次动作播完回到基础动画（idle/move 按移动自动切）。
func _on_anim_finished() -> void:
	_transient_anim = false
	if _anim == null:
		return
	var want := _base_anim_name()
	if _sprite_frames.has_animation(want):
		_anim.play(want)


## 由 frame strip PNG（帧数×256 × 256）代码构建 SpriteFrames：
## 不依赖编辑器动画，帧坐标元数据写在本类 const（§6.0 帧图规范）。
func _build_sprite_frames() -> SpriteFrames:
	var sf := SpriteFrames.new()
	var built := false
	for action in FORM_STRIPS[anim_form]:
		var spec: Array = FORM_STRIPS[anim_form][action]
		var path: String = STRIP_DIR + (spec[0] as String) + ".png"
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			continue
		var frames: int = spec[1]
		sf.add_animation(action)
		sf.set_animation_loop(action, action == "idle" or action == "move")
		sf.set_animation_speed(action, _ANIM_FPS[action])
		for i in frames:
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(float(i) * FRAME_PX, 0.0, FRAME_PX, FRAME_PX)
			sf.add_frame(action, atlas)
		built = true
	# 两形态共用受击帧条（§6.1 hurt_shared）。
	var hurt_path := STRIP_DIR + HURT_STRIP + ".png"
	if ResourceLoader.exists(hurt_path):
		var hurt_tex := load(hurt_path) as Texture2D
		if hurt_tex != null:
			sf.add_animation("hurt")
			sf.set_animation_loop("hurt", false)
			sf.set_animation_speed("hurt", _ANIM_FPS["hurt"])
			for i in HURT_FRAMES:
				var atlas := AtlasTexture.new()
				atlas.atlas = hurt_tex
				atlas.region = Rect2(float(i) * FRAME_PX, 0.0, FRAME_PX, FRAME_PX)
				sf.add_frame("hurt", atlas)
			built = true
	return sf if built else null


## 切换程序化/2D 层的可见性（同源两形态共用一套闪烁/受击逻辑，R4）。
func _sync_visual_layers() -> void:
	var use_2d: bool = _anim != null and _sprite_frames != null
	_procedural_root.visible = not use_2d
	if _anim != null:
		_anim.visible = use_2d
	# 2D 形态枪口锚到形态语义位（R5：技能/子弹仍可引用 muzzle）。
	if anim_form == "sword":
		muzzle.position = Vector3(0.0, 1.1, 0.85)
	else:
		muzzle.position = Vector3(0.0, 0.9, 0.8)


## 由 BoomGame 在切换武器时注入武器 def：机体数值 + 形态（design §3.3/§4.1）。
func apply_weapon(def: BoomWeaponDef) -> void:
	weapon_id = def.id
	move_speed = MOVE_SPEED * def.move_mult
	max_hp = maxi(1, BASE_MAX_HP + def.max_hp_bonus)
	hp = max_hp
	radius = def.radius
	var new_form := "sword" if def.kind == BoomWeaponDef.AttackKind.MELEE else "bubble"
	if new_form != anim_form or _anim == null:
		anim_form = new_form
		_clear_art()
		_build_form_art()


func _clear_art() -> void:
	if _anim != null:
		_anim.queue_free()
		_anim = null
	_sprite_frames = null
	_transient_anim = false


## 设定移动输入（来自摇杆的 -1..1 向量）。
func set_move(v: Vector2) -> void:
	move_vec = v


## 播放单次形态动作（泡泡开火后座 / 大剑挥斩 / 受击），播完回到基础动画。
func play_anim_once(action: String) -> void:
	if _anim == null or _sprite_frames == null:
		return
	if not _sprite_frames.has_animation(action):
		return
	_anim.play(action)
	_transient_anim = true


func _base_anim_name() -> String:
	return "move" if move_vec.length_squared() > 0.01 else "idle"


## 每物理帧由 BoomGame 调用：执行移动并做小幅呼吸动画。
## 摇杆屏幕向量 → 世界 XZ：x 直通，屏幕下(y+)对应世界 +z（相机在 +z 侧俯瞰）。
func physics_update(delta: float, bounds_half_x: float, bounds_half_z: float) -> void:
	bob_t += delta * 6.0
	var dir := Vector3(move_vec.x, 0.0, move_vec.y)
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	if lock_move_left > 0.0:
		lock_move_left = maxf(0.0, lock_move_left - delta)
		dir = Vector3.ZERO
	position += dir * move_speed * delta
	position.x = clampf(position.x, -bounds_half_x, bounds_half_x)
	position.z = clampf(position.z, -bounds_half_z, bounds_half_z)

	# 受击无敌闪烁。
	if invuln_left > 0.0:
		invuln_left -= delta
		_flicker_t -= delta
		if _flicker_t <= 0.0:
			_flicker_t = 0.06
			if _anim != null:
				var a: float = 0.25 if _anim.modulate.a > 0.5 else 1.0
				_anim.modulate.a = a
			else:
				_procedural_root.visible = not _procedural_root.visible
	else:
		if _anim != null:
			_anim.modulate.a = 1.0
		else:
			_procedural_root.visible = true

	# 受击闪白能量衰减回常态（程序化 emission；2D 形态用 modulate 过曝近似白闪，R6）。
	if _flash_energy > 0.0:
		_flash_energy = maxf(0.0, _flash_energy - delta * 9.0)
		_body_mat.emission_energy_multiplier = 0.35 + _flash_energy
		if _anim != null:
			var f: float = _flash_energy * 0.5
			_anim.modulate.r = 1.0 + f
			_anim.modulate.g = 1.0 + f
			_anim.modulate.b = 1.0 + f
	else:
		_body_mat.emission_energy_multiplier = 0.35
		if _anim != null:
			_anim.modulate.r = 1.0
			_anim.modulate.g = 1.0
			_anim.modulate.b = 1.0

	# 呼吸起伏：2D 形态对 AnimatedSprite3D 做 scale 呼吸，程序化回退走 body 位移。
	if _anim != null:
		var breath := 1.0 + sin(bob_t) * 0.012
		_anim.scale = Vector3(breath, breath, breath)
		if not _transient_anim:
			var want := _base_anim_name()
			if _sprite_frames.has_animation(want) and _anim.animation != want:
				_anim.play(want)
	else:
		_procedural_root.position.y = sin(bob_t) * 0.03


## 让枪口朝向某方向（XZ 平面，用于自动瞄准的可视反馈）。
func face_toward(world_dir: Vector3) -> void:
	if world_dir.length_squared() < 0.0001:
		return
	facing = Vector3(world_dir.x, 0.0, world_dir.z).normalized()
	rotation.y = atan2(facing.x, facing.z)


## 返回 2D 形态是否激活（play_test/表现层查询）。
func is_2d_form() -> bool:
	return _anim != null and _anim.visible


func take_damage() -> void:
	if invuln_left > 0.0:
		return
	hp -= 1
	invuln_left = INVULN_TIME
	_flash_energy = 2.0
	if _anim != null:
		play_anim_once("hurt")
