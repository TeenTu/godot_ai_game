class_name BoomGame
extends Node3D
## 《B-Boom》核心对局（零 UI 依赖，可无头逻辑测试）。
##   - 玩家：摇杆输入驱动（input_move），自动瞄准最近敌人、自动开火。
##   - 敌人：果冻兵（BoomJelly），波次刷怪，前摇 + 冲撞。
##   - 子弹：对象池，命中扣血 + 击退；击杀计分连击。
##   - 手感：击杀顿帧（0.5s 内最多一次全停）、击退、squash 由敌人自身做。
## 本类只发信号 + 暴露数据；视觉表现（粒子/震屏/音效/HUD）由 main.gd 订阅。

signal enemy_damaged(pos: Vector3, dir: Vector3)
signal enemy_died(pos: Vector3)
signal shot_fired(pos: Vector3)
signal player_damaged(amount: int, from_pos: Vector3)
signal wave_cleared(wave: int, bonus: int)
signal wave_started(wave: int)
signal game_over(final_score: int)
signal prop_broken(pos: Vector3, coin_value: int)

const PLAYER_BOUND_X: float = 3.6
const PLAYER_BOUND_Z: float = 9.5
const ENEMY_BOUND_X: float = 4.4
const ENEMY_BOUND_Z: float = 11.5
const KILL_SCORE: int = 10
const BULLET_DMG: int = 1
const FIRE_CD: float = 0.22
const BULLET_POOL_SIZE: int = 24
const COMBO_WINDOW: float = 2.0
const AIM_LOCK_TIME: float = 0.15
const AIM_ASSIST_RAD: float = 0.14  # ±8° 吸附锥（0.14 rad）

# ---- M2 技能参数（design_m2_danmaku.md）----
const FAN_COUNT: int = 5
const FAN_SPREAD_RAD: float = deg_to_rad(15.0)
const CHAIN_MAX_TARGETS: int = 3
const CHAIN_JUMP_RANGE: float = 8.0
const CHAIN_DECAY: float = 0.7
const NUKE_RADIUS: float = 6.0
const NUKE_DMG_MULT: int = 4

# ---- M3 击杀播报阈值（design_boom.md §7.2：DOUBLE/TRIPLE/RAMPAGE）----
const ANNOUNCE_DOUBLE: int = 2
const ANNOUNCE_TRIPLE: int = 3
const ANNOUNCE_RAMPAGE: int = 5

# ---- M3 结算星级阈值（无尽模式：撑到的波次即荣誉，代替关卡的通关/限时/零受伤）----
const RESULT_STAR_WAVE_1: int = 2
const RESULT_STAR_WAVE_2: int = 4
const RESULT_STAR_WAVE_3: int = 6

var player: BoomPlayer
var enemies: Array = []
var bullets: Array = []  # BoomBullet 池
var props: Array = []
var wave: int = 1
var score: int = 0
var coins: int = 0
var kills: int = 0
var combo: int = 0
var combo_left: float = 0.0
var is_over: bool = false
var game_time: float = 0.0
var auto_spawn: bool = true
var input_move: Vector2 = Vector2.ZERO

var _spawned_total: int = 0
var _quota_current: int = 0
var _spawn_cd: float = 0.5
var _between_waves: bool = false
var _next_wave_cd: float = 0.0
var _fire_cd: float = 0.2
var _bullet_idx: int = 0
var _freeze_left: float = 0.0
var _last_killstop: float = -10.0
## 瞄准目标防抖：锁定后 0.15s 内不轻易换目标，避免多个敌人之间抖动。
var _locked: BoomJelly = null
var _lock_ttl: float = 0.0


func _init() -> void:
	player = BoomPlayer.new()
	add_child(player)
	for i in BULLET_POOL_SIZE:
		var b := BoomBullet.new()
		bullets.append(b)
		add_child(b)
	restart()


