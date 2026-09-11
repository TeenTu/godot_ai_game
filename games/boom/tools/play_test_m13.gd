extends RefCounted
## 装备系统回归；由主冒烟入口调用，存档测试使用独立文件。

var failures: int = 0


func run(host: SceneTree) -> int:
	var equipment := BoomEquipmentSystem.new()
	_check(equipment.snapshot().size() == 7, "equipment.snapshot().size() == 7")
	_check(
		not equipment.equip("boots", "patrol_armor"), 'not equipment.equip("boots", "patrol_armor")'
	)
	_check(not equipment.unequip("artifact"), 'not equipment.unequip("artifact")')
	var snapshot := equipment.snapshot()
	snapshot["armor"] = ""
	_check(
		equipment.snapshot()["armor"] == "patrol_armor",
		'equipment.snapshot()["armor"] == "patrol_armor"'
	)
	var migrated := BoomSave.migrate_equipment({"weapon": "greatsword"})
	_check(migrated["artifact"] == "greatsword", 'migrated["artifact"] == "greatsword"')
	_check(migrated["armor"] == "patrol_armor", 'migrated["armor"] == "patrol_armor"')
	_check(
		BoomSave.migrate_equipment({"equipment": {"boots": ""}})["boots"] == "",
		'BoomSave.migrate_equipment({"equipment": {"boots": ""}})["boots"] == ""'
	)
	var game := BoomGame.new()
	host.root.add_child(game)
	game.bind_equipment(equipment)
	var original_snapshot := game.stats_snapshot()
	var comparison := game.preview_equipment("necklace")
	_check(comparison["before"]["crit_dmg_pct"] == 165, "预览当前暴伤165%")
	_check(comparison["after"]["crit_dmg_pct"] == 150, "卸下项链预览暴伤150%")
	_check(comparison["after"]["crit_rate_pct"] == 0, "卸下项链预览暴击0%")
	_check(game.stats_snapshot() == original_snapshot, "预览不改变实际属性或生命")
	_check(equipment.snapshot()["necklace"] != "", "预览不卸下实际装备")
	_check(game.player.max_hp == 70, "game.player.max_hp == 70")
	_check(game._base_attack() == 12, "game._base_attack() == 12")
	_check(game.stats.total_defense() == 15, "game.stats.total_defense() == 15")
	_check(game.stats_snapshot()["defense"] == 15, 'game.stats_snapshot()["defense"] == 15')
	_check(
		is_equal_approx(game._fire_interval(), 0.22 / 1.05),
		"is_equal_approx(game._fire_interval(), 0.22 / 1.05)"
	)
	_check(
		is_equal_approx(game.stats.cooldown_reduction(), 0.04),
		"is_equal_approx(game.stats.cooldown_reduction(), 0.04)"
	)
	_check(
		is_equal_approx(game.player.move_speed, BoomPlayer.MOVE_SPEED * 1.05),
		"is_equal_approx(game.player.move_speed, BoomPlayer.MOVE_SPEED * 1.05)"
	)
	var mitigated := BoomCombatMath.resolve_player_damage(100, 0.0, game.stats.total_defense())
	_check(mitigated[0] == 86, "mitigated[0] == 86")
	_check(
		is_equal_approx(game.stats.crit_dmg_mult(), 1.65),
		"is_equal_approx(game.stats.crit_dmg_mult(), 1.65)"
	)
	_check(
		is_equal_approx(game.stats.crit_rate(), 0.03),
		"is_equal_approx(game.stats.crit_rate(), 0.03)"
	)
	_check(
		is_equal_approx(game.stats.dodge_rate(), 0.03),
		"is_equal_approx(game.stats.dodge_rate(), 0.03)"
	)
	_check(equipment.unequip("armor"), 'equipment.unequip("armor")')
	_check(game.player.max_hp == 58, "game.player.max_hp == 58")
	_check(game.stats.total_defense() == 5, "game.stats.total_defense() == 5")
	_check(
		BoomCombatMath.resolve_player_damage(100, 0.0, game.stats.total_defense())[0] == 95,
		"BoomCombatMath.resolve_player_damage(100, 0.0, game.stats.total_defense())[0] == 95"
	)
	_check(equipment.unequip("gloves"), 'equipment.unequip("gloves")')
	_check(game._base_attack() == 10, "game._base_attack() == 10")
	_check(equipment.equip("artifact", "greatsword"), 'equipment.equip("artifact", "greatsword")')
	_check(game._base_attack() == 30, "game._base_attack() == 30")
	_check(game.player.max_hp == 78, "game.player.max_hp == 78")
	game.begin_match()
	_check(
		not equipment.equip("armor", "patrol_armor"), 'not equipment.equip("armor", "patrol_armor")'
	)
	_check(not equipment.restore({}), "not equipment.restore({})")
	_check(not equipment.unequip("boots"), 'not equipment.unequip("boots")')
	game.restart()
	_check(not equipment.locked, "not equipment.locked")
	_check(game.player.max_hp == 78, "game.player.max_hp == 78")
	_check(game.stats.total_defense() == 5, "game.stats.total_defense() == 5")
	var encoded := JSON.stringify({"equipment": equipment.snapshot()})
	var restored := BoomEquipmentSystem.new()
	_check(
		restored.restore(BoomSave.migrate_equipment(JSON.parse_string(encoded))),
		"restored.restore(BoomSave.migrate_equipment(JSON.parse_string(encoded)))"
	)
	_check(
		restored.snapshot() == equipment.snapshot(), "restored.snapshot() == equipment.snapshot()"
	)
	_check(restored.bonuses() == equipment.bonuses(), "restored.bonuses() == equipment.bonuses()")
	for slot in BoomEquipmentRegistry.DEFAULTS:
		var item := BoomEquipmentRegistry.get_def(String(BoomEquipmentRegistry.DEFAULTS[slot]))
		_check(item != null and item.slot == slot, "item != null and item.slot == slot")
		_check(ResourceLoader.exists(item.icon_path), "ResourceLoader.exists(item.icon_path)")
	game.free()
	_test_persistence(host)
	print("M13_EQUIPMENT result=%s" % ("PASS" if failures == 0 else "FAIL"))
	return failures


