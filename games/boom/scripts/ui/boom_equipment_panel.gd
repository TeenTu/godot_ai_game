class_name BoomEquipmentPanel
extends Control
## 普通装备页，使用装备系统快照；法器与技能配置由相邻页面管理。

const SLOT_NAMES: Dictionary = {
	"armor": "护甲",
	"bracer": "护腕",
	"necklace": "项链",
	"gloves": "护手",
	"boots": "鞋子",
	"pants": "裤子",
}
const STAT_NAMES: Dictionary = {
	"max_hp": "生命",
	"defense": "防御",
	"attack": "攻击",
	"attack_speed": "攻速",
	"cdr": "冷却缩减",
	"crit_rate": "暴击率",
	"crit_dmg": "暴击伤害",
	"move_speed": "移速",
	"dodge": "闪避",
}

const SNAPSHOT_KEYS: Dictionary = {
	"max_hp": "max_hp",
	"defense": "defense",
	"attack": "final_attack",
	"attack_speed": "attack_speed",
	"cdr": "haste_pct",
	"crit_rate": "crit_rate_pct",
	"crit_dmg": "crit_dmg_pct",
	"move_speed": "move_speed",
	"dodge": "dodge_pct",
}

var equipment: BoomEquipmentSystem
var _rows: Dictionary = {}
var _preview: Callable


func setup(value: BoomEquipmentSystem, preview: Callable = Callable()) -> void:
	equipment = value
	_preview = preview
	for slot in SLOT_NAMES:
		var button := Button.new()
		button.position = Vector2(40, 150 + _rows.size() * 140)
		button.size = Vector2(640, 125)
		button.add_theme_font_size_override("font_size", 20)
		var item := BoomEquipmentRegistry.get_def(String(BoomEquipmentRegistry.DEFAULTS[slot]))
		if ResourceLoader.exists(item.icon_path):
			button.icon = load(item.icon_path) as Texture2D
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 72)
		button.pressed.connect(_toggle.bind(String(slot)))
		add_child(button)
		_rows[slot] = button
	equipment.changed.connect(refresh)
	refresh()


func refresh() -> void:
	var slots := equipment.snapshot()
	for slot in _rows:
		var item := BoomEquipmentRegistry.get_def(String(BoomEquipmentRegistry.DEFAULTS[slot]))
		var worn: bool = slots[slot] == item.id
		var values: Array[String] = []
		var changes: Array[String] = []
		var comparison: Dictionary = _preview.call(String(slot)) if _preview.is_valid() else {}
		for key in item.flat_stats:
			var value := float(item.flat_stats[key])
			var percent: bool = key not in ["max_hp", "defense", "attack"]
			changes.append(
				(
					"%s %s%.0f%s"
					% [
						STAT_NAMES[key],
						"−" if worn else "+",
						value * 100 if percent else value,
						"百分点" if percent else ""
					]
				)
			)
			values.append(
				(
					"%s +%.0f%s"
					% [STAT_NAMES[key], value * 100 if percent else value, "%" if percent else ""]
				)
			)
			if not comparison.is_empty():
				var field: String = SNAPSHOT_KEYS[key]
				var suffix := "%" if field.ends_with("_pct") else ""
				changes[-1] = (
					"%s %s%s → %s%s"
					% [
						STAT_NAMES[key],
						str(comparison["before"][field]),
						suffix,
						str(comparison["after"][field]),
						suffix
					]
				)
		var button: Button = _rows[slot]
		button.text = (
			"%s · %s\n%s\n%s\n%s"
			% [
				SLOT_NAMES[slot],
				item.display_name,
				" / ".join(values),
				"已装备 · 点击卸下" if worn else "未装备 · 点击装备",
				" / ".join(changes)
			]
		)
		button.disabled = equipment.locked


func _toggle(slot: String) -> void:
	if equipment.snapshot()[slot] == "":
		equipment.equip(slot, String(BoomEquipmentRegistry.DEFAULTS[slot]))
	else:
		equipment.unequip(slot)
