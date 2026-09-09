extends SceneTree
## 交互式绑定检查场景（真实玩家与绑定代码，需非 headless）：
##   godot --path games/boom --resolution 720x1280 --audio-driver Dummy \
##     --script res://tools/binding_inspector.gd
## 按键：
##   TAB  切换武器(bubble/greatsword)   SPACE 暂停/继续
##   LEFT/RIGHT 逐帧步进               UP/DOWN 上/下一动作
##   1-4 强制朝向 下/左/右/上           G 攻击(recoil/swing)
##   H 受击  C 施法  K 倒地             A 锚点标记开关
##   B 只看身体  N 只看武器  M 全部      F 游戏尺寸/放大 切换
##   ESC 退出

const WeaponBinding := preload("res://scripts/core/boom_weapon_binding.gd")
const ACTIONS := [
	"idle_down",
	"idle_up",
	"idle_left",
	"idle_right",
	"move_down",
	"move_up",
	"move_left",
	"move_right",
	"recoil",
	"swing",
	"hurt",
	"skill_cast",
	"knockdown",
]
const KEY_WEAPON := KEY_TAB
const CAM_ZOOM := 3.4
const CAM_GAME := 8.0

var player: BoomPlayer
var weapon_index: int = 0
var action_index: int = 0
var hold: bool = false
var show_anchors: bool = true
var layer_mode: int = 0  # 0=全部 1=只身体 2=只武器
var zoomed: bool = true
var _hand_mark: MeshInstance3D
var _grip_mark: MeshInstance3D
var _hud: Label
var _keys_pressed := {}


func _initialize() -> void:
	call_deferred("_build")


func _build() -> void:
	root.content_scale_size = Vector2i(720, 1280)
	root.size = Vector2i(720, 1280)
	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = CAM_ZOOM
	cam.position = Vector3(0, 1.0, 6.0)
	world.add_child(cam)
	cam.current = true
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(6, 6)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.position.y = -0.02
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.09, 0.11, 0.2)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	world.add_child(floor_mi)
	player = BoomPlayer.new()
	world.add_child(player)
	player.apply_weapon(BoomWeapons.get_def("bubble"))
	_hand_mark = _make_mark(Color(1.0, 0.15, 0.15))
	_grip_mark = _make_mark(Color(0.15, 0.9, 1.0))
	world.add_child(_hand_mark)
	world.add_child(_grip_mark)
	_hud = Label.new()
	_hud.position = Vector2(16, 16)
	_hud.add_theme_font_size_override("font_size", 22)
	root.add_child(_hud)
	_play_action()
	# 主循环：用 process_frame 驱动。
	_loop()


func _make_mark(col: Color) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.render_priority = 10
	mi.visible = false
	return mi


func _loop() -> void:
	while true:
		_handle_input()
		if not hold:
			player.physics_update(1.0 / 60.0, 30.0, 30.0)
		_update_marks()
		_update_hud()
		await process_frame


func _play_action() -> void:
	var action := _current_action()
	if player._sprite_frames != null and player._sprite_frames.has_animation(action):
		player.play_anim_once(action)
		if not player._anim.is_playing():
			player._anim.play(action)
		hold = true  # 单次动作播完会回落，锁定便于逐帧检查
		player._anim.pause()
		player._anim.set_frame_and_progress(0, 0.0)


func _current_action() -> String:
	var form := player.anim_form
	var action: String = ACTIONS[action_index]
	var cfg: Dictionary = WeaponBinding.config(player.visual_id)
	# 形态没有或视觉配置缺失的动作（policy=stow）自动跳过。
	if not BoomPlayer.FORM_STRIPS[form].has(action) and action != "hurt":
		action_index = (action_index + 1) % ACTIONS.size()
		return _current_action()
	return action


func _edge(key: Key) -> bool:
	var down: bool = Input.is_key_pressed(key)
	var was: bool = _keys_pressed.get(key, false)
	_keys_pressed[key] = down
	return down and not was


