class_name BoomPlayTestM11
extends RefCounted
## M11 首领战与首领奖励无头断言。

const DT: float = 1.0 / 60.0

var host


func _init(p_host) -> void:
	host = p_host


func run_all() -> void:
	print("[m11-boss]")
	_test_boss_wave_and_phases()
	_test_boss_attacks()
	_test_boss_reward_flow()
	_test_boss_ui_and_hook()


func _test_boss_wave_and_phases() -> void:
	var game: BoomGame = host._new_game()
	game.wave = 10
	game.auto_spawn = false
	var spawned: Array[BoomBoss] = []
	game.boss_spawned.connect(func(value: BoomBoss) -> void: spawned.append(value))
	game.begin_match()
	host._check(
		BoomBossSystem.is_boss_wave(game, 10) and BoomBossSystem.is_boss_wave(game, 20),
		"每 10 波进入 Boss 波"
	)
	host._check(not BoomBossSystem.is_boss_wave(game, 9), "普通波不误判为 Boss 波")
	host._check(spawned.size() == 1 and BoomBossSystem.is_active(game), "W10 生成唯一提灯无常")
	var boss: BoomBoss = game.boss
	host._check(boss.max_hp == 1200 and boss.hp == 1200, "首个 Boss 独立基础生命 1200")
	host._check(boss.contact_damage == 12, "首个 Boss 独立攻击 12")
	host._check(game._quota_current == 0, "Boss 波不读取普通怪物配额")
	game.step(3.0)
	host._check(game.wave == 10 and not game._between_waves, "Boss 存活时波次不推进")
	var phase_events: Array[int] = []
	boss.boss_phase_changed.connect(func(value: int) -> void: phase_events.append(value))
	boss.take_damage(481, Vector3.ZERO)
	host._check(boss.boss_phase == 2, "生命降至 60% 以下进入阶段 2")
	boss.take_damage(360, Vector3.ZERO)
	host._check(boss.boss_phase == 3, "生命降至 30% 以下进入阶段 3")
	host._check(phase_events == [2, 3], "阶段变化各广播一次")
	(
		host
		. _check(
			(
				boss._phase_pattern()
				== [
					BoomBoss.ATTACK_GHOSTFIRE,
					BoomBoss.ATTACK_LANTERN_ARRAY,
					BoomBoss.ATTACK_DASH,
					BoomBoss.ATTACK_GHOSTFIRE,
				]
			),
			"阶段 3 使用高压复合攻击序列而非仅提升数值"
		)
	)
	var later := BoomBoss.new(3)
	host._check(later.max_hp == 2400 and later.contact_damage == 16, "Boss 成长独立按遭遇次数计算")
	later.free()
	game.free()


func _test_boss_attacks() -> void:
	var game: BoomGame = host._new_game()
	game.wave = 10
	game.auto_spawn = false
	game.begin_match()
	var boss: BoomBoss = game.boss
	var telegraphs: Array[String] = []
	game.boss_attack_telegraphed.connect(
		func(kind: String, _duration: float) -> void: telegraphs.append(kind)
	)
	boss._attack_cooldown = 0.0
	boss.physics_update(DT, game.player.position, game.enemies, 9.4, 26.4)
	host._check(boss.current_attack == BoomBoss.ATTACK_GHOSTFIRE, "阶段 1 首招为扇形鬼火")
	host._check(boss.telegraph_left > 0.0 and telegraphs.size() == 1, "鬼火攻击有明确前摇预警")
	boss.physics_update(0.7, game.player.position, game.enemies, 9.4, 26.4)
	var active_projectiles := 0
	for entry in game.boss_projectiles:
		if (entry as BoomBossProjectile).active:
			active_projectiles += 1
	host._check(active_projectiles == 5, "阶段 1 扇形鬼火释放 5 枚池化弹体")
	boss.boss_state = BoomBoss.BossState.IDLE
	boss._attack_cooldown = 0.0
	boss.physics_update(DT, game.player.position, game.enemies, 9.4, 26.4)
	host._check(boss.current_attack == BoomBoss.ATTACK_DASH, "阶段 1 次招为锁魂冲撞")
	host._check(boss.telegraph_left > 0.0, "冲撞先显示方向预警")
	boss.hp = int(float(boss.max_hp) * 0.5)
	boss.boss_phase = 2
	boss.boss_state = BoomBoss.BossState.IDLE
	boss._pattern_index = 2
	boss._attack_cooldown = 0.0
	boss.physics_update(DT, game.player.position, game.enemies, 9.4, 26.4)
	host._check(boss.current_attack == BoomBoss.ATTACK_LANTERN_ARRAY, "阶段 2 加入百鬼灯阵")
	var summoned: int = BoomBossSystem.summon_adds(game, 6)
	host._check(summoned == 6 and game.enemies.size() == 7, "灯阵召唤少量杂兵且含 Boss 共 7 个单位")
	var all_paper := true
	for entry in game.enemies:
		if entry != boss and (entry as BoomJelly)._is_mist_spirit:
			all_paper = false
	host._check(all_paper, "灯阵杂兵固定为纸偶")
	host._check(BoomBossSystem.summon_adds(game, 2) == 0, "灯阵杂兵受 6 只硬上限约束")
	game.player.hp = game.player.max_hp
	game.player.invuln_left = 0.0
	game.wave = 99
	game._damage_player_raw(boss.contact_damage, boss.position)
	host._check(game.player.hp == game.player.max_hp - 12, "Boss 伤害不读取普通波次攻击曲线")
	game.free()


