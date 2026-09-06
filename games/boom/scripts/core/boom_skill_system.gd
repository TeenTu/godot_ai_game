class_name BoomSkillSystem
extends Node
## 技能系统逻辑层（M7R 重构）：技能池存全部技能定义，每武器一棵 6 槽技能树
## （BoomWeaponDef.tree["skills"] 决定该武器可见/可解锁集合——加新武器 = 定义一棵树）。
## 解锁消耗跨局货币（BoomSave.coins，user:// 持久化）；装备为局内 ≤3 槽手势映射。
## 纯逻辑，不含视觉/粒子/音频；只发信号，效果由 main.gd 订阅后触发。

# 冷却结束（就绪）
signal skill_ready(skill_id: String)
# 技能已施放：result 为 cast_* 返回值（fan/ring/twin 为 int 发射数；chain/nuke/whirl 为命中数组；heal 为回复量）
signal skill_fired(skill_id: String, result: Variant)
# 金币解锁成功
signal skill_unlocked(skill_id: String)

# 冷却阶梯（秒）：Fan=3 / Chain=8 / Nuke=20 / Ring=10 / Twin=6 / Whirl=12 / Heal=30
const FAN_COOLDOWN: float = 3.0
const CHAIN_COOLDOWN: float = 8.0
const NUKE_COOLDOWN: float = 20.0
const RING_COOLDOWN: float = 10.0
const TWIN_COOLDOWN: float = 6.0
const WHIRL_COOLDOWN: float = 12.0
const HEAL_COOLDOWN: float = 30.0

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
const TREE_PRICES: Array[int] = [0, 60, 120, 200, 300, 420]

# M7R skill_id -> BoomGame 施放方法名（扩容登记一处；查表规避 lint max-returns）。
const CAST_METHODS: Dictionary = {
	"fan": "cast_fan_shot",
	"chain": "cast_chain_arc",
	"nuke": "cast_aoe_nuke",
	"ring": "cast_ring_shot",
	"twin": "cast_twin_shot",
	"whirl": "cast_whirl",
	"heal": "cast_repair",
}

# §4.2 技能飘字规格：fan=黄"嘭!"小字 / chain=紫"链!"大字 / nuke=金"轰!"巨型。
const TEXT_FAN: String = "POP!"
const TEXT_CHAIN: String = "ZAP!"
const TEXT_NUKE: String = "BOOM!"
const TEXT_COLOR_FAN: Color = Color(1.0, 0.9, 0.3)
const TEXT_COLOR_CHAIN: Color = Color(0.7, 0.4, 1.0)
const TEXT_COLOR_NUKE: Color = Color(1.0, 0.78, 0.25)
const TEXT_SCALE_FAN: float = 0.85
const TEXT_SCALE_CHAIN: float = 1.3
const TEXT_SCALE_NUKE: float = 1.7

# M7 被动加成数值（bubble 专属 rapid / sword 专属 titan）。
const RAPID_FIRE_MULT: float = 0.8  # 装备 rapid：普攻 CD ×0.8（射速 +25%）
const TITAN_DMG_BONUS: int = 1  # 装备 titan：弧斩/旋风斩伤害 +1

# M7 每局装备上限（§5.4 硬红线：3 槽手势，超编拒绝）。
const MAX_EQUIPPED: int = 3

# 注入的对局引用，由 main.gd 赋值
var game: BoomGame

# M7R 技能池：skill_id -> BoomSkill（全部技能定义都在池里，武器树决定可见子集）。
var pool: Dictionary = {}
# M7R 当前武器树（BoomWeapons.get_def(weapon_id).tree["skills"] 的 6 槽序列）。
var weapon_id: String = "bubble"
var tree: Array[String] = []
# M7 本局装备槽（顺序 = 手势槽：0=tap / 1=←swipe / 2=→swipe）。
var equipped: Array[String] = []


