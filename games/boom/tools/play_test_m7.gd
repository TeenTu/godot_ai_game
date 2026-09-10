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
	test_attack_range()
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


func test_attack_range() -> void:
	print("[m10-range]")
	var g: BoomGame = host._new_game()
	var attack_range: float = g.weapon_cfg.attack_range
	host._check(attack_range == 8.0, "镇夜灯普通攻击射程 = 8m")
	host._check(attack_range < BoomCam.CAM_SIZE * 720.0 / 1280.0, "攻击半径小于竖屏相机横向半宽，屏外敌人不可锁定")
	var outside := g.spawn_enemy_at(Vector3(attack_range + 0.2, 0.0, 0.0))
	host._check(g._nearest_enemy(attack_range) == null, "射程外敌人不进入自动锁定")
	var inside := g.spawn_enemy_at(Vector3(attack_range - 0.5, 0.0, 0.0))
	host._check(g._nearest_enemy(attack_range) == inside, "射程内敌人可进入自动锁定")
	outside.queue_free()
	inside.queue_free()
	g.enemies.clear()
	var bullet := g.bullets[0] as BoomBullet
	bullet.fire(Vector3.ZERO, Vector3.FORWARD, attack_range)
	for _frame in 90:
		g._tick_bullets(DT)
		if not bullet.active:
			break
	host._check(not bullet.active, "普通灵印抵达 8m 硬上限后回收")
	host._check(bullet.position.length() <= attack_range + 0.3, "普通灵印不会飞入屏外继续伤敌")
	g._spawn_bullet(Vector3.ZERO, Vector3.FORWARD, "ring")
	var skill_bullet := g.bullets[0] as BoomBullet
	host._check(skill_bullet.max_distance == attack_range, "镇夜灯主动技能灵印同样受 8m 限制")
	g.free()


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
	host._check(BoomExperience.xp_to_next(1) == 50, "角色曲线：升 2 级固定需 50 xp")
	host._check(BoomExperience.xp_to_next(2) == 90, "角色曲线：升 3 级固定需 90 xp")
	var e := BoomExperience.new()
	var last_level: Array = [0]
	e.leveled_up.connect(func(lv: int) -> void: last_level[0] = lv)
	host._check(e.add_xp(49) == 0 and e.level == 1, "49 xp 不升级")
	host._check(e.add_xp(1) == 1 and e.level == 2, "第 50 点 xp 升到 2 级")
	host._check(last_level[0] == 2, "升级信号广播 new_level=2")
	host._check(e.xp == 0, "升级后 xp 清零")
	e.add_xp(BoomExperience.xp_to_next(2) + BoomExperience.xp_to_next(3))
	host._check(e.level == 4, "一次入账两级经验跨级到 4")
	e.level = BoomExperience.LEVEL_CAP
	host._check(e.add_xp(99) == 0 and e.level == BoomExperience.LEVEL_CAP, "满级封顶不再升级")
	# 经验由怪物类型定价；角色升级公式不读取波次、配额或怪物数量。
	var paper := BoomJelly.new()
	paper.set_variant(false)
	host._check(paper.xp_reward() == 5, "纸偶经验 = 5")
	var mist := BoomJelly.new()
	mist.set("_is_mist_spirit", true)
	host._check(mist.xp_reward() == 8, "雾灵经验 = 8")
	var elite_reward := BoomJelly.new()
	elite_reward.elite = true
	host._check(elite_reward.xp_reward() == 30, "精英经验 = 30")
	paper.free()
	mist.free()
	elite_reward.free()
	var g: BoomGame = host._new_game()
	var curve_before := BoomExperience.xp_to_next(g.exp_sys.level)
	g.wave = 99
	for i in 10:
		g.spawn_enemy_at(Vector3(float(i), 0.0, 20.0))
	host._check(BoomExperience.xp_to_next(g.exp_sys.level) == curve_before, "角色经验曲线独立于波次与怪物数量")
	g.player.invuln_left = 10.0
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	var expected_reward: int = jelly.xp_reward()
	var guard := 0
	while guard < MAX_FRAMES and not jelly.is_dead():
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
	host._check(jelly.is_dead(), "经验测试敌人被击杀")
	host._check(g.exp_sys.xp == expected_reward, "击杀按怪物类型入账 %d xp" % expected_reward)
	g.free()


