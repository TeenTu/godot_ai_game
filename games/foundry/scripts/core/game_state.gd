class_name FoundryGame
extends RefCounted

## 核心状态机。纯逻辑、零 UI 依赖，可无头直接测试。
##
## 回合循环：PREPARE(买卡+放置+手动选工位，点「开工」自动补齐)
##          -> PLAY(抽 5 打 5 手牌) -> VS(与幽灵比战力, 赢 +1 分)
## 8 回合后比分高者胜。
##
## 动态难度：幽灵本回合战力 = 玩家历史平均战力 × 难度系数(>1) × 回合趋势，
## 第一回合用基准值。玩家越强幽灵越强，每局都有拉扯感，消灭碾压局。

enum Phase { PREPARE, PLAY, VS, GAME_OVER }

const TOTAL_ROUNDS := 8
const WORKERS := 3
const HAND_SIZE := 5
const ENERGY_PER_ROUND := 3

## 动态难度系数：幽灵战力 = 玩家**上一回合**战力 × 系数 + 随机抖动。
## 系数 1.0 = 势均力敌；< 1 偏松；> 1 偏紧。抖动 ±3 模拟不可预测。
const GHOST_FACTORS: Dictionary = {1: 0.92, 2: 1.00, 3: 1.10, 4: 1.20, 5: 1.30}
## 第一回合无历史战绩时幽灵的基准战力（含少量随机）
const GHOST_FIRST_POWER: Dictionary = {1: 6, 2: 8, 3: 10, 4: 12, 5: 14}

var board := FoundryBoard.new()
var rng := RandomNumberGenerator.new()
var gold := 4
var round := 1
var phase: Phase = Phase.PREPARE
var my_score := 0
var ghost_score := 0
var ghost: Dictionary = {}
var ghost_round_power := 0

var pending: Array[Dictionary] = []  # 商店三选一
var taken_card: Dictionary = {}  # 已购买的待放置建筑
var active_positions: Array = []  # 已激活工位 origin 列表
var player_power_history: Array[int] = []  # 每回合最终战力（动态难度用）
var hand: Array[String] = []  # 手牌 id
var energy := ENERGY_PER_ROUND
var played_power := 0  # 手牌累计 flat 战力
var played_mult := 1.0  # 手牌累计倍率
var round_power := 0  # 本回合最终战力
var last_result := ""  # win / lose / tie
var is_over := false


func _init(seed_val: int = 0, ghost_data: Dictionary = {}) -> void:
	if seed_val != 0:
		rng.seed = seed_val
	board = FoundryBoard.new()
	ghost = ghost_data
	if ghost.is_empty():
		ghost = GhostFactory.make_ghost(rng, 2)
	_begin_round()


# ---------- 回合流程 ----------


func _begin_round() -> void:
	phase = Phase.PREPARE
	energy = ENERGY_PER_ROUND
	hand = []
	active_positions = []
	taken_card = {}
	round_power = 0
	played_power = 0
	played_mult = 1.0
	ghost_round_power = 0
	last_result = ""
	_roll_shop()


func _roll_shop() -> void:
	pending = []
	var pool := _shuffled(CardDB.BUILDINGS)
	for i in 3:
		pending.append(pool[i % pool.size()].duplicate(true))


func _shuffled(arr: Array) -> Array:
	var a := arr.duplicate(true)
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
	return a


# ---------- PREPARE（买卡 + 放置 + 选工位） ----------


## 购买商店第 idx 张卡（同回合最多买 1 张）
func buy_card(idx: int) -> bool:
	if phase != Phase.PREPARE or idx < 0 or idx >= pending.size():
		return false
	if not taken_card.is_empty():
		return false
	var card: Dictionary = pending[idx]
	if gold < card["cost"]:
		return false
	gold -= card["cost"]
	taken_card = card.duplicate(true)
	return true


func place_card(pos: Vector2i) -> bool:
	if phase != Phase.PREPARE or taken_card.is_empty():
		return false
	if not board.place(taken_card, pos):
		return false
	taken_card = {}
	# 放置即自动激活（名额未满时），减少一步操作
	if active_positions.size() < WORKERS:
		active_positions.append(pos)
	return true


func abandon_card() -> void:
	taken_card = {}


## 点击建筑切换激活/休眠（准备阶段可反复调整）
func toggle_active(pos: Vector2i) -> bool:
	if phase != Phase.PREPARE:
		return false
	if board.get_building_at(pos).is_empty():
		return false
	if active_positions.has(pos):
		active_positions.erase(pos)
		return true
	if active_positions.size() < WORKERS:
		active_positions.append(pos)
		return true
	return false


