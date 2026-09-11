class_name BoomSkillSystem
extends Node
## 技能系统逻辑层：每把武器一棵 2 分支 × 3 阶技能树。
## 普攻分支改变攻速/基础攻击/普攻形态；技能分支提供两个主动形态与冷却缩减。
## 解锁消耗跨局货币（BoomSave.coins，user:// 持久化）；构筑最多装备 3 个节点。
## 被动节点常驻生效但不占战斗触发位；tap / 左滑 / 右滑按主动技能装备顺序映射。
## 纯逻辑，不含视觉/粒子/音频；只发信号，效果由 main.gd 订阅后触发。

# 冷却结束（就绪）
signal skill_ready(skill_id: String)
# 技能已施放：result 为 cast_* 返回值（fan/ring/twin 为 int 发射数；chain/nuke/whirl 为命中数组；heal 为回复量）
signal skill_fired(skill_id: String, result: Variant)
# 金币解锁成功
signal skill_unlocked(skill_id: String)
# M11 首领奖励：当前局主动技能已进化。
signal skill_evolved(skill_id: String)

# 新武器专属主动技能冷却（秒）。
const FAN_COOLDOWN: float = 3.0
const CHAIN_COOLDOWN: float = 8.0
const NUKE_COOLDOWN: float = 20.0
const RING_COOLDOWN: float = 10.0
const TWIN_COOLDOWN: float = 6.0
const WHIRL_COOLDOWN: float = 12.0
const HEAL_COOLDOWN: float = 30.0
const LAMP_VOLLEY_COOLDOWN: float = 4.0
const LAMP_BEACON_COOLDOWN: float = 12.0
const BRUSH_WAVE_COOLDOWN: float = 6.0
const BRUSH_DOMAIN_COOLDOWN: float = 15.0

# 技能图标主题色
const FAN_COLOR: Color = Color(1.0, 0.75, 0.25)
const CHAIN_COLOR: Color = Color(0.3, 0.85, 1.0)
const NUKE_COLOR: Color = Color(1.0, 0.3, 0.3)
const RING_COLOR: Color = Color(0.55, 1.0, 0.65)
const TWIN_COLOR: Color = Color(0.55, 0.75, 1.0)
const WHIRL_COLOR: Color = Color(1.0, 0.6, 0.35)
const HEAL_COLOR: Color = Color(0.45, 0.95, 0.75)

# M7R 树内顺序解锁价（design_m7_progression.md §5.3）：树内第 1 个免费（默认解锁），
# 其余 60/120/200/300/420 递增。unlock_cost 返回 -1 表示免费/不可购买。
const TREE_PRICES: Array[int] = [0, 120, 300]

# §4.2 技能飘字规格：fan=黄"嘭!"小字 / chain=紫"链!"大字 / nuke=金"轰!"巨型。
const TEXT_FAN: String = "嘭!"
const TEXT_CHAIN: String = "链!"
const TEXT_NUKE: String = "轰!"
const TEXT_COLOR_FAN: Color = Color(1.0, 0.9, 0.3)
const TEXT_COLOR_CHAIN: Color = Color(0.7, 0.4, 1.0)
const TEXT_COLOR_NUKE: Color = Color(1.0, 0.78, 0.25)
const TEXT_SCALE_FAN: float = 0.85
const TEXT_SCALE_CHAIN: float = 1.3
const TEXT_SCALE_NUKE: float = 1.7

# M7 被动加成数值（bubble 专属 rapid / sword 专属 titan）。
const RAPID_FIRE_MULT: float = 0.8  # 装备 rapid：普攻 CD ×0.8（射速 +25%）
const TITAN_DMG_BONUS: int = 1  # 装备 titan：弧斩/旋风斩伤害 +1
const BASIC_ATTACK_MULT: float = 1.20
const BASIC_SPEED_MULT: float = 1.15
const SKILL_COOLDOWN_MULT: float = 0.85

# M7 每局装备上限（§5.4 硬红线：3 槽手势，超编拒绝）。
const MAX_EQUIPPED: int = 3

