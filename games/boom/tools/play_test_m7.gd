extends RefCounted

## M7/M7R 无头自检分册（从 play_test.gd 拆出，控制主文件行数门禁）。
## host = play_test.gd（SceneTree）：复用其 _check/_new_game/_run/_active_bullets/_main。
## 节清单见 play_test.gd 头注释 [m7-*] 各条。

const DT: float = 1.0 / 60.0
const MAX_FRAMES: int = 1200

var host


func _init(p_host) -> void:
	host = p_host


func run_all() -> void:
	test_assets()
	test_experience()
	test_skill_tree()
	test_tree_passives()
	test_save()
	test_tree_ui()


# ------------------------------------------------------------------ M7 素材 / 属性 / 经验 / 技能树


func test_assets() -> void:
	print("[m7-assets]")
	for asset_path in [
		"res://assets/images/characters/night_patrol/hero_idle_unarmed.png",
		"res://assets/images/characters/night_patrol/hero_move_unarmed.png",
		"res://assets/images/characters/night_patrol/hero_hurt_unarmed.png",
		"res://assets/images/characters/night_patrol/hero_ranged_cast_body.png",
		"res://assets/images/characters/night_patrol/hero_melee_swing_body.png",
		"res://assets/images/characters/night_patrol/hero_skill_cast_body.png",
		"res://assets/images/characters/night_patrol/hero_knockdown_unarmed.png",
		"res://assets/images/characters/night_patrol/hero_move_up.png",
		"res://assets/images/characters/night_patrol/hero_move_left.png",
		"res://assets/images/characters/night_patrol/hero_move_right.png",
		"res://assets/images/characters/paper_doll.png",
		"res://assets/images/characters/mist_spirit.png",
		"res://assets/images/icons/spirit_seal_coin.png",
		"res://assets/images/backgrounds/rainy_ancient_town.png",
		"res://assets/images/floors/wet_stone_tiles.png",
		"res://assets/images/projectiles/candidates/projectile_lantern_seal.png",
		"res://assets/images/projectiles/candidates/projectile_paper_talisman.png",
		"res://assets/images/projectiles/candidates/projectile_ink_binding.png",
		"res://assets/images/icons/weapon_night_ruler.png",
		"res://assets/images/icons/weapon_ink_judge_brush.png",
		"res://assets/images/weapons/night_patrol/night_ruler_idle.png",
		"res://assets/images/weapons/night_patrol/night_ruler_move.png",
		"res://assets/images/weapons/night_patrol/night_ruler_recoil.png",
		"res://assets/images/weapons/night_patrol/ink_brush_idle.png",
		"res://assets/images/weapons/night_patrol/ink_brush_move.png",
		"res://assets/images/weapons/night_patrol/ink_brush_swing.png",
	]:
		host._check(ResourceLoader.exists(asset_path), "M7 玩家素材可加载: %s" % asset_path)
	var g: BoomGame = host._new_game()
	var ranged_layer := g.player.get("_weapon_anim") as AnimatedSprite3D
	host._check(ranged_layer != null, "镇夜灯·镇尺武器层已挂入 WeaponSocket")
	g.player.play_anim_once("recoil")
	g.player.physics_update(DT, 9.0, 5.0)
	if ranged_layer != null:
		host._check(ranged_layer.animation == "recoil", "远程身体/武器动作同帧切换 recoil")
	g.set_weapon("greatsword")
	var melee_layer := g.player.get("_weapon_anim") as AnimatedSprite3D
	host._check(melee_layer != null, "墨线判笔武器层已挂入 WeaponSocket")
	g.player.play_anim_once("swing_left")
	g.player.physics_update(DT, 9.0, 5.0)
	if melee_layer != null:
		host._check(melee_layer.animation == "swing_left", "近战身体/武器动作同帧切换 swing_left")
	g.free()
	var seal_bullet := BoomBullet.new()
	host._check(seal_bullet.get("_anim") != null, "灯火灵印雪碧层已接入投射物对象池")
	seal_bullet.free()


