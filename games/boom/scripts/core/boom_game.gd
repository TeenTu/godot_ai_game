class_name BoomGame
extends Node3D
## 《B-Boom》核心对局（零 UI 依赖，可无头逻辑测试）。
##   - 玩家：摇杆输入驱动（input_move），自动瞄准最近敌人、自动开火。
##   - 敌人：纸偶/雾灵（BoomJelly），波次刷怪，前摇 + 冲撞。
##   - 灵印投射物：对象池，命中扣血 + 击退；击杀计分连击。
##   - 手感：击杀顿帧（0.5s 内最多一次全停）、击退、squash 由敌人自身做。
## 本类只发信号 + 暴露数据；视觉表现（粒子/震屏/音效/HUD）由 main.gd 订阅。

signal enemy_damaged(pos: Vector3, dir: Vector3)
## M8 统一输出结算广播（§5/§6）：dmg=最终结算伤害，crit=是否暴击。
signal enemy_hit(pos: Vector3, dmg: int, crit: bool)
signal enemy_died(pos: Vector3)
signal shot_fired(pos: Vector3)
signal player_damaged(amount: int, from_pos: Vector3)
## M8 闪避成功（§8）：不扣血/不无敌帧/不受击反馈，仅消耗敌人攻击冷却。
signal player_dodged(from_pos: Vector3)
signal wave_cleared(wave: int, bonus: int)
signal wave_started(wave: int)
signal game_over(final_score: int)
signal prop_broken(pos: Vector3, coin_value: int)
## 技能弹道命中（非普通弹）：pos=命中点，skill_id=弹道归属（§4.2 fan 每命中飘字）。
signal skill_bullet_hit(pos: Vector3, skill_id: String)
## M5 大剑弧斩命中（§4.2/§4.3）：pos=命中点，dmg=单目标伤害（=swing_dmg）；不走 enemy_damaged 飘字管线，表现层按此信号做重击反馈。
signal blade_hit(pos: Vector3, dmg: int)
## 判笔每次出手只发一次，用于刀光、音效和震屏；避免怪海中逐目标重复触发表现。
signal swing_released(pos: Vector3, facing: Vector3, hit_count: int)
## M7 经验入账（击杀后广播，amount 为本次获得经验）。
signal exp_gained(amount: int)
## M7 升级（BoomExperience.leveled_up 转发；升级点进入 pending_upgrades）。
signal level_up(new_level: int)
## M7 属性升级已应用（kind: hp/speed/dmg）。
signal stat_applied(kind: String)
## M7 应急维修回复（heal 技能；amount 为实际回复量）。
signal player_healed(amount: int)

## M5 挥斩 FSM（design_m5_weapons.md §4.2：蓄 → 抡 → 收，纯逻辑可无头断言）。
enum SwingState { NONE, WINDUP, ACTIVE, RECOVER }

const CrowdSystem = preload("res://scripts/core/boom_crowd_system.gd")
const MeleeSystem = preload("res://scripts/core/boom_melee_system.gd")

# 百怪夜巡扩展场域：玩家/敌人边界与 20×54 内场栏杆保持约 0.6m 安全边距。
const PLAYER_BOUND_X: float = 8.8
const PLAYER_BOUND_Z: float = 25.8
const ENEMY_BOUND_X: float = 9.4
const ENEMY_BOUND_Z: float = 26.4
const KILL_SCORE: int = 10
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