const SKILL_DESCRIPTIONS: Dictionary = {
	"lamp_quick_wick": "普攻速度 +15%",
	"lamp_bright_core": "基础攻击力 +20%",
	"lamp_threefold_seal": "每第 3 次普攻化为三重灵印",
	"lamp_firefly_volley": "向目标扇射 5 枚流萤灵印",
	"lamp_echo": "主动技能冷却 ×0.85",
	"lamp_soul_beacon": "360° 环射 12 枚灵印",
	"brush_firm_grip": "基础攻击力 +20%",
	"brush_flowing_script": "连挥节奏速度 +15%",
	"brush_verdict": "挥击扩至 180°/360°，连段伤害 ×1.25",
	"brush_ink_wave": "泼出前方 100° 墨浪，最多 8 目标",
	"brush_focus": "主动技能冷却 ×0.85",
	"brush_seal_domain": "封域 4.5m，最多 16 目标",
}

# 注入的对局引用，由 main.gd 赋值
var game: BoomGame

# M7R 技能池：skill_id -> BoomSkill（全部技能定义都在池里，武器树决定可见子集）。
var pool: Dictionary = {}
# M7R 当前武器树（BoomWeapons.get_def(weapon_id).tree["skills"] 的 6 槽序列）。
var weapon_id: String = "bubble"
var tree: Array[String] = []
# M7 本局构筑槽（主动与被动混排，最多 3 个）；手势槽读取 active_equipped()。
var equipped: Array[String] = []
## M11 本局主动技能进化，不写跨局存档；restart/reset 时清空。
var evolved_skills: Array[String] = []


func _init() -> void:
	_add_passive("lamp_quick_wick", "速燃灯芯", FAN_COLOR)
	_add_passive("lamp_bright_core", "明芯", FAN_COLOR)
	_add_passive("lamp_threefold_seal", "三重灵印", FAN_COLOR)
	pool["lamp_firefly_volley"] = BoomSkill.new(
		"lamp_firefly_volley", "流萤齐射", LAMP_VOLLEY_COOLDOWN, FAN_COLOR
	)
	_add_passive("lamp_echo", "灯影回响", RING_COLOR)
	pool["lamp_soul_beacon"] = BoomSkill.new(
		"lamp_soul_beacon", "引魂灯", LAMP_BEACON_COOLDOWN, RING_COLOR
	)
	_add_passive("brush_firm_grip", "稳执笔", WHIRL_COLOR)
	_add_passive("brush_flowing_script", "行云笔意", WHIRL_COLOR)
	_add_passive("brush_verdict", "朱砂判", NUKE_COLOR)
	pool["brush_ink_wave"] = BoomSkill.new(
		"brush_ink_wave", "泼墨横波", BRUSH_WAVE_COOLDOWN, CHAIN_COLOR
	)
	_add_passive("brush_focus", "一气呵成", CHAIN_COLOR)
	pool["brush_seal_domain"] = BoomSkill.new(
		"brush_seal_domain", "封域", BRUSH_DOMAIN_COOLDOWN, NUKE_COLOR
	)
	# 默认泡泡树；解锁进度从跨局存档加载（无存档 = 各树第 1 技能默认解锁）。
	set_weapon_tree("bubble")


func _add_passive(id: String, title: String, color: Color) -> void:
	pool[id] = BoomSkill.new(id, title, 0.0, color)
	(pool[id] as BoomSkill).is_passive = true


# ------------------------------------------------------------------ M7R 武器树


## 切换武器树：按 BoomWeaponDef.tree 过滤可见/可解锁集合。
## 同武器保留当前配置；换武器恢复独立存档，无历史配置时取已解锁的前 3 个。
func set_weapon_tree(p_weapon_id: String) -> void:
	var def := BoomWeapons.get_def(p_weapon_id)
	if weapon_id == p_weapon_id and not tree.is_empty():
		_refresh_passives()
		return
	weapon_id = p_weapon_id
	tree = []
	var ids: Variant = def.tree.get("skills", [])
	for id in ids as Array:
		tree.append(String(id))
	# 每法器独立持久配置；无配置时沿用树序默认，空数组表示主动卸空。
	equipped = []
	var unlocked := BoomSave.unlocked_for(weapon_id)
	var builds: Dictionary = BoomSave.data().get("skill_loadouts", {})
	var saved: Variant = builds.get(weapon_id, tree)
	var candidates: Array = saved if saved is Array else tree
	for sid in candidates:
		if equipped.size() >= MAX_EQUIPPED:
			break
		if sid is String and tree.has(sid) and unlocked.has(sid) and not equipped.has(sid):
			equipped.append(sid)
	_refresh_passives()


