class_name BoomPlayer
extends Node3D
## 玩家：夜巡灯使可换武器。移动由 BoomGame 驱动（读摇杆向量），本类只管
## 视觉与朝向、受击无敌闪烁状态、武器动作语义（2D 雪碧图动画 vs 程序化回退）。
## 远程/近战共用同一位无武器女灯使；武器通过 WeaponSocket 作为独立图层绑定。

## M8 数值制（design_m8_attributes.md §4.1）：泡泡枪 50 / 大剑 70（+20 武器补偿）。
## 升级不再增加最大生命；生命类升级统一为"回满当前生命"。
const BASE_MAX_HP: int = 50
const RADIUS: float = 0.55
const MOVE_SPEED: float = 5.4
const INVULN_TIME: float = 0.9
const FACING_HYSTERESIS: float = 1.18
const WeaponBinding = preload("res://scripts/core/boom_weapon_binding.gd")

## 2D 帧条规格（design §6.0）：单帧 256×256、横向无缝拼接、透明底。
const FRAME_PX: int = 256
const STRIP_DIR: String = "res://assets/images/characters/night_patrol/"
## 武器素材/比例/握柄/缺失动作策略全部来自 WeaponBinding.CONFIGS[visual_id]。
const _ANIM_FPS: Dictionary = {
	"idle": 6.0,
	"move": 12.0,
	"idle_down": 6.0,  # ≈6fps 呼吸起伏
	"idle_up": 6.0,
	"idle_left": 6.0,
	"idle_right": 6.0,
	"move_down": 12.0,  # ≈12fps 小步快挪
	"move_up": 12.0,
	"move_left": 12.0,
	"move_right": 12.0,
	"recoil": 14.0,  # 3 帧远程施法身姿
	"swing": 16.0,  # 5 帧近战挥击身姿
	"hurt": 12.0,  # 3 帧受击
	"skill_cast": 12.0,
	"knockdown": 10.0,
}
## 每形态可用的帧条（前缀→文件名；帧数见 design §6.1）。
const FORM_STRIPS: Dictionary = {
	"bubble":
	{
		"idle_down": ["hero_idle_unarmed", 4],
		"idle_up": ["hero_idle_up", 1],
		"idle_left": ["hero_idle_left", 1],
		"idle_right": ["hero_idle_right", 1],
		"move_down": ["hero_move_unarmed", 6],
		"move_up": ["hero_move_up", 6],
		"move_left": ["hero_move_left", 6],
		"move_right": ["hero_move_right", 6],
		"recoil": ["hero_ranged_cast_body", 3],
		"skill_cast": ["hero_skill_cast_body", 4],
		"knockdown": ["hero_knockdown_unarmed", 4],
	},
	"sword":
	{
		"idle_down": ["hero_idle_unarmed", 4],
		"idle_up": ["hero_idle_up", 1],
		"idle_left": ["hero_idle_left", 1],
		"idle_right": ["hero_idle_right", 1],
		"move_down": ["hero_move_unarmed", 6],
		"move_up": ["hero_move_up", 6],
		"move_left": ["hero_move_left", 6],
		"move_right": ["hero_move_right", 6],
		"swing": ["hero_melee_swing_body", 5],
		"skill_cast": ["hero_skill_cast_body", 4],
		"knockdown": ["hero_knockdown_unarmed", 4],
	},
}
const HURT_STRIP: String = "hero_hurt_unarmed"
const HURT_FRAMES: int = 3

## 有效机体数值（由 BoomGame.apply_weapon 注入当前武器 def，见 design §3.3）。
var max_hp: int = BASE_MAX_HP
var hp: int = BASE_MAX_HP
var radius: float = RADIUS
var move_speed: float = MOVE_SPEED
var weapon_id: String = ""
var anim_form: String = "bubble"  # 动画形态：bubble=镇夜灯·镇尺，sword=墨线判笔
var visual_id: String = "night_ruler"  # 视觉配置 ID（WeaponBinding.CONFIGS 的 key）

var invuln_left: float = 0.0
var move_vec: Vector2 = Vector2.ZERO
var facing_anim: String = "down"
var facing: Vector3 = Vector3.FORWARD
var muzzle: Node3D = null
var bob_t: float = 0.0
## 锁移动窗口（墨线判笔挥击 active 段，由 BoomGame 写入，design §4.2）。
var lock_move_left: float = 0.0

