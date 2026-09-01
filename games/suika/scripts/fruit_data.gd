class_name FruitData
extends RefCounted

## 水果等级表。索引即等级：0 最小（葡萄），10 最大（大西瓜）。
const LEVELS: Array = [
	{"name": "葡萄", "radius": 22.0, "color": Color(0.56, 0.36, 0.86)},
	{"name": "樱桃", "radius": 31.0, "color": Color(0.91, 0.30, 0.28)},
	{"name": "橘子", "radius": 42.0, "color": Color(0.95, 0.61, 0.12)},
	{"name": "柠檬", "radius": 53.0, "color": Color(0.93, 0.80, 0.15)},
	{"name": "猕猴桃", "radius": 65.0, "color": Color(0.49, 0.70, 0.26)},
	{"name": "西红柿", "radius": 78.0, "color": Color(0.90, 0.29, 0.14)},
	{"name": "桃子", "radius": 92.0, "color": Color(0.96, 0.60, 0.68)},
	{"name": "菠萝", "radius": 106.0, "color": Color(0.98, 0.75, 0.18)},
	{"name": "椰子", "radius": 121.0, "color": Color(0.63, 0.50, 0.40)},
	{"name": "半个瓜", "radius": 137.0, "color": Color(0.94, 0.35, 0.32)},
	{"name": "大西瓜", "radius": 154.0, "color": Color(0.18, 0.55, 0.24)},
]

## 合成出「该等级」时获得的分数，索引与 LEVELS 对齐。
const SCORE: Array = [0, 1, 3, 6, 10, 15, 21, 28, 36, 45, 55]

## 两颗大西瓜相撞时一起消失，给这个奖励分。
const TOP_MERGE_BONUS: int = 100

## 只会随机掉落 0..MAX_SPAWN_LEVEL 这些小水果。
const MAX_SPAWN_LEVEL: int = 4

const COUNT: int = 11


static func radius_of(level: int) -> float:
	return float(LEVELS[clampi(level, 0, COUNT - 1)]["radius"])


static func color_of(level: int) -> Color:
	return LEVELS[clampi(level, 0, COUNT - 1)]["color"]


static func name_of(level: int) -> String:
	return String(LEVELS[clampi(level, 0, COUNT - 1)]["name"])