func test_stats() -> void:
	print("[m7-stats]")
	# M8 已重构属性系统（design_m8_attributes.md）：本节迁移至 play_test_m8.gd [m8-stats]。
	var s := BoomStats.new()
	host._check(s.move_mult() == 1.0 and s.dmg_mult() == 1.0, "初始属性零加成")
	var g: BoomGame = host._new_game()
	host._check(
		g.player.max_hp == 50 and absf(g.player.move_speed - 5.4) < 0.001, "零加成时机体与 M8 数值一致"
	)
	g.free()


func test_experience() -> void:
	print("[m7-exp]")
	host._check(BoomExperience.xp_to_next(1) == 5, "curve: 升 2 级需 5 xp")
	host._check(BoomExperience.xp_to_next(2) == 9, "curve: 升 3 级需 9 xp（+4 递增）")
	var e := BoomExperience.new()
	var last_level: Array = [0]
	e.leveled_up.connect(func(lv: int) -> void: last_level[0] = lv)
	host._check(e.add_xp(4) == 0 and e.level == 1, "4 xp 不升级")
	host._check(e.add_xp(1) == 1 and e.level == 2, "第 5 点 xp 升到 2 级")
	host._check(last_level[0] == 2, "升级信号广播 new_level=2")
	host._check(e.xp == 0, "升级后 xp 清零")
	e.add_xp(BoomExperience.xp_to_next(2) + BoomExperience.xp_to_next(3))
	host._check(e.level == 4, "一次入账两级经验跨级到 4")
	e.level = BoomExperience.LEVEL_CAP
	host._check(e.add_xp(99) == 0 and e.level == BoomExperience.LEVEL_CAP, "满级封顶不再升级")
	# 对局集成：普通击杀 +1 xp；精英 +8 xp 且升级产出属性点。
	var g: BoomGame = host._new_game()
	g.player.invuln_left = 10.0
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	var guard := 0
	while guard < MAX_FRAMES and not jelly.is_dead():
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
	host._check(jelly.is_dead(), "经验测试敌人被击杀")
	host._check(g.exp_sys.xp == BoomExperience.KILL_XP, "普通击杀入账 1 xp")
	g.free()
	var g2: BoomGame = host._new_game()
	g2.wave = 5
	g2.player.invuln_left = 10.0
	var elite := g2.spawn_enemy_at(Vector3(0.0, 0.0, -5.0), true)
	var guard2 := 0
	while guard2 < MAX_FRAMES and not elite.is_dead():
		guard2 += 1
		g2.player.invuln_left = 10.0
		g2.step(DT)
	host._check(elite.is_dead(), "精英被自动火力击杀")
	host._check(
		g2.exp_sys.xp == BoomExperience.ELITE_XP - BoomExperience.xp_to_next(1), "精英 +8 xp 升级后余 3"
	)
	host._check(g2.exp_sys.level == 2, "精英击杀升到 2 级")
	host._check(g2.pending_upgrades == 1, "升级产出 1 个待消费属性点")
	g2.free()


