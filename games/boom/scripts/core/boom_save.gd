class_name BoomSave
extends RefCounted
## M7R 跨局持久存档（design_m7_progression.md §6）：解锁进度 + 跨局货币。
## 纯静态门面：内存缓存 + user://boom_save.json 落盘，headless 可读写。
## 结构：{"coins": int, "unlocked": {"bubble": ["lamp_..."], "greatsword": ["brush_..."]}}
## 货币语义：解锁消耗跨局货币（存档 coins）；对局内拾取金币在获得时即时
## 累加进存档内存（落盘合并到解锁 / 结算时机，见 save() 调用方）。
## 测试模式（enter_test_mode）另开 test_mode + 独立档 user://boom_save_test.json。

const SAVE_PATH: String = "user://boom_save.json"
## 测试模式存档（独立文件）：进入测试模式不改动真实玩家进度，退出即切回。
const TEST_SAVE_PATH: String = "user://boom_save_test.json"
## 测试模式注入的跨局货币余额（充足即可，便于走解锁/消费路径不被打断）。
const TEST_COINS: int = 999999

## 每把武器的两条派生各开放根节点；旧存档技能保留但不再进入新树。
const DEFAULT_UNLOCKED: Dictionary = {
	"bubble": ["lamp_quick_wick", "lamp_firefly_volley"],
	"greatsword": ["brush_firm_grip", "brush_ink_wave"],
}

static var _data: Dictionary = {}
## 测试入口可切换到独立 user:// 测试档，不触碰真实玩家存档。
static var _path: String = SAVE_PATH
## 测试模式标记（开局全解锁）；由 main.gd 按 URL / 启动参数置位。
static var test_mode: bool = false
## 进入测试模式前的存档路径，退出时还原（避免测试档路径泄漏给后续调用方）。
static var _path_before_test: String = ""


## 取当前存档（懒加载：无文件 / 解析失败回退默认结构）。
static func data() -> Dictionary:
	if _data.is_empty():
		_data = _load_from_disk()
	return _data


static func _load_from_disk() -> Dictionary:
	var loaded: Dictionary = _default_data()
	if not FileAccess.file_exists(_path):
		return loaded
	var fa := FileAccess.open(_path, FileAccess.READ)
	if fa == null:
		return loaded
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return loaded
	var src: Dictionary = parsed
	loaded["equipment"] = migrate_equipment(src)
	var builds: Variant = src.get("skill_loadouts", {})
	loaded["skill_loadouts"] = builds.duplicate(true) if builds is Dictionary else {}
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
		"skill_loadouts": {},
		"equipment": BoomEquipmentRegistry.DEFAULTS.duplicate(),
		"unlocked":
		{
			"bubble": (DEFAULT_UNLOCKED["bubble"] as Array).duplicate(),
			"greatsword": (DEFAULT_UNLOCKED["greatsword"] as Array).duplicate(),
		},
	}


## 落盘（JSON 序列化整包覆盖写）。成功返回 true。
static func save() -> bool:
	# 懒加载必须在打开 WRITE 之前，否则首次保存会先截断尚未读取的旧档。
	var payload := JSON.stringify(data(), "  ")
	var fa := FileAccess.open(_path, FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_string(payload)
	return true


static func migrate_equipment(source: Dictionary) -> Dictionary:
	var raw: Variant = source.get("equipment", {})
	var slots: Dictionary = raw.duplicate(true) if raw is Dictionary else {}
	if not slots.has("artifact") and source.get("weapon") is String:
		slots["artifact"] = source["weapon"]
	return BoomEquipmentRegistry.normalize(slots)


static func equipment() -> Dictionary:
	return (data()["equipment"] as Dictionary).duplicate(true)


static func save_equipment(slots: Dictionary) -> bool:
	var previous := equipment()
	data()["equipment"] = BoomEquipmentRegistry.normalize(slots)
	if save():
		return true
	data()["equipment"] = previous
	return false


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
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))


# ------------------------------------------------------------------ 测试模式（全解锁）


## 进入测试模式（本地调试用）：切换到独立测试档，注入「全武器树全解锁 + 充足金币」，
## 免刷解锁直接验证构筑 / 技能 / 面板。
## 幂等：重复调用不叠加金币（取 max）、不重复追加已解锁项，可安全多次调用。
static func enter_test_mode() -> void:
	test_mode = true
	if _path != TEST_SAVE_PATH:
		if _path_before_test.is_empty():
			_path_before_test = _path
		_path = TEST_SAVE_PATH
		_data = {}  # 换档：丢弃上一档缓存，强制按测试档重新加载
	var d := data()
	d["coins"] = maxi(int(d["coins"]), TEST_COINS)
	# 解锁清单按 BoomWeapons 注册表推导（加新武器自动纳入，无需改本函数）。
	var unlocked: Dictionary = d["unlocked"] as Dictionary
	for weapon: BoomWeaponDef in BoomWeapons.all():
		var list: Array = unlocked.get(weapon.id, [])
		for skill_id in weapon.tree.get("skills", []) as Array:
			var sid := String(skill_id)
			if not list.has(sid):
				list.append(sid)
		unlocked[weapon.id] = list
	save()


## 退出测试模式：还原进入前的存档路径（测试收尾用）。
static func exit_test_mode() -> void:
	test_mode = false
	if _path_before_test.is_empty():
		return
	_path = _path_before_test
	_path_before_test = ""
	_data = {}
