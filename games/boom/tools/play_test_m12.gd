class_name BoomPlayTestM12
extends RefCounted
## M12 技能完成度回归：12 个节点真实效果、主动槽触发链、四种独立表现。

const EPS: float = 0.002

var host


func _init(p_host) -> void:
	host = p_host


func run_all() -> void:
	print("[m12-skill-routing]")
	_test_active_slot_routing()
	_test_touch_input_path()
	print("[m12-passive-effects]")
	_test_lantern_passives()
	_test_brush_passives()
	print("[m12-active-effects]")
	_test_brush_actives()
	_test_effect_catalog_and_presentations()


func _new_skill_game(weapon_id: String) -> Array:
	BoomSave.test_reset()
	var game: BoomGame = host._new_game()
	game.set_weapon(weapon_id)
	var system := BoomSkillSystem.new()
	system.game = game
	game.add_child(system)
	system.set_weapon_tree(weapon_id)
	return [game, system]


func _test_active_slot_routing() -> void:
	var ctx := _new_skill_game("bubble")
	var game := ctx[0] as BoomGame
	var system := ctx[1] as BoomSkillSystem
	var fired: Array[String] = []
	system.skill_fired.connect(func(id: String, _result: Variant) -> void: fired.append(id))
	host._check(system.equipped == ["lamp_quick_wick", "lamp_firefly_volley"], "构筑槽保留默认被动与主动")
	host._check(system.active_equipped() == ["lamp_firefly_volley"], "主动槽自动过滤被动")
	host._check(system.passive_equipped() == ["lamp_quick_wick"], "被动仍在构筑中生效")
	var before: int = int(host._active_bullets(game))
	system.handle_tap()
	host._check(fired == ["lamp_firefly_volley"], "默认 tap 不再被被动吞掉")
	host._check(host._active_bullets(game) == before + 5, "tap 真实发射 5 枚流萤灵印")
	system.debug_grant("lamp_soul_beacon")
	host._check(system.equip("lamp_soul_beacon"), "第二主动技能可加入剩余构筑槽")
	host._check(
		system.active_equipped() == ["lamp_firefly_volley", "lamp_soul_beacon"], "主动槽顺序稳定且不含被动"
	)
	before = host._active_bullets(game)
	system.handle_swipe_left()
	host._check(fired[-1] == "lamp_soul_beacon", "左滑触发第二个主动技能")
	host._check(host._active_bullets(game) == before + 12, "魂灯结界真实环射 12 枚灵印")
	var fired_count := fired.size()
	system.handle_swipe_right()
	host._check(fired.size() == fired_count, "未装备第三主动技能时右滑安全忽略")
	game.free()
	BoomSave.test_reset()


func _test_touch_input_path() -> void:
	BoomSave.test_reset()
	var scene := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	host.root.add_child(scene)
	scene._start_match_with("bubble")
	var fired: Array[String] = []
	scene.skill_sys.skill_fired.connect(
		func(id: String, _result: Variant) -> void: fired.append(id)
	)
	var press := InputEventScreenTouch.new()
	press.index = 17
	press.position = Vector2(520.0, 520.0)
	press.pressed = true
	scene._input(press)
	var release := InputEventScreenTouch.new()
	release.index = press.index
	release.position = press.position
	release.pressed = false
	scene._input(release)
	host._check(fired == ["lamp_firefly_volley"], "真实 ScreenTouch tap 贯通输入→主动槽→施放")
	host.root.remove_child(scene)
	scene.free()
	BoomSave.test_reset()


func _test_lantern_passives() -> void:
	var ctx := _new_skill_game("bubble")
	var game := ctx[0] as BoomGame
	var system := ctx[1] as BoomSkillSystem
	host._check(
		(
			is_equal_approx(game.skill_basic_speed_mult, 1.15)
			and is_equal_approx(game._fire_interval(), 0.22 / 1.15)
		),
		"速燃灯芯真实把普攻间隔缩短 15%"
	)
	system.debug_grant("lamp_bright_core")
	host._check(system.equip("lamp_bright_core") and game._base_attack() == 12, "明芯使基础攻击 10→12")
	system.unequip("lamp_bright_core")
	system.debug_grant("lamp_threefold_seal")
	host._check(system.equip("lamp_threefold_seal") and game.skill_threefold_seal, "三重灵印开启三叠镇印")
	var muzzle := game.player.position + Vector3(0.0, 0.5, 0.0)
	for _shot in 3:
		game._fire_ranged_basic(muzzle, Vector3.FORWARD)
	host._check(host._active_bullets(game) == 5, "三次普攻实际生成 1+1+3 枚灵印")
	system.unequip("lamp_threefold_seal")
	system.debug_grant("lamp_echo")
	host._check(system.equip("lamp_echo"), "灯影回响可正常装备")
	system.cast_skill("lamp_firefly_volley")
	host._check(
		is_equal_approx(
			float(system.get_state()["lamp_firefly_volley"]),
			BoomSkillSystem.LAMP_VOLLEY_COOLDOWN * BoomSkillSystem.SKILL_COOLDOWN_MULT
		),
		"灯影回响真实把主动技能冷却乘 0.85"
	)
	game.free()
	BoomSave.test_reset()


