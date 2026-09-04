class_name BoomWeapons
extends RefCounted
## M5 武器注册表（design_m5_weapons.md §3.2 1a）：
## 加一把武器 = 在 _build() 里登记一个 BoomWeaponDef。只读查询，零 UI 依赖。
## 默认武器恒为 "bubble"（CI 依赖：存量断言/参数零改动）。

static var _cache: Array[BoomWeaponDef] = []


static func _ensure_built() -> void:
	if not _cache.is_empty():
		return
	# 泡泡枪：参数逐字等于现常量（FIRE_CD=0.22/BULLET_DMG=1/HP5/移速1.0）。
	_cache.append(_bubble_def())
	_cache.append(_greatsword_def())


static func _bubble_def() -> BoomWeaponDef:
	var def := BoomWeaponDef.new()
	def.id = "bubble"
	def.display_name = "BUBBLE BLASTER"
	def.icon_path = "res://assets/images/icons/weapon_bubble.png"
	def.blurb = "Auto fire, easy to learn"
	def.kind = BoomWeaponDef.AttackKind.RANGED
	def.fire_cd = 0.22
	def.proj_speed = 15.0
	def.proj_life = 1.6
	def.proj_dmg = 1
	def.proj_color = Color("8ce6ff")
	def.move_mult = 1.0
	def.max_hp_bonus = 0
	def.skill_kit_id = "core"
	def.anim_set_id = "bubble_captain"
	return def


static func _greatsword_def() -> BoomWeaponDef:
	var def := BoomWeaponDef.new()
	def.id = "greatsword"
	def.display_name = "GREATSWORD"
	def.icon_path = "res://assets/images/icons/weapon_sword.png"
	def.blurb = "Heavy swings hit hard"
	def.kind = BoomWeaponDef.AttackKind.MELEE
	def.swing_windup = 0.24
	def.swing_active = 0.12
	def.swing_recover = 0.34
	def.swing_arc_deg = 150.0
	def.swing_range = 2.9
	def.swing_max_targets = 6
	def.swing_dmg = 3
	def.swing_knock = 6.0
	def.swing_freeze = 0.05
	def.move_mult = 0.85
	def.max_hp_bonus = 2
	def.skill_kit_id = "core"
	def.anim_set_id = "greatsword_captain"
	return def


## 全武器列表（只读）。
static func all() -> Array[BoomWeaponDef]:
	_ensure_built()
	return _cache.duplicate()


## 按 id 取武器定义；未知 id 回退默认泡泡枪（防御）。
static func get_def(id: String) -> BoomWeaponDef:
	_ensure_built()
	for def in _cache:
		if def.id == id:
			return def
	return _cache[0]


## 默认武器恒为泡泡枪（CI 依赖：存量回归全绿）。
static func default_id() -> String:
	return "bubble"