func _physics_process(delta: float) -> void:
	if is_over:
		return
	step(delta)


## 手动驱动一步（无头逻辑测试直接调用，与物理帧同路径）。
func step(delta: float) -> void:
	game_time += delta
	# 顿帧：整局逻辑冻结，视觉（相机/粒子/tween）不停，短促有力不晕。
	if _freeze_left > 0.0:
		_freeze_left -= delta
		return
	combo_left = maxf(0.0, combo_left - delta)
	player.set_move(input_move)
	_tick_player(delta)
	_tick_enemies(delta)
	_tick_bullets(delta)
	_tick_props(delta)
	_tick_spawns(delta)
	_tick_player_contact()


func restart() -> void:
	wave = 1
	score = 0
	coins = 0
	kills = 0
	combo = 0
	combo_left = 0.0
	game_time = 0.0
	is_over = false
	auto_spawn = true
	_spawned_total = 0
	_quota_current = 0
	_between_waves = false
	_next_wave_cd = 0.0
	_fire_cd = 0.2
	_freeze_left = 0.0
	_last_killstop = -10.0
	_locked = null
	_lock_ttl = 0.0
	player.hp = BoomPlayer.MAX_HP
	player.invuln_left = 0.0
	player.position = Vector3.ZERO
	player.set_move(Vector2.ZERO)
	for b in bullets:
		(b as BoomBullet).recycle()
	for e in enemies:
		if is_instance_valid(e):
			remove_child(e)
			e.queue_free()
	enemies.clear()
	for prop in props:
		if is_instance_valid(prop):
			remove_child(prop)
			prop.queue_free()
	props.clear()
	_spawn_props()
	_begin_wave()


# ------------------------------------------------------------------ 玩家


func _tick_player(delta: float) -> void:
	player.physics_update(delta, PLAYER_BOUND_X, PLAYER_BOUND_Z)
	_lock_ttl = maxf(0.0, _lock_ttl - delta)
	if _locked != null and (not is_instance_valid(_locked) or _locked.is_dead()):
		_locked = null
	var target := _resolve_target()
	if target != _locked:
		_locked = target
		_lock_ttl = AIM_LOCK_TIME
	_fire_cd -= delta
	# 枪口世界坐标：离树安全（测试/生产同路径，不依赖 global_transform）。
	var muzzle_pos: Vector3 = player.position + player.basis * player.muzzle.position
	if target != null:
		var aim_dir := _aim_dir(muzzle_pos, target)
		player.face_toward(aim_dir)
		if _fire_cd <= 0.0:
			_fire_cd = FIRE_CD
			_spawn_bullet(muzzle_pos, aim_dir)
	elif player.move_vec.length_squared() > 0.01:
		# 无目标时朝移动方向边走边扫（只转向不开火会留空档）。
		var mv := Vector3(player.move_vec.x, 0.0, player.move_vec.y)
		player.face_toward(mv)
		if _fire_cd <= 0.0:
			_fire_cd = FIRE_CD
			_spawn_bullet(muzzle_pos, mv.normalized())


## 目标决议：加权最优为候选；锁定窗口内不换目标（防抖），
## 窗口结束后新目标与旧锁夹角 ≤±8° 时吸附续锁，避免扫描枪口抖动。
func _resolve_target() -> BoomJelly:
	var best := _nearest_enemy()
	if best == null or _locked == null:
		return best
	if _locked == best:
		return _locked
	if _lock_ttl > 0.0:
		return _locked
	if _aim_angle_between(_locked, best) <= AIM_ASSIST_RAD:
		return _locked
	return best


func _aim_angle_between(a: BoomJelly, b: BoomJelly) -> float:
	var da := a.position - player.position
	da.y = 0.0
	var db := b.position - player.position
	db.y = 0.0
	if da.length_squared() < 0.0001 or db.length_squared() < 0.0001:
		return 0.0
	return acos(clampf(da.normalized().dot(db.normalized()), -1.0, 1.0))