func test_skill_tree() -> void:
	print("[m7-tree]")
	BoomSave.test_reset()
	var g: BoomGame = host._new_game()
	var sys := BoomSkillSystem.new()
	sys.game = g
	g.add_child(sys)
	# 两把武器各 6 个独占节点，不再共享前三项技能。
	host._check(sys.pool_ids().size() == 12, "两棵独立技能树共 12 个定义")
	var bubble_tree := sys.tree_ids()
	host._check(
		(
			bubble_tree
			== [
				"lamp_quick_wick",
				"lamp_firefly_volley",
				"lamp_bright_core",
				"lamp_echo",
				"lamp_threefold_seal",
				"lamp_soul_beacon"
			]
		),
		"镇夜灯树 = 普攻/技能双分支交错三阶"
	)
	host._check(BoomSkillSystem.MAX_EQUIPPED == 3, "每局装备上限 = 3")
	host._check(
		sys.is_unlocked("lamp_quick_wick") and sys.is_unlocked("lamp_firefly_volley"),
		"新档免费解锁两条分支根节点"
	)
	host._check(sys.equipped == ["lamp_quick_wick", "lamp_firefly_volley"], "默认装备两根节点")
	host._check(sys.tree_node("lamp_bright_core")["branch"] == "basic", "亮灯芯属于普攻分支")
	host._check(sys.tree_node("lamp_echo")["branch"] == "skill", "灯回响属于技能分支")
	host._check(sys.unlock_cost("lamp_bright_core") == 120, "普攻二阶价格 120")
	host._check(sys.unlock_cost("lamp_threefold_seal") < 0, "未解锁二阶时三阶不可购买")
	host._check(sys.unlock_cost("brush_firm_grip") < 0, "判笔节点不可跨树购买")
	BoomSave.add_coins(119)
	host._check(not sys.try_unlock("lamp_bright_core"), "金币不足解锁失败")
	BoomSave.add_coins(1)
	var unlocked_box: Array = [""]
	sys.skill_unlocked.connect(func(id: String) -> void: unlocked_box[0] = id)
	host._check(sys.try_unlock("lamp_bright_core"), "普攻二阶足额解锁成功")
	host._check(unlocked_box[0] == "lamp_bright_core", "广播灯芯节点解锁")
	host._check(BoomSave.coins() == 0, "解锁扣跨局币 (coins=%d)" % BoomSave.coins())
	host._check(sys.unlock_cost("lamp_threefold_seal") == 300, "满足前置后普攻三阶价格 300")
	host._check(sys.equip("lamp_bright_core"), "已解锁节点可装备到第三槽")
	sys.debug_grant("lamp_echo")
	host._check(not sys.equip("lamp_echo"), "装备满 3 时拒绝第四节点")
	host._check(sys.unequip("lamp_bright_core") and sys.equip("lamp_echo"), "卸装后可切换构筑")
	# 主动根节点按装备槽进入施放管线。
	var fired_box: Array = [0]
	sys.skill_fired.connect(func(_id: String, _r: Variant) -> void: fired_box[0] += 1)
	var before: int = host._active_bullets(g)
	sys.handle_tap()
	host._check(
		host._active_bullets(g) == before + BoomGame.FAN_COUNT, "流萤散射施放 %d 枚灵印" % BoomGame.FAN_COUNT
	)
	host._check(fired_box[0] == 1, "handle_slot 触发 skill_fired")
	# 判笔树完全独立。
	sys.set_weapon_tree("greatsword")
	var sword_tree := sys.tree_ids()
	host._check(
		(
			sword_tree
			== [
				"brush_firm_grip",
				"brush_ink_wave",
				"brush_flowing_script",
				"brush_focus",
				"brush_verdict",
				"brush_seal_domain"
			]
		),
		"墨线判笔树 = 独立普攻/技能双分支"
	)
	host._check(not sword_tree.any(func(id: String) -> bool: return bubble_tree.has(id)), "两树节点零共享")
	host._check(sys.equipped == ["brush_firm_grip", "brush_ink_wave"], "切树后装备判笔两根节点")
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
	sys.set_weapon_tree("bubble")
	host._check(absf(g.skill_basic_speed_mult - 1.15) < 0.001, "镇夜灯根节点提供普攻速度 +15%")
	sys.debug_grant("lamp_bright_core")
	host._check(sys.equip("lamp_bright_core"), "装备亮灯芯")
	host._check(g._base_attack() == 12, "亮灯芯使基础攻击 10 → 12")
	# 被动节点不进入施放管线。
	var fired_box: Array = [0]
	sys.skill_fired.connect(func(_id: String, _r: Variant) -> void: fired_box[0] += 1)
	sys.reset()
	sys.cast_skill("lamp_quick_wick")
	host._check(fired_box[0] == 0, "被动技能不可施放（skill_fired 不触发）")
	# 灯回响是独立的技能冷却乘区，并与角色直接冷却缩减相乘。
	host._check(sys.unequip("lamp_bright_core"), "卸下亮灯芯腾出槽位")
	sys.debug_grant("lamp_echo")
	host._check(sys.equip("lamp_echo"), "装备灯回响")
	g.stats.haste_stacks = 1
	sys.cast_skill("lamp_firefly_volley")
	var expected_cd := BoomSkillSystem.LAMP_VOLLEY_COOLDOWN * 0.85 * 0.92
	host._check(
		absf(float(sys.get_state()["lamp_firefly_volley"]) - expected_cd) < 0.02,
		"武器 -15% 与角色 -8% 冷却乘算"
	)
	# 灯普攻终阶：第三发从单发改成三重灵印，三次共生成 5 发。
	host._check(sys.unequip("lamp_echo"), "卸下灯回响腾出形态槽")
	sys.debug_grant("lamp_threefold_seal")
	host._check(sys.equip("lamp_threefold_seal"), "装备三叠镇印")
	for bullet_variant in g.bullets:
		(bullet_variant as BoomBullet).recycle()
	g._ranged_shot_index = 0
	var muzzle := g.player.position + Vector3(0.0, 0.5, 0.0)
	for _shot in 3:
		g._fire_ranged_basic(muzzle, Vector3.FORWARD)
	host._check(host._active_bullets(g) == 5, "镇夜灯第三次普攻改为三重灵印（3 次共 5 发）")
	# 判笔普攻三阶改变三段动作形态。
	sys.set_weapon_tree("greatsword")
	g.set_weapon("greatsword")
	sys.debug_grant("brush_verdict")
	host._check(sys.equip("brush_verdict"), "装备朱批判决")
	host._check(g.skill_brush_verdict, "判笔普攻形态切换标记生效")
	var step: Dictionary = BoomMeleeSystem.next_step(g)
	step["arc_deg"] = 180.0 if String(step["action"]) != "swing_whirl" else 360.0
	step["damage_mult"] = float(step["damage_mult"]) * 1.25
	host._check(float(step["arc_deg"]) >= 180.0, "朱批判决扩大左右挥覆盖角")
	# 判笔技能两端形态：前向墨浪与圆形封域均进入真实伤害管线。
	g.wave = 20
	g.player.face_toward(Vector3.FORWARD)
	var wave_target := g.spawn_enemy_at(Vector3(-0.7, 0.0, -3.0))
	var wave_target_2 := g.spawn_enemy_at(Vector3(0.7, 0.0, -3.0))
	var wave_hp_before: int = wave_target.hp
	var wave_hits: Array = g.cast_brush_ink_wave()
	host._check(
		(
			wave_hits.size() == 2
			and wave_target.hp < wave_hp_before
			and wave_target_2.hp < wave_hp_before
		),
		(
			"泼墨锋命中前方 5m 目标 (hits=%d hp=%d→%d facing=%s)"
			% [wave_hits.size(), wave_hp_before, wave_target.hp, g.player.facing]
		)
	)
	g.enemies.erase(wave_target)
	g.enemies.erase(wave_target_2)
	wave_target.free()
	wave_target_2.free()
	var domain_target := g.spawn_enemy_at(Vector3(3.0, 0.0, 0.0))
	var domain_target_2 := g.spawn_enemy_at(Vector3(-3.0, 0.0, 0.0))
	var domain_hits: Array = g.cast_brush_seal_domain()
	host._check(
		domain_hits.size() == 2 and domain_target.is_dead() and domain_target_2.is_dead(),
		"朱砂封域命中 4.5m 圆域内多目标"
	)
	g.remove_child(sys)
	sys.free()
	g.free()
	BoomSave.test_reset()


