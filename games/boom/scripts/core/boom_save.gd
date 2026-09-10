class_name BoomSave
extends RefCounted
## M7R 跨局持久存档（design_m7_progression.md §6）：解锁进度 + 跨局货币。
## 纯静态门面：内存缓存 + user://boom_save.json 落盘，headless 可读写。
## 结构：{"coins": int, "unlocked": {"bubble": ["lamp_..."], "greatsword": ["brush_..."]}}
## 货币语义：解锁消耗跨局货币（存档 coins）；对局内拾取金币在获得时即时
## 累加进存档内存（落盘合并到解锁 / 结算时机，见 save() 调用方）。

const SAVE_PATH: String = "user://boom_save.json"

## 每把武器的两条派生各开放根节点；旧存档技能保留但不再进入新树。
const DEFAULT_UNLOCKED: Dictionary = {
	"bubble": ["lamp_quick_wick", "lamp_firefly_volley"],
	"greatsword": ["brush_firm_grip", "brush_ink_wave"],
}

static var _data: Dictionary = {}


## 取当前存档（懒加载：无文件 / 解析失败回退默认结构）。
static func data() -> Dictionary:
	if _data.is_empty():
		_data = _load_from_disk()
	return _data


static func _load_from_disk() -> Dictionary:
	var loaded: Dictionary = _default_data()
	if not FileAccess.file_exists(SAVE_PATH):
		return loaded
	var fa := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if fa == null:
		return loaded
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return loaded
	var src: Dictionary = parsed
	loaded["coins"] = int(src.get("coins", 0))
	var unlocked: Dictionary = loaded["unlocked"] as Dictionary
	var src_unlocked: Dictionary = src.get("unlocked", {}) as Dictionary
	for weapon_id in unlocked:
		var list: Array = src_unlocked.get(weapon_id, []) as Array
		for id in list:
			var sid := String(id)
			if not (unlocked[weapon_id] as Array).has(sid):
				(unlocked[weapon_id] as Array).append(sid)
	return loaded


static func _default_data() -> Dictionary:
	# 存档键 = BoomWeaponDef.id（"bubble"/"greatsword"；加新武器自动分桶）。
	return {
		"coins": 0,
		"unlocked":
		{
			"bubble": (DEFAULT_UNLOCKED["bubble"] as Array).duplicate(),
			"greatsword": (DEFAULT_UNLOCKED["greatsword"] as Array).duplicate(),
		},
	}


## 落盘（JSON 序列化整包覆盖写）。成功返回 true。
static func save() -> bool:
	var fa := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_string(JSON.stringify(data(), "  "))
	return true


## 跨局货币只读。
static func coins() -> int:
	return int(data()["coins"])


## 对局内金币入账：获得时即时累加进存档内存（落盘由调用方择机 save()）。
static func add_coins(amount: int) -> void:
	if amount <= 0:
		return
	data()["coins"] = int(data()["coins"]) + amount


## 消费跨局货币：余额不足返回 false；成功扣减（内存，落盘由调用方择机）。
static func spend_coins(amount: int) -> bool:
	if amount < 0 or int(data()["coins"]) < amount:
		return false
	data()["coins"] = int(data()["coins"]) - amount
	return true


## 某武器树已解锁技能 id 列表（副本；未登记武器返回空表）。
static func unlocked_for(weapon_id: String) -> Array[String]:
	var out: Array[String] = []
	var unlocked: Dictionary = data()["unlocked"] as Dictionary
	if not unlocked.has(weapon_id):
		return out
	for id in unlocked[weapon_id] as Array:
		out.append(String(id))
	return out


## 已解锁判定。
static func is_unlocked(weapon_id: String, skill_id: String) -> bool:
	return unlocked_for(weapon_id).has(skill_id)


## 解锁写入存档内存并即时落盘（解锁是低频关键操作，不等结算）。
static func unlock_skill(weapon_id: String, skill_id: String) -> void:
	var unlocked: Dictionary = data()["unlocked"] as Dictionary
	if not unlocked.has(weapon_id):
		unlocked[weapon_id] = []
	if not (unlocked[weapon_id] as Array).has(skill_id):
		(unlocked[weapon_id] as Array).append(skill_id)
	save()


## 测试辅助：清内存缓存 + 删除存档文件，回到全新默认态（headless 无残留）。
static func test_reset() -> void:
	_data = {}
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
