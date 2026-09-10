class_name BoomBoss
extends BoomJelly
## M11 首领“提灯无常”：独立于普通怪数值曲线的三阶段攻击状态机。

signal attack_telegraphed(kind: String, duration: float)
signal attack_released(kind: String, origin: Vector3, direction: Vector3, phase_index: int)
signal boss_phase_changed(phase_index: int)

enum BossState { IDLE, WINDUP, DASH, RECOVER }

const DISPLAY_NAME: String = "LANTERN WARDEN"
const ATTACK_GHOSTFIRE: String = "ghostfire_fan"
const ATTACK_DASH: String = "soul_dash"
const ATTACK_LANTERN_ARRAY: String = "lantern_array"
const BASE_MAX_HP: int = 1200
const HP_PER_ENCOUNTER: int = 600
const BASE_DAMAGE: int = 12
const DAMAGE_PER_ENCOUNTER: int = 2
const MAX_DAMAGE: int = 20
const WALK_SPEED_BOSS: float = 1.25
const DASH_SPEED: float = 12.0
const DASH_TIME: float = 0.52
const RECOVER_TIME: float = 0.48
const PHASE_TWO_RATIO: float = 0.60
const PHASE_THREE_RATIO: float = 0.30
const ART_PATH: String = "res://assets/images/characters/boss_lantern_warden.png"

var max_hp: int = BASE_MAX_HP
var encounter_index: int = 1
var contact_damage: int = BASE_DAMAGE
var boss_phase: int = 1
var boss_state: int = BossState.IDLE
var current_attack: String = ""
var telegraph_left: float = 0.0

var _state_time: float = 0.0
var _attack_cooldown: float = 1.1
var _pattern_index: int = 0
var _target_snapshot: Vector3 = Vector3.FORWARD
var _dash_direction: Vector3 = Vector3.FORWARD
var _dash_line: MeshInstance3D


func _init(p_encounter_index: int = 1) -> void:
	super()
	encounter_index = maxi(1, p_encounter_index)
	max_hp = BASE_MAX_HP + HP_PER_ENCOUNTER * (encounter_index - 1)
	hp = max_hp
	contact_damage = mini(MAX_DAMAGE, BASE_DAMAGE + DAMAGE_PER_ENCOUNTER * (encounter_index - 1))
	elite = false
	radius = 1.25
	base_scale = 1.0
	walk_speed = WALK_SPEED_BOSS
	_replace_character_art()
	_build_dash_line()


func _replace_character_art() -> void:
	if _art != null:
		remove_child(_art)
		_art.free()
		_art = null
	if not ResourceLoader.exists(ART_PATH):
		return
	var texture := load(ART_PATH) as Texture2D
	if texture == null:
		return
	var frames := SpriteFrames.new()
	frames.add_animation("idle")
	frames.set_animation_loop("idle", true)
	frames.add_frame("idle", texture)
	_art = AnimatedSprite3D.new()
	_art.sprite_frames = frames
	_art.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_art.pixel_size = 0.0054
	_art.position = Vector3(0.0, 1.25, 0.0)
	_art.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_art.render_priority = 2
	add_child(_art)
	_art.play("idle")
	if _body != null:
		_body.visible = false
	if _telegraph != null:
		_telegraph.scale = Vector3(1.7, 1.0, 1.7)


func _build_dash_line() -> void:
	_dash_line = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.36, 0.025, 9.0)
	_dash_line.mesh = mesh
	_dash_line.position = Vector3(0.0, 0.025, -4.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.18, 0.16, 0.58)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color("b84235")
	mat.emission_energy_multiplier = 1.7
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dash_line.material_override = mat
	_dash_line.visible = false
	add_child(_dash_line)


func xp_reward() -> int:
	return 0


func take_damage(dmg: int, _knock_dir: Vector3, _knock_speed_override: float = -1.0) -> bool:
	var died := super.take_damage(dmg, Vector3.ZERO, -1.0)
	_update_boss_phase()
	return died