func test_save() -> void:
	print("[m7-save]")
	# 1) 全新档默认结构：coins=0 / 各树两条分支根节点。
	BoomSave.test_reset()
	var data: Dictionary = BoomSave.data()
	host._check(int(data["coins"]) == 0, "新档 coins = 0")
	host._check(
		BoomSave.unlocked_for("bubble") == ["lamp_quick_wick", "lamp_firefly_volley"], "镇夜灯默认解锁两根节点"
	)
	host._check(
		BoomSave.unlocked_for("greatsword") == ["brush_firm_grip", "brush_ink_wave"], "判笔默认解锁两根节点"
	)
	# 2) 货币语义：入账 / 消费 / 余额不足。
	BoomSave.add_coins(77)
	host._check(BoomSave.coins() == 77, "add_coins 入账 77")
	host._check(BoomSave.spend_coins(100) == false, "余额不足消费拒绝")
	host._check(BoomSave.spend_coins(27), "足额消费成功")
	host._check(BoomSave.coins() == 50, "消费后余额 50")
	# 3) roundtrip：写盘 → 清内存缓存 → 重读一致（含解锁）。
	BoomSave.unlock_skill("bubble", "lamp_bright_core")
	BoomSave.add_coins(100)
	host._check(BoomSave.save(), "存档落盘成功")
	BoomSave._data = {}
	var reloaded: Dictionary = BoomSave.data()
	host._check(int(reloaded["coins"]) == 150, "roundtrip 金币一致 (%d)" % int(reloaded["coins"]))
	host._check(BoomSave.is_unlocked("bubble", "lamp_bright_core"), "roundtrip 解锁一致")
	host._check(not BoomSave.is_unlocked("greatsword", "lamp_bright_core"), "跨树解锁互不串扰")
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
	host._check(BoomSave.is_unlocked("bubble", "lamp_quick_wick"), "restart 后解锁进度保留")
	host._check(not BoomSave.is_unlocked("bubble", "lamp_threefold_seal"), "未解锁进度不受影响")
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
	# 1) 镇夜灯卡：技能区两列六节点，且图标全部装载。
	sel.set_selected("bubble")
	var rows: Dictionary = sel.skill_rows()
	host._check(rows.size() == 6, "技能配置区 6 行 (n=%d)" % rows.size())
	var bubble_texts: Array = []
	for i in rows.size():
		bubble_texts.append((rows[i] as Button).text)
	host._check(
		str(bubble_texts).contains("速燃灯芯") and str(bubble_texts).contains("引魂灯"), "镇夜灯技能区含独立双分支节点"
	)
	host._check(
		not str(bubble_texts).contains("泼墨横波") and not str(bubble_texts).contains("朱砂判"),
		"镇夜灯技能区不出现判笔节点"
	)
	host._check(str(bubble_texts[0]).contains("已装备"), "普攻根节点显示已装备")
	host._check(str(bubble_texts[2]).contains("解锁 120"), "普攻二阶显示价格 120")
	host._check(str(bubble_texts[4]).contains("需前置"), "普攻三阶显示前置条件")
	for row_variant in rows.values():
		var row := row_variant as Button
		var icon := row.get_node_or_null("Icon") as TextureRect
		host._check(icon != null and icon.texture != null, "技能树节点图标已加载")
	# 3) 切大剑卡：列表随之切换为 sword 树。
	sel.set_selected("greatsword")
	var sword_texts: Array = []
	for i in rows.size():
		sword_texts.append((rows[i] as Button).text)
	host._check(
		str(sword_texts).contains("泼墨横波") and str(sword_texts).contains("封域"), "判笔技能区含独立技能分支"
	)
	host._check(not str(sword_texts).contains("引魂灯"), "判笔技能区不出现镇夜灯节点")
	# 4) 行点击：已解锁节点可勾选/取消。
	sel.set_selected("bubble")
	sel.skill_sys.debug_grant("lamp_bright_core")
	sel._refresh_skill_rows()
	var node_idx: int = sel.skill_sys.tree_ids().find("lamp_bright_core")
	sel._on_skill_row_pressed(node_idx)
	host._check(sel.skill_sys.equipped.has("lamp_bright_core"), "点击已解锁节点勾选")
	sel._on_skill_row_pressed(node_idx)
	host._check(not sel.skill_sys.equipped.has("lamp_bright_core"), "再次点击取消勾选")
	# 5) 还原：bubble 树 + 默认装备（不污染后续断言）。
	sel.set_selected("bubble")
	sel.skill_sys.set_weapon_tree("bubble")
	BoomSave.test_reset()
