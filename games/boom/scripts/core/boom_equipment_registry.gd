class_name BoomEquipmentRegistry
extends RefCounted
## 装备目录。法器引用原战斗定义，其余部位仅提供角色属性。

const DEFAULTS: Dictionary = {
	"artifact": "bubble",
	"armor": "patrol_armor",
	"bracer": "copper_bracer",
	"necklace": "cinnabar_necklace",
	"gloves": "exorcist_gloves",
	"boots": "shadow_cloth_boots",
	"pants": "night_patrol_pants",
}
const ITEMS: Dictionary = {
	"patrol_armor": ["armor", "巡夜司制式护甲", {"max_hp": 12, "defense": 10}],
	"copper_bracer": ["bracer", "镇魂铜护腕", {"attack_speed": 0.05, "cdr": 0.04}],
	"cinnabar_necklace": ["necklace", "朱砂定魄项链", {"crit_rate": 0.03, "crit_dmg": 0.15}],
	"exorcist_gloves": ["gloves", "伏妖铁护手", {"attack": 2}],
	"shadow_cloth_boots": ["boots", "踏影布靴", {"move_speed": 0.05, "dodge": 0.03}],
	"night_patrol_pants": ["pants", "夜行短裤", {"max_hp": 8, "defense": 5}],
}


static func get_def(id: String) -> BoomEquipmentDef:
	var item := BoomEquipmentDef.new()
	item.id = id
	if id in ["bubble", "greatsword"]:
		var weapon := BoomWeapons.get_def(id)
		item.slot = "artifact"
		item.artifact_id = id
		item.display_name = weapon.display_name
		item.description = weapon.blurb
		item.icon_path = weapon.icon_path
		item.visual_id = weapon.anim_set_id
	elif ITEMS.has(id):
		var spec: Array = ITEMS[id]
		item.slot = String(spec[0])
		item.display_name = String(spec[1])
		item.flat_stats = (spec[2] as Dictionary).duplicate(true)
		item.icon_path = "res://assets/images/icons/equipment_%s.svg" % item.slot
	else:
		return null
	item.category = item.slot
	return item


static func normalize(source: Dictionary) -> Dictionary:
	var result := DEFAULTS.duplicate()
	for slot in DEFAULTS:
		if not source.has(slot):
			continue
		var id := String(source[slot]) if source[slot] is String else "invalid"
		if id.is_empty() and slot != "artifact":
			result[slot] = ""
			continue
		var item := get_def(id)
		if item != null and item.slot == slot:
			result[slot] = id
	return result