var _procedural_root: Node3D
var _body_mat: StandardMaterial3D
var _anim: AnimatedSprite3D = null
var _sprite_frames: SpriteFrames = null
var _weapon_socket: Node3D = null
var _weapon_anim: AnimatedSprite3D = null
var _weapon_frames: SpriteFrames = null
var _hand_anim: AnimatedSprite3D = null
var _hand_frames: SpriteFrames = null
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
	var idle_sheet: Array = FORM_STRIPS[anim_form]["idle_down"]
	var idle_path: String = STRIP_DIR + (idle_sheet[0] as String) + ".png"
	if not ResourceLoader.exists(idle_path):
		_anim = null
		_sprite_frames = null
		_clear_weapon_art()
		_sync_visual_layers()
		return
	_sprite_frames = _build_sprite_frames()
	if _sprite_frames == null:
		_anim = null
		_clear_weapon_art()
		_sync_visual_layers()
		return
	_anim = AnimatedSprite3D.new()
	_anim.name = "PlayerAnim2D"
	_anim.sprite_frames = _sprite_frames
	_anim.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_anim.pixel_size = WeaponBinding.BODY_PIXEL  # 256px 画布 ≈1.95 世界单位高（§6.0 换算）
	_anim.position = Vector3(0.0, 0.92, 0.0)
	_anim.render_priority = 2
	add_child(_anim)
	_anim.play("idle_down")
	_anim.animation_finished.connect(_on_anim_finished)
	_build_weapon_art()
	_build_hand_art()
	_anim.frame_changed.connect(_sync_weapon_animation)
	_sync_weapon_animation()
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
		sf.set_animation_loop(action, action.begins_with("idle_") or action.begins_with("move_"))
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


## 构建独立武器层：武器挂在 WeaponSocket，不烘焙进人物身体帧条。
func _build_weapon_art() -> void:
	var cfg: Dictionary = WeaponBinding.config(visual_id)
	var specs: Dictionary = cfg.get("strips", {})
	var strip_dir: String = cfg.get("weapon_dir", "")
	if specs.is_empty():
		return
	var sf := SpriteFrames.new()
	var built := false
	for action in specs:
		var spec: Array = specs[action]
		var path: String = strip_dir + (spec[0] as String) + ".png"
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			continue
		var action_name: String = action as String
		var frames: int = int(spec[1])
		sf.add_animation(action_name)
		sf.set_animation_loop(action_name, action_name in ["idle", "move"])
		sf.set_animation_speed(action_name, float(_ANIM_FPS.get(action_name, 12.0)))
		for i in frames:
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(float(i) * FRAME_PX, 0.0, FRAME_PX, FRAME_PX)
			sf.add_frame(action_name, atlas)
		built = true
	if not built:
		return
	_weapon_frames = sf
	if _weapon_socket == null:
		_weapon_socket = Node3D.new()
		_weapon_socket.name = "WeaponSocket"
		add_child(_weapon_socket)
	# 与身体共用中心；屏幕内握持偏移由 sprite offset 表达，避免自动瞄准旋转挂点。
	_weapon_socket.position = _anim.position
	_weapon_anim = AnimatedSprite3D.new()
	_weapon_anim.name = "WeaponAnim2D"
	_weapon_anim.sprite_frames = _weapon_frames
	_weapon_anim.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_weapon_anim.pixel_size = cfg.get("weapon_pixel", 0.006)
	_weapon_anim.position = Vector3.ZERO
	_weapon_anim.render_priority = 3
	_weapon_socket.add_child(_weapon_anim)
	var initial_action: String = (
		"idle"
		if _weapon_frames.has_animation("idle")
		else String(_weapon_frames.get_animation_names()[0])
	)
	_weapon_anim.play(initial_action)