func _aim_dir(from: Vector3, target: BoomJelly) -> Vector3:
	var aim_pos := target.position + Vector3(0.0, 0.6, 0.0)
	var dir := (aim_pos - from).normalized()
	# 少量散布让泡泡枪不那么死板。
	var spread := 0.03
	dir = dir.rotated(Vector3.UP, randf_range(-spread, spread))
	return dir


func _nearest_enemy() -> BoomJelly:
	# 加权自动瞄准：距离权重 0.6 + 朝向角度权重 0.4，玩家当前朝向内的敌人更优先；
	# ±8° 锥内带吸附权重，让扫射手感集中而非跳来跳去。
	# 目标切换防抖由 _tick_player/_resolve_target 用 _locked + 0.15s 窗口收口。
	var best: BoomJelly = null
	var best_w := INF
	# 玩家面朝用其显式保存的 facing(+Z 系，见 BoomPlayer.face_toward)，不依赖节点旋转符号。
	var fwd: Vector3 = player.facing
	if fwd.length_squared() < 0.001:
		fwd = Vector3(0.0, 0.0, 1.0)
	for e in enemies:
		var jelly := e as BoomJelly
		if jelly == null or jelly.is_dead() or jelly.hp <= 0:
			continue
		var to_enemy: Vector3 = jelly.position - player.position
		to_enemy.y = 0.0
		var d: float = to_enemy.length()
		if d <= 0.001:
			continue
		var to_dir := to_enemy.normalized()
		var angle := acos(clampf(fwd.dot(to_dir), -1.0, 1.0))
		var w_dist: float = 0.6 * (d / ENEMY_BOUND_Z)
		var w_ang: float = 0.4 * (angle / PI)
		var w: float = w_dist + w_ang
		# ±8°(约 0.14 rad) 锥内吸附：权重显著压低，命中更稳。
		if angle < AIM_ASSIST_RAD:
			w *= 0.5
		# 威胁加权：前摇/冲锋中的敌人 ×1.5 优先（成本 ÷1.5），别放跑贴脸冲撞。
		if jelly.phase == BoomJelly.Phase.WINDUP or jelly.phase == BoomJelly.Phase.LUNGE:
			w *= 0.667
		if w < best_w:
			best_w = w
			best = jelly
	return best


func _spawn_bullet(from: Vector3, dir: Vector3) -> void:
	var b := bullets[_bullet_idx] as BoomBullet
	_bullet_idx = (_bullet_idx + 1) % bullets.size()
	b.fire(from, dir)
	shot_fired.emit(from)


# ------------------------------------------------------------------ 技能（M2）


## 当前瞄准的最远敌人（供闪电链起点/扇形朝向）。无可攻击目标返回 null。
func nearest_attacker() -> BoomJelly:
	return _nearest_enemy()


## 供表现层触发一次性顿帧（如闪电链首跳 0.06s，design_m2_danmaku.md §4.2）。
func trigger_freeze(dur: float) -> void:
	_freeze_left = maxf(_freeze_left, dur)


## M3 击杀播报：按当前连杀数给出播报文案（空串 = 不播报）。
## 阈值 2/3/5（design_boom.md §7.2）；4 连杀维持 TRIPLE 档继续弹播报。
static func announce_for_combo(combo: int) -> String:
	if combo >= ANNOUNCE_RAMPAGE:
		return "RAMPAGE"
	if combo >= ANNOUNCE_TRIPLE:
		return "TRIPLE"
	if combo >= ANNOUNCE_DOUBLE:
		return "DOUBLE"
	return ""


## M3 结算星级：无尽模式下按撑到的波次给星（2/4/6 波各一颗，上限 3）。
static func result_stars(wave: int) -> int:
	var stars := 0
	if wave >= RESULT_STAR_WAVE_1:
		stars += 1
	if wave >= RESULT_STAR_WAVE_2:
		stars += 1
	if wave >= RESULT_STAR_WAVE_3:
		stars += 1
	return stars