func _test_boss_reward_flow() -> void:
	BoomSave.test_reset()
	var game: BoomGame = host._new_game()
	game.wave = 10
	game.auto_spawn = false
	game.begin_match()
	var boss: BoomBoss = game.boss
	var cleared: Array = []
	game.wave_cleared.connect(func(w: int, bonus: int) -> void: cleared.append([w, bonus]))
	boss.take_damage(boss.max_hp, Vector3.ZERO)
	game._finalize_kill(boss)
	host._check(game.boss_reward_pending and not BoomBossSystem.is_active(game), "Boss 死亡后进入奖励等待态")
	host._check(game.boss_chest != null, "Boss 死亡点生成首领宝箱")
	host._check(cleared.is_empty() and game.wave == 10, "选择奖励前 Boss 波不结算")
	var skills := BoomSkillSystem.new()
	skills.game = game
	skills.set_weapon_tree("bubble")
	var choices := BoomBossRewards.build_choices(skills, 1)
	host._check(choices.size() == 3, "首领宝箱固定三选一")
	(
		host
		. _check(
			(
				[choices[0]["type"], choices[1]["type"], choices[2]["type"]]
				== [
					BoomBossRewards.TYPE_UNLOCK,
					BoomBossRewards.TYPE_EVOLVE,
					BoomBossRewards.TYPE_RARE,
				]
			),
			"奖励覆盖免费节点/主动进化/稀有属性"
		)
	)
	var unlock_id := String(choices[0]["target"])
	host._check(BoomBossRewards.apply(choices[0], game, skills), "免费节点奖励可应用")
	host._check(skills.is_unlocked(unlock_id), "免费节点不消费金币并完成解锁")
	var evolve_id := String(choices[1]["target"])
	host._check(BoomBossRewards.apply(choices[1], game, skills), "主动技能进化奖励可应用")
	host._check(skills._is_evolved(evolve_id), "主动技能记录为本局进化")
	var evolved_count: int = int(skills._dispatch_cast(evolve_id))
	host._check(evolved_count == 7, "流萤散射进化形态释放 7 枚灵印")
	host._check(BoomBossRewards.apply(choices[2], game, skills), "稀有属性奖励可应用")
	host._check(game.stats.defense == 15, "首个首领稀有奖励提供防御 +15")
	host._check(BoomBossSystem.complete_reward(game, String(choices[0]["type"])), "选择后完成 Boss 波")
	host._check(cleared.size() == 1 and game._between_waves, "奖励后结算并进入波间歇")
	skills.free()
	game.free()
	BoomSave.test_reset()


func _test_boss_ui_and_hook() -> void:
	var panel := BoomBossRewardPanel.new()
	panel.size = Vector2(720, 1280)
	var skills := BoomSkillSystem.new()
	var game: BoomGame = host._new_game()
	skills.game = game
	skills.set_weapon_tree("bubble")
	var choices := BoomBossRewards.build_choices(skills, 1)
	var selected: Array[Dictionary] = []
	panel.reward_chosen.connect(func(choice: Dictionary) -> void: selected.append(choice))
	panel.open_with(choices)
	host._check(panel.visible and panel.current_choices().size() == 3, "首领奖励 UI 渲染三张卡")
	host._check(panel.process_mode == Node.PROCESS_MODE_ALWAYS, "奖励 UI 在暂停时仍可操作")
	panel.choose(1)
	host._check(
		selected.size() == 1 and selected[0]["type"] == BoomBossRewards.TYPE_EVOLVE, "奖励卡点击映射正确"
	)
	var state: Dictionary = host._main.call("_test_hook_get_state")
	var hook_keys := [
		"boss_active",
		"boss_hp",
		"boss_max_hp",
		"boss_phase",
		"boss_attack",
		"boss_telegraph",
		"boss_reward_pending",
		"boss_reward_choices",
	]
	var has_all := true
	for key in hook_keys:
		if not state.has(key):
			has_all = false
	host._check(has_all, "test_hook 暴露完整 Boss 状态与奖励选项")
	host._check(ResourceLoader.exists(BoomBoss.ART_PATH), "提灯无常 2D 素材可加载")
	host._check(ResourceLoader.exists(BoomBossChest.ART_PATH), "首领宝箱 2D 素材可加载")
	panel.free()
	skills.free()
	game.free()