func _init() -> void:
	pool["fan"] = BoomSkill.new("fan", "BULLET STORM", FAN_COOLDOWN, FAN_COLOR)
	pool["chain"] = BoomSkill.new("chain", "CHAIN LIGHTNING", CHAIN_COOLDOWN, CHAIN_COLOR)
	pool["nuke"] = BoomSkill.new("nuke", "MEGA NUKE", NUKE_COOLDOWN, NUKE_COLOR)
	pool["ring"] = BoomSkill.new("ring", "RING BURST", RING_COOLDOWN, RING_COLOR)
	pool["twin"] = BoomSkill.new("twin", "TWIN CANNON", TWIN_COOLDOWN, TWIN_COLOR)
	pool["rapid"] = BoomSkill.new("rapid", "OVERDRIVE", 0.0, FAN_COLOR)
	(pool["rapid"] as BoomSkill).is_passive = true
	pool["heal"] = BoomSkill.new("heal", "REPAIR", HEAL_COOLDOWN, HEAL_COLOR)
	pool["whirl"] = BoomSkill.new("whirl", "WHIRLWIND", WHIRL_COOLDOWN, WHIRL_COLOR)
	pool["titan"] = BoomSkill.new("titan", "TITAN EDGE", 0.0, WHIRL_COLOR)
	(pool["titan"] as BoomSkill).is_passive = true
	# 默认泡泡树；解锁进度从跨局存档加载（无存档 = 各树第 1 技能默认解锁）。
	set_weapon_tree("bubble")


# ------------------------------------------------------------------ M7R 武器树


## 切换武器树：按 BoomWeaponDef.tree 过滤可见/可解锁集合。
## 同武器重复调用保留玩家已勾选装备；换武器则重置为该树已解锁的前 3 个。
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
	# 装备重置为该树已解锁技能中树序靠前的 ≤3 个（装备配置不持久化）。
	equipped = []
	var unlocked := BoomSave.unlocked_for(weapon_id)
	for sid in tree:
		if equipped.size() >= MAX_EQUIPPED:
			break
		if unlocked.has(sid):
			equipped.append(sid)
	_refresh_passives()


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
	var idx := tree.find(skill_id)
	if idx < 0:
		return -1
	var cost := TREE_PRICES[idx] if idx < TREE_PRICES.size() else TREE_PRICES[-1]
	return cost if cost > 0 else -1


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


## 装备进槽：非本树 / 未解锁 / 重复 / 超过 MAX_EQUIPPED 拒绝。
func equip(skill_id: String) -> bool:
	if not in_current_tree(skill_id) or not is_unlocked(skill_id) or equipped.has(skill_id):
		return false
	if equipped.size() >= MAX_EQUIPPED:
		return false
	equipped.append(skill_id)
	_refresh_passives()
	return true


func unequip(skill_id: String) -> bool:
	if not equipped.has(skill_id):
		return false
	equipped.erase(skill_id)
	_refresh_passives()
	return true


## M7R 被动加成落到对局管线（equip/unequip/换树后刷新；game 未注入时跳过）。
func _refresh_passives() -> void:
	if game == null:
		return
	game.skill_fire_cd_mult = RAPID_FIRE_MULT if equipped.has("rapid") else 1.0
	game.skill_swing_dmg_bonus = TITAN_DMG_BONUS if equipped.has("titan") else 0


# ------------------------------------------------------------------ 施放入口


## 右区单击 -> 装备槽 0（默认 fan）。
func handle_tap() -> void:
	handle_slot(0)


## 左滑 -> 装备槽 1（默认 chain）。
func handle_swipe_left() -> void:
	handle_slot(1)


## 右滑 -> 装备槽 2（默认 nuke）。
func handle_swipe_right() -> void:
	handle_slot(2)


## M7 统一槽位入口：槽位越界静默忽略（3 槽手势映射到装备顺序）。
func handle_slot(slot: int) -> void:
	if slot < 0 or slot >= equipped.size():
		return
	cast_skill(equipped[slot])


## 施放指定技能：CD 未就绪 / game 未注入 / 未知 id / 被动技能 静默忽略。
func cast_skill(skill_id: String) -> void:
	var skill := get_skill(skill_id)
	if skill == null or skill.is_passive or game == null or not skill.try_start():
		return
	var result: Variant = _dispatch_cast(skill_id)
	skill_fired.emit(skill_id, result)


func _dispatch_cast(skill_id: String) -> Variant:
	var method := CAST_METHODS.get(skill_id, "") as String
	if method == "":
		return null
	return game.call(method)


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
	return {}
