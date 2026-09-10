class_name BoomExperience
extends RefCounted
## M7 经验升级（design_m7_progression.md §4）：击杀入账经验，升级发信号。
## 纯数据 + 纯函数，零 UI / 零节点依赖，可无头断言。
## 升级点消费走 BoomGame.apply_level_upgrade（→ BoomStats），本类只管经验曲线。

# 升级信号：new_level 为升级后的新等级。
signal leveled_up(new_level: int)

const PAPER_DOLL_XP: int = 5
const MIST_SPIRIT_XP: int = 8
const ELITE_XP: int = 30
const KILL_XP: int = PAPER_DOLL_XP  # 兼容旧测试/调用；新结算读取 BoomJelly.xp_reward()
# 人物曲线只由等级决定，绝不读取波次、配额或怪物数量；经验单位扩大 10 倍方便怪种定价。
const LEVEL_BASE: int = 50  # 升到 2 级所需经验
const LEVEL_STEP: int = 40  # 每级递增（固定线性曲线）
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
