class_name GhostFactory
extends RefCounted

## 幽灵对手：本地生成，含昵称、难度、build 流派。
## 战力不再是预生成曲线——由 FoundryGame 动态难度接管
## （幽灵战力 = 玩家历史平均 × 难度系数，见 game_state.gd）。

const NAMES: Array[String] = [
	"老铁匠",
	"火炉阿强",
	"齿轮狂人",
	"仓库管理员",
	"蓝领小李",
	"夜班保安",
	"流水线女王",
	"废料大亨",
]

const BUILD_TYPES: Array[String] = ["火焰", "工业", "商业", "科技"]


static func make_ghost(rng: RandomNumberGenerator, difficulty: int) -> Dictionary:
	difficulty = clampi(difficulty, 1, 5)
	return {
		"name": NAMES[rng.randi_range(0, NAMES.size() - 1)],
		"difficulty": difficulty,
		"build_type": BUILD_TYPES[rng.randi_range(0, BUILD_TYPES.size() - 1)],
	}


## 根据玩家上一局表现选难度：赢得多就升级，输得多就降级。
static func pick_difficulty(_rng: RandomNumberGenerator, last_win: bool, last_diff: int) -> int:
	var d := last_diff
	if last_win:
		d += 1
	else:
		d -= 1
	return clampi(d, 1, 5)