func physics_update(
	delta: float,
	player_pos: Vector3,
	_others: Array,
	bounds_half_x: float,
	bounds_half_z: float,
	_crowd_index: int = 0,
	_crowd_tick: int = 0,
	_crowd_stride: int = 1
) -> void:
	if is_dead():
		return
	anim_t += delta
	hit_cd = maxf(0.0, hit_cd - delta)
	_state_time += delta
	_attack_cooldown -= delta
	telegraph_left = maxf(0.0, telegraph_left - delta)
	_tick_spawn_and_flash(delta)
	_update_boss_phase()

	var to_player := player_pos - position
	to_player.y = 0.0
	var distance := to_player.length()
	var toward := to_player / maxf(distance, 0.001)
	match boss_state:
		BossState.IDLE:
			_tick_idle(delta, player_pos, toward, distance)
		BossState.WINDUP:
			_tick_windup(toward)
		BossState.DASH:
			position += _dash_direction * DASH_SPEED * delta
			if _state_time >= DASH_TIME:
				_enter_recover()
		BossState.RECOVER:
			if _state_time >= RECOVER_TIME:
				boss_state = BossState.IDLE
				_state_time = 0.0
				current_attack = ""
				_attack_cooldown = _phase_attack_cooldown()

	if toward.length_squared() > 0.001:
		rotation.y = lerp_angle(rotation.y, atan2(toward.x, toward.z), minf(1.0, delta * 7.0))
	if _art != null:
		_art.position.y = 1.25 + sin(anim_t * 3.2) * 0.08
		var pulse := 1.0 + sin(anim_t * 5.0) * 0.025
		_art.scale = Vector3.ONE * pulse
	if _telegraph != null:
		_telegraph.visible = boss_state == BossState.WINDUP
		if _telegraph.visible:
			var ring_pulse := 1.65 + sin(anim_t * 15.0) * 0.12
			_telegraph.scale = Vector3(ring_pulse, 1.0, ring_pulse)
	_dash_line.visible = boss_state == BossState.WINDUP and current_attack == ATTACK_DASH
	position.x = clampf(position.x, -bounds_half_x, bounds_half_x)
	position.z = clampf(position.z, -bounds_half_z, bounds_half_z)


func _tick_spawn_and_flash(delta: float) -> void:
	if _spawn_ttl > 0.0:
		_spawn_ttl = maxf(0.0, _spawn_ttl - delta)
		var progress := 1.0 - _spawn_ttl / SPAWN_POP_TIME
		scale = Vector3.ONE * clampf(progress * 1.15, 0.05, 1.0)
		if _art != null:
			_art.modulate.a = progress
	else:
		scale = Vector3.ONE
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		if _art != null:
			var flash := clampf(_flash_left / FLASH_TIME, 0.0, 1.0)
			_art.modulate = Color(1.0 + flash * 2.5, 1.0 + flash * 2.5, 1.0 + flash * 2.5, 1.0)
	elif _art != null:
		_art.modulate = Color.WHITE


func _tick_idle(delta: float, player_pos: Vector3, toward: Vector3, distance: float) -> void:
	if _attack_cooldown <= 0.0:
		_begin_next_attack(player_pos)
		return
	if distance > 4.2:
		var side := Vector3(toward.z, 0.0, -toward.x)
		position += (toward * WALK_SPEED_BOSS + side * sin(anim_t * 1.8) * 0.35) * delta


func _begin_next_attack(player_pos: Vector3) -> void:
	var pattern := _phase_pattern()
	current_attack = pattern[_pattern_index % pattern.size()]
	_pattern_index += 1
	_target_snapshot = player_pos
	var direction := player_pos - position
	direction.y = 0.0
	if direction.length_squared() < 0.001:
		direction = Vector3.FORWARD
	_dash_direction = direction.normalized()
	rotation.y = atan2(_dash_direction.x, _dash_direction.z)
	boss_state = BossState.WINDUP
	_state_time = 0.0
	telegraph_left = _windup_for(current_attack)
	attack_telegraphed.emit(current_attack, telegraph_left)


func _tick_windup(fallback_direction: Vector3) -> void:
	if _state_time < _windup_for(current_attack):
		return
	var direction := _target_snapshot - position
	direction.y = 0.0
	if direction.length_squared() < 0.001:
		direction = fallback_direction
	direction = direction.normalized()
	attack_released.emit(current_attack, position, direction, boss_phase)
	telegraph_left = 0.0
	if current_attack == ATTACK_DASH:
		_dash_direction = direction
		boss_state = BossState.DASH
		_state_time = 0.0
	else:
		_enter_recover()


func _enter_recover() -> void:
	boss_state = BossState.RECOVER
	_state_time = 0.0
	_dash_line.visible = false


func _update_boss_phase() -> void:
	var ratio := float(hp) / float(maxi(1, max_hp))
	var next_phase := 3 if ratio <= PHASE_THREE_RATIO else (2 if ratio <= PHASE_TWO_RATIO else 1)
	if next_phase == boss_phase:
		return
	boss_phase = next_phase
	_pattern_index = 0
	boss_phase_changed.emit(boss_phase)


func _phase_pattern() -> Array[String]:
	if boss_phase == 1:
		return [ATTACK_GHOSTFIRE, ATTACK_DASH]
	if boss_phase == 2:
		return [ATTACK_GHOSTFIRE, ATTACK_DASH, ATTACK_LANTERN_ARRAY]
	return [ATTACK_GHOSTFIRE, ATTACK_LANTERN_ARRAY, ATTACK_DASH, ATTACK_GHOSTFIRE]


func _phase_attack_cooldown() -> float:
	if boss_phase == 1:
		return 2.25
	if boss_phase == 2:
		return 1.75
	return 1.30


func _windup_for(kind: String) -> float:
	match kind:
		ATTACK_DASH:
			return 0.82
		ATTACK_LANTERN_ARRAY:
			return 0.92
	return 0.68


func state_name() -> String:
	return BossState.keys()[boss_state].to_lower()