func test_skill_tree() -> void:
	print("[m7-tree]")
	BoomSave.test_reset()
	var g: BoomGame = host._new_game()
	var sys := BoomSkillSystem.new()
	sys.game = g
	g.add_child(sys)
	# 1) 全池扩容：9 个技能定义；bubble 树 6 槽 = 共用 4 + 专属 2。
	host._check(sys.pool_ids().size() == 9, "技能池存全部定义 (n=%d)" % sys.pool_ids().size())
	var bubble_tree := sys.tree_ids()
	host._check(
		bubble_tree == ["fan", "chain", "nuke", "ring", "twin", "rapid"],
		"bubble 树 = fan/chain/nuke/ring + 专属 twin/rapid"
	)
	host._check(BoomSkillSystem.MAX_EQUIPPED == 3, "每局装备上限 = 3")
	# 2) M7R 跨局解锁：新档仅树首 fan 解锁并装备。
	host._check(
		sys.is_unlocked("fan") and not sys.is_unlocked("chain") and not sys.is_unlocked("nuke"),
		"新档仅树首 fan 免费解锁"
	)
	host._check(sys.equipped == ["fan"], "新档默认装备 = [fan]")
	# 3) 树内顺序价：60/120/200/300/420；树首免费；非本树技能不可购买。
	host._check(sys.unlock_cost("chain") == 60, "chain 树序价 60")
	host._check(sys.unlock_cost("nuke") == 120, "nuke 树序价 120")
	host._check(sys.unlock_cost("ring") == 200, "ring 树序价 200")
	host._check(sys.unlock_cost("twin") == 300, "twin（bubble 专属）树序价 300")
	host._check(sys.unlock_cost("rapid") == 420, "rapid（bubble 专属被动）树序价 420")
	host._check(sys.unlock_cost("fan") < 0, "树首免费不可购买")
	host._check(sys.unlock_cost("heal") < 0, "sword 树技能在 bubble 树不可见不可购买")
	# 4) 跨局金币解锁：余额不足失败 → 足额成功扣存档币并即时落盘。
	host._check(not sys.equip("ring"), "未解锁不能装备")
	BoomSave.add_coins(199)
	host._check(not sys.try_unlock("ring"), "跨局金币不足解锁失败")
	BoomSave.add_coins(1)
	var unlocked_box: Array = [""]
	sys.skill_unlocked.connect(func(id: String) -> void: unlocked_box[0] = id)
	host._check(sys.try_unlock("ring"), "跨局金币足额解锁成功")
	host._check(unlocked_box[0] == "ring", "skill_unlocked 信号广播 ring")
	host._check(BoomSave.coins() == 0, "解锁扣跨局币 (coins=%d)" % BoomSave.coins())
	host._check(BoomSave.is_unlocked("bubble", "ring"), "解锁状态写入存档")
	host._check(BoomSave.unlocked_for("bubble").has("ring"), "bubble 树存档含 ring")
	host._check(sys.is_unlocked("ring"), "ring 已解锁")
	host._check(not sys.try_unlock("ring"), "重复解锁拒绝")
	# 5) 装备上限：满 3 拒绝 → 换装成功。
	host._check(sys.equip("ring"), "解锁后装备 ring 成功")
	sys.debug_grant("chain")
	host._check(sys.equip("chain"), "装备 chain 凑满 3 槽")
	sys.debug_grant("twin")
	host._check(not sys.equip("twin"), "装备满 3 时再装备被拒")
	host._check(sys.unequip("chain"), "卸下 chain")
	host._check(not sys.equipped.has("chain") and sys.equipped.size() == 2, "卸下后槽位 2")
	host._check(sys.equip("twin"), "装备 bubble 专属 twin 成功")
	host._check(sys.equipped.size() == BoomSkillSystem.MAX_EQUIPPED, "重新装备满 3 槽")
	host._check(not sys.equip("fan"), "重复装备被拒")
	# 6) 槽位手势重映射：槽 2 = twin，施放 2 发平行重弹。
	var fired_box: Array = [0]
	sys.skill_fired.connect(func(_id: String, _r: Variant) -> void: fired_box[0] += 1)
	var before: int = host._active_bullets(g)
	sys.handle_slot(2)
	host._check(
		host._active_bullets(g) == before + BoomGame.TWIN_COUNT,
		"twin 槽位施放 %d 发重弹" % BoomGame.TWIN_COUNT
	)
	host._check(fired_box[0] == 1, "handle_slot 触发 skill_fired")
	var st: Dictionary = sys.get_state()
	host._check(st.has("twin") and st["twin"] > 0.0, "twin 施放后进入 CD (%.2f)" % st["twin"])
	host._check(st["equipped"].size() == 3, "get_state 返回装备槽")
	sys.handle_slot(9)
	host._check(fired_box[0] == 1, "槽位越界静默忽略")
	# 7) ring 环形弹：槽位施放 12 发（twin 弹仍存活，取下界）。
	sys.reset()
	sys.handle_slot(sys.equipped.find("ring"))
	host._check(
		host._active_bullets(g) >= BoomGame.RING_COUNT, "ring 槽位施放 %d 发环形弹" % BoomGame.RING_COUNT
	)
	# 8) 换大剑树：ring 不可见不可购买，heal/whirl/titan 解锁可用。
	sys.set_weapon_tree("greatsword")
	var sword_tree := sys.tree_ids()
	host._check(
		sword_tree == ["fan", "chain", "nuke", "heal", "whirl", "titan"],
		"sword 树 = fan/chain/nuke/heal + 专属 whirl/titan"
	)
	host._check(sys.unlock_cost("ring") < 0, "bubble 树技能 ring 在 sword 树不可购买")
	host._check(not sys.is_unlocked("ring"), "bubble 树解锁进度不串 sword 树")
	host._check(sys.unlock_cost("heal") == 200, "heal 在 sword 树树序价 200")
	host._check(sys.unlock_cost("whirl") == 300, "whirl（sword 专属）树序价 300")
	host._check(sys.unlock_cost("titan") == 420, "titan（sword 专属被动）树序价 420")
	host._check(sys.equipped == ["fan"], "切树后装备重置为该树已解锁")
	# 9) heal 应急维修（sword 树）：解锁 → 回复 min(REPAIR_HP=15, 缺口)；满血 0。
	BoomSave.add_coins(200)
	host._check(sys.try_unlock("heal"), "跨局金币解锁 heal")
	host._check(sys.equip("heal"), "装备 heal")
	g.player.hp = 40
	var heal_slot: int = sys.equipped.find("heal")
	sys.handle_slot(heal_slot)
	host._check(g.player.hp == 50, "heal 回复 min(15, 缺口10) → 满血 (hp=50)")
	host._check(fired_box[0] == 3, "heal 触发 skill_fired（累计 twin+ring+heal）")
	g.player.hp = g.player.max_hp
	sys.reset()
	sys.handle_slot(heal_slot)
	host._check(g.player.hp == g.player.max_hp, "满血时 heal 回复 0")
	# 10) M7R 跨局保留：restart 清局内金币，不清存档解锁与跨局币。
	BoomSave.add_coins(50)
	g.coins = 999
	sys.debug_grant("whirl")
	g.restart()
	host._check(g.coins == 0, "restart 清局内金币")
	host._check(BoomSave.coins() == 50, "restart 不清跨局金币 (%d)" % BoomSave.coins())
	host._check(BoomSave.is_unlocked("greatsword", "whirl"), "restart 不清解锁进度")
	host._check(sys.is_unlocked("whirl"), "系统视角解锁跨局保留")
	g.remove_child(sys)
	sys.free()
	g.free()
	BoomSave.test_reset()


