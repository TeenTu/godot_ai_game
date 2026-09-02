class_name GhostFactory
extends RefCounted

## 幽灵对手：本地生成，含昵称、难度、build 流派。
## 战力不再是预生成曲线——由 FoundryGame 动态难度接管
## （幽灵战力 = 玩家历史平均 × 难度系数，见 game_state.gd）。

const NAMES: Array[String] = [
	"Iron Mike",
	"Furnace Karl",
	"Gear Grinder",
	"Warehouse Tom",
	"Bluecollar Lee",
	"Night Shift",
	"Assembly Queen",
	"Scrap Tycoon",
]

const BUILD_TYPES: Array[String] = ["Fire", "Industry", "Commerce", "Tech"]

## 幽灵人格台词：按流派分组，VS 结算时显示，让对手"像个人"。
const QUOTES: Dictionary = {
	"Fire":
	[
		"My forge never sleeps!",
		"Burn brighter or burn out!",
		"Feel the heat of real craft!",
	],
	"Industry":
	[
		"Discipline beats talent.",
		"My conveyor has no brakes!",
		"Built to last, built to win.",
	],
	"Commerce":
	[
		"Everything has a price, friend.",
		"I already bought your victory.",
		"Money talks, factories walk.",
	],
	"Tech":
	[
		"Calculated. Executed. Won.",
		"Efficiency is my middle name.",
		"Your moves are 3 steps behind.",
	],
}


static func make_ghost(rng: RandomNumberGenerator, difficulty: int) -> Dictionary:
	difficulty = clampi(difficulty, 1, 5)
	var build: String = BUILD_TYPES[rng.randi_range(0, BUILD_TYPES.size() - 1)]
	var pool: Array = QUOTES.get(build, ["Let's build!"])
	return {
		"name": NAMES[rng.randi_range(0, NAMES.size() - 1)],
		"difficulty": difficulty,
		"build_type": build,
		"quote": pool[rng.randi_range(0, pool.size() - 1)],
	}


## 根据玩家上一局表现选难度：赢得多就升级，输得多就降级。
static func pick_difficulty(_rng: RandomNumberGenerator, last_win: bool, last_diff: int) -> int:
	var d := last_diff
	if last_win:
		d += 1
	else:
		d -= 1
	return clampi(d, 1, 5)
