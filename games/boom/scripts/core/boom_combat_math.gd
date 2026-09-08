class_name BoomCombatMath
extends RefCounted
## M8 战斗结算纯数学分册（从 BoomGame 拆出控制主文件行数，模式同 BoomGameSkillCasts）：
## 全部静态、零节点依赖，可无头断言。BoomGame 保留薄包装作为统一结算入口。


## M8 最终攻击力（§5.2）：floor(基础攻击力 × (1 + 伤害加成倍率))。
static func final_attack(p_base: int, dmg_mult: float) -> int:
	return int(floor(float(p_base) * dmg_mult))


## M8 暴击判定（§6.3）：对"最终攻击力"掷一次暴击，暴击则 × 暴击倍率后取整。
## 返回 [dmg, crit]。
static func roll_crit(final_dmg: int, crit_rate: float, crit_dmg_mult: float) -> Array:
	var crit: bool = randf() < crit_rate
	if crit:
		final_dmg = int(floor(float(final_dmg) * crit_dmg_mult))
	return [final_dmg, crit]


## M8 统一输出结算入口（§5.2/§6）：由"基础攻击力"得到最终伤害与暴击标记。
## 返回 [dmg, crit]。
static func roll_attack(
	p_base: int, dmg_mult: float, crit_rate: float, crit_dmg_mult: float
) -> Array:
	return roll_crit(final_attack(p_base, dmg_mult), crit_rate, crit_dmg_mult)


## M8 敌人原始接触攻击力（§10.2 数值表为准）：基础 8 + min(floor(wave/5), 4)
## → W1-4=8 / W5-9=9 / W10-14=10 / W15-19=11 / W20+=12。
@warning_ignore("integer_division")
static func enemy_raw_attack(p_wave: int) -> int:
	var bonus: int = mini(maxi(0, p_wave / 5), BoomGame.ENEMY_ATTACK_BONUS_CAP)
	return BoomJelly.BASE_ATTACK + bonus


# ---- M4 波次纯数学（从 BoomGame 拆出；常量仍归 BoomGame 所有）----


## §3.2 配额分段：教学段 2+n → 中段每波 +2 → W10 台阶 18 起，封顶 30。
static func wave_quota(n: int) -> int:
	if n <= BoomGame.WAVE_QUOTA_EARLY_END:
		return BoomGame.WAVE_QUOTA_EARLY_BASE + n
	if n <= BoomGame.WAVE_QUOTA_MID_END:
		return (
			BoomGame.WAVE_QUOTA_MID_BASE
			+ BoomGame.WAVE_QUOTA_STEP * (n - BoomGame.WAVE_QUOTA_EARLY_END - 1)
		)
	return mini(
		(
			BoomGame.WAVE_QUOTA_LATE_BASE
			+ BoomGame.WAVE_QUOTA_STEP * (n - BoomGame.WAVE_QUOTA_MID_END - 1)
		),
		BoomGame.WAVE_QUOTA_CAP
	)


## W1-4→0 / W5-9→1 / W10-14→2 / W15-19→3 / W20-24→4 / W25+→5。
@warning_ignore("integer_division")
static func hp_tier(n: int) -> int:
	return mini(n / 5, BoomGame.WAVE_HP_MULTS.size() - 1)


## W1-9→1.0 / W10-14→1.1 / W15-19→1.2 / W20+→1.3（封顶硬红线）。
@warning_ignore("integer_division")
static func speed_tier(n: int) -> int:
	return mini(n / 5, BoomGame.WAVE_SPEED_MULTS.size() - 1)


## §3.4 波间歇阶梯：2.5s 起、每 5 波降 0.5s、下限 1.0s。
static func wave_rest(n: int) -> float:
	if n <= BoomGame.WAVE_REST_EARLY_END:
		return BoomGame.WAVE_REST_EARLY
	if n <= BoomGame.WAVE_REST_MID_END:
		return BoomGame.WAVE_REST_MID
	if n <= BoomGame.WAVE_REST_LATE_END:
		return BoomGame.WAVE_REST_LATE
	return BoomGame.WAVE_REST_MIN


## §3.5 波结算奖励查表；W10/20 台阶波 ×2（台阶仪式感）。
static func wave_bonus(n: int) -> int:
	var bonus := BoomGame.WAVE_BONUS_BASE + n * BoomGame.WAVE_BONUS_PER_WAVE
	if n % BoomGame.WAVE_STAGE_EVERY == 0:
		bonus *= BoomGame.WAVE_STAGE_BONUS_MULT
	return bonus


## M8 统一受伤结算（§8/§10.3）：先闪避判定，再防御减伤，保底 1 点。
## 返回 [final_dmg, dodged]。
static func resolve_player_damage(raw: int, dodge_rate: float, p_defense: int) -> Array:
	if randf() < dodge_rate:
		return [0, true]
	var mit: float = BoomStats.mitigation_for(p_defense)
	return [maxi(1, int(floor(float(raw) * (1.0 - mit)))), false]


## M8 属性快照（§12.3）：属性面板与 test_hook 共用，数值全部来自实际结算函数。
static func build_snapshot(
	stats: BoomStats,
	player: BoomPlayer,
	exp_sys: BoomExperience,
	weapon_base: int,
	fire_interval: float
) -> Dictionary:
	return {
		"level": exp_sys.level,
		"xp": exp_sys.xp,
		"xp_next": BoomExperience.xp_to_next(exp_sys.level),
		"hp": player.hp,
		"max_hp": player.max_hp,
		"base_attack": weapon_base,
		"final_attack": final_attack(weapon_base, stats.dmg_mult()),
		"attack_speed": 0.0 if fire_interval <= 0.0 else snappedf(1.0 / fire_interval, 0.01),
		"crit_rate_pct": int(round(stats.crit_rate() * 100.0)),
		"crit_dmg_pct": int(round(stats.crit_dmg_mult() * 100.0)),
		"haste_pct": int(round((stats.haste_mult() - 1.0) * 100.0)),
		"defense": stats.defense,
		"mitigation_pct": snappedf(stats.mitigation() * 100.0, 0.1),
		"dodge_pct": int(round(stats.dodge_rate() * 100.0)),
		"move_speed": snappedf(player.move_speed, 0.01),
	}