func test_tree_passives() -> void:
	print("[m7-passive]")
	BoomSave.test_reset()
	var g: BoomGame = host._new_game()
	var sys := BoomSkillSystem.new()
	sys.game = g
	g.add_child(sys)
	# 1) rapid（bubble 专属被动）：装备即普攻 CD ×0.8，卸下还原。
	sys.debug_grant("rapid")
	host._check(sys.equip("rapid"), "装备 rapid 被动")
	host._check(
		absf(g.skill_fire_cd_mult - BoomSkillSystem.RAPID_FIRE_MULT) < 0.001,
		"rapid 装备后 fire_cd ×0.8"
	)
	g.player.invuln_left = 10.0
	g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	host._run(g, 30)
	host._check(host._active_bullets(g) > 0, "rapid 生效期自动开火正常")
	host._check(sys.unequip("rapid"), "卸下 rapid")
	host._check(absf(g.skill_fire_cd_mult - 1.0) < 0.001, "rapid 卸下后 fire_cd 复位")
	# 2) 被动技能不进施放管线：handle_slot 指向 rapid 不发 skill_fired / 不进 CD。
	sys.equip("rapid")
	var fired_box: Array = [0]
	sys.skill_fired.connect(func(_id: String, _r: Variant) -> void: fired_box[0] += 1)
	sys.reset()
	sys.handle_slot(sys.equipped.find("rapid"))
	host._check(fired_box[0] == 0, "被动技能不可施放（skill_fired 不触发）")
	host._check(float(sys.get_state()["rapid"]) <= 0.0, "被动技能无冷却")
	# 3) titan（sword 专属被动）：弧斩/旋风斩伤害 +1。
	sys.set_weapon_tree("greatsword")
	sys.debug_grant("titan")
	host._check(sys.equip("titan"), "装备 titan 被动")
	g.set_weapon("greatsword")
	host._check(g.skill_swing_dmg_bonus == BoomSkillSystem.TITAN_DMG_BONUS, "titan 装备后弧斩加成 +1")
	# restart 归零机体被动加成（局内状态），重走 equip 管线恢复（模拟选单确认次序）。
	g.restart()
	host._check(g.skill_swing_dmg_bonus == 0, "restart 归零被动加成")
	g.set_weapon("greatsword")
	host._check(sys.unequip("titan") and sys.equip("titan"), "重走 equip 管线恢复 titan")
	host._check(g.skill_swing_dmg_bonus == 1, "equip 管线恢复 titan 加成")
	g.player.invuln_left = 10.0
	for offset in [-1.5, 0.0, 1.5]:
		g.spawn_enemy_at(Vector3(float(offset), 0.0, 2.0))
	var blade_box: Array = [0]
	g.blade_hit.connect(func(_pos: Vector3, dmg: int) -> void: blade_box[0] += dmg)
	var hits: int = g.cast_whirl()
	host._check(hits == 3, "whirl 命中斩距内 3 敌 (hits=%d)" % hits)
	host._check(
		blade_box[0] == 93, "whirl 单体伤害 = (base_attack 30 + titan 1)×1.0 = 31 (总 %d)" % blade_box[0]
	)
	# 4) whirl 命中封顶：WHIRL_MAX_TARGETS 截断。
	g.restart()
	g.set_weapon("greatsword")
	g.player.invuln_left = 10.0
	for i in BoomGame.WHIRL_MAX_TARGETS + 3:
		g.spawn_enemy_at(Vector3(-2.0 + float(i) * 0.4, 0.0, 2.0))
	var hits2: int = g.cast_whirl()
	host._check(
		hits2 == BoomGame.WHIRL_MAX_TARGETS,
		"whirl 命中封顶 %d (hits=%d)" % [BoomGame.WHIRL_MAX_TARGETS, hits2]
	)
	g.remove_child(sys)
	sys.free()
	g.free()
	BoomSave.test_reset()


