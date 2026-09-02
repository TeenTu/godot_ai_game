class_name BoomSkillSystem
extends Node
## 技能系统逻辑层：管理 Fan/Chain/Nuke 三个技能槽与冷却，对外提供手势 API。
## 纯逻辑，不含视觉/粒子/音频；只发信号，效果由 main.gd 订阅后触发。

# 冷却结束（就绪）
signal skill_ready(skill_id: String)
# 技能已施放：result 为 cast_* 返回值（fan 为 int 发射数；chain/nuke 为命中数组）
signal skill_fired(skill_id: String, result: Variant)

# 冷却阶梯（秒）：Fan=3 / Chain=8 / Nuke=20
const FAN_COOLDOWN: float = 3.0
const CHAIN_COOLDOWN: float = 8.0
const NUKE_COOLDOWN: float = 20.0

# 技能图标主题色
const FAN_COLOR: Color = Color(1.0, 0.75, 0.25)
const CHAIN_COLOR: Color = Color(0.3, 0.85, 1.0)
const NUKE_COLOR: Color = Color(1.0, 0.3, 0.3)

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

# 注入的对局引用，由 main.gd 赋值
var game: BoomGame

# 技能槽 -> 手势：Fan=tap / Chain=←swipe / Nuke=→swipe
var fan_skill: BoomSkill
var chain_skill: BoomSkill
var nuke_skill: BoomSkill


func _init() -> void:
	fan_skill = BoomSkill.new("fan", "爆裂弹幕", FAN_COOLDOWN, FAN_COLOR)
	chain_skill = BoomSkill.new("chain", "闪电链", CHAIN_COOLDOWN, CHAIN_COLOR)
	nuke_skill = BoomSkill.new("nuke", "核能爆轰", NUKE_COOLDOWN, NUKE_COLOR)


## 每帧驱动三个技能的冷却，并在技能从 CD 中归零时广播 skill_ready。
func tick(delta: float) -> void:
	for skill: BoomSkill in [fan_skill, chain_skill, nuke_skill]:
		var prev: float = skill.cooldown_left
		skill.tick(delta)
		if prev > 0.0 and skill.cooldown_left <= 0.0:
			skill_ready.emit(skill.skill_id)


## 右区单击 -> Fan 扇形散弹。
func handle_tap() -> void:
	if not fan_skill.try_start():
		return
	var fired_count: int = game.cast_fan_shot()
	skill_fired.emit(fan_skill.skill_id, fired_count)


## 左滑 -> Chain 闪电链。
func handle_swipe_left() -> void:
	if not chain_skill.try_start():
		return
	var hit_enemies: Array = game.cast_chain_arc()
	skill_fired.emit(chain_skill.skill_id, hit_enemies)


## 右滑 -> Nuke 核爆 AOE。
func handle_swipe_right() -> void:
	if not nuke_skill.try_start():
		return
	var hit_enemies: Array = game.cast_aoe_nuke()
	skill_fired.emit(nuke_skill.skill_id, hit_enemies)


## 供 test_hook / UI 读取的冷却快照。cooldown_left 保留两位小数，避免浮点抖动。
func get_state() -> Dictionary:
	var ready_ids: Array[String] = []
	if fan_skill.is_ready():
		ready_ids.append(fan_skill.skill_id)
	if chain_skill.is_ready():
		ready_ids.append(chain_skill.skill_id)
	if nuke_skill.is_ready():
		ready_ids.append(nuke_skill.skill_id)
	return {
		"fan": snappedf(fan_skill.cooldown_left, 0.01),
		"chain": snappedf(chain_skill.cooldown_left, 0.01),
		"nuke": snappedf(nuke_skill.cooldown_left, 0.01),
		"ready": ready_ids,
	}


## 重置所有冷却。
func reset() -> void:
	fan_skill.cooldown_left = 0.0
	chain_skill.cooldown_left = 0.0
	nuke_skill.cooldown_left = 0.0


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