## 爆裂弹幕：朝最近敌人方向射出 FAN_COUNT 发扇形散弹（复用子弹池，走既有命中/回收）。
## 无目标时朝玩家朝向扇形散射。返回实际发射数（顿帧/特效由上层订阅 shot_fired）。
func cast_fan_shot() -> int:
	var muzzle: Vector3 = player.position + player.basis * player.muzzle.position
	var base_dir: Vector3 = player.facing
	var target := _nearest_enemy()
	if target != null:
		base_dir = _aim_dir(muzzle, target)
	var count: int = 0
	var span := FAN_SPREAD_RAD
	var step_rad := 0.0 if FAN_COUNT == 1 else span * 2.0 / float(FAN_COUNT - 1)
	for i in FAN_COUNT:
		var off := -span + float(i) * step_rad
		var dir := base_dir.rotated(Vector3.UP, off)
		_spawn_bullet(muzzle, dir)
		count += 1
	return count


## 闪电链：以最近敌人为起点，向其它敌人链式弹跳 CHAIN_MAX_TARGETS 次，每次伤害衰减 CHAIN_DECAY。
## 返回被命中的敌人数组（含存活者，供上层画电弧/飘字/顿帧）。起点 null 返回空数组。
func cast_chain_arc() -> Array:
	var hits: Array = []
	var from := player.position
	var dmg := float(BULLET_DMG)
	var start := _nearest_enemy()
	if start == null:
		return hits
	_apply_skill_hit(start, int(round(dmg)), hits)
	from = start.position
	var chain := [start]
	for _i in CHAIN_MAX_TARGETS - 1:
		dmg *= CHAIN_DECAY
		var next: BoomJelly = _nearest_jelly_from(from, chain)
		if next == null:
			break
		_apply_skill_hit(next, int(round(dmg)), hits)
		chain.append(next)
		from = next.position
	return hits


## 核爆：以玩家为中心 NUKE_RADIUS 半径内所有敌人受 BULLET_DMG*NUKE_DMG_MULT 伤害。
## 返回被命中的敌人数组。命中触发一次击杀顿帧（大事件感）。
func cast_aoe_nuke() -> Array:
	var hits: Array = []
	var targets: Array = []
	for e in enemies:
		var jelly := e as BoomJelly
		if jelly == null or jelly.is_dead() or jelly.hp <= 0:
			continue
		if player.position.distance_to(jelly.position) <= NUKE_RADIUS:
			targets.append(jelly)
	for jelly in targets:
		_apply_skill_hit(jelly, BULLET_DMG * NUKE_DMG_MULT, hits)
	if not targets.is_empty():
		# 核爆：一次大顿帧（0.14s，事件型一次性，压防晕铁律事件上限内）。
		var dur := 0.14
		_freeze_left = maxf(_freeze_left, dur)
		_last_killstop = game_time
	return hits


## 距 from 平面距离最近且不在 exclude 内、未死的敌人（闪电链找下一跳用）。
func _nearest_jelly_from(from: Vector3, exclude: Array) -> BoomJelly:
	var best: BoomJelly = null
	var best_d := INF
	for e in enemies:
		var jelly := e as BoomJelly
		if jelly == null or jelly.is_dead() or jelly.hp <= 0:
			continue
		if exclude.has(jelly):
			continue
		var d := jelly.position.distance_to(from)
		if d <= CHAIN_JUMP_RANGE and d < best_d:
			best_d = d
			best = jelly
	return best