# ---- M4 波次系统（design_m4_waves.md §3/§4/§6，全部数值常量化调参不改逻辑）----
const WAVE_QUOTA_EARLY_BASE: int = 8  # W≤4：quota = 8+4n → 12/16/20/24
const WAVE_QUOTA_EARLY_END: int = 4
const WAVE_QUOTA_MID_BASE: int = 30  # W5–9：30+6*(n-5) → 30/36/42/48/54
const WAVE_QUOTA_MID_END: int = 9
const WAVE_QUOTA_LATE_BASE: int = 64  # W≥10：64+8*(n-10)，W10 怪海台阶
const WAVE_QUOTA_EARLY_STEP: int = 4
const WAVE_QUOTA_MID_STEP: int = 6
const WAVE_QUOTA_STEP: int = 8
const WAVE_QUOTA_CAP: int = 96
# 每 5 波一档（W1-4/W5-9/W10-14/W15-19/W20-24/W25+）→ 有效 HP 3/4/5/6/7/8。
const WAVE_HP_MULTS: Array[float] = [1.0, 1.34, 1.67, 2.0, 2.34, 2.67]
# 速度系数分段（W1-9/W10-14/W15-19/W20+）；1.3 为硬红线：再快前摇冲撞不可躲。
const WAVE_SPEED_MULTS: Array[float] = [1.0, 1.0, 1.1, 1.2, 1.3]
const WAVE_REST_READY: float = 2.0  # 开局准备时长（W1 首刷前）
const WAVE_REST_EARLY: float = 2.5  # W1–4 波间歇
const WAVE_REST_MID: float = 2.0  # W5–9
const WAVE_REST_LATE: float = 1.5  # W10–14
const WAVE_REST_MIN: float = 1.0  # W15+（下限）
const WAVE_REST_EARLY_END: int = 4
const WAVE_REST_MID_END: int = 9
const WAVE_REST_LATE_END: int = 14
const WAVE_BONUS_BASE: int = 20  # 波奖励 = base + wave*per_wave
const WAVE_BONUS_PER_WAVE: int = 10
const WAVE_STAGE_EVERY: int = 10  # 台阶波周期（W10/20…）：奖励 ×2
const WAVE_STAGE_BONUS_MULT: int = 2
const ELITE_EVERY_N: int = 5  # 每 5 波（W5/10/15…）最后一只为精英
const ELITE_HP_MULT: float = 3.0  # 精英血量 = 当波有效 HP × 3
const ELITE_SCALE: float = 1.4  # 精英体型
const ELITE_SPEED_MULT: float = 0.85  # 精英更慢（更大更肉但好打）
const ELITE_COIN_COUNT: int = 8  # 死亡金币雨枚数
const ELITE_COIN_VALUE: int = 5  # 单枚金币值（雨合计 40）
const MAX_ALIVE_CAP: int = 48  # Web 目标的怪海上限；分离计算按 4 帧轮转
const MAX_ALIVE_BASE: int = 12
const MAX_ALIVE_PER_WAVE: int = 4
const SPAWN_INTERVAL_START: float = 0.47
const SPAWN_INTERVAL_MIN: float = 0.16
const SPAWN_INTERVAL_STEP: float = 0.03
const SPAWN_BURST_MAX: int = 4
const CROWD_SEPARATION_STRIDE: int = 4

# ---- M7 成长系统（design_m7_progression.md）----
const RING_COUNT: int = 12  # ring 环形弹幕发数
const TWIN_COUNT: int = 2  # M7R twin 双管重弹发数（平行弹，落点聚合即重击）
const TWIN_SPACING: float = 0.35  # twin 双弹横向间距（世界单位）
const WHIRL_MAX_TARGETS: int = 8  # M7R whirl 旋风斩单次命中上限

# ---- M8 属性与战斗数值（design_m8_attributes.md）----
const REPAIR_HP: int = 15  # heal 单次回复量（§4.2）
const ENEMY_ATTACK_BONUS_CAP: int = 4  # 波次攻击加成封顶（§10.2）

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

## M5：当前武器（BoomWeaponDef，由 set_weapon 注入；默认恒为泡泡枪）。
var weapon_cfg: BoomWeaponDef
## M5 R9：对局是否已开战（选武器期间 sim 已建但未发波）。
var match_started: bool = false
## M7：属性容器（升级点消费落点）与经验曲线；升级点待消费数。
var stats: BoomStats
var exp_sys: BoomExperience
var pending_upgrades: int = 0
## M7R 被动加成（_refresh_passives 写入；restart 归零）：
## rapid → 普攻 CD ×skill_fire_cd_mult；titan → 弧斩/旋风斩 +skill_swing_dmg_bonus。
var skill_fire_cd_mult: float = 1.0
var skill_swing_dmg_bonus: int = 0

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
# ---- M5 大剑挥斩状态 ----
var _swing_state: int = SwingState.NONE
var _swing_t: float = 0.0
## 当前双手判笔连段步骤。左挥 → 右挥 → 大回旋；只在下一次出手时推进。
var _swing_combo_index: int = 0
var _swing_step: Dictionary = {}
## 挥出瞬间的朝向快照（前摇期内不再转向新目标，宽容判定按挥出瞬间算，§4.2）。
var _swing_facing: Vector3 = Vector3.FORWARD
var _last_swing_freeze: float = -10.0  # 斩中顿帧 0.5s 门控
var _crowd_tick: int = 0
## R3 死亡表现窗：已死 jelly 移出 enemies 后仍挂树演 0.2s 压扁/淡出（不阻塞结算）。
var _corpses: Array = []


