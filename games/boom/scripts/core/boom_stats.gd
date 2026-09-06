class_name BoomStats
extends RefCounted
## M7 属性系统（design_m7_progression.md §3）：局内成长数值容器。
## 纯数据 + 纯函数，零 UI / 零节点依赖，可无头断言。
## 升级点由 BoomExperience.level_up 产生（pending_upgrades），由 BoomGame.apply_level_upgrade
## 消费并转发到本类；玩家机体数值由 BoomGame._apply_stats_to_player 落地。
## 默认全零加成 → 现有 M5 机体断言（max_hp=5 / move_speed=5.4）零改动。

const KIND_HP: String = "hp"
const KIND_SPEED: String = "speed"
const KIND_DMG: String = "dmg"
const KINDS: Array[String] = [KIND_HP, KIND_SPEED, KIND_DMG]

# 每档加成数值（design_m7_progression.md §3.2 数值表）。
const HP_UP_PER_STACK: int = 1  # max_hp +1，并回复等量 HP
const MOVE_MULT_PER_STACK: float = 1.08  # 移速 ×1.08（叠加乘算）
const DMG_UP_PER_STACK: int = 1  # 子弹/技能伤害 +1

var hp_stacks: int = 0
var speed_stacks: int = 0
var dmg_stacks: int = 0


func reset() -> void:
	hp_stacks = 0
	speed_stacks = 0
	dmg_stacks = 0


## 应用一档升级；未知 kind 返回 false（防御）。
func apply(kind: String) -> bool:
	match kind:
		KIND_HP:
			hp_stacks += 1
		KIND_SPEED:
			speed_stacks += 1
		KIND_DMG:
			dmg_stacks += 1
		_:
			return false
	return true


func stacks(kind: String) -> int:
	match kind:
		KIND_HP:
			return hp_stacks
		KIND_SPEED:
			return speed_stacks
		KIND_DMG:
			return dmg_stacks
	return 0


## HP 上限增量（BoomPlayer.BASE_MAX_HP + weapon.max_hp_bonus 之上）。
func max_hp_bonus() -> int:
	return hp_stacks * HP_UP_PER_STACK


## 移速倍率（BoomPlayer.MOVE_SPEED * weapon.move_mult 之上，乘算）。
func move_mult() -> float:
	return pow(MOVE_MULT_PER_STACK, float(speed_stacks))


## 伤害增量（BULLET_DMG 之上）。
func dmg_bonus() -> int:
	return dmg_stacks * DMG_UP_PER_STACK


## 本局已消耗的升级总档数（HUD/结算展示用）。
func total_stacks() -> int:
	return hp_stacks + speed_stacks + dmg_stacks
