class_name GhostFactory
extends RefCounted

## 幽灵对手：本地预生成，含昵称、难度、8 回合战力曲线。
## 异步对战的"对手"就是一张快照，不需要任何后端。

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
	# 曲线参数：玩家满激活约 3 工位 + 手牌，峰值 ~30-40。
	# D1~D5 峰值约 19 / 32 / 47 / 66 / 88，随难度递进。
	var base := 5.0 + float(difficulty - 1) * 1.5
	var growth := 0.4 + float(difficulty - 1) * 0.15
	var curve: Array[int] = []
	for r in range(1, 9):
		var v := base * (1.0 + growth * float(r - 1))
		curve.append(int(round(v)))
	return {
		"name": NAMES[rng.randi_range(0, NAMES.size() - 1)],
		"difficulty": difficulty,
		"build_type": BUILD_TYPES[rng.randi_range(0, BUILD_TYPES.size() - 1)],
		"curve": curve,
	}


## 根据玩家上一局表现选难度：赢得多就升级，输得多就降级。
static func pick_difficulty(_rng: RandomNumberGenerator, last_win: bool, last_diff: int) -> int:
	var d := last_diff
	if last_win:
		d += 1
	else:
		d -= 1
	return clampi(d, 1, 5)