func _handle_input() -> void:
	if _edge(KEY_ESCAPE):
		quit(0)
		return
	if _edge(KEY_TAB):
		weapon_index = (weapon_index + 1) % WeaponBinding.CONFIGS.size()
		var vid: String = WeaponBinding.CONFIGS.keys()[weapon_index]
		var form: String = WeaponBinding.config(vid).get("form", "bubble")
		var combat: String = WeaponBinding.config(vid)["combat_ids"][0]
		if WeaponBinding.visual_for_combat(combat) == vid:
			player.apply_weapon(BoomWeapons.get_def(combat))
		else:
			# 测试配置没有正式战斗 def：借用同形态 def + 显式视觉覆盖。
			player.apply_weapon(
				BoomWeapons.get_def("bubble" if form == "bubble" else "greatsword"), vid
			)
		_play_action()
	if _edge(KEY_UP):
		action_index = (action_index + ACTIONS.size() - 1) % ACTIONS.size()
		_play_action()
	if _edge(KEY_DOWN):
		action_index = (action_index + 1) % ACTIONS.size()
		_play_action()
	if _edge(KEY_SPACE):
		hold = not hold
		if not hold and player._anim != null:
			player._anim.play(String(player._anim.animation))
	var body: AnimatedSprite3D = player._anim
	if body != null:
		if _edge(KEY_LEFT) or _edge(KEY_RIGHT):
			hold = true
			var delta := -1 if Input.is_key_pressed(KEY_LEFT) else 1
			var count := player._sprite_frames.get_frame_count(String(body.animation))
			var target := wrapi(body.frame + delta, 0, count)
			body.pause()
			body.set_frame_and_progress(target, 0.0)
		for i in 4:
			if _edge((KEY_1 + i) as Key):
				player.facing_anim = ["down", "left", "right", "up"][i]
				player.move_vec = Vector2.ZERO
				_play_action()
	if _edge(KEY_G):
		_play_attack()
	if _edge(KEY_H):
		_play_action_named("hurt")
	if _edge(KEY_C):
		_play_action_named("skill_cast")
	if _edge(KEY_K):
		_play_action_named("knockdown")
	if _edge(KEY_A):
		show_anchors = not show_anchors
	if _edge(KEY_B):
		layer_mode = 1
	if _edge(KEY_N):
		layer_mode = 2
	if _edge(KEY_M):
		layer_mode = 0
	if _edge(KEY_F):
		zoomed = not zoomed
		var cam: Camera3D = root.get_viewport().get_camera_3d()
		cam.size = CAM_ZOOM if zoomed else CAM_GAME
	if player._anim != null:
		player._anim.visible = layer_mode != 2
		if player._weapon_anim != null:
			player._weapon_anim.visible = (
				layer_mode != 1 and not (String(player._anim.animation) in WeaponBinding.STOWED)
			)


func _play_attack() -> void:
	if player.anim_form == "sword":
		_play_action_named("swing")
	else:
		_play_action_named("recoil")


func _play_action_named(action: String) -> void:
	action_index = ACTIONS.find(action)
	if action_index < 0:
		action_index = 0
	_play_action()


func _update_marks() -> void:
	var body: AnimatedSprite3D = player._anim
	var weapon: AnimatedSprite3D = player._weapon_anim
	if body == null or weapon == null or not show_anchors:
		_hand_mark.visible = false
		_grip_mark.visible = false
		return
	var action := String(body.animation)
	var frame := body.frame
	var binding: Dictionary = WeaponBinding.resolve(
		player.visual_id, action, frame, body.pixel_size, weapon.pixel_size
	)
	if not binding.get("visible", false):
		_hand_mark.visible = false
		_grip_mark.visible = false
		return
	var base := player.position + Vector3(0, 0.92, 0)
	var bp: float = body.pixel_size
	var wp: float = weapon.pixel_size
	var hand: Vector2 = WeaponBinding.HANDS[action][frame]
	_hand_mark.visible = true
	_hand_mark.position = base + Vector3((hand.x - 128.0) * bp, (128.0 - hand.y) * bp, 0.02)
	var cfg2: Dictionary = WeaponBinding.config(player.visual_id)
	var grip: Vector2 = WeaponBinding.GRIPS[cfg2["grips"]][String(binding["action"])][frame]
	var gx := grip.x
	if binding["flip_h"]:
		gx = 256.0 - gx
	_grip_mark.visible = true
	_grip_mark.position = (
		base
		+ Vector3(
			binding["offset"].x * wp + (gx - 128.0) * wp,
			binding["offset"].y * wp + (128.0 - grip.y) * wp,
			0.02
		)
	)


func _update_hud() -> void:
	var body: AnimatedSprite3D = player._anim
	var action: String = String(body.animation) if body != null else "-"
	var frame := body.frame if body != null else -1
	var weapon_name: String = player.visual_id
	_hud.text = (
		"%s  action=%s frame=%d\npaused=%s anchors=%s layer=%s zoom=%s"
		% [
			weapon_name,
			action,
			frame,
			hold,
			show_anchors,
			["all", "body", "weapon"][layer_mode],
			"2x" if zoomed else "game"
		]
	)