func _test_brush_passives() -> void:
	var ctx := _new_skill_game("greatsword")
	var game := ctx[0] as BoomGame
	var system := ctx[1] as BoomSkillSystem
	host._check(game._base_attack() == 36, "稳执笔使判笔基础攻击 30→36")
	system.debug_grant("brush_flowing_script")
	host._check(system.equip("brush_flowing_script"), "行云笔意可正常装备")
	var target := game.spawn_enemy_at(Vector3(0.0, 0.0, -2.0))
	game.player.face_toward(Vector3.FORWARD)
	BoomMeleeSystem.tick(game, 0.0)
	var speed := game._basic_attack_speed_mult()
	host._check(absf(game._swing_t - float(game._swing_step["windup"]) / speed) < EPS, "行云笔意压缩连招前摇")
	BoomMeleeSystem.tick(game, game._swing_t + EPS)
	host._check(
		(
			game._swing_state == game.SwingState.ACTIVE
			and absf(game._swing_t - float(game._swing_step["active"]) / speed) < EPS
		),
		"行云笔意同时压缩有效帧"
	)
	BoomMeleeSystem.tick(game, game._swing_t + EPS)
	host._check(
		(
			game._swing_state == game.SwingState.RECOVER
			and absf(game._swing_t - float(game._swing_step["recover"]) / speed) < EPS
		),
		"行云笔意同时压缩收势，完整连招 +15%"
	)
	if is_instance_valid(target) and target.get_parent() != null:
		game.enemies.erase(target)
		target.free()
	system.unequip("brush_flowing_script")
	system.debug_grant("brush_verdict")
	host._check(system.equip("brush_verdict") and game.skill_brush_verdict, "朱砂判开启判决形态")
	game._swing_state = game.SwingState.NONE
	game._swing_combo_index = 0
	game.spawn_enemy_at(Vector3(0.0, 0.0, -2.0))
	BoomMeleeSystem.tick(game, 0.0)
	host._check(
		(
			is_equal_approx(float(game._swing_step["arc_deg"]), 180.0)
			and is_equal_approx(float(game._swing_step["damage_mult"]), 1.25)
		),
		"朱砂判真实扩大左右挥至 180°并增伤 25%"
	)
	game._swing_state = game.SwingState.NONE
	game._swing_combo_index = 2
	game.spawn_enemy_at(Vector3(0.0, 0.0, -2.0))
	BoomMeleeSystem.tick(game, 0.0)
	host._check(
		(
			is_equal_approx(float(game._swing_step["arc_deg"]), 360.0)
			and is_equal_approx(float(game._swing_step["damage_mult"]), 1.5)
		),
		"朱砂判真实把大回旋扩至 360°并叠加 25% 伤害"
	)
	system.unequip("brush_verdict")
	system.debug_grant("brush_focus")
	host._check(system.equip("brush_focus"), "一气呵成可正常装备")
	system.cast_skill("brush_ink_wave")
	host._check(
		is_equal_approx(
			float(system.get_state()["brush_ink_wave"]),
			BoomSkillSystem.BRUSH_WAVE_COOLDOWN * BoomSkillSystem.SKILL_COOLDOWN_MULT
		),
		"一气呵成真实把主动技能冷却乘 0.85"
	)
	game.free()
	BoomSave.test_reset()


func _test_brush_actives() -> void:
	var ctx := _new_skill_game("greatsword")
	var game := ctx[0] as BoomGame
	var system := ctx[1] as BoomSkillSystem
	game.wave = 20
	game.player.face_toward(Vector3.FORWARD)
	var front := game.spawn_enemy_at(Vector3(0.0, 0.0, -3.0))
	var front_hp := front.hp
	var fired: Array[String] = []
	system.skill_fired.connect(func(id: String, _result: Variant) -> void: fired.append(id))
	system.handle_tap()
	host._check(fired == ["brush_ink_wave"] and front.hp < front_hp, "tap 触发泼墨锋并真实伤害前方目标")
	system.debug_grant("brush_seal_domain")
	host._check(system.equip("brush_seal_domain"), "朱砂封域可加入剩余构筑槽")
	var side := game.spawn_enemy_at(Vector3(3.5, 0.0, 0.0))
	var side_hp := side.hp
	system.handle_swipe_left()
	host._check(fired[-1] == "brush_seal_domain" and side.hp < side_hp, "左滑触发朱砂封域并伤害圆域目标")
	game.free()
	BoomSave.test_reset()


