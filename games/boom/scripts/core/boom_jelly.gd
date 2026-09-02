class_name BoomJelly
extends Node3D
## 果冻兵：最普通的追尾敌人。行为三段：
##   CHASE  —— 朝玩家直线慢走 + 随机停顿 + 相遇分离（由 BoomGame 处理外推），
##             移动带 sin 横摆与上下果冻颤，笨拙好笑。
##   WINDUP —— 距离足够后前摇 0.45s：身体胀大、冒红光、原地抖动（明示玩家躲）。
##   LUNGE  —— 猛地朝锁定方向冲一小段，命中判定交给 BoomGame。
## 受击：扣血 + 白闪 + 沿弹道击退 + squash&stretch（沿击退方向的拉伸用通用压扁实现）。

enum Phase { CHASE, WINDUP, LUNGE }

const WALK_SPEED: float = 1.7
const LUNGE_SPEED: float = 11.0
const LUNGE_RANGE: float = 2.7
const WINDUP_TIME: float = 0.45
const LUNGE_TIME: float = 0.28
const ATTACK_CD: float = 1.3
const KNOCK_SPEED: float = 4.6
const HIT_RADIUS: float = 0.95
const MAX_HP: int = 3

const PALETTES: Array[Color] = [
	Color(0.45, 0.85, 0.45),  # 草绿
	Color(0.40, 0.75, 0.60),  # 青绿
	Color(0.55, 0.80, 0.35),  # 黄绿
]

var hp: int = MAX_HP
var radius: float = 0.6
var phase: int = Phase.CHASE
var phase_t: float = 0.0
var attack_cd: float = 1.2
var hit_cd: float = 0.0
var lunge_dir: Vector3 = Vector3.FORWARD
var knock_vel: Vector3 = Vector3.ZERO
var squash_impact: float = 0.0
var pause_t: float = 0.0
var anim_t: float = 0.0
var body_mat: StandardMaterial3D
var _body: MeshInstance3D
var _dead: bool = false


func _init() -> void:
	var palette: Color = PALETTES[randi() % PALETTES.size()]
	palette = palette.lerp(Color.WHITE, randf() * 0.12)
	_build_visuals(palette)


func _build_visuals(palette: Color) -> void:
	var body_sphere := SphereMesh.new()
	body_sphere.radius = 0.55
	body_sphere.height = 1.05
	body_sphere.radial_segments = 14
	body_sphere.rings = 8
	body_mat = StandardMaterial3D.new()
	body_mat.albedo_color = palette
	body_mat.roughness = 0.6
	body_mat.emission_enabled = true
	body_mat.emission = palette.lightened(0.15)
	body_mat.emission_energy_multiplier = 0.2
	_body = MeshInstance3D.new()
	_body.mesh = body_sphere
	_body.material_override = body_mat
	_body.position.y = 0.55
	add_child(_body)

	# 呆萌大眼睛（眼睛朝 +Z，追人时会自动面向玩家）。
	var white_mat := StandardMaterial3D.new()
	white_mat.albedo_color = Color(0.98, 0.98, 1.0)
	white_mat.roughness = 0.3
	_add_eye(Vector3(-0.2, 0.78, 0.42), 0.13, white_mat)
	_add_eye(Vector3(0.2, 0.78, 0.42), 0.13, white_mat)
	var pupil_mat := StandardMaterial3D.new()
	pupil_mat.albedo_color = Color(0.06, 0.09, 0.1)
	_add_eye(Vector3(-0.2, 0.76, 0.54), 0.06, pupil_mat)
	_add_eye(Vector3(0.2, 0.76, 0.54), 0.06, pupil_mat)


func _add_eye(local_pos: Vector3, r: float, mat: StandardMaterial3D) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = r
	sphere.height = r * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	var eye := MeshInstance3D.new()
	eye.mesh = sphere
	eye.material_override = mat
	eye.position = local_pos
	add_child(eye)


func _ready() -> void:
	body_mat.emission_energy_multiplier = 0.2


func is_dead() -> bool:
	return _dead


## 轻微弹开（玩家近身反推敌人用，不造成伤害）。
func knock_back(dir: Vector3) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 0.0001:
		return
	knock_vel += flat.normalized() * 2.6
	squash_impact = maxf(squash_impact, 0.55)