func _init() -> void:
	stats = BoomStats.new()
	exp_sys = BoomExperience.new()
	exp_sys.leveled_up.connect(_on_leveled_up)
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
	_tick_corpses(delta)
	_tick_player_contact()


## M5：纯数值重置（R9 把"开波"拆到 begin_match；存量调用语义 = 默认武器重开）。
func restart() -> void:
	# M7：成长状态随对局重置（金币也在下方清零；解锁/跨局金币在 BoomSave 不清）。
	stats.reset()
	exp_sys.reset()
	pending_upgrades = 0
	skill_fire_cd_mult = 1.0
	skill_swing_dmg_bonus = 0
	weapon_cfg = BoomWeapons.get_def(BoomWeapons.default_id())
	player.apply_weapon(weapon_cfg)
	_apply_stats_to_player()
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
	_fire_cd = weapon_cfg.fire_cd
	_freeze_left = 0.0
	_last_killstop = -10.0
	_locked = null
	_lock_ttl = 0.0
	_swing_state = SwingState.NONE
	_swing_t = 0.0
	_swing_combo_index = 0
	_swing_step.clear()
	_swing_facing = player.facing
	_last_swing_freeze = -10.0
	_crowd_tick = 0
	match_started = false
	player.hp = player.max_hp
	player.invuln_left = 0.0
	player.lock_move_left = 0.0
	player.position = Vector3.ZERO
	player.set_move(Vector2.ZERO)
	for b in bullets:
		(b as BoomBullet).recycle()
	for e in enemies:
		if is_instance_valid(e):
			e.queue_free()
	enemies.clear()
	for prop in props:
		if is_instance_valid(prop):
			prop.queue_free()
	props.clear()
	for corpse in _corpses:
		if is_instance_valid(corpse):
			corpse.queue_free()
	_corpses.clear()


## M5：选择武器并落机体数值（§3.3 关键工程点 1）。
func set_weapon(id: String) -> void:
	weapon_cfg = BoomWeapons.get_def(id)
	player.apply_weapon(weapon_cfg)
	_apply_stats_to_player()
	player.hp = player.max_hp
	_fire_cd = _fire_interval()
	_swing_state = SwingState.NONE
	_swing_t = 0.0
	_swing_combo_index = 0
	_swing_step.clear()


# ------------------------------------------------------------------ M8 属性/结算


## 升级回调：每级累积 1 个待消费升级点（apply_level_upgrade 消费）。
func _on_leveled_up(new_level: int) -> void:
	pending_upgrades += 1
	level_up.emit(new_level)


## 消费 1 个升级点应用升级卡（kind 见 BoomStats.KINDS）。
## KIND_HEAL 为一次性效果：回满当前生命、不进堆叠（§4.2）；未知 kind / 无点数拒绝。
func apply_level_upgrade(kind: String) -> bool:
	if pending_upgrades <= 0:
		return false
	if kind == BoomStats.KIND_HEAL:
		var healed: int = player.max_hp - player.hp
		player.hp = player.max_hp
		if healed > 0:
			player_healed.emit(healed)
	elif not stats.apply(kind):
		return false
	pending_upgrades -= 1
	_apply_stats_to_player()
	stat_applied.emit(kind)
	return true


## 把 stats 加成落到玩家机体；M8 §3.2：最大生命仅由武器决定，不随等级成长。
func _apply_stats_to_player() -> void:
	player.move_speed = BoomPlayer.MOVE_SPEED * weapon_cfg.move_mult * stats.move_mult()
	player.max_hp = maxi(1, BoomPlayer.BASE_MAX_HP + weapon_cfg.max_hp_bonus)


## M8 基础攻击力（§5.1）：当前武器决定的初始攻击参数。
func _base_attack() -> int:
	return weapon_cfg.base_attack


## M8 最终攻击力（§5.2）：floor(基础攻击力 × (1 + 伤害加成倍率))。
func _final_attack() -> int:
	return BoomCombatMath.final_attack(_base_attack(), stats.dmg_mult())


## 当前普攻间隔（秒）：武器 CD ×rapid 被动 ÷攻速倍率（§3.1）；修复 M7R rapid 只写不读未生效的缺口。
func _fire_interval() -> float:
	return weapon_cfg.fire_cd * skill_fire_cd_mult / stats.aspd_mult()


## M8 暴击判定（§6.3）：逐目标独立掷一次暴击。返回 [dmg, crit]。
func _roll_crit(final_dmg: int) -> Array:
	return BoomCombatMath.roll_crit(final_dmg, stats.crit_rate(), stats.crit_dmg_mult())