func _save_loadout() -> void:
	var builds: Dictionary = BoomSave.data().get("skill_loadouts", {})
	builds[weapon_id] = equipped.duplicate()
	BoomSave.data()["skill_loadouts"] = builds
	BoomSave.save()


## 当前武器树的 6 槽技能 id 列表（树序）。
func tree_ids() -> Array[String]:
	return tree.duplicate()


## 技能是否属于当前武器树（跨树技能不可见/不可解锁）。
func in_current_tree(skill_id: String) -> bool:
	return tree.has(skill_id)


## M7R 全池 id 列表（调试/测试用；可见集合看 tree_ids()）。
func pool_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in pool:
		ids.append(id)
	return ids


func get_skill(skill_id: String) -> BoomSkill:
	return pool.get(skill_id) as BoomSkill


## 战斗触发槽投影：只保留构筑中的主动技能，顺序稳定。
## 这样被动仍消耗构筑容量并持续生效，但永远不会吞掉 tap / swipe 输入。
func active_equipped() -> Array[String]:
	var ids: Array[String] = []
	for skill_id in equipped:
		var skill := get_skill(skill_id)
		if skill != null and not skill.is_passive:
			ids.append(skill_id)
	return ids


## 当前构筑中的被动节点，供 UI/test hook 明确展示，不与主动触发槽混为一谈。
func passive_equipped() -> Array[String]:
	var ids: Array[String] = []
	for skill_id in equipped:
		var skill := get_skill(skill_id)
		if skill != null and skill.is_passive:
			ids.append(skill_id)
	return ids


static func icon_path(skill_id: String) -> String:
	return "res://assets/images/icons/skill_%s.png" % skill_id


static func description_for(skill_id: String) -> String:
	return str(SKILL_DESCRIPTIONS.get(skill_id, ""))


static func branch_title(branch_id: String) -> String:
	return "普攻" if branch_id == "basic" else "主动技能"


## 每帧驱动整个技能池的冷却，并在技能从 CD 中归零时广播 skill_ready。
func tick(delta: float) -> void:
	for skill: BoomSkill in pool.values():
		var prev: float = skill.cooldown_left
		skill.tick(delta)
		if prev > 0.0 and skill.cooldown_left <= 0.0:
			skill_ready.emit(skill.skill_id)


# ------------------------------------------------------------------ 解锁 / 装备


## 解锁状态：读跨局存档（本武器树内），fan 默认免费拥有。
func is_unlocked(skill_id: String) -> bool:
	if not in_current_tree(skill_id):
		return false
	return BoomSave.is_unlocked(weapon_id, skill_id)


## 树内顺序价（TREE_PRICES[树序]）；树首免费/非本树技能/未知 id 返回 -1（不可购买）。
func unlock_cost(skill_id: String) -> int:
	var node := tree_node(skill_id)
	if node.is_empty():
		return -1
	var tier: int = int(node["tier"])
	if tier > 0 and not is_unlocked(String(node["depends_on"])):
		return -1
	var cost := TREE_PRICES[tier]
	return cost if cost > 0 else -1


func tree_node(skill_id: String) -> Dictionary:
	var branches: Dictionary = BoomWeapons.get_def(weapon_id).tree.get("branches", {})
	for branch_variant in branches:
		var branch: String = branch_variant
		var ids: Array = branches[branch]
		var tier: int = ids.find(skill_id)
		if tier >= 0:
			return {
				"branch": branch,
				"tier": tier,
				"depends_on": "" if tier == 0 else String(ids[tier - 1])
			}
	return {}