## 对单个敌人结算一次技能伤害：扣血 + 发 damaged 信号。
## 命中即把敌人放入 out_hits（含存活者——衰减伤害是常态，上层需要为每个
## 被命中的目标画电弧/提示，而不是只画被击杀的）；致死则最终结算击杀。
func _apply_skill_hit(jelly: BoomJelly, dmg: int, out_hits: Array) -> void:
	if jelly.is_dead() or jelly.hp <= 0:
		return
	var hit_dir := (jelly.position - player.position).normalized()
	enemy_damaged.emit(jelly.position, hit_dir)
	out_hits.append(jelly)
	if jelly.take_damage(dmg, hit_dir):
		_finalize_kill(jelly)


# ------------------------------------------------------------------ 子弹


func _tick_bullets(delta: float) -> void:
	var dead_this_tick: Array = []
	var broken_this_tick: Array = []
	for b in bullets:
		var bullet := b as BoomBullet
		if not bullet.active:
			continue
		bullet.position += bullet.vel * delta
		bullet.life -= delta
		var out: bool = (
			bullet.life <= 0.0
			or absf(bullet.position.x) > ENEMY_BOUND_X + 1.0
			or absf(bullet.position.z) > ENEMY_BOUND_Z + 1.0
		)
		if out:
			bullet.recycle()
			continue
		for e in enemies:
			var jelly := e as BoomJelly
			if jelly == null or jelly.is_dead() or jelly.hp <= 0:
				continue
			if bullet.position.distance_to(jelly.position) <= BoomJelly.HIT_RADIUS:
				var hit_dir: Vector3 = bullet.vel.normalized()
				bullet.recycle()
				enemy_damaged.emit(bullet.position, hit_dir)
				if jelly.take_damage(BULLET_DMG, hit_dir):
					dead_this_tick.append(jelly)
				break
		if bullet.active:
			for prop in props:
				var target := prop as BoomProp
				if target == null or target.broken:
					continue
				if bullet.position.distance_to(target.position) <= BoomProp.HIT_RADIUS:
					bullet.recycle()
					if target.take_damage():
						broken_this_tick.append(target)
					break
	for e in dead_this_tick:
		var jelly := e as BoomJelly
		if jelly != null:
			_finalize_kill(jelly)
	for prop in broken_this_tick:
		_finalize_prop(prop as BoomProp)


func _tick_props(delta: float) -> void:
	for prop in props:
		var target := prop as BoomProp
		if target != null:
			target.tick(delta)


func _spawn_props() -> void:
	var placements: Array = [
		["crate", Vector3(-2.8, 0.0, -3.5)],
		["barrel", Vector3(3.0, 0.0, 1.8)],
		["crate", Vector3(-3.1, 0.0, 6.0)],
	]
	for entry in placements:
		var prop := BoomProp.new(entry[0])
		prop.position = entry[1]
		props.append(prop)
		add_child(prop)


func _finalize_prop(prop: BoomProp) -> void:
	if prop == null or not props.has(prop):
		return
	coins += prop.coin_value
	score += prop.coin_value
	prop_broken.emit(prop.position, prop.coin_value)
	props.erase(prop)
	remove_child(prop)
	prop.queue_free()


func _finalize_kill(jelly: BoomJelly) -> void:
	kills += 1
	if combo_left > 0.0:
		combo += 1
	else:
		combo = 1
	combo_left = COMBO_WINDOW
	score += KILL_SCORE
	# 击杀顿帧：0.5s 内最多一次大停，防晕；首停 80ms 不超防晕铁律，连发用 25ms 轻点。
	var now: float = game_time
	var dur := 0.08 if now - _last_killstop >= 0.5 else 0.025
	_last_killstop = now
	_freeze_left = maxf(_freeze_left, dur)
	enemy_died.emit(jelly.position)
	enemies.erase(jelly)
	if is_instance_valid(jelly):
		remove_child(jelly)
		jelly.queue_free()


# ------------------------------------------------------------------ 敌人


func _tick_enemies(delta: float) -> void:
	for e in enemies:
		var jelly := e as BoomJelly
		if jelly == null:
			continue
		jelly.physics_update(delta, player.position, enemies, ENEMY_BOUND_X, ENEMY_BOUND_Z)