## M8 统一输出结算入口（§5.2/§6）：所有输出经这里得最终伤害与暴击。返回 [dmg, crit]。
func _roll_attack(p_base: int) -> Array:
	return BoomCombatMath.roll_attack(
		p_base, stats.dmg_mult(), stats.crit_rate(), stats.crit_dmg_mult()
	)


## M8 属性快照（§12.3）：面板与 test_hook 共用，数值来自实际结算函数。
func stats_snapshot() -> Dictionary:
	return BoomCombatMath.build_snapshot(stats, player, exp_sys, _base_attack(), _fire_interval())


## M5：开战（= 原 restart 后半段 _spawn_props + _begin_wave；R9 与构造解耦）。
func begin_match() -> void:
	match_started = true
	_spawn_props()
	_begin_wave()


# ------------------------------------------------------------------ 玩家


## 攻击循环按当前武器分发（design §3/§4）：RANGED=自动连射；MELEE=挥斩 FSM。
func _tick_player(delta: float) -> void:
	if weapon_cfg.kind == BoomWeaponDef.AttackKind.MELEE:
		_tick_melee(delta)
	else:
		_tick_ranged(delta)


## 泡泡枪：自动瞄准连射（保留现手感；参数读武器 def，默认与旧常量一致）。
func _tick_ranged(delta: float) -> void:
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
			_fire_cd = _fire_interval()
			_spawn_bullet(muzzle_pos, aim_dir)
			player.play_anim_once("recoil")
	elif player.move_vec.length_squared() > 0.01:
		# 无目标时朝移动方向边走边扫（只转向不开火会留空档）。
		var mv := Vector3(player.move_vec.x, 0.0, player.move_vec.y)
		player.face_toward(mv)
		if _fire_cd <= 0.0:
			_fire_cd = _fire_interval()
			_spawn_bullet(muzzle_pos, mv.normalized())
			player.play_anim_once("recoil")


## 判笔双手大剑 FSM：左挥 → 右挥 → 360° 大回旋。前摇可走但转向冻结；无目标不空挥；
## 判定按挥出瞬间朝向快照算一次，三段均复用同一 2.9m 斩距。
## 判笔双手大剑状态机已拆入 boom_melee_system.gd，保持 BoomGame 只负责对局编排。
func _tick_melee(delta: float) -> void:
	MeleeSystem.tick(self, delta)


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


func _spawn_bullet(from: Vector3, dir: Vector3, variant: String = "straight") -> void:
	var b := bullets[_bullet_idx] as BoomBullet
	_bullet_idx = (_bullet_idx + 1) % bullets.size()
	b.fire(from, dir)
	b.variant = variant
	shot_fired.emit(from)


# ------------------------------------------------------------------ 技能（M2）


## 当前瞄准的最远敌人（供闪电链起点/扇形朝向）。无可攻击目标返回 null。
func nearest_attacker() -> BoomJelly:
	return _nearest_enemy()


## 供表现层触发一次性顿帧（如闪电链首跳 0.06s，design_m2_danmaku.md §4.2）。
func trigger_freeze(dur: float) -> void:
	_freeze_left = maxf(_freeze_left, dur)


## M3 击杀播报：按当前连杀数给出播报文案（空串 = 不播报）；阈值 2/3/5，4 连杀维持 TRIPLE 档。
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
		_spawn_bullet(muzzle, dir, "fan")
		count += 1
	return count


## 闪电链：以最近敌人为起点链式弹跳 CHAIN_MAX_TARGETS 次，每次衰减 CHAIN_DECAY；返回被命中敌人数组（含存活者）。起点 null 返回空数组。
func cast_chain_arc() -> Array:
	var hits: Array = []
	var from := player.position
	# M8：链起点伤害 = 最终攻击力，每跳衰减后独立暴击判定（§6.3 chain 每跳独立）。
	var dmg := float(_final_attack())
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


## 核爆：以玩家为中心 NUKE_RADIUS 半径内所有敌人受伤害；返回被命中敌人数组，命中触发一次击杀顿帧。
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
		# M8：每个受击目标独立结算最终攻击力 ×4 并独立暴击判定（§6.3）。
		_apply_skill_hit(jelly, _final_attack() * NUKE_DMG_MULT, hits)
	if not targets.is_empty():
		# 核爆：一次大顿帧（0.14s，事件型一次性，压防晕铁律事件上限内）。
		var dur := 0.14
		_freeze_left = maxf(_freeze_left, dur)
		_last_killstop = game_time
	return hits


