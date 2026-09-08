class_name BoomGameSkillCasts
extends RefCounted
## M7/M7R 技能施放实现分册（从 BoomGame 拆出控制主文件行数）：
## 全部静态、以 BoomGame 为上下文，复用其子弹池 / 命中 / 击杀 / 回复管线。
## BoomGame 上保留同名薄包装（cast_ring_shot / cast_repair / cast_twin_shot /
## cast_whirl），测试与表现层调用方式不变。


## M7 ring 环形弹幕：以玩家为中心 RING_COUNT 发 360° 均布弹（复用子弹池，
## variant="ring" 走技能命中管线）。返回实际发射数。
static func ring_shot(g: BoomGame) -> int:
	var from: Vector3 = g.player.position + Vector3(0.0, 0.5, 0.0)
	var count: int = 0
	for i in BoomGame.RING_COUNT:
		var ang := TAU * float(i) / float(BoomGame.RING_COUNT)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		g._spawn_bullet(from, dir, "ring")
		count += 1
	return count


## M7 heal 应急维修：回复 min(REPAIR_HP, 缺口)；满血时 0（CD 照常消耗）。
## 返回实际回复量（发 player_healed 供表现层飘字）。
static func repair(g: BoomGame) -> int:
	var healed: int = mini(BoomGame.REPAIR_HP, g.player.max_hp - g.player.hp)
	if healed > 0:
		g.player.hp += healed
		g.player_healed.emit(healed)
	return healed


## M7R twin 双管重弹（bubble 专属）：朝瞄准方向平行射出 TWIN_COUNT 发重弹
## （variant="twin" 走技能命中管线；横向错开 TWIN_SPACING，聚合落点即重击）。
## 返回实际发射数。
static func twin_shot(g: BoomGame) -> int:
	var muzzle: Vector3 = g.player.position + g.player.basis * g.player.muzzle.position
	var base_dir: Vector3 = g.player.facing
	var target := g.nearest_attacker()
	if target != null:
		base_dir = g._aim_dir(muzzle, target)
	var side := base_dir.cross(Vector3.UP).normalized()
	if side.length_squared() < 0.001:
		side = Vector3(1.0, 0.0, 0.0)
	var count: int = 0
	for i in BoomGame.TWIN_COUNT:
		var offset: float = (
			(float(i) - float(BoomGame.TWIN_COUNT - 1) * 0.5) * BoomGame.TWIN_SPACING
		)
		var from: Vector3 = muzzle + side * offset
		g._spawn_bullet(from, base_dir, "twin")
		count += 1
	return count


## M7R whirl 旋风斩（sword 专属）：以玩家为圆心、斩距内 360° 全向一斩，
## 至多 WHIRL_MAX_TARGETS 名敌人各受统一结算伤害（§5.2：floor(base×倍率)+独立暴击）
## + 强击退。复用弧斩的 blade_hit / take_damage / _finalize_kill 管线。返回命中数。
static func whirl(g: BoomGame) -> int:
	var swing_base: int = g._base_attack() + g.skill_swing_dmg_bonus
	var hits: int = 0
	var candidates: Array = []
	for e in g.enemies:
		var jelly := e as BoomJelly
		if jelly == null or jelly.is_dead() or jelly.hp <= 0:
			continue
		if g.player.position.distance_to(jelly.position) <= g.weapon_cfg.swing_range:
			candidates.append(jelly)
	for jelly in candidates:
		if hits >= BoomGame.WHIRL_MAX_TARGETS:
			break
		var hit_dir: Vector3 = (jelly.position - g.player.position).normalized()
		hit_dir.y = 0.0
		if hit_dir.length_squared() < 0.001:
			hit_dir = g.player.facing
		var roll: Array = g._roll_attack(swing_base)
		g.blade_hit.emit(jelly.position, roll[0])
		g.enemy_hit.emit(jelly.position, roll[0], roll[1])
		if jelly.take_damage(roll[0], hit_dir, g.weapon_cfg.swing_knock):
			g._finalize_kill(jelly)
		hits += 1
	return hits