func _test_persistence(host: SceneTree) -> void:
	var previous_path := BoomSave._path
	var previous_data := BoomSave._data.duplicate(true)
	BoomSave._path = "user://boom_m13_equipment_test.json"
	BoomSave.test_reset()
	var file := FileAccess.open(BoomSave._path, FileAccess.WRITE)
	_check(file != null, "可创建隔离旧存档")
	if file == null:
		BoomSave._path = previous_path
		BoomSave._data = previous_data
		return
	file.store_string(
		JSON.stringify(
			{"weapon": "greatsword", "coins": 321, "unlocked": {"bubble": ["lamp_bright_core"]}}
		)
	)
	file.close()
	_check(BoomSave.equipment()["artifact"] == "greatsword", "磁盘旧武器迁移为法器")
	_check(BoomSave.coins() == 321, "迁移保留货币")
	_check(BoomSave.is_unlocked("bubble", "lamp_bright_core"), "迁移保留技能解锁")
	var equipment := BoomEquipmentSystem.new()
	equipment.load_saved()
	equipment.unequip("boots")
	_check(equipment.persist(), "装备保存成功")
	var skills := BoomSkillSystem.new()
	host.root.add_child(skills)
	skills.set_weapon_tree("bubble")
	_check(skills.unequip("lamp_firefly_volley"), "灯法器卸下主动技能")
	var lamp_loadout := skills.equipped.duplicate()
	skills.set_weapon_tree("greatsword")
	_check(skills.unequip("brush_ink_wave"), "判笔卸下主动技能")
	var brush_loadout := skills.equipped.duplicate()
	skills.set_weapon_tree("bubble")
	_check(skills.equipped == lamp_loadout, "来回切换恢复灯配置")
	BoomSave._data = {}
	_check(BoomSave.equipment() == equipment.snapshot(), "七槽磁盘读回一致，包括空槽")
	_check(BoomSave.coins() == 321, "换装未污染货币")
	skills.set_weapon_tree("greatsword")
	_check(skills.equipped == brush_loadout, "重新读档恢复判笔配置")
	_check(BoomSave.is_unlocked("bubble", "lamp_bright_core"), "换装未污染解锁")
	skills.free()
	BoomSave.test_reset()
	BoomSave._path = previous_path
	BoomSave._data = previous_data


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error("M13: " + label)