## 自动补齐工人：按单建筑产出潜力排序，把空缺名额填满。
func _auto_fill_workers() -> void:
	if active_positions.size() >= WORKERS:
		return
	var inactive: Array[Dictionary] = []
	for b in board.get_all_buildings():
		if not active_positions.has(b["pos"]):
			inactive.append(b)
	inactive.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return _building_value(a) > _building_value(b)
	)
	for b in inactive:
		if active_positions.size() >= WORKERS:
			break
		active_positions.append(b["pos"])


func _building_value(b: Dictionary) -> int:
	var card: Dictionary = CardDB.get_building(b["id"])
	var value := int(card["power"]) * 10 + int(card["gold"])
	value += board.count_adjacent(b) * (int(card["adj_power"]) * 10 + int(card["adj_gold"]))
	if card["draw"] > 0:
		value += 8
	if card["mult"] > 0.0:
		value += int(card["mult"] * 20)
	return value


## 开工：自动补齐工人 -> 结算产出(金币入库 + 抽手牌) -> 进入 PLAY
func finish_prepare() -> bool:
	if phase != Phase.PREPARE:
		return false
	_auto_fill_workers()
	var out := board.compute_output(active_positions)
	gold += out["gold"]
	_roll_hand(HAND_SIZE + out["draw"])
	phase = Phase.PLAY
	return true


func _roll_hand(count: int) -> void:
	var pool := _shuffled(CardDB.ACTIONS)
	hand = []
	for i in count:
		hand.append(pool[i % pool.size()]["id"])


# ---------- PLAY ----------


func play_card(index: int) -> bool:
	if phase != Phase.PLAY or index < 0 or index >= hand.size():
		return false
	var card: Dictionary = CardDB.get_action(hand[index])
	if energy < card["cost"]:
		return false
	energy -= card["cost"]
	played_power += card["flat_power"]
	played_mult *= card["mult"]
	gold += card["flat_gold"]
	hand.remove_at(index)
	return true


## 结束出牌，结算战力并比分，进入 VS
func finish_play() -> bool:
	if phase != Phase.PLAY:
		return false
	var out := board.compute_output(active_positions)
	var mult_total: float = 1.0 + float(out["mult"])
	round_power = int(round(float(out["power"]) * mult_total * played_mult)) + played_power
	player_power_history.append(round_power)
	ghost_round_power = _calc_ghost_power()
	if round_power > ghost_round_power:
		my_score += 1
		last_result = "win"
	elif round_power < ghost_round_power:
		ghost_score += 1
		last_result = "lose"
	else:
		last_result = "tie"
	phase = Phase.VS
	return true


## 动态难度：幽灵本回合战力 = 玩家上一回合战力 × 系数 + 随机抖动。
## 抖动模拟人类波动的不可预测性，避免 AI 平稳发挥时 100% 胜率。
## 首回合无历史用基准值（含抖动）。
func _calc_ghost_power() -> int:
	var diff := int(ghost.get("difficulty", 2))
	if player_power_history.is_empty():
		var base: int = GHOST_FIRST_POWER.get(diff, 8)
		return rng.randi_range(maxi(1, base - 2), base + 2)
	var last := float(player_power_history[player_power_history.size() - 1])
	var factor: float = GHOST_FACTORS.get(diff, 1.0)
	var jitter: int = rng.randi_range(-3, 3)
	return maxi(1, int(round(last * factor + float(jitter))))


## 下一回合或结束
func next_round() -> bool:
	if phase != Phase.VS:
		return false
	if round >= TOTAL_ROUNDS:
		phase = Phase.GAME_OVER
		is_over = true
		return true
	round += 1
	_begin_round()
	return true


# ---------- 状态导出 ----------


func to_dict() -> Dictionary:
	var cells := []
	for c in board.cells:
		cells.append(null if c == null else c.duplicate(true))
	var active := []
	for p in active_positions:
		active.append("%d,%d" % [p.x, p.y])
	var shop := []
	for c in pending:
		shop.append(c.duplicate(true))
	return {
		"phase": phase,
		"round": round,
		"total_rounds": TOTAL_ROUNDS,
		"gold": gold,
		"workers": WORKERS,
		"used_workers": active_positions.size(),
		"my_score": my_score,
		"ghost_score": ghost_score,
		"ghost_name": ghost.get("name", ""),
		"ghost_diff": ghost.get("difficulty", 0),
		"ghost_build": ghost.get("build_type", ""),
		"ghost_round_power": ghost_round_power,
		"round_power": round_power,
		"hand": hand.duplicate(),
		"energy": energy,
		"board_cells": cells,
		"active": active,
		"shop": shop,
		"taken_card": taken_card.duplicate(true),
		"last_result": last_result,
		"is_over": is_over,
	}
