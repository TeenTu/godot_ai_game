class_name FoundryBoard
extends RefCounted

## 4x5 背包网格 = 工厂平面图。
## 建筑卡占若干格子并生成工位；同色相邻触发加成。

const W := 4
const H := 5

var cells: Array = []  # 20 项，null 或 {"id","origin","size","level"}


func _init() -> void:
	cells.resize(W * H)
	for i in cells.size():
		cells[i] = null


func _idx(x: int, y: int) -> int:
	return y * W + x


func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < W and y >= 0 and y < H


## 返回格子内容（null = 空）。统一 null 表示空，方便外部判断。
func _peek(x: int, y: int) -> Variant:
	if not _in_bounds(x, y):
		return null
	return cells[_idx(x, y)]


func is_empty_cell(pos: Vector2i) -> bool:
	return _peek(pos.x, pos.y) == null


func can_place(card: Dictionary, pos: Vector2i) -> bool:
	var size: Vector2i = card["size"]
	for dy in size.y:
		for dx in size.x:
			if not _in_bounds(pos.x + dx, pos.y + dy):
				return false
			if _peek(pos.x + dx, pos.y + dy) != null:
				return false
	return true


func place(card: Dictionary, pos: Vector2i) -> bool:
	if not can_place(card, pos):
		return false
	var size: Vector2i = card["size"]
	for dy in size.y:
		for dx in size.x:
			cells[_idx(pos.x + dx, pos.y + dy)] = {
				"id": card["id"],
				"pos": pos,
				"size": size,
				"level": 1,
			}
	return true


func remove_at(pos: Vector2i) -> void:
	var b: Variant = _peek(pos.x, pos.y)
	if b == null:
		return
	var bd: Dictionary = b
	var size: Vector2i = bd["size"]
	var origin: Vector2i = bd["pos"]
	for dy in size.y:
		for dx in size.x:
			cells[_idx(origin.x + dx, origin.y + dy)] = null


func get_building_at(pos: Vector2i) -> Dictionary:
	var b: Variant = _peek(pos.x, pos.y)
	if b == null:
		return {}
	return (b as Dictionary).duplicate()


func get_all_buildings() -> Array[Dictionary]:
	var seen := {}
	var out: Array[Dictionary] = []
	for y in H:
		for x in W:
			var v: Variant = _peek(x, y)
			if v == null:
				continue
			var b: Dictionary = v
			var key: String = "%d,%d" % [b["pos"].x, b["pos"].y]
			if seen.has(key):
				continue
			seen[key] = true
			out.append({"id": b["id"], "pos": b["pos"], "size": b["size"], "level": b["level"]})
	return out


## 同色相邻建筑数（按建筑去重，2x1/2x2 也只算 1 次）
func count_adjacent(b: Dictionary) -> int:
	var card: Dictionary = CardDB.get_building(b["id"])
	var family: String = card["family"]
	var size: Vector2i = b["size"]
	var origin: Vector2i = b["pos"]
	var neighbors := {}
	for dy in size.y:
		for dx in size.x:
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = origin.x + dx + d.x
				var ny: int = origin.y + dy + d.y
				var nv: Variant = _peek(nx, ny)
				if nv == null:
					continue
				var nb: Dictionary = nv
				if nb["pos"] == origin:
					continue
				if CardDB.get_building(nb["id"])["family"] == family:
					neighbors["%d,%d" % [nb["pos"].x, nb["pos"].y]] = true
	return neighbors.size()


## 汇总激活工位的产出。active: 激活建筑的 origin 坐标数组。
func compute_output(active: Array) -> Dictionary:
	var out := {"gold": 0, "power": 0, "draw": 0, "mult": 0.0}
	var active_set := {}
	for p in active:
		active_set["%d,%d" % [p.x, p.y]] = true
	for b in get_all_buildings():
		var key := "%d,%d" % [b["pos"].x, b["pos"].y]
		if not active_set.has(key):
			continue
		var card: Dictionary = CardDB.get_building(b["id"])
		var adj := count_adjacent(b)
		out["gold"] += card["gold"] + card["adj_gold"] * adj
		out["power"] += card["power"] + card["adj_power"] * adj
		out["draw"] += card["draw"]
		out["mult"] += card["mult"] + card["adj_mult"] * adj
	return out