func test_save() -> void:
	print("[m7-save]")
	# 1) 全新档默认结构：coins=0 / 各树仅 fan。
	BoomSave.test_reset()
	var data: Dictionary = BoomSave.data()
	host._check(int(data["coins"]) == 0, "新档 coins = 0")
	host._check(
		(
			BoomSave.unlocked_for("bubble") == ["fan"]
			and BoomSave.unlocked_for("greatsword") == ["fan"]
		),
		"新档各树默认解锁 = [fan]"
	)
	# 2) 货币语义：入账 / 消费 / 余额不足。
	BoomSave.add_coins(77)
	host._check(BoomSave.coins() == 77, "add_coins 入账 77")
	host._check(BoomSave.spend_coins(100) == false, "余额不足消费拒绝")
	host._check(BoomSave.spend_coins(27), "足额消费成功")
	host._check(BoomSave.coins() == 50, "消费后余额 50")
	# 3) roundtrip：写盘 → 清内存缓存 → 重读一致（含解锁）。
	BoomSave.unlock_skill("bubble", "twin")
	BoomSave.add_coins(100)
	host._check(BoomSave.save(), "存档落盘成功")
	BoomSave._data = {}
	var reloaded: Dictionary = BoomSave.data()
	host._check(int(reloaded["coins"]) == 150, "roundtrip 金币一致 (%d)" % int(reloaded["coins"]))
	host._check(BoomSave.is_unlocked("bubble", "twin"), "roundtrip 解锁一致")
	host._check(not BoomSave.is_unlocked("greatsword", "twin"), "跨树解锁互不串扰")
	# 4) 跨局保留：对局 restart 不动存档；对局金币获得即时入存档。
	BoomSave.test_reset()
	BoomSave.add_coins(10)
	var g: BoomGame = host._new_game()
	g.player.invuln_left = 10.0
	g.begin_match()
	var prop := g.props[0] as BoomProp
	prop.take_damage()
	g.call("_finalize_prop", prop)
	host._check(BoomSave.coins() == 11, "对局拾取金币即时入存档 (coins=%d)" % BoomSave.coins())
	g.coins = 500
	g.restart()
	host._check(g.coins == 0, "restart 清局内金币")
	host._check(BoomSave.coins() == 11, "restart 后跨局金币保留")
	host._check(BoomSave.is_unlocked("bubble", "fan"), "restart 后解锁进度保留")
	host._check(not BoomSave.is_unlocked("bubble", "ring"), "未解锁进度不受对局影响")
	# 5) 精英金币雨同样即时入存档（40）。
	var g2: BoomGame = host._new_game()
	g2.wave = 5
	g2.player.invuln_left = 10.0
	var elite := g2.spawn_enemy_at(Vector3(0.0, 0.0, -5.0), true)
	var guard := 0
	while guard < MAX_FRAMES and not elite.is_dead():
		guard += 1
		g2.player.invuln_left = 10.0
		g2.step(DT)
	host._check(elite.is_dead(), "存档节精英被击杀")
	host._check(
		BoomSave.coins() == 11 + BoomGame.ELITE_COIN_COUNT * BoomGame.ELITE_COIN_VALUE,
		"精英金币雨 40 即时入存档 (coins=%d)" % BoomSave.coins()
	)
	# 6) main 层结算落盘：_on_game_over 触发 BoomSave.save()（文件存在即落盘路径可用）。
	host._main.call("_on_game_over", 88)
	host._main.call("_end_slowmo")
	host._check(FileAccess.file_exists(BoomSave.SAVE_PATH), "结算后存档文件存在（落盘路径可用）")
	g.free()
	g2.free()
	BoomSave.test_reset()


