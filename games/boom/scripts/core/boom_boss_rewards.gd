class_name BoomBossRewards
extends RefCounted
## M11 首领三选一：免费技能节点 / 主动技能进化 / 稀有人物属性。

const TYPE_UNLOCK: String = "free_unlock"
const TYPE_EVOLVE: String = "evolve_active"
const TYPE_RARE: String = "rare_stat"
const TYPE_COINS: String = "fallback_coins"

const RARE_DEFS: Array[Dictionary] = [
	{"id": "iron_paper", "title": "铁纸", "desc": "防御 +15"},
	{"id": "cinnabar_eye", "title": "朱砂瞳", "desc": "暴击率 +6%"},
	{"id": "mist_body", "title": "雾身", "desc": "闪避 +5%"},
]


static func build_choices(skill_system: BoomSkillSystem, encounter_index: int) -> Array[Dictionary]:
	var unlock_target := _next_unlock(skill_system)
	var evolve_target := skill_system._first_evolvable_active()
	var rare: Dictionary = RARE_DEFS[(maxi(1, encounter_index) - 1) % RARE_DEFS.size()]
	var choices: Array[Dictionary] = []
	if unlock_target != "":
		(
			choices
			. append(
				{
					"id": TYPE_UNLOCK,
					"type": TYPE_UNLOCK,
					"target": unlock_target,
					"title": "免费节点",
					"desc": "解锁 %s" % skill_system.get_skill(unlock_target).display_name,
					"icon": BoomSkillSystem.icon_path(unlock_target),
				}
			)
		)
	else:
		choices.append(_coin_fallback("树已圆满"))
	if evolve_target != "":
		(
			choices
			. append(
				{
					"id": TYPE_EVOLVE,
					"type": TYPE_EVOLVE,
					"target": evolve_target,
					"title": "主动进化",
					"desc": "%s · 进化为最终形态" % skill_system.get_skill(evolve_target).display_name,
					"icon": BoomSkillSystem.icon_path(evolve_target),
				}
			)
		)
	else:
		choices.append(_coin_fallback("已全部进化"))
	(
		choices
		. append(
			{
				"id": TYPE_RARE,
				"type": TYPE_RARE,
				"target": rare["id"],
				"title": rare["title"],
				"desc": rare["desc"],
				"icon": "res://assets/images/icons/spirit_seal_coin.png",
			}
		)
	)
	return choices


static func apply(choice: Dictionary, game: BoomGame, skill_system: BoomSkillSystem) -> bool:
	var reward_type := String(choice.get("type", ""))
	var target := String(choice.get("target", ""))
	match reward_type:
		TYPE_UNLOCK:
			if not skill_system._grant_free_unlock(target):
				return false
			if skill_system.equipped.size() < BoomSkillSystem.MAX_EQUIPPED:
				skill_system.equip(target)
		TYPE_EVOLVE:
			if not skill_system._evolve_skill(target):
				return false
		TYPE_RARE:
			if not game.stats.apply_rare(target):
				return false
			game._apply_stats_to_player()
			game.stat_applied.emit(target)
		TYPE_COINS:
			game.coins += 200
			BoomSave.add_coins(200)
		_:
			return false
	return true


static func _next_unlock(skill_system: BoomSkillSystem) -> String:
	for skill_id in skill_system.tree_ids():
		if not skill_system.is_unlocked(skill_id) and skill_system.unlock_cost(skill_id) >= 0:
			return skill_id
	return ""


static func _coin_fallback(reason: String) -> Dictionary:
	return {
		"id": TYPE_COINS,
		"type": TYPE_COINS,
		"target": "",
		"title": reason,
		"desc": "灵印 +200",
		"icon": "res://assets/images/icons/spirit_seal_coin.png",
	}