## M7 ring 环形弹幕薄包装（实现见 BoomGameSkillCasts.ring_shot）。
func cast_ring_shot() -> int:
	return BoomGameSkillCasts.ring_shot(self)


## M7 heal 应急维修薄包装（实现见 BoomGameSkillCasts.repair）。
func cast_repair() -> int:
	return BoomGameSkillCasts.repair(self)


## M7R twin 双管重弹薄包装（实现见 BoomGameSkillCasts.twin_shot）。
func cast_twin_shot() -> int:
	return BoomGameSkillCasts.twin_shot(self)


## M7R whirl 旋风斩薄包装（实现见 BoomGameSkillCasts.whirl）。
func cast_whirl() -> int:
	return BoomGameSkillCasts.whirl(self)


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


## 对单个敌人结算一次技能伤害：暴击判定 + 扣血 + 发信号；dmg 为最终攻击力口径，暴击逐目标独立判定（§6.3）。
## 命中即放入 out_hits（含存活者，衰减伤害是常态）；致死则最终结算击杀。
func _apply_skill_hit(jelly: BoomJelly, dmg: int, out_hits: Array) -> void:
	if jelly.is_dead() or jelly.hp <= 0:
		return
	var hit_dir := (jelly.position - player.position).normalized()
	enemy_damaged.emit(jelly.position, hit_dir)
	out_hits.append(jelly)
	var roll: Array = _roll_crit(dmg)
	enemy_hit.emit(jelly.position, roll[0], roll[1])
	if jelly.take_damage(roll[0], hit_dir):
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
				# 技能弹道命中广播（§4.2）：fan 每命中 1 个飘字，普通弹不发。
				if bullet.variant != "straight":
					skill_bullet_hit.emit(bullet.position, bullet.variant)
				# M8 统一输出结算入口（§5.2）：普攻逐发独立暴击判定。
				var roll: Array = _roll_attack(_base_attack())
				enemy_hit.emit(bullet.position, roll[0], roll[1])
				if jelly.take_damage(roll[0], hit_dir):
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
	# M7R 货币语义：对局内金币获得时即时累加进跨局存档（内存；落盘择机 save()）。
	BoomSave.add_coins(prop.coin_value)
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
	# M7 击杀经验入账（精英 ×8；升级在 exp_sys 内同步发信号 → pending_upgrades）。
	var xp_gain: int = BoomExperience.ELITE_XP if jelly.elite else BoomExperience.KILL_XP
	exp_sys.add_xp(xp_gain)
	exp_gained.emit(xp_gain)
	# 击杀顿帧：0.5s 内最多一次大停，防晕；首停 80ms 不超防晕铁律，连发用 25ms 轻点。
	var now: float = game_time
	var dur := 0.08 if now - _last_killstop >= 0.5 else 0.025
	_last_killstop = now
	_freeze_left = maxf(_freeze_left, dur)
	enemy_died.emit(jelly.position)
	if jelly.elite:
		_elite_coin_rain(jelly.position)
	enemies.erase(jelly)
	# R3：移出逻辑数组（enemies）但延迟销毁——由 BoomJelly 的表现窗 Tween 完成后
	# queue_free（_tick_corpses 兜底驱动，避免无头环境 tween 不跑导致的悬挂）。
	_corpses.append(jelly)
	if not is_instance_valid(jelly):
		return
	if not jelly.is_dying():
		jelly.begin_death()


## 死亡表现窗驱动（R3）：已死 jelly 不参与对局逻辑，仅推进 0.2s 压扁/淡出。
func _tick_corpses(delta: float) -> void:
	var done: Array = []
	for corpse in _corpses:
		var jelly := corpse as BoomJelly
		if jelly == null or not is_instance_valid(jelly):
			done.append(corpse)
			continue
		jelly.tick_death(delta)
		if jelly.death_elapsed() >= BoomJelly.DEATH_WINDOW:
			done.append(corpse)
			if is_instance_valid(jelly) and jelly.is_inside_tree():
				remove_child(jelly)
			if is_instance_valid(jelly):
				jelly.queue_free()
	for c in done:
		_corpses.erase(c)