## 返回 true 表示本次受伤致死。
func take_damage(dmg: int, knock_dir: Vector3) -> bool:
	if _dead or hp <= 0:
		return false
	hp -= dmg
	squash_impact = 1.0
	body_mat.emission_enabled = true
	body_mat.emission = Color(1.0, 1.0, 1.0)
	body_mat.emission_energy_multiplier = 3.0
	var flat := Vector3(knock_dir.x, 0.0, knock_dir.z)
	if flat.length_squared() > 0.0001:
		knock_vel += flat.normalized() * KNOCK_SPEED
	# 受击打断前摇并小幅重置攻击节奏，避免站着挨打出不完招。
	if phase == Phase.WINDUP:
		phase = Phase.CHASE
		phase_t = 0.0
	attack_cd = maxf(attack_cd, 0.45)
	if hp <= 0:
		_dead = true
		return true
	return false


## 由 BoomGame 每物理帧驱动；others 用于相遇分离（简化为两两推开）。
func physics_update(
	delta: float, player_pos: Vector3, others: Array, bounds_half_x: float, bounds_half_z: float
) -> void:
	if _dead:
		return
	anim_t += delta
	phase_t += delta
	attack_cd -= delta
	hit_cd -= delta
	if squash_impact > 0.0:
		squash_impact = maxf(0.0, squash_impact - delta * 4.5)
	# 受击白闪衰减。
	if body_mat.emission_energy_multiplier > 0.3:
		var e: float = body_mat.emission_energy_multiplier - delta * 16.0
		body_mat.emission_energy_multiplier = maxf(0.3, e)

	var to_player: Vector3 = player_pos - position
	to_player.y = 0.0
	var dist: float = to_player.length()
	var toward: Vector3 = to_player / maxf(dist, 0.001)

	# 击退速度（受击位移），指数衰减制造弹性回弹手感。
	if knock_vel.length_squared() > 0.0001:
		position += knock_vel * delta
		knock_vel *= exp(-7.0 * delta)

	match phase:
		Phase.WINDUP:
			# 前摇：胀大抖动 + 红光脉冲，可被打断。
			var pulse := 1.15 + sin(anim_t * 46.0) * 0.05
			_apply_scale(Vector3(pulse, 1.05, pulse))
			body_mat.emission = Color(1.0, 0.35, 0.2).lerp(
				Color.WHITE, sin(anim_t * 38.0) * 0.5 + 0.5
			)
			body_mat.emission_energy_multiplier = 2.2
			if phase_t >= WINDUP_TIME:
				phase = Phase.LUNGE
				phase_t = 0.0
				lunge_dir = toward
		Phase.LUNGE:
			position += lunge_dir * LUNGE_SPEED * delta
			_apply_scale(Vector3(1.35, 0.62, 1.35))
			body_mat.emission = Color(1.0, 0.75, 0.3)
			body_mat.emission_energy_multiplier = 2.0
			if phase_t >= LUNGE_TIME:
				phase = Phase.CHASE
				phase_t = 0.0
				attack_cd = ATTACK_CD
		Phase.CHASE:
			if dist <= LUNGE_RANGE and attack_cd <= 0.0:
				phase = Phase.WINDUP
				phase_t = 0.0
			else:
				if pause_t <= 0.0:
					# 沿朝向玩家方向走，叠加横摆与随机停顿。
					var sway := Vector3(toward.z, 0.0, -toward.x) * sin(anim_t * 2.7) * 0.35
					position += (toward * WALK_SPEED + sway) * delta
					if randf() < delta * 0.22:
						pause_t = randf_range(0.25, 0.7)
				else:
					pause_t -= delta
				_apply_scale(Vector3(1.0, 1.0, 1.0))

	# 相遇分离：把挤压自己的邻居推开一点，别叠成一坨。
	for other in others:
		var j := other as BoomJelly
		if j == null or j == self or j.is_dead():
			continue
		var d: Vector3 = position - j.position
		d.y = 0.0
		var min_d: float = radius + j.radius
		var dlen := d.length()
		if dlen > 0.0001 and dlen < min_d:
			position += d / dlen * (min_d - dlen) * 0.5

	# 面向玩家（CHASE / WINDUP 都盯着人看）。
	if toward.length_squared() > 0.001:
		rotation.y = lerp_angle(rotation.y, atan2(toward.x, toward.z), minf(1.0, delta * 9.0))

	position.x = clampf(position.x, -bounds_half_x, bounds_half_x)
	position.z = clampf(position.z, -bounds_half_z, bounds_half_z)


## 果冻颤 + squash&stretch（击退时压扁回弹）。
func _apply_scale(target: Vector3) -> void:
	var wobble := 1.0 + sin(anim_t * 7.0) * 0.06
	var squash: float = squash_impact
	var s := Vector3(
		lerpf(target.x, 1.35, squash) * wobble,
		lerpf(target.y, 0.5, squash) / wobble,
		lerpf(target.z, 1.35, squash) * wobble
	)
	scale = s