## 手部前景层：从同一帧身体贴图裁 HAND_RECTS 区域，垫回 256x256 画布原位，
## 以高于武器的优先级重绘——与底层身体逐像素重合、零接缝，等效手指包住握柄。
func _build_hand_art() -> void:
	_hand_frames = null
	if _anim == null or _sprite_frames == null:
		return
	var sf := SpriteFrames.new()
	var built := false
	for action in FORM_STRIPS[anim_form]:
		if not WeaponBinding.HAND_RECTS.has(action):
			continue
		var rects: Array = WeaponBinding.HAND_RECTS[action]
		var spec: Array = FORM_STRIPS[anim_form][action]
		var count: int = spec[1]
		if rects.size() != count:
			continue
		var path := STRIP_DIR + (spec[0] as String) + ".png"
		if not ResourceLoader.exists(path):
			continue
		var strip := Image.load_from_file(ProjectSettings.globalize_path(path))
		if strip == null:
			continue
		sf.add_animation(action)
		sf.set_animation_loop(action, action.begins_with("idle_") or action.begins_with("move_"))
		sf.set_animation_speed(action, float(_ANIM_FPS.get(action, 12.0)))
		for i in count:
			var rect: Rect2 = rects[i]
			var frame_img := strip.get_region(Rect2(i * 256, 0, 256, 256))
			var crop := frame_img.get_region(Rect2i(rect))
			var padded := Image.create(256, 256, false, Image.FORMAT_RGBA8)
			padded.blend_rect(
				crop, Rect2i(0, 0, crop.get_width(), crop.get_height()), Vector2i(rect.position)
			)
			sf.add_frame(action, ImageTexture.create_from_image(padded))
			built = true
	if not built:
		return
	_hand_frames = sf
	_hand_anim = AnimatedSprite3D.new()
	_hand_anim.name = "HandFrontAnim2D"
	_hand_anim.sprite_frames = _hand_frames
	_hand_anim.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hand_anim.pixel_size = WeaponBinding.BODY_PIXEL
	_hand_anim.position = _anim.position
	_hand_anim.render_priority = 4
	_hand_anim.visible = false
	add_child(_hand_anim)


func _clear_weapon_art() -> void:
	if _weapon_anim != null:
		_weapon_anim.queue_free()
	_weapon_anim = null
	_weapon_frames = null
	if _hand_anim != null:
		_hand_anim.queue_free()
	_hand_anim = null
	_hand_frames = null


## 将身体动画的动作语义/帧进度镜像到武器层，保证握持与挥击同拍。
func _sync_weapon_animation() -> void:
	if _anim == null or _weapon_anim == null or _weapon_frames == null:
		return
	var binding: Dictionary = WeaponBinding.resolve(
		visual_id, String(_anim.animation), _anim.frame, _anim.pixel_size, _weapon_anim.pixel_size
	)
	_weapon_anim.visible = binding["visible"]
	if not _weapon_anim.visible:
		return
	var desired: String = binding["action"]
	if not _weapon_frames.has_animation(desired):
		return
	if _weapon_anim.animation != desired:
		_weapon_anim.animation = desired
	# 武器无独立时钟：身体换帧信号与物理更新共同驱动。
	_weapon_anim.pause()
	_weapon_anim.offset = binding["offset"]
	_weapon_anim.flip_h = binding["flip_h"]
	_weapon_anim.render_priority = binding["priority"]
	_weapon_anim.modulate = _anim.modulate
	var frame_count: int = _weapon_frames.get_frame_count(desired)
	if frame_count <= 0:
		return
	_weapon_anim.set_frame_and_progress(mini(_anim.frame, frame_count - 1), _anim.frame_progress)
	_sync_hand_layer()


## 手部前景层只在"武器可见且该动作有完整手部矩形"时出现。
func _sync_hand_layer() -> void:
	if _hand_anim == null or _hand_frames == null or _anim == null:
		return
	var action := String(_anim.animation)
	var has_rects: bool = (
		WeaponBinding.HAND_RECTS.has(action)
		and WeaponBinding.HAND_RECTS[action].size() == _anim.sprite_frames.get_frame_count(action)
	)
	_hand_anim.visible = _weapon_anim != null and _weapon_anim.visible and has_rects
	if not _hand_anim.visible:
		return
	if _hand_anim.animation != action:
		_hand_anim.animation = action
	_hand_anim.pause()
	_hand_anim.flip_h = false
	_hand_anim.modulate = _anim.modulate
	_hand_anim.set_frame_and_progress(_anim.frame, _anim.frame_progress)