## §4 精英死亡金币雨：ELITE_COIN_COUNT 枚 × ELITE_COIN_VALUE 逐枚入账，
## 逐枚沿 prop_broken 管线散射（表现层复用金币结算 + 飘字，零新增经济系统）。
func _elite_coin_rain(pos: Vector3) -> void:
	for i in ELITE_COIN_COUNT:
		var ang := TAU * float(i) / float(ELITE_COIN_COUNT) + randf_range(-0.25, 0.25)
		var drop := pos + Vector3(cos(ang), 0.0, sin(ang)) * randf_range(0.5, 1.1)
		coins += ELITE_COIN_VALUE
		score += ELITE_COIN_VALUE
		# M7R 货币语义：金币雨逐枚即时累加进跨局存档。
		BoomSave.add_coins(ELITE_COIN_VALUE)
		prop_broken.emit(drop, ELITE_COIN_VALUE)


# ------------------------------------------------------------------ 敌人


func _tick_enemies(delta: float) -> void:
	CrowdSystem.tick_enemies(self, delta)


func spawn_enemy_at(pos: Vector3, elite: bool = false) -> BoomJelly:
	var jelly := BoomJelly.new()
	jelly.position = pos
	_apply_wave_scaling(jelly, elite)
	enemies.append(jelly)
	add_child(jelly)
	return jelly


## §3.3/§4：按当波阶梯缩放敌人属性（hp = round(30*mult)，M8 §9.1；速度乘系数）；
## elite 追加参数放大（血 ×3 / 体型 ×1.4 / 速度 ×0.85），不加新 AI 行为。
func _apply_wave_scaling(jelly: BoomJelly, elite: bool) -> void:
	var hp := int(round(float(BoomJelly.MAX_HP) * WAVE_HP_MULTS[BoomCombatMath.hp_tier(wave)]))
	var sp_mult: float = WAVE_SPEED_MULTS[BoomCombatMath.speed_tier(wave)]
	if elite:
		hp = int(round(float(hp) * ELITE_HP_MULT))
		sp_mult *= ELITE_SPEED_MULT
		jelly.elite = true
		jelly.base_scale = ELITE_SCALE
		jelly.radius = BoomJelly.RADIUS * ELITE_SCALE
	jelly.hp = hp
	jelly.walk_speed = BoomJelly.WALK_SPEED * sp_mult
	jelly.lunge_speed = BoomJelly.LUNGE_SPEED * sp_mult


func _spawn_edge_enemy(elite: bool = false) -> void:
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
			spawn_enemy_at(pos, elite)
			return
	# 兜底：随手刷一个远点。
	var fallback := Vector3(randf_range(-ENEMY_BOUND_X, ENEMY_BOUND_X), 0.0, -ENEMY_BOUND_Z)
	spawn_enemy_at(fallback, elite)


# ------------------------------------------------------------------ 波次

# 波次纯数学（配额/档位/间歇/奖励查表）已拆至 BoomCombatMath（M8 行数门禁拆分）。


func _max_alive() -> int:
	return CrowdSystem.max_alive(self)


func _spawn_interval() -> float:
	return CrowdSystem.spawn_interval(self)


@warning_ignore("integer_division")
func _spawn_burst() -> int:
	return CrowdSystem.spawn_burst(self)


func _begin_wave() -> void:
	_quota_current = BoomCombatMath.wave_quota(wave)
	_spawned_total = 0
	# W1 首刷前留开局准备时长（§3.4），其后每波 0.6s 内开刷。
	_spawn_cd = WAVE_REST_READY if wave == 1 else 0.6
	_between_waves = false
	wave_started.emit(wave)


func _tick_spawns(delta: float) -> void:
	CrowdSystem.tick_spawns(self, delta)


## §4 精英周期：每 ELITE_EVERY_N 波的最后一只刷出为精英（W5/10/15…）。
func _is_elite_spawn() -> bool:
	return wave % ELITE_EVERY_N == 0 and _spawned_total >= _quota_current


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


## M8 统一受伤结算入口（§8/§10.3）：闪避判定 → 防御减伤 → 扣最终伤害；闪避成功不扣血/不进无敌帧。
func _damage_player(from_pos: Vector3) -> void:
	var raw := BoomCombatMath.enemy_raw_attack(wave)
	var result: Array = BoomCombatMath.resolve_player_damage(raw, stats.dodge_rate(), stats.defense)
	if result[1]:
		player_dodged.emit(from_pos)
		return
	player.take_damage(result[0])
	# 规格：顿帧仅击杀/爆炸触发，玩家受击不停帧（避免紧张而非爽）。
	if player.hp <= 0:
		is_over = true
		game_over.emit(score)
	else:
		player_damaged.emit(result[0], from_pos)
