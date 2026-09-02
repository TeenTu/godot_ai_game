class_name CardDB
extends RefCounted

## 建筑卡池与手牌池（纯数据，静态可测）
## 建筑卡占背包格子并生成工位；手牌在出牌阶段打出，放大战力。

const BUILDINGS: Array[Dictionary] = [
	{
		"id": "mine",
		"name": "Mine",
		"family": "blue",
		"size": Vector2i(2, 1),
		"cost": 3,
		"gold": 3,
		"power": 0,
		"draw": 0,
		"mult": 0.0,
		"adj_gold": 1,
		"adj_power": 0,
		"adj_mult": 0.0
	},
	{
		"id": "forge",
		"name": "Forge",
		"family": "red",
		"size": Vector2i(1, 1),
		"cost": 2,
		"gold": 0,
		"power": 4,
		"draw": 0,
		"mult": 0.0,
		"adj_gold": 0,
		"adj_power": 1,
		"adj_mult": 0.0
	},
	{
		"id": "workshop",
		"name": "Workshop",
		"family": "amber",
		"size": Vector2i(2, 1),
		"cost": 3,
		"gold": 0,
		"power": 0,
		"draw": 1,
		"mult": 0.0,
		"adj_gold": 1,
		"adj_power": 0,
		"adj_mult": 0.0
	},
	{
		"id": "warehouse",
		"name": "Warehouse",
		"family": "green",
		"size": Vector2i(2, 2),
		"cost": 5,
		"gold": 1,
		"power": 1,
		"draw": 0,
		"mult": 0.0,
		"adj_gold": 1,
		"adj_power": 1,
		"adj_mult": 0.0
	},
	{
		"id": "market",
		"name": "Market",
		"family": "pink",
		"size": Vector2i(1, 1),
		"cost": 2,
		"gold": 2,
		"power": 0,
		"draw": 0,
		"mult": 0.0,
		"adj_gold": 1,
		"adj_power": 0,
		"adj_mult": 0.0
	},
	{
		"id": "barracks",
		"name": "Barracks",
		"family": "crimson",
		"size": Vector2i(2, 1),
		"cost": 4,
		"gold": 0,
		"power": 6,
		"draw": 0,
		"mult": 0.0,
		"adj_gold": 0,
		"adj_power": 1,
		"adj_mult": 0.0
	},
	{
		"id": "lab",
		"name": "Lab",
		"family": "purple",
		"size": Vector2i(1, 1),
		"cost": 4,
		"gold": 0,
		"power": 0,
		"draw": 0,
		"mult": 0.5,
		"adj_gold": 0,
		"adj_power": 0,
		"adj_mult": 0.25
	},
	{
		"id": "gearbox",
		"name": "Gearbox",
		"family": "gray",
		"size": Vector2i(1, 1),
		"cost": 1,
		"gold": 1,
		"power": 1,
		"draw": 0,
		"mult": 0.0,
		"adj_gold": 0,
		"adj_power": 0,
		"adj_mult": 0.0
	},
]

const ACTIONS: Array[Dictionary] = [
	{"id": "strike", "name": "Strike", "cost": 1, "flat_power": 3, "mult": 1.0, "flat_gold": 0},
	{"id": "scrap", "name": "Scrap", "cost": 0, "flat_power": 1, "mult": 1.0, "flat_gold": 1},
	{"id": "gear_up", "name": "Gear Up", "cost": 1, "flat_power": 0, "mult": 1.3, "flat_gold": 0},
	{
		"id": "blueprint",
		"name": "Blueprint",
		"cost": 1,
		"flat_power": 2,
		"mult": 1.0,
		"flat_gold": 1
	},
	{"id": "rush", "name": "Rush", "cost": 2, "flat_power": 6, "mult": 1.0, "flat_gold": 0},
	{"id": "bargain", "name": "Bargain", "cost": 0, "flat_power": 0, "mult": 1.0, "flat_gold": 3},
	{
		"id": "overclock",
		"name": "Overclock",
		"cost": 2,
		"flat_power": 0,
		"mult": 1.6,
		"flat_gold": 0
	},
	{"id": "steal", "name": "Steal", "cost": 1, "flat_power": 4, "mult": 1.0, "flat_gold": 0},
]

const FAMILY_COLORS: Dictionary = {
	"blue": "#4A7FC1",
	"red": "#D85A30",
	"amber": "#BA7517",
	"green": "#639922",
	"pink": "#D4537E",
	"crimson": "#A32D2D",
	"purple": "#7F77DD",
	"gray": "#888780",
}

const ICON_BASE := "res://assets/icons/building_"


static func get_building(id: String) -> Dictionary:
	for b in BUILDINGS:
		if b["id"] == id:
			return b
	return {}


static func get_action(id: String) -> Dictionary:
	for a in ACTIONS:
		if a["id"] == id:
			return a
	return {}


static func building_icon(id: String) -> String:
	return ICON_BASE + id + ".png"