## 花跨局金币解锁（写入存档并即时落盘）：
## 已解锁 / 非本树技能 / 余额不足 返回 false；成功广播 skill_unlocked。
func try_unlock(skill_id: String) -> bool:
	var cost := unlock_cost(skill_id)
	if is_unlocked(skill_id) or cost < 0:
		return false
	if not BoomSave.spend_coins(cost):
		return false
	BoomSave.unlock_skill(weapon_id, skill_id)
	skill_unlocked.emit(skill_id)
	return true


## 首领奖励免费解锁：仍严格检查武器树和前置，但不消费金币。
func _grant_free_unlock(skill_id: String) -> bool:
	if is_unlocked(skill_id) or unlock_cost(skill_id) < 0:
		return false
	BoomSave.unlock_skill(weapon_id, skill_id)
	skill_unlocked.emit(skill_id)
	return true


## 装备进槽：非本树 / 未解锁 / 重复 / 超过 MAX_EQUIPPED 拒绝。
func equip(skill_id: String) -> bool:
	if not in_current_tree(skill_id) or not is_unlocked(skill_id) or equipped.has(skill_id):
		return false
	if equipped.size() >= MAX_EQUIPPED:
		return false
	equipped.append(skill_id)
	_save_loadout()
	_refresh_passives()
	return true


func unequip(skill_id: String) -> bool:
	if not equipped.has(skill_id):
		return false
	equipped.erase(skill_id)
	_save_loadout()
	_refresh_passives()
	return true


func _first_evolvable_active() -> String:
	for skill_id in equipped:
		var skill := get_skill(skill_id)
		if skill != null and not skill.is_passive and not evolved_skills.has(skill_id):
			return skill_id
	for skill_id in tree:
		var skill := get_skill(skill_id)
		if (
			skill != null
			and not skill.is_passive
			and is_unlocked(skill_id)
			and not evolved_skills.has(skill_id)
		):
			return skill_id
	return ""


func _evolve_skill(skill_id: String) -> bool:
	var skill := get_skill(skill_id)
	if (
		skill == null
		or skill.is_passive
		or not in_current_tree(skill_id)
		or not is_unlocked(skill_id)
		or evolved_skills.has(skill_id)
	):
		return false
	evolved_skills.append(skill_id)
	skill_evolved.emit(skill_id)
	return true


func _is_evolved(skill_id: String) -> bool:
	return evolved_skills.has(skill_id)


## M7R 被动加成落到对局管线（equip/unequip/换树后刷新；game 未注入时跳过）。
func _refresh_passives() -> void:
	if game == null:
		return
	game.skill_fire_cd_mult = 1.0
	game.skill_swing_dmg_bonus = 0
	game.skill_base_attack_mult = (
		BASIC_ATTACK_MULT
		if equipped.has("lamp_bright_core") or equipped.has("brush_firm_grip")
		else 1.0
	)
	game.skill_basic_speed_mult = (
		BASIC_SPEED_MULT
		if equipped.has("lamp_quick_wick") or equipped.has("brush_flowing_script")
		else 1.0
	)
	game.skill_cooldown_mult = (
		SKILL_COOLDOWN_MULT if equipped.has("lamp_echo") or equipped.has("brush_focus") else 1.0
	)
	game.skill_threefold_seal = equipped.has("lamp_threefold_seal")
	game.skill_brush_verdict = equipped.has("brush_verdict")


# ------------------------------------------------------------------ 施放入口


## 右区单击 -> 主动触发槽 0。
func handle_tap() -> void:
	handle_slot(0)


## 左滑 -> 主动触发槽 1。
func handle_swipe_left() -> void:
	handle_slot(1)


## 右滑 -> 主动触发槽 2。
func handle_swipe_right() -> void:
	handle_slot(2)


## 统一触发入口：槽位越界静默忽略；槽位映射到 active_equipped()，不再被被动吞掉。
func handle_slot(slot: int) -> void:
	var active := active_equipped()
	if slot < 0 or slot >= active.size():
		return
	cast_skill(active[slot])


