class_name BoomWeapons
extends RefCounted
## M5 武器注册表（design_m5_weapons.md §3.2 1a）：
## 加一把武器 = 在 _build() 里登记一个 BoomWeaponDef。只读查询，零 UI 依赖。
## 默认武器恒为 "bubble"（CI 依赖：存量断言/参数零改动）。

static var _cache: Array[BoomWeaponDef] = []


static func _ensure_built() -> void:
	if not _cache.is_empty():
		return
	# 泡泡枪：M8 数值制（base_attack=10 / HP50 / 移速1.0，design_m8_attributes.md §5.1）。
	_cache.append(_bubble_def())
	_cache.append(_greatsword_def())


static func _bubble_def() -> BoomWeaponDef:
	var def := BoomWeaponDef.new()
	def.id = "bubble"
	def.display_name = "镇夜灯·镇尺"
	def.icon_path = "res://assets/images/icons/weapon_night_ruler.png"
	def.blurb = "灵印连射，稳定易上手"
	def.kind = BoomWeaponDef.AttackKind.RANGED
	def.fire_cd = 0.22
	def.proj_speed = 15.0
	def.proj_life = 1.6
	# 竖屏相机横向半宽约 8.72m；8m 保守半径保证目标仍在可视区内。
	def.attack_range = 8.0  # 锁敌与普通弹飞行共用此硬上限
	def.base_attack = 10  # M8 基础攻击力：每发普通子弹 10 点（≈3 发杀 W1 30HP）
	def.proj_dmg = def.base_attack  # 与统一结算入口同源（M8 §5.2）
	def.proj_color = Color("8ce6ff")
	def.move_mult = 1.0
	def.max_hp_bonus = 0
	def.skill_kit_id = "lantern"
	def.anim_set_id = "night_ruler"
	def.tree = {
		"branches":
		{
			"basic": ["lamp_quick_wick", "lamp_bright_core", "lamp_threefold_seal"],
			"skill": ["lamp_firefly_volley", "lamp_echo", "lamp_soul_beacon"],
		},
		"skills":
		[
			"lamp_quick_wick",
			"lamp_firefly_volley",
			"lamp_bright_core",
			"lamp_echo",
			"lamp_threefold_seal",
			"lamp_soul_beacon"
		],
	}
	return def


static func _greatsword_def() -> BoomWeaponDef:
	var def := BoomWeaponDef.new()
	def.id = "greatsword"
	def.display_name = "墨线判笔"
	def.icon_path = "res://assets/images/icons/weapon_ink_judge_brush.png"
	def.blurb = "挥墨成弧，势大力沉"
	def.kind = BoomWeaponDef.AttackKind.MELEE
	# 重剑节奏：明显蓄势 → 极短释放 → 带重量的收势。斩距保持 2.9m，不做范围成长。
	def.swing_windup = 0.32
	def.swing_active = 0.08
	def.swing_recover = 0.36
	def.swing_arc_deg = 150.0
	def.swing_range = 2.9
	def.swing_max_targets = 12
	def.base_attack = 30  # M8 基础攻击力：每个弧斩命中 30 点（一刀杀 W1 30HP）
	def.swing_dmg = def.base_attack  # 与统一结算入口同源（M8 §5.2）
	def.swing_knock = 6.0
	def.swing_freeze = 0.065
	# 双手大剑模板：左右两记压迫横扫 → 同距离 360° 大回旋收尾。
	# 只有收尾提高覆盖面/目标数；全段斩距严格锁定为 2.9m。
	def.melee_combo = [
		{
			"action": "swing_left",
			"windup": 0.22,
			"active": 0.07,
			"recover": 0.20,
			"arc_deg": 130.0,
			"max_targets": 8,
			"damage_mult": 1.0,
			"windup_frames": 2,
			"active_frames": 1,
			"recover_frames": 1,
		},
		{
			"action": "swing_right",
			"windup": 0.22,
			"active": 0.07,
			"recover": 0.20,
			"arc_deg": 130.0,
			"max_targets": 8,
			"damage_mult": 1.0,
			"windup_frames": 2,
			"active_frames": 1,
			"recover_frames": 1,
		},
		{
			"action": "swing_whirl",
			"windup": 0.30,
			"active": 0.14,
			"recover": 0.38,
			"arc_deg": 360.0,
			"max_targets": 12,
			"damage_mult": 1.20,
			"windup_frames": 2,
			"active_frames": 2,
			"recover_frames": 2,
		},
	]
	def.move_mult = 0.85
	def.max_hp_bonus = 20  # M8 近战生存补偿：50 + 20 = 70（§4.1）
	def.skill_kit_id = "brush"
	def.anim_set_id = "ink_judge_brush"
	def.tree = {
		"branches":
		{
			"basic": ["brush_firm_grip", "brush_flowing_script", "brush_verdict"],
			"skill": ["brush_ink_wave", "brush_focus", "brush_seal_domain"],
		},
		"skills":
		[
			"brush_firm_grip",
			"brush_ink_wave",
			"brush_flowing_script",
			"brush_focus",
			"brush_verdict",
			"brush_seal_domain"
		],
	}
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
