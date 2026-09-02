extends SceneTree

## 无头自检（CI 门禁用）。
##
## 逻辑层测试（不加载场景，直接测 FoundryGame / FoundryBoard）：
##  1. 版图放置：成功 / 重叠失败 / 越界失败 / 移除
##  2. 相邻加成：同色相邻产出计算
##  3. 战力公式：工位产出 × 倍率 + 手牌加成
##  4. 完整对局：AI 自动打满 8 回合，比分完整、状态不崩
##
## 用法：godot --headless --path games/foundry --script res://tools/play_test.gd

# AI 买卡偏好（核心战力优先，lab 需要基础建筑才有用）
const _AI_BUY_ORDER: Array[String] = [
	"forge",
	"barracks",
	"market",
	"mine",
	"workshop",
	"warehouse",
	"gearbox",
	"lab",
]

var _failures := 0
var _step := 0
var _scene_ok := false
var _tests_done := false
var _main: Node


func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn") as PackedScene
	if ps == null:
		_failures += 1
		print("  FAIL: 加载 scenes/main.tscn")
		print("PLAY_TEST result=FAIL failures=", _failures)
		quit(1)
		return
	_main = ps.instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_step += 1
	if not _scene_ok and _step >= 3:
		_scene_ok = true
		_check(_main != null, "主场景实例化成功")
		_check(is_instance_valid(_main) and _main.get_child_count() > 0, "主场景 _ready 后含子节点")
	if _scene_ok and not _tests_done:
		_tests_done = true
		_test_board()
		_test_power_formula()
		_test_full_game(20260902, 4)
		if _failures == 0:
			print("PLAY_TEST result=PASS")
			quit(0)
		else:
			print("PLAY_TEST result=FAIL failures=", _failures)
			quit(1)
	return false


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: ", msg)
	else:
		_failures += 1
		print("  FAIL: ", msg)


# ---------- 1. 版图 ----------


func _test_board() -> void:
	print("[board]")
	var board := FoundryBoard.new()
	var mine: Dictionary = CardDB.get_building("mine")
	var gearbox: Dictionary = CardDB.get_building("gearbox")
	var warehouse: Dictionary = CardDB.get_building("warehouse")

	_check(board.place(mine, Vector2i(0, 0)), "放置矿场(0,0)")
	_check(board.place(mine, Vector2i(0, 1)), "放置矿场(0,1) 相邻")
	_check(not board.place(mine, Vector2i(0, 0)), "重叠放置被拒绝")
	_check(not board.place(warehouse, Vector2i(3, 4)), "越界放置被拒绝")
	_check(board.place(gearbox, Vector2i(2, 2)), "放置齿轮箱(2,2)")
	_check(board.get_all_buildings().size() == 3, "共 3 栋建筑")

	var b0: Dictionary = board.get_building_at(Vector2i(0, 0))
	_check(board.count_adjacent(b0) == 1, "矿场(0,0) 相邻同色数 = 1")

	var out := board.compute_output([Vector2i(0, 0), Vector2i(0, 1)])
	_check(out["gold"] == 8, "双矿场相邻激活产出 = 8 金 (3+1 + 3+1)")

	board.remove_at(Vector2i(0, 1))
	_check(board.get_all_buildings().size() == 2, "移除(0,1)后剩 2 栋")


# ---------- 2. 战力公式 ----------


func _test_power_formula() -> void:
	print("[power]")
	var board := FoundryBoard.new()
	var forge: Dictionary = CardDB.get_building("forge")
	var lab: Dictionary = CardDB.get_building("lab")
	board.place(forge, Vector2i(0, 0))
	board.place(forge, Vector2i(0, 1))
	board.place(lab, Vector2i(2, 0))

	var out := board.compute_output([Vector2i(0, 0), Vector2i(0, 1), Vector2i(2, 0)])
	var mult_total: float = 1.0 + float(out["mult"])
	var power := int(round(float(out["power"]) * mult_total))
	# 双熔炉相邻: 4+1 + 4+1 = 10；lab mult 0.5 → 10 × 1.5 = 15
	_check(out["power"] == 10, "双熔炉相邻 power = 10")
	_check(mult_total == 1.5, "lab 倍率 = 1.5")
	_check(power == 15, "基础战力 10 × 1.5 = 15")


# ---------- 3. 完整对局 ----------


func _test_full_game(seed_val: int, games: int) -> void:
	print("[full-game]")
	var wins := 0
	var total_power_sum := 0
	for g in games:
		var s := seed_val + g * 1000
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		var ghost: Dictionary = GhostFactory.make_ghost(rng, 2)
		var game := FoundryGame.new(s, ghost)
		var guard := 0
		while not game.is_over and guard < 300:
			guard += 1
			match game.phase:
				FoundryGame.Phase.BUILD:
					var bought := false
					for pref in _AI_BUY_ORDER:
						for i in game.pending.size():
							if game.pending[i]["id"] == pref and game.buy_card(i):
								bought = true
								break
						if bought:
							break
					if bought and not game.taken_card.is_empty():
						# 选能让同色相邻最多的位置（试探式搜索）
						var best_pos := Vector2i(-1, -1)
						var best_adj := -1
						for y in FoundryBoard.H:
							for x in FoundryBoard.W:
								if not game.board.can_place(game.taken_card, Vector2i(x, y)):
									continue
								if game.board.place(game.taken_card, Vector2i(x, y)):
									var nb: Dictionary = game.board.get_building_at(Vector2i(x, y))
									var adj := game.board.count_adjacent(nb)
									game.board.remove_at(Vector2i(x, y))
									if adj > best_adj:
										best_adj = adj
										best_pos = Vector2i(x, y)
						if best_pos.x >= 0:
							game.place_card(best_pos)
						else:
							game.abandon_card()
					game.finish_build()
				FoundryGame.Phase.ASSIGN:
					for b in game.board.get_all_buildings():
						if game.active_positions.size() >= FoundryGame.WORKERS:
							break
						game.assign_worker(b["pos"])
					game.finish_assign()
				FoundryGame.Phase.PLAY:
					var played_any := true
					while played_any:
						played_any = false
						for i in game.hand.size():
							if game.play_card(i):
								played_any = true
								break
					game.finish_play()
				FoundryGame.Phase.VS:
					game.next_round()
		_check(
			game.is_over and game.round == FoundryGame.TOTAL_ROUNDS,
			"对局 %d 完成 (比分 %d:%d)" % [g + 1, game.my_score, game.ghost_score]
		)
		total_power_sum += game.my_score
		if game.my_score > game.ghost_score:
			wins += 1
	print("  战绩: ", wins, "/", games, " 胜 (难度2幽灵, AI 自动打)")
