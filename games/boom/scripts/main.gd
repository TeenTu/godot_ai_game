extends Node
## 《B-Boom》入口：一切节点由本脚本在 _ready 里代码构建。
##   3D 世界（程序化原语 + 简易灯光）→ BoomGame 对局 → BoomFx 粒子/焦痕
##   → BoomCam 俯视跟拍 → BoomAudio 程序化音效 → 纯代码 HUD（摇杆/血条/分数）。

const HUD_W: float = 720.0
const HUD_H: float = 1280.0

# ---- M2 技能手势区 / 识别参数（design_m2_danmaku.md §2）----
const SKILL_ZONE_X: float = 0.65  # 触点 x 归一 > 0.65 = 右侧技能手势区
const TAP_MAX_TIME: float = 0.20
const TAP_MAX_DIST: float = 14.0
const SWIPE_MIN_DIST: float = 110.0

const COL_ORANGE: Color = Color("ff8a3d")
const COL_CYAN: Color = Color("2bd9ff")
const COL_CREAM: Color = Color("fff6e8")
const COL_GOLD: Color = Color("ffc93c")
const COL_CORAL: Color = Color("ff7a5c")
const COL_BUBBLE: Color = COL_CYAN
const COL_ENEMY: Color = Color("57c84d")
const COL_ACCENT: Color = COL_GOLD
const COL_DANGER: Color = Color("ff3b4e")

var sim: BoomGame
var world: Node3D
var cam: BoomCam
var fx: BoomFx
var hitnum: BoomHitNum
var audio: BoomAudio
var joystick: GameKitVirtualJoystick
var skill_sys: BoomSkillSystem
var skill_fx: BoomSkillFx

# M2 手势识别状态：touch_index -> {sx,sy,t,dx,dy}
var _gestures: Dictionary = {}

var _score_label: Label
var _wave_label: Label
var _kills_label: Label
var _coin_label: Label
var _hp_blocks: Array = []
var _hp_box: HBoxContainer
var _vignette: ColorRect
var _kill_white: ColorRect = null  # 击杀全屏泛白 overlay（峰值≤0.15，≤50ms 淡出）
var _kill_white_a: float = 0.0
var _toast: Label
var _over_panel: Control
var _over_title: Label
var _over_stats: Label
var _hint_label: Label
var _started := false
var _dmg_flash := 0.0
var _skill_buttons: Dictionary = {}


func _ready() -> void:
	if not _is_test_mode():
		randomize()
	world = _build_world()
	sim = BoomGame.new()
	add_child(sim)
	fx = BoomFx.new()
	world.add_child(fx)
	hitnum = BoomHitNum.new()
	world.add_child(hitnum)
	cam = BoomCam.new()
	cam.setup_follow(sim.player)
	world.add_child(cam)
	audio = BoomAudio.new()
	add_child(audio)
	# M2 技能：逻辑系统 + 视觉 FX（先建逻辑，main.gd 在 physics 里 tick；FX 挂 world）。
	skill_sys = BoomSkillSystem.new()
	skill_sys.game = sim
	add_child(skill_sys)
	skill_fx = BoomSkillFx.new()
	world.add_child(skill_fx)
	_build_hud()
	_connect_signals()
	_started = true
	_hud_refresh()


func _physics_process(_delta: float) -> void:
	if not _started or sim == null:
		return
	sim.input_move = joystick.output
	if skill_sys != null:
		skill_sys.tick(_delta)
	_dmg_flash = maxf(0.0, _dmg_flash - _delta * 2.4)
	_vignette.color.a = _dmg_flash
	# 击杀白闪淡出：峰值 0.15、~3.0/s → ≤50ms 归零（§3.3 防晕铁律 3）。
	_kill_white_a = maxf(0.0, _kill_white_a - _delta * 3.0)
	if _kill_white != null:
		_kill_white.color.a = _kill_white_a
	_hud_refresh()


# ------------------------------------------------------------------ M2 技能手势


