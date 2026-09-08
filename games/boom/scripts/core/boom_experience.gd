class_name BoomExperience
extends RefCounted
## M7 经验升级（design_m7_progression.md §4）：击杀入账经验，升级发信号。
## 纯数据 + 纯函数，零 UI / 零节点依赖，可无头断言。
## 升级点消费走 BoomGame.apply_level_upgrade（→ BoomStats），本类只管经验曲线。

# 升级信号：new_level 为升级后的新等级。
signal leveled_up(new_level: int)

const KILL_XP: int = 1  # 普通击杀经验
const ELITE_XP: int = 6  # 精英击杀经验（M8 review 后由 8 下调，design_m8_attributes.md §11.2）
const LEVEL_BASE: int = 5  # 升到 2 级所需经验
const LEVEL_STEP: int = 4  # 每级递增（线性曲线）
const LEVEL_CAP: int = 20  # 等级封顶（单局 30 配额波内自然到不了，防刷红线）

var level: int = 1
var xp: int = 0


func reset() -> void:
	level = 1
	xp = 0


## 升到 l+1 级所需经验（静态曲线，可无头断言边界值）。
static func xp_to_next(l: int) -> int:
	return LEVEL_BASE + (l - 1) * LEVEL_STEP


## 入账经验，返回本次升级次数（可能 0 次或跨级多次）；每升 1 级发一次 leveled_up。
func add_xp(amount: int) -> int:
	if amount <= 0:
		return 0
	var gained := 0
	xp += amount
	while level < LEVEL_CAP and xp >= xp_to_next(level):
		xp -= xp_to_next(level)
		level += 1
		gained += 1
		leveled_up.emit(level)
	if level >= LEVEL_CAP:
		xp = 0  # 满级溢出经验丢弃（防无意义累积）
	return gained
