class_name BoomEquipmentSystem
extends RefCounted
## 七部位装备状态；对外仅返回副本，战斗开始后锁定变更。

signal changed

var locked: bool = false
var _slots: Dictionary = BoomEquipmentRegistry.DEFAULTS.duplicate()


func restore(source: Dictionary) -> bool:
	if locked:
		return false
	_slots = BoomEquipmentRegistry.normalize(source)
	changed.emit()
	return true


func equip(slot: String, id: String) -> bool:
	if locked or not _slots.has(slot):
		return false
	var item := BoomEquipmentRegistry.get_def(id)
	if item == null or item.slot != slot:
		return false
	_slots[slot] = id
	changed.emit()
	return true


func unequip(slot: String) -> bool:
	if locked or slot == "artifact" or not _slots.has(slot):
		return false
	_slots[slot] = ""
	changed.emit()
	return true


func snapshot() -> Dictionary:
	return _slots.duplicate(true)


func load_saved() -> bool:
	return restore(BoomSave.equipment())


func persist() -> bool:
	return BoomSave.save_equipment(snapshot())


func bonuses() -> Dictionary:
	var result: Dictionary = {}
	for id in _slots.values():
		var item := BoomEquipmentRegistry.get_def(String(id))
		if item == null:
			continue
		for key in item.flat_stats:
			result[key] = float(result.get(key, 0.0)) + float(item.flat_stats[key])
	return result