## 把屏幕/物理坐标经 canvas 逆变换回 720×1280 设计空间（与摇杆同一坐标系）。
func _to_canvas(sp: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * sp


## 屏幕右侧(触点设计x > 屏宽*SKILL_ZONE_X)的触摸由本节点做手势识别：
## tap = 爆裂弹幕 / ←swipe = 闪电链 / →swipe = 核爆。
## 左侧触点不在此处理——交给虚拟摇杆(DYNAMIC,已设 exclude_right_x)。
func _input(event: InputEvent) -> void:
	if skill_sys == null or sim == null:
		return
	if event is InputEventScreenTouch:
		var idx: int = event.index
		var cp: Vector2 = _to_canvas(event.position)
		if event.pressed:
			# 仅在右侧技能区开一条手势轨迹。
			if cp.x > HUD_W * SKILL_ZONE_X:
				_gestures[idx] = {
					"sx": cp.x,
					"sy": cp.y,
					"t": Time.get_ticks_msec(),
					"dx": 0.0,
					"dy": 0.0,
				}
			return
		# 释放：归类手势。
		if not _gestures.has(idx):
			return
		var g: Dictionary = _gestures[idx]
		_gestures.erase(idx)
		var dt: float = float(Time.get_ticks_msec() - int(g["t"])) / 1000.0
		var dist: float = Vector2(g["dx"], g["dy"]).length()
		var adx: float = absf(g["dx"])
		var ady: float = absf(g["dy"])
		if dt <= TAP_MAX_TIME and dist <= TAP_MAX_DIST:
			skill_sys.handle_tap()
		elif adx >= SWIPE_MIN_DIST and adx > ady * 2.0:
			if g["dx"] < 0.0:
				skill_sys.handle_swipe_left()
			else:
				skill_sys.handle_swipe_right()
	elif event is InputEventScreenDrag:
		var idx: int = event.index
		if not _gestures.has(idx):
			return
		var cp: Vector2 = _to_canvas(event.position)
		var g: Dictionary = _gestures[idx]
		g["dx"] = cp.x - g["sx"]
		g["dy"] = cp.y - g["sy"]


## vision-e2e 用：与 test_hook.gd::_detect_test_mode 语义一致。
func _is_test_mode() -> bool:
	if not OS.has_feature("web"):
		return false
	if not Engine.has_singleton("JavaScriptBridge"):
		return false
	var v: Variant = Engine.get_singleton("JavaScriptBridge").call(
		"eval", "new URLSearchParams(location.search).get('test')"
	)
	if typeof(v) != TYPE_STRING:
		return false
	return (v as String) == "1"


func _test_hook_get_state() -> Dictionary:
	var jg: Dictionary = joystick.get_debug_geom()
	var state: Dictionary = {
		"score": sim.score,
		"wave": sim.wave,
		"kills": sim.kills,
		"coins": sim.coins,
		"combo": sim.combo,
		"hp": sim.player.hp,
		"max_hp": sim.player.max_hp,
		"enemies": sim.enemies.size(),
		"bullets": _active_bullet_count(),
		"over": sim.is_over,
		"x": sim.player.position.x,
		"z": sim.player.position.z,
		"joy_pressed": jg["pressed"],
		"joy_bx": jg["base_x"],
		"joy_by": jg["base_y"],
		"joy_kx": jg["knob_x"],
		"joy_ky": jg["knob_y"],
	}
	if skill_sys == null:
		return state
	var sk: Dictionary = skill_sys.get_state()
	state["sk_fan"] = sk["fan"]
	state["sk_chain"] = sk["chain"]
	state["sk_nuke"] = sk["nuke"]
	state["sk_ready"] = sk["ready"]
	return state


func _active_bullet_count() -> int:
	var n := 0
	for b in sim.bullets:
		if (b as BoomBullet).active:
			n += 1
	return n


# ------------------------------------------------------------------ 信号


func _connect_signals() -> void:
	sim.shot_fired.connect(_on_shot_fired)
	sim.enemy_damaged.connect(_on_enemy_damaged)
	sim.enemy_died.connect(_on_enemy_died)
	sim.player_damaged.connect(_on_player_damaged)
	sim.wave_started.connect(_on_wave_started)
	sim.wave_cleared.connect(_on_wave_cleared)
	sim.game_over.connect(_on_game_over)
	sim.prop_broken.connect(_on_prop_broken)
	skill_sys.skill_fired.connect(_on_skill_fired)


func _on_skill_fired(skill_id: String, result: Variant) -> void:
	var ppos: Vector3 = sim.player.position
	var hits: Array = result if result is Array else []
	match skill_id:
		"fan":
			audio.play("shoot", -9.0)
			skill_fx.muzzle_flash(
				ppos + Vector3(0.0, 0.5, 0.0), sim.player.facing, BoomSkillSystem.FAN_COLOR
			)
		"chain":
			audio.play("graze", -6.0)
			if not hits.is_empty():
				var prev: Vector3 = ppos + Vector3(0.0, 0.5, 0.0)
				for jelly in hits:
					var hp: Vector3 = (jelly as BoomJelly).position + Vector3(0.0, 0.5, 0.0)
					skill_fx.arc_bolt(prev, hp, BoomSkillSystem.CHAIN_COLOR)
					prev = hp
				_show_toast("CHAIN!")
		"nuke":
			audio.play("boom", -4.0)
			_trigger_kill_flash()
			skill_fx.shockwave(ppos, BoomGame.NUKE_RADIUS, BoomSkillSystem.NUKE_COLOR)
			skill_fx.burst(ppos + Vector3(0.0, 0.6, 0.0), BoomSkillSystem.NUKE_COLOR, 40)
			_show_toast("NUKE!")


func _on_shot_fired(pos: Vector3) -> void:
	fx.puff(pos, COL_BUBBLE, 5)
	audio.play("shoot", -14.0)


func _on_enemy_damaged(pos: Vector3, _dir: Vector3) -> void:
	fx.puff(pos, COL_BUBBLE, 6)
	audio.play("hit", -9.0)
	cam.add_trauma(0.05)
	if hitnum != null:
		hitnum.spawn(pos, str(BoomGame.BULLET_DMG), BoomHitNum.COLOR_DAMAGE)


func _on_enemy_died(pos: Vector3) -> void:
	# 连杀震屏每档衰减 40%（0.5^combo 近似等比衰减链）。
	var chain: float = pow(0.6, float(maxi(0, sim.combo - 1)))
	cam.add_trauma(0.5 * chain)
	fx.goo_burst(pos, COL_ENEMY)
	fx.scorch(pos, 0.7)
	audio.play("kill", -6.0)
	audio.play("boom", -16.0)
	_trigger_kill_flash()
	# 击杀得分飘字：金币色，连杀放大 1.3×（§7.2）。
	if hitnum != null:
		var scale_p := 1.3 if sim.combo >= 2 else 1.0
		hitnum.spawn(pos, "+%d" % BoomGame.KILL_SCORE, BoomHitNum.COLOR_SCORE, scale_p)
	if _hint_label != null:
		_hint_label.queue_free()
		_hint_label = null


func _on_prop_broken(pos: Vector3, coin_value: int) -> void:
	fx.goo_burst(pos, COL_GOLD)
	audio.play("pickup", -7.0)
	if hitnum != null:
		hitnum.spawn(pos + Vector3(0.0, 0.4, 0.0), "+%d" % coin_value, COL_GOLD, 1.15)


func _on_player_damaged(_amount: int, _from_pos: Vector3) -> void:
	_dmg_flash = 0.4
	cam.add_trauma(0.65)
	audio.play("hurt", -8.0)


func _on_wave_started(wave: int) -> void:
	audio.play("wave", -12.0)
	_show_toast("WAVE %d" % wave)


func _on_wave_cleared(wave: int, bonus: int) -> void:
	audio.play("wave_clear", -6.0)
	_show_toast("WAVE %d CLEARED  +%d" % [wave, bonus])


func _on_game_over(score: int) -> void:
	audio.play("over", -4.0)
	cam.add_trauma(0.8)
	_over_stats.text = "SCORE  %d\nKILLS  %d" % [score, sim.kills]
	_over_panel.visible = true
	if _hint_label != null:
		_hint_label.visible = false


# ------------------------------------------------------------------ 3D 世界


func _build_world() -> Node3D:
	var w := Node3D.new()
	w.name = "World"
	add_child(w)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(26.0, 38.0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color("ffe9b8")
	var floor_path := "res://assets/images/floors/carnival_tiles.png"
	if ResourceLoader.exists(floor_path):
		floor_mat.albedo_texture = load(floor_path) as Texture2D
		floor_mat.uv1_scale = Vector3(3.0, 5.0, 1.0)
	floor_mat.roughness = 0.95
	var floor := MeshInstance3D.new()
	floor.mesh = floor_mesh
	floor.material_override = floor_mat
	floor.rotation_degrees.x = -90.0
	w.add_child(floor)

	_add_environment(w)
	_add_grid_accents(w)
	_add_court_rails(w)
	_add_exit_gate(w)
	_add_carnival_decor(w)
	_add_lights(w)
	return w


func _add_environment(w: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("ffd9a3")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("fff0d2")
	env.ambient_light_energy = 0.72
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	w.add_child(world_env)


func _add_grid_accents(w: Node3D) -> void:
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color("ffb26b")
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var thick := 0.035
	for x in range(-12, 13, 4):
		_add_box(w, Vector3(float(x), 0.012, 0.0), Vector3(thick, 0.01, 38.0), line_mat)
	for z in range(-18, 19, 4):
		_add_box(w, Vector3(0.0, 0.012, float(z)), Vector3(26.0, 0.01, thick), line_mat)


func _add_court_rails(w: Node3D) -> void:
	var rail_mat := _make_mat(COL_CORAL, 0.72)
	var cap_mat := _make_mat(COL_CREAM, 0.55)
	var hx := 5.0
	var hz := 13.5
	_add_box(w, Vector3(0.0, 0.32, -hz), Vector3(hx * 2.0 + 0.4, 0.64, 0.35), rail_mat)
	_add_box(w, Vector3(0.0, 0.32, hz), Vector3(hx * 2.0 + 0.4, 0.64, 0.35), rail_mat)
	_add_box(w, Vector3(-hx, 0.32, 0.0), Vector3(0.35, 0.64, hz * 2.0 + 0.4), rail_mat)
	_add_box(w, Vector3(hx, 0.32, 0.0), Vector3(0.35, 0.64, hz * 2.0 + 0.4), rail_mat)
	_add_box(w, Vector3(0.0, 0.67, -hz), Vector3(hx * 2.0 + 0.5, 0.10, 0.42), cap_mat)
	_add_box(w, Vector3(0.0, 0.67, hz), Vector3(hx * 2.0 + 0.5, 0.10, 0.42), cap_mat)
	_add_box(w, Vector3(-hx, 0.67, 0.0), Vector3(0.42, 0.10, hz * 2.0 + 0.5), cap_mat)
	_add_box(w, Vector3(hx, 0.67, 0.0), Vector3(0.42, 0.10, hz * 2.0 + 0.5), cap_mat)


func _add_exit_gate(w: Node3D) -> void:
	var gold := _make_mat(COL_GOLD, 0.32, COL_GOLD)
	var cream := _make_mat(COL_CREAM, 0.42)
	_add_box(w, Vector3(-1.25, 1.15, -13.15), Vector3(0.38, 2.3, 0.55), gold)
	_add_box(w, Vector3(1.25, 1.15, -13.15), Vector3(0.38, 2.3, 0.55), gold)
	_add_box(w, Vector3(0.0, 2.2, -13.15), Vector3(2.9, 0.38, 0.55), cream)
	_add_box(w, Vector3(0.0, 0.035, -12.75), Vector3(2.2, 0.04, 1.0), gold)


func _add_carnival_decor(w: Node3D) -> void:
	var colors: Array[Color] = [COL_ORANGE, COL_CYAN, COL_GOLD, COL_CORAL]
	var spots: Array[Vector3] = [
		Vector3(-5.45, 1.2, -9.0),
		Vector3(5.45, 1.2, -5.0),
		Vector3(-5.45, 1.2, 4.0),
		Vector3(5.45, 1.2, 9.0),
	]
	for i in spots.size():
		var p: Vector3 = spots[i]
		_add_cylinder(w, p - Vector3(0.0, 0.72, 0.0), 0.05, 1.45, _make_mat(COL_CREAM, 0.7))
		_add_sphere(w, p, 0.42, _make_mat(colors[i], 0.2, colors[i]))
		_add_sphere(
			w, p + Vector3(0.32, 0.18, 0.0), 0.28, _make_mat(colors[(i + 1) % colors.size()], 0.2)
		)


func _add_lights(w: Node3D) -> void:
	var key := DirectionalLight3D.new()
	key.light_color = Color("fff0d2")
	key.light_energy = 1.0
	key.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 30.0
	w.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.45
	fill.rotation_degrees = Vector3(-60.0, 130.0, 0.0)
	fill.shadow_enabled = false
	w.add_child(fill)


func _make_mat(
	color: Color, roughness: float, emission: Color = Color.TRANSPARENT
) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	if emission.a > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = 0.45
	return mat


func _add_sphere(w: Node3D, pos: Vector3, radius: float, mat: StandardMaterial3D) -> void:
	var m := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	m.mesh = sphere
	m.material_override = mat
	m.position = pos
	w.add_child(m)


func _add_cylinder(
	w: Node3D, pos: Vector3, radius: float, height: float, mat: StandardMaterial3D
) -> void:
	var m := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 10
	m.mesh = cylinder
	m.material_override = mat
	m.position = pos
	w.add_child(m)


func _add_box(w: Node3D, pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = mat
	m.position = pos
	w.add_child(m)


# ------------------------------------------------------------------ HUD


func _build_hud() -> void:
	var hud := Control.new()
	hud.name = "HUD"
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	_build_battle_frame(hud)

	_vignette = ColorRect.new()
	_vignette.color = Color(0.9, 0.1, 0.1, 0.0)
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_vignette)

	# 击杀泛白：击杀/爆炸瞬间 ≤50ms 全屏白闪，叠在受击红之上但事件不同源。
	_kill_white = ColorRect.new()
	_kill_white.color = Color(1.0, 1.0, 1.0, 0.0)
	_kill_white.set_anchors_preset(Control.PRESET_FULL_RECT)
	_kill_white.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_kill_white)
	_kill_white_a = 0.0

	_add_hud_card(hud, Vector2(14, 20), Vector2(190, 86), Color(1.0, 0.45, 0.18, 0.88))
	_add_hud_card(hud, Vector2(208, 20), Vector2(304, 70), Color(0.10, 0.68, 0.86, 0.90))
	_add_hud_card(hud, Vector2(522, 20), Vector2(184, 86), Color(1.0, 0.69, 0.16, 0.90))
	_score_label = _make_label(hud, "0", 30, COL_CREAM, Vector2(28, 28))
	_kills_label = _make_label(hud, "", 15, Color(1, 1, 1, 0.82), Vector2(28, 68))
	_wave_label = _make_label(hud, "WAVE 1", 32, COL_CREAM, Vector2(210, 29))
	_wave_label.size = Vector2(320, 46)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_coin_hud(hud)

	_hint_label = _make_label(
		hud,
		"LEFT: MOVE   \u00b7  RIGHT TAP: FAN   \u00b7  \u2190 CHAIN   \u2192 NUKE",
		15,
		Color(0.45, 0.20, 0.10, 0.65),
		Vector2(0, 1168),
	)
	_hint_label.size = Vector2(720, 26)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_toast = _make_label(hud, "", 40, Color.WHITE, Vector2(0, 500))
	_toast.size = Vector2(720, 60)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false

	_build_hp(hud)
	_build_joystick(hud)
	_build_skill_hud(hud)
	_build_game_over(hud)


func _build_battle_frame(hud: Control) -> void:
	var path := "res://assets/images/backgrounds/carnival_arena.png"
	if not ResourceLoader.exists(path):
		return
	var frame := TextureRect.new()
	frame.texture = load(path) as Texture2D
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	frame.modulate = Color(1.0, 1.0, 1.0, 0.16)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(frame)


func _add_hud_card(hud: Control, pos: Vector2, card_size: Vector2, color: Color) -> void:
	var panel := Panel.new()
	panel.position = pos
	panel.size = card_size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 20
	style.corner_radius_top_right = 20
	style.corner_radius_bottom_left = 20
	style.corner_radius_bottom_right = 20
	style.set_border_width_all(3)
	style.border_color = Color(1.0, 0.97, 0.88, 0.72)
	panel.add_theme_stylebox_override("panel", style)
	hud.add_child(panel)


func _build_coin_hud(hud: Control) -> void:
	var coin := TextureRect.new()
	coin.position = Vector2(532, 28)
	coin.size = Vector2(54, 54)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var coin_path := "res://assets/images/icons/coin.png"
	if ResourceLoader.exists(coin_path):
		coin.texture = load(coin_path) as Texture2D
	hud.add_child(coin)
	_coin_label = _make_label(hud, "0", 30, COL_CREAM, Vector2(588, 34))
	_coin_label.size = Vector2(104, 44)
	_coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_skill_hud(hud: Control) -> void:
	var specs: Array = [
		[
			"fan",
			"res://assets/images/icons/skill_fan.png",
			BoomSkillSystem.FAN_COOLDOWN,
			BoomSkillSystem.FAN_COLOR,
			"TAP",
			760.0
		],
		[
			"chain",
			"res://assets/images/icons/skill_chain.png",
			BoomSkillSystem.CHAIN_COOLDOWN,
			BoomSkillSystem.CHAIN_COLOR,
			"< SWIPE",
			886.0
		],
		[
			"nuke",
			"res://assets/images/icons/skill_nuke.png",
			BoomSkillSystem.NUKE_COOLDOWN,
			BoomSkillSystem.NUKE_COLOR,
			"SWIPE >",
			1012.0
		],
	]
	for spec in specs:
		var button := BoomSkillButton.new()
		button.position = Vector2(596.0, float(spec[5]))
		button.setup(spec[0], spec[1], spec[2], spec[3], spec[4])
		hud.add_child(button)
		_skill_buttons[spec[0]] = button


func _build_hp(hud: Control) -> void:
	# 先垫暗色插槽，再叠亮块：段间自然留缝形成分段血条。
	var slot := ColorRect.new()
	slot.color = Color(0.52, 0.20, 0.12, 0.72)
	slot.size = Vector2(24 + float(sim.player.max_hp - 1) * 62.0 + 48.0, 34)
	slot.position = Vector2(14, 111)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(slot)
	for i in sim.player.max_hp:
		var block := ColorRect.new()
		block.color = COL_CREAM
		block.size = Vector2(52, 24)
		block.position = Vector2(24.0 + float(i) * 62.0, 116.0)
		block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(block)
		_hp_blocks.append(block)


func _build_joystick(hud: Control) -> void:
	joystick = GameKitVirtualJoystick.new()
	joystick.mode = GameKitVirtualJoystick.Mode.DYNAMIC
	joystick.base_radius = 84.0
	joystick.knob_radius = 34.0
	joystick.dead_zone = 0.08
	joystick.exclude_right_x = SKILL_ZONE_X
	joystick.position = Vector2(8, 900)
	joystick.size = Vector2(360, 372)
	joystick.modulate = Color(1.0, 0.56, 0.24, 0.92)
	hud.add_child(joystick)


func _trigger_kill_flash() -> void:
	if _kill_white != null:
		_kill_white_a = 0.15  # §3.3 上限 ≤0.15；_physics_process 以 3.0/s 衰减，≤50ms 归零。


func _build_game_over(hud: Control) -> void:
	_over_panel = Control.new()
	_over_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_over_panel.visible = false
	_over_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(_over_panel)
	var dim := ColorRect.new()
	dim.color = Color(1.0, 0.44, 0.24, 0.30)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over_panel.add_child(dim)
	var backdrop_path := "res://assets/images/backgrounds/carnival_arena.png"
	if ResourceLoader.exists(backdrop_path):
		var backdrop := TextureRect.new()
		backdrop.texture = load(backdrop_path) as Texture2D
		backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
		backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		backdrop.modulate = Color(1.0, 1.0, 1.0, 0.92)
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_over_panel.add_child(backdrop)
		_over_panel.move_child(backdrop, 0)

	_over_title = _make_label(_over_panel, "BUBBLE BREAK!", 52, COL_ORANGE, Vector2(100, 360))
	_over_title.size = Vector2(520, 70)
	_over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_over_stats = _make_label(_over_panel, "", 24, Color.WHITE, Vector2(0, 480))
	_over_stats.size = Vector2(720, 110)
	_over_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var restart := Button.new()
	restart.text = "TAP TO RETRY"
	restart.add_theme_font_size_override("font_size", 30)
	restart.position = Vector2(190, 700)
	restart.size = Vector2(340, 90)
	restart.pressed.connect(_on_retry)
	_over_panel.add_child(restart)


func _on_retry() -> void:
	get_tree().reload_current_scene()


func _make_label(parent: Node, text: String, font_size: int, color: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _show_toast(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.visible = true
	_toast.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_interval(0.5)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.4)


func _hud_refresh() -> void:
	if sim == null:
		return
	_score_label.text = str(sim.score)
	_kills_label.text = "KILLS %d   COMBO x%d" % [sim.kills, maxi(1, sim.combo)]
	_wave_label.text = "WAVE %d" % sim.wave
	if _coin_label != null:
		_coin_label.text = str(sim.coins)
	if skill_sys != null:
		var skill_state := skill_sys.get_state()
		for skill_id in _skill_buttons:
			(_skill_buttons[skill_id] as BoomSkillButton).set_cooldown(float(skill_state[skill_id]))
	for i in _hp_blocks.size():
		var block := _hp_blocks[i] as ColorRect
		if block == null:
			continue
		block.color = COL_CREAM if i < sim.player.hp else Color(0.52, 0.20, 0.12, 0.20)