func test_tree_ui() -> void:
	print("[m7-tree-ui]")
	BoomSave.test_reset()
	var sel := host._main.get("_select") as BoomWeaponSelect
	host._check(sel != null, "选武器面板已构建")
	if sel == null:
		return
	host._check(sel.skill_sys != null, "选单已注入技能系统")
	if sel.skill_sys == null:
		return
	# 1) bubble 卡：技能区 6 行 = bubble 树，含专属 twin/rapid，不含 sword 专属。
	sel.set_selected("bubble")
	var rows: Dictionary = sel.skill_rows()
	host._check(rows.size() == 6, "技能配置区 6 行 (n=%d)" % rows.size())
	var bubble_texts: Array = []
	for i in rows.size():
		bubble_texts.append((rows[i] as Button).text)
	host._check(
		str(bubble_texts).contains("TWIN") and str(bubble_texts).contains("OVERDRIVE"),
		"bubble 技能区含专属 twin/rapid"
	)
	host._check(
		not str(bubble_texts).contains("WHIRL") and not str(bubble_texts).contains("REPAIR"),
		"bubble 技能区不出现 sword 专属技能"
	)
	# 2) 未解锁行显示价格；fan 已解锁显示 EQUIPPED。
	host._check(str(bubble_texts[0]).contains("EQUIPPED"), "fan 行显示已勾选")
	host._check(str(bubble_texts[3]).contains("UNLOCK 200"), "ring 行显示解锁价 200")
	# 3) 切大剑卡：列表随之切换为 sword 树。
	sel.set_selected("greatsword")
	var sword_texts: Array = []
	for i in rows.size():
		sword_texts.append((rows[i] as Button).text)
	host._check(
		str(sword_texts).contains("WHIRLWIND") and str(sword_texts).contains("REPAIR"),
		"sword 技能区含 whirl/heal"
	)
	host._check(not str(sword_texts).contains("TWIN"), "sword 技能区不出现 bubble 专属 twin")
	# 4) 行点击解锁：ring 价 200，余额不足点击不解锁、足额点击解锁并勾选。
	sel.set_selected("bubble")
	sel.skill_sys.debug_grant("ring")  # 直接给解锁，专注测勾选路径
	sel._refresh_skill_rows()
	var ring_idx: int = sel.skill_sys.tree_ids().find("ring")
	sel._on_skill_row_pressed(ring_idx)
	host._check(sel.skill_sys.equipped.has("ring"), "点击已解锁行勾选 ring")
	sel._on_skill_row_pressed(ring_idx)
	host._check(not sel.skill_sys.equipped.has("ring"), "再次点击取消勾选")
	# 5) 还原：bubble 树 + 默认装备（不污染后续断言）。
	sel.set_selected("bubble")
	sel.skill_sys.set_weapon_tree("bubble")
	BoomSave.test_reset()