## 切换程序化/2D 层的可见性（同源两形态共用一套闪烁/受击逻辑，R4）。
func _sync_visual_layers() -> void:
	var use_2d: bool = _anim != null and _sprite_frames != null
	_procedural_root.visible = not use_2d
	if _anim != null:
		_anim.visible = use_2d
	if _weapon_socket != null:
		_weapon_socket.visible = use_2d and _weapon_anim != null and _weapon_frames != null
	# 2D 形态枪口锚到形态语义位（R5：技能/子弹仍可引用 muzzle）。
	if anim_form == "sword":
		muzzle.position = Vector3(0.24, 1.05, 0.70)
	else:
		muzzle.position = Vector3(0.36, 1.00, 0.78)


## 由 BoomGame 在切换武器时注入武器 def：机体数值 + 形态（design §3.3/§4.1）。
func apply_weapon(def: BoomWeaponDef, visual_override: String = "") -> void:
	weapon_id = def.id
	move_speed = MOVE_SPEED * def.move_mult
	max_hp = maxi(1, BASE_MAX_HP + def.max_hp_bonus)
	hp = max_hp
	radius = def.radius
	var vid := visual_override
	if vid.is_empty():
		vid = WeaponBinding.visual_for_combat(def.id)
	var new_form: String = WeaponBinding.config(vid).get("form", "bubble")
	if vid != visual_id or new_form != anim_form or _anim == null:
		visual_id = vid
		anim_form = new_form
		_clear_art()
		_build_form_art()


func _clear_art() -> void:
	if _anim != null:
		_anim.queue_free()
	_anim = null
	_sprite_frames = null
	_clear_weapon_art()
	_transient_anim = false


## 设定移动输入（来自摇杆的 -1..1 向量）。
func set_move(v: Vector2) -> void:
	move_vec = v
	if v.length_squared() <= 0.01:
		return
	# 已经面向的轴在对角线附近保留，避免微小摇杆噪声来回切换贴图。
	var horizontal: bool = facing_anim in ["left", "right"]
	if absf(v.x) > absf(v.y) * FACING_HYSTERESIS:
		horizontal = true
	elif absf(v.y) > absf(v.x) * FACING_HYSTERESIS:
		horizontal = false
	if horizontal:
		facing_anim = "right" if v.x > 0.0 else "left"
	else:
		facing_anim = "down" if v.y > 0.0 else "up"


## 播放单次形态动作（灯火灵印施法 / 墨线判笔挥击 / 受击），播完回到基础动画。
func play_anim_once(action: String) -> void:
	if _anim == null or _sprite_frames == null:
		return
	if not _sprite_frames.has_animation(action):
		return
	_anim.play(action)
	_transient_anim = true


## 近战五帧由战斗阶段驱动：两帧蓄力、一帧出手、两帧收招。
func sync_swing_phase(first: int, count: int, progress: float) -> void:
	if _anim == null or _anim.animation != "swing":
		return
	_anim.pause()
	var phase: float = clampf(progress, 0.0, 0.9999) * count
	_anim.set_frame_and_progress(first + int(phase), fmod(phase, 1.0))
	_sync_weapon_animation()


func finish_swing_visual() -> void:
	if _anim != null and _anim.animation == "swing":
		_on_anim_finished()


func _base_anim_name() -> String:
	return ("move_" if move_vec.length_squared() > 0.01 else "idle_") + facing_anim


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
		if _weapon_anim != null:
			_weapon_anim.scale = Vector3(breath, breath, breath)
		if not _transient_anim:
			var want := _base_anim_name()
			if _sprite_frames.has_animation(want) and _anim.animation != want:
				# 同一行走周期转向时保留步相，避免摇杆斜向抖动反复重播第一帧。
				var preserve_step: bool = (
					String(_anim.animation).begins_with("move_") and want.begins_with("move_")
				)
				var previous_frame: int = _anim.frame
				var previous_progress: float = _anim.frame_progress
				_anim.play(want)
				if preserve_step:
					_anim.set_frame_and_progress(
						mini(previous_frame, _sprite_frames.get_frame_count(want) - 1),
						previous_progress
					)
		_sync_weapon_animation()
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


## M8（§8/§10.3）：amount 为统一受伤结算后的最终伤害（闪避/防御已在 BoomGame 扣除）。
## 闪避成功不会调用本函数（不扣血、不进无敌帧、不播受击动画）。
func take_damage(amount: int) -> void:
	if invuln_left > 0.0:
		return
	hp -= amount
	invuln_left = INVULN_TIME
	_flash_energy = 2.0
	if _anim != null:
		play_anim_once("hurt")