## 施放指定技能：未装备 / CD 未就绪 / game 未注入 / 未知 id / 被动技能静默忽略。
## M8 技能急速（design_m8_attributes.md §3.1）：实际冷却 = 基础 CD ÷ haste_mult()。
func cast_skill(skill_id: String) -> void:
	var skill := get_skill(skill_id)
	if (
		skill == null
		or skill.is_passive
		or not active_equipped().has(skill_id)
		or game == null
		or not skill.is_ready()
	):
		return
	skill.cooldown_left = (
		skill.cooldown * game.skill_cooldown_mult * (1.0 - game.stats.cooldown_reduction())
	)
	var result: Variant = _dispatch_cast(skill_id)
	skill_fired.emit(skill_id, result)


func _dispatch_cast(skill_id: String) -> Variant:
	var evolved := evolved_skills.has(skill_id)
	var effect := BoomSkillEffects.get_effect(skill_id, evolved)
	match skill_id:
		"lamp_firefly_volley":
			return game.cast_fan_shot(
				int(effect["projectiles"]), deg_to_rad(float(effect["arc_deg"]) * 0.5)
			)
		"lamp_soul_beacon":
			return game.cast_ring_shot(int(effect["projectiles"]))
		"brush_ink_wave":
			return game.cast_brush_ink_wave(evolved)
		"brush_seal_domain":
			return game.cast_brush_seal_domain(evolved)
	return null


## 供 test_hook / UI 读取的快照：全池冷却 + 装备槽 + 就绪列表。
## cooldown_left 保留两位小数，避免浮点抖动。
func get_state() -> Dictionary:
	var ready_ids: Array[String] = []
	for skill_id in equipped:
		var skill := get_skill(skill_id)
		if skill != null and skill.is_ready() and not skill.is_passive:
			ready_ids.append(skill_id)
	var state: Dictionary = {
		"equipped": equipped.duplicate(),
		"active": active_equipped(),
		"passive": passive_equipped(),
		"evolved": evolved_skills.duplicate(),
		"ready": ready_ids,
		"weapon": weapon_id,
	}
	for skill_id in pool:
		var skill := get_skill(skill_id)
		state[skill_id] = snappedf(skill.cooldown_left, 0.01)
	return state


## 重置所有冷却（不动解锁/装备状态——那是元进度）。
func reset() -> void:
	for skill: BoomSkill in pool.values():
		skill.cooldown_left = 0.0
	evolved_skills.clear()


## 测试辅助：直接写入解锁（绕过存档扣币，供无头测试构造前置状态）。
func debug_grant(skill_id: String) -> void:
	if in_current_tree(skill_id) and not is_unlocked(skill_id):
		BoomSave.unlock_skill(weapon_id, skill_id)


## §4.2 技能飘字映射（纯逻辑，可无头测试）：skill_id -> {text, color, scale}。
## 未登记的 skill_id 返回空字典（上层跳过生成）。
static func float_text_for(skill_id: String) -> Dictionary:
	match skill_id:
		"fan":
			return {"text": TEXT_FAN, "color": TEXT_COLOR_FAN, "scale": TEXT_SCALE_FAN}
		"chain":
			return {"text": TEXT_CHAIN, "color": TEXT_COLOR_CHAIN, "scale": TEXT_SCALE_CHAIN}
		"nuke":
			return {"text": TEXT_NUKE, "color": TEXT_COLOR_NUKE, "scale": TEXT_SCALE_NUKE}
		"lamp_firefly_volley":
			return {"text": "萤!", "color": FAN_COLOR, "scale": TEXT_SCALE_FAN}
		"lamp_soul_beacon":
			return {"text": "引!", "color": RING_COLOR, "scale": TEXT_SCALE_CHAIN}
		"brush_ink_wave":
			return {"text": "墨!", "color": CHAIN_COLOR, "scale": TEXT_SCALE_CHAIN}
		"brush_seal_domain":
			return {"text": "封!", "color": NUKE_COLOR, "scale": TEXT_SCALE_NUKE}
	return {}