func spawn_enemy_at(pos: Vector3) -> BoomJelly:
	var jelly := BoomJelly.new()
	jelly.position = pos
	enemies.append(jelly)
	add_child(jelly)
	return jelly


func _spawn_edge_enemy() -> void:
	for attempt in 12:
		var side := randi() % 4
		var pos := Vector3(0.0, 0.0, 0.0)
		match side:
			0:  # 上
				pos = Vector3(randf_range(-ENEMY_BOUND_X, ENEMY_BOUND_X), 0.0, -ENEMY_BOUND_Z)
			1:  # 下
				pos = Vector3(randf_range(-ENEMY_BOUND_X, ENEMY_BOUND_X), 0.0, ENEMY_BOUND_Z)
			2:  # 左
				pos = Vector3(-ENEMY_BOUND_X, 0.0, randf_range(-ENEMY_BOUND_Z, ENEMY_BOUND_Z))
			_:
				pos = Vector3(ENEMY_BOUND_X, 0.0, randf_range(-ENEMY_BOUND_Z, ENEMY_BOUND_Z))
		if pos.distance_to(player.position) >= 4.0:
			spawn_enemy_at(pos)
			return
	# 兜底：随手刷一个远点。
	var fallback := Vector3(randf_range(-ENEMY_BOUND_X, ENEMY_BOUND_X), 0.0, -ENEMY_BOUND_Z)
	spawn_enemy_at(fallback)


# ------------------------------------------------------------------ 波次


func _wave_quota(n: int) -> int:
	return clampi(3 + (n - 1), 3, 24)


func _max_alive() -> int:
	return clampi(2 + wave, 2, 9)


func _spawn_interval() -> float:
	return clampf(1.7 - wave * 0.15, 0.7, 1.7)


func _begin_wave() -> void:
	_quota_current = _wave_quota(wave)
	_spawned_total = 0
	_spawn_cd = 0.6
	_between_waves = false
	wave_started.emit(wave)


func _tick_spawns(delta: float) -> void:
	if is_over:
		return
	if _between_waves:
		_next_wave_cd -= delta
		if _next_wave_cd <= 0.0:
			wave += 1
			_begin_wave()
		return
	if _spawned_total >= _quota_current:
		if enemies.is_empty():
			var bonus: int = 20 + wave * 10
			score += bonus
			wave_cleared.emit(wave, bonus)
			_between_waves = true
			_next_wave_cd = 1.8
		return
	if not auto_spawn:
		return
	if enemies.size() < _max_alive():
		_spawn_cd -= delta
		if _spawn_cd <= 0.0:
			_spawn_cd = _spawn_interval()
			_spawned_total += 1
			_spawn_edge_enemy()


## 测试/调试用：标记当前波次已经刷满（配合 spawn_enemy_at 后手动结算波次）。
func force_wave_spawned_done() -> void:
	_spawned_total = _quota_current


# ------------------------------------------------------------------ 玩家受击


func _tick_player_contact() -> void:
	for e in enemies:
		var jelly := e as BoomJelly
		if jelly == null or jelly.is_dead():
			continue
		# hit_cd 由 BoomJelly.physics_update 统一递减（避免双重递减使冷却减半）。
		if jelly.hit_cd > 0.0:
			continue
		var flat := player.position - jelly.position
		flat.y = 0.0
		if flat.length() <= player.radius + jelly.radius + 0.12:
			jelly.hit_cd = 1.0
			jelly.knock_back(Vector3(jelly.position - player.position).normalized())
			_damage_player(jelly.position)


func _damage_player(from_pos: Vector3) -> void:
	player.take_damage()
	# 规格：顿帧仅击杀/爆炸触发，玩家受击不停帧（避免紧张而非爽）。
	if player.hp <= 0:
		is_over = true
		game_over.emit(score)
	else:
		player_damaged.emit(player.hp, from_pos)