func _test_effect_catalog_and_presentations() -> void:
	host._check(BoomSkillEffects.ids().size() == 4, "四个主动技能均有唯一效果定义")
	var normal_volley := BoomSkillEffects.get_effect(BoomSkillEffects.LAMP_FIREFLY_VOLLEY)
	var evolved_volley := BoomSkillEffects.get_effect(BoomSkillEffects.LAMP_FIREFLY_VOLLEY, true)
	host._check(
		(
			int(normal_volley["projectiles"]) == 5
			and float(normal_volley["arc_deg"]) == 30.0
			and float(normal_volley["range"]) == 8.0
			and int(evolved_volley["projectiles"]) == 7
			and float(evolved_volley["arc_deg"]) == 40.0
		),
		"流萤散射参数完整：5→7 枚、30°→40°、8m"
	)
	var normal_beacon := BoomSkillEffects.get_effect(BoomSkillEffects.LAMP_SOUL_BEACON)
	var evolved_beacon := BoomSkillEffects.get_effect(BoomSkillEffects.LAMP_SOUL_BEACON, true)
	host._check(
		(
			int(normal_beacon["projectiles"]) == 12
			and int(evolved_beacon["projectiles"]) == 18
			and float(normal_beacon["arc_deg"]) == 360.0
			and float(normal_beacon["range"]) == 8.0
		),
		"魂灯结界参数完整：12→18 枚、360°、8m"
	)
	var normal_wave := BoomSkillEffects.get_effect(BoomSkillEffects.BRUSH_INK_WAVE)
	var evolved_wave := BoomSkillEffects.get_effect(BoomSkillEffects.BRUSH_INK_WAVE, true)
	host._check(
		(
			float(normal_wave["arc_deg"]) == 100.0
			and float(normal_wave["range"]) == 5.0
			and int(normal_wave["max_targets"]) == 8
			and is_equal_approx(float(normal_wave["damage_mult"]), 1.8)
		),
		"泼墨锋参数完整：100°/5m/8目标/×1.8"
	)
	host._check(
		(
			float(evolved_wave["arc_deg"]) == 130.0
			and float(evolved_wave["range"]) == 6.0
			and int(evolved_wave["max_targets"]) == 12
			and is_equal_approx(float(evolved_wave["damage_mult"]), 2.4)
		),
		"进化泼墨锋参数完整：130°/6m/12目标/×2.4"
	)
	var normal_domain := BoomSkillEffects.get_effect(BoomSkillEffects.BRUSH_SEAL_DOMAIN)
	var evolved_domain := BoomSkillEffects.get_effect(BoomSkillEffects.BRUSH_SEAL_DOMAIN, true)
	host._check(
		(
			float(normal_domain["range"]) == 4.5
			and int(normal_domain["max_targets"]) == 16
			and is_equal_approx(float(normal_domain["damage_mult"]), 2.5)
			and float(evolved_domain["range"]) == 5.5
			and int(evolved_domain["max_targets"]) == 24
			and is_equal_approx(float(evolved_domain["damage_mult"]), 3.2)
		),
		"朱砂封域参数完整：4.5→5.5m、16→24目标、×2.5→×3.2"
	)
	var ctx := _new_skill_game("bubble")
	var game := ctx[0] as BoomGame
	var system := ctx[1] as BoomSkillSystem
	var fx := BoomSkillFx.new()
	host.root.add_child(fx)
	var presenter := BoomSkillPresenter.new()
	host.root.add_child(presenter)
	presenter.setup(game, system, fx, null, null, Callable(), Callable())
	presenter.present(BoomSkillEffects.LAMP_FIREFLY_VOLLEY, 5)
	var state := presenter.debug_state()
	var fx_state := fx.debug_state()
	host._check(
		(
			state["presentation"] == "firefly_fan"
			and fx_state["shape"] == "sector"
			and float(fx_state["arc_deg"]) == 30.0
		),
		"流萤散射使用 30° 琥珀扇面表现"
	)
	presenter.present(BoomSkillEffects.LAMP_SOUL_BEACON, 12)
	state = presenter.debug_state()
	fx_state = fx.debug_state()
	host._check(
		(
			state["presentation"] == "soul_beacon_ring"
			and fx_state["shape"] == "ring"
			and float(fx_state["radius"]) == 8.0
		),
		"魂灯结界使用 8m 全向灯阵表现"
	)
	presenter.present(BoomSkillEffects.BRUSH_INK_WAVE, [])
	state = presenter.debug_state()
	fx_state = fx.debug_state()
	host._check(
		(
			state["presentation"] == "ink_wave_sector"
			and fx_state["shape"] == "sector"
			and float(fx_state["arc_deg"]) == 100.0
			and float(fx_state["radius"]) == 5.0
		),
		"泼墨锋使用与判定一致的 100°/5m 墨浪扇面"
	)
	presenter.present(BoomSkillEffects.BRUSH_SEAL_DOMAIN, [])
	state = presenter.debug_state()
	fx_state = fx.debug_state()
	host._check(
		(
			state["presentation"] == "cinnabar_seal_domain"
			and fx_state["shape"] == "ring"
			and float(fx_state["radius"]) == 4.5
		),
		"朱砂封域使用与判定一致的 4.5m 朱砂圆域"
	)
	host.root.remove_child(presenter)
	presenter.free()
	host.root.remove_child(fx)
	fx.free()
	game.free()
	BoomSave.test_reset()
