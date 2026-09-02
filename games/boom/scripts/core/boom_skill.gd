class_name BoomSkill
extends Node
## 单一技能实例：技能元数据 + 冷却计时。纯数据/计时，不持有任何 game / 视觉引用。

# 技能元数据
var skill_id: String = ""
var display_name: String = ""
var cooldown: float = 0.0
var icon_color: Color = Color.WHITE

# 运行时状态
var cooldown_left: float = 0.0


func _init(
	p_skill_id: String = "",
	p_display_name: String = "",
	p_cooldown: float = 0.0,
	p_icon_color: Color = Color.WHITE
) -> void:
	skill_id = p_skill_id
	display_name = p_display_name
	cooldown = p_cooldown
	icon_color = p_icon_color


## 冷却是否已结束。
func is_ready() -> bool:
	return cooldown_left <= 0.0


## 就绪则消耗冷却返回 true；否则返回 false。
func try_start() -> bool:
	if not is_ready():
		return false
	cooldown_left = cooldown
	return true


## 每帧递减冷却，到 0 即停。
func tick(delta: float) -> void:
	if cooldown_left <= 0.0:
		return
	cooldown_left = maxf(cooldown_left - delta, 0.0)
