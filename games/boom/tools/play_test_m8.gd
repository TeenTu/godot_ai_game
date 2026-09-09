extends RefCounted

## M8 无头自检分册（design_m8_attributes.md）：
##   [m8-stats]      属性容器：固定数额成长、暴击/闪避/减伤上限、restart 清零
##   [m8-attack]     统一输出结算：base_attack→final_attack、普攻间隔攻速化、
##                   快照数值来自实际结算函数
##   [m8-intake]     统一受伤结算：波次攻击成长、闪避免伤、防御减伤、无敌帧语义
##   [m8-crit]       暴击结算：暴伤倍率、逐目标独立判定（chain/nuke/弧斩）
##   [m8-levelup]    升级卡消费：KIND 扩容、回灯一次性效果、restart 清零
##   [m8-levelup-ui] 三选一升级卡面板：3 张不重复、满血不出回灯、选择回调
##   [m8-statspanel] 属性查看面板：数值与快照一致、打开暂停/关闭恢复
##
## host = play_test.gd（SceneTree）：复用其 _check/_new_game/_run/_active_bullets/_main。

const DT: float = 1.0 / 60.0
const MAX_FRAMES: int = 1200

var host


func _init(p_host) -> void:
	host = p_host


func run_all() -> void:
	test_stats()
	test_attack()
	test_intake()
	test_crit()
	test_levelup()
	test_levelup_ui()
	test_stats_panel()
	test_motion()


# ------------------------------------------------------------------ 属性容器


func test_stats() -> void:
	print("[m8-stats]")
	var s := BoomStats.new()
	# 初始全零：无暴击、基础爆伤 150%、无闪避/减伤/急速。
	host._check(s.crit_rate() == 0.0 and s.dodge_rate() == 0.0, "初始暴击率/闪避率 = 0")
	host._check(is_equal_approx(s.crit_dmg_mult(), 1.5), "基础暴击伤害 150%")
	host._check(s.mitigation() == 0.0 and s.defense == 0, "初始防御 0 → 减伤 0")
	host._check(s.dmg_mult() == 1.0 and s.aspd_mult() == 1.0 and s.haste_mult() == 1.0, "初始倍率全 1")
	# 固定数额成长（§3.1）：每次 +3pp 暴击率 / +15pp 爆伤 / +3pp 闪避。
	s.apply(BoomStats.KIND_CRIT)
	s.apply(BoomStats.KIND_CRIT)
	host._check(is_equal_approx(s.crit_rate(), 0.06), "暴击率 +3pp×2 = 6%")
	s.apply(BoomStats.KIND_CRIT_DMG)
	host._check(is_equal_approx(s.crit_dmg_mult(), 1.65), "暴伤 +15pp = 165%")
	s.apply(BoomStats.KIND_DODGE)
	host._check(is_equal_approx(s.dodge_rate(), 0.03), "闪避 +3pp = 3%")
	s.apply(BoomStats.KIND_DMG)
	s.apply(BoomStats.KIND_DMG)
	host._check(is_equal_approx(s.dmg_mult(), 1.2), "伤害 +10%×2 → ×1.20")
	s.apply(BoomStats.KIND_ASPD)
	host._check(is_equal_approx(s.aspd_mult(), 1.1), "攻速 +10% → ×1.10")
	s.apply(BoomStats.KIND_HASTE)
	host._check(is_equal_approx(s.haste_mult(), 1.08), "急速 +8% → ×1.08")
	s.apply(BoomStats.KIND_SPEED)
	host._check(is_equal_approx(s.move_mult(), 1.08), "移速 +8% → ×1.08")
	# 闪避上限 20%（§8）：34 档 ×3pp = 102% → 封顶。
	s.dodge_stacks = 34
	host._check(is_equal_approx(s.dodge_rate(), BoomStats.DODGE_CAP), "闪避封顶 20%")
	# 减伤公式（§7.2）查表：0→0 / 10→9.1% / 70+→40% 封顶。
	host._check(BoomStats.mitigation_for(0) == 0.0, "防御 0 → 减伤 0")
	host._check(absf(BoomStats.mitigation_for(10) - 0.0909) < 0.001, "防御 10 → 减伤 9.1%")
	host._check(absf(BoomStats.mitigation_for(50) - 0.3333) < 0.001, "防御 50 → 减伤 33.3%")
	host._check(BoomStats.mitigation_for(70) == BoomStats.MITIGATION_CAP, "防御 70 → 减伤 40% 封顶")
	host._check(BoomStats.mitigation_for(200) == BoomStats.MITIGATION_CAP, "防御 200 → 40% 封顶")
	# KIND_HEAL 不进堆叠；未知 kind 拒绝。
	host._check(s.apply(BoomStats.KIND_HEAL), "heal 视为合法 kind")
	host._check(s.stacks(BoomStats.KIND_HEAL) == 0, "heal 不产生堆叠")
	host._check(not s.apply("nope"), "未知升级种类拒绝")
	# restart 清零（随对局重置）。
	s.reset()
	host._check(s.total_stacks() == 0 and s.defense == 0, "reset 清空全部属性")


# ------------------------------------------------------------------ 统一输出


func test_attack() -> void:
	print("[m8-attack]")
	var g: BoomGame = host._new_game()
	# base_attack → final_attack（§5.1/§5.2）：泡泡 10，floor(10×1.2)=12。
	host._check(g._base_attack() == 10, "泡泡基础攻击力 = 10")
	host._check(g._final_attack() == 10, "零加成最终攻击力 = 10")
	g.stats.dmg_stacks = 2
	host._check(g._final_attack() == 12, "伤害 +10%×2 → floor(10×1.20) = 12")
	g.stats.dmg_stacks = 0
	g.set_weapon("greatsword")
	host._check(g._base_attack() == 30, "大剑基础攻击力 = 30")
	host._check(g._final_attack() == 30, "大剑零加成最终攻击力 = 30")
	# 普攻间隔（§3.1）：fire_cd ÷ 攻速倍率 ÷ rapid 被动。
	g.set_weapon("bubble")
	host._check(absf(g._fire_interval() - 0.22) < 0.0001, "初始普攻间隔 = 0.22s")
	g.stats.aspd_stacks = 2
	g.skill_fire_cd_mult = BoomSkillSystem.RAPID_FIRE_MULT
	host._check(absf(g._fire_interval() - 0.22 * 0.8 / 1.2) < 0.0001, "rapid ×0.8 与攻速 ÷1.2 叠加")
	g.skill_fire_cd_mult = 1.0
	host._check(absf(g._fire_interval() - 0.22 / 1.2) < 0.0001, "攻速 ×1.2 → 间隔 ÷1.2")
	# 快照全部来自实际结算函数（§12.3）。
	var snap: Dictionary = g.stats_snapshot()
	host._check(int(snap["base_attack"]) == 10 and int(snap["final_attack"]) == 10, "快照攻 = 10/10")
	host._check(absf(float(snap["attack_speed"]) - 1.0 / (0.22 / 1.2)) < 0.01, "快照攻速来自实际间隔")
	host._check(int(snap["crit_dmg_pct"]) == 150, "快照暴伤 150%")
	host._check(int(snap["max_hp"]) == 50 and int(snap["hp"]) == 50, "快照生命 50/50")
	host._check(absf(float(snap["move_speed"]) - 5.4) < 0.01, "快照移速 = 5.4")
	g.free()


# ------------------------------------------------------------------ 统一受伤


func test_intake() -> void:
	print("[m8-intake]")
	# 波次攻击成长（§10.2）：8/8/9/10/11/12，封顶 4 档。
	host._check(BoomCombatMath.enemy_raw_attack(1) == 8, "W1 原始接触伤害 = 8")
	host._check(BoomCombatMath.enemy_raw_attack(4) == 8, "W4 原始接触伤害 = 8")
	host._check(BoomCombatMath.enemy_raw_attack(5) == 9, "W5 原始接触伤害 = 9")
	host._check(BoomCombatMath.enemy_raw_attack(10) == 10, "W10 原始接触伤害 = 10")
	host._check(BoomCombatMath.enemy_raw_attack(15) == 11, "W15 原始接触伤害 = 11")
	host._check(BoomCombatMath.enemy_raw_attack(20) == 12, "W20 原始接触伤害 = 12")
	host._check(BoomCombatMath.enemy_raw_attack(99) == 12, "W99 攻击加成封顶 = 12")
	# 受伤结算纯函数（§10.3）：闪避 / 减伤 / 保底 1。
	var r: Array = BoomCombatMath.resolve_player_damage(8, 1.0, 0)
	host._check(int(r[0]) == 0 and bool(r[1]), "闪避成功 → 0 伤")
	r = BoomCombatMath.resolve_player_damage(8, 0.0, 0)
	host._check(int(r[0]) == 8 and not bool(r[1]), "无防御 → 全额 8 伤")
	r = BoomCombatMath.resolve_player_damage(8, 0.0, 10)
	host._check(int(r[0]) == 7, "防御 10 → floor(8×0.909) = 7")
	r = BoomCombatMath.resolve_player_damage(8, 0.0, 100)
	host._check(int(r[0]) == 4, "防御 100 → 40% 封顶 → 4")
	r = BoomCombatMath.resolve_player_damage(0, 0.0, 0)
	host._check(int(r[0]) >= 1, "保底至少 1 伤")
	# 对局集成：W1 接触命中 → 扣 8 血 + 进无敌帧。
	var g: BoomGame = host._new_game()
	var damaged_box: Array = [0]
	g.player_damaged.connect(func(_a: int, _p: Vector3) -> void: damaged_box[0] += 1)
	g.spawn_enemy_at(Vector3(0.3, 0.0, 0.0))
	g.step(DT)
	host._check(
		g.player.hp == 50 - BoomCombatMath.enemy_raw_attack(1), "接触受击扣 8 血 (hp=%d)" % g.player.hp
	)
	host._check(g.player.invuln_left > 0.0, "受击进入无敌帧")
	host._check(damaged_box[0] == 1, "player_damaged 广播 1 次")
	g.free()
	# 闪避集成（§8）：0.2 闪避率反复受击 → 免伤分支不扣血、不进无敌帧。
	var g2: BoomGame = host._new_game()
	seed(20260902)
	g2.stats.dodge_stacks = 34  # 20% 封顶
	var dodge_box: Array = [0]
	g2.player_dodged.connect(func(_p: Vector3) -> void: dodge_box[0] += 1)
	var hit_count := 0
	var dodge_seen := false
	for i in 60:
		g2.player.invuln_left = 0.0
		var hp_before: int = g2.player.hp
		var invuln_before: float = g2.player.invuln_left
		g2._damage_player(Vector3.ZERO)
		if g2.player.hp == hp_before:
			# 免伤分支：无受击反馈（无敌帧未置位）。
			host._check(is_equal_approx(g2.player.invuln_left, invuln_before), "闪避不进无敌帧")
			dodge_seen = true
		else:
			hit_count += 1
			host._check(g2.player.hp == hp_before - BoomCombatMath.enemy_raw_attack(1), "未闪避全额扣 8")
	host._check(dodge_box[0] > 0 and dodge_seen, "0.2 闪避率出现免伤分支 (n=%d)" % dodge_box[0])
	host._check(hit_count > 0, "未闪避分支仍存在 (n=%d)" % hit_count)
	host._check(g2.player.hp == 50 - hit_count * BoomCombatMath.enemy_raw_attack(1), "总扣血与命中数一致")
	g2.free()


# ------------------------------------------------------------------ 暴击


func test_crit() -> void:
	print("[m8-crit]")
	seed(20260902)
	var g: BoomGame = host._new_game()
	# 暴击率 0：永不暴击。
	var roll: Array = g._roll_attack(10)
	host._check(int(roll[0]) == 10 and not bool(roll[1]), "0% 暴击率不暴击")
	# 强制必暴：暴伤 = floor(最终攻击力 × 1.5)（§6.2/§6.3）。
	g.stats.crit_stacks = 34
	roll = g._roll_attack(10)
	host._check(int(roll[0]) == 15 and bool(roll[1]), "必暴 → floor(10×1.5) = 15")
	g.stats.crit_dmg_stacks = 2
	roll = g._roll_attack(10)
	host._check(int(roll[0]) == 18, "爆伤 +15pp×2 → floor(10×1.8) = 18")
	# 逐目标独立判定（§6.3）：chain 每跳独立。
	g.stats.crit_stacks = 0
	g.stats.crit_dmg_stacks = 0
	g.stats.dmg_stacks = 1  # 最终攻击力 = floor(10×1.1) = 11
	g.player.invuln_left = 10.0
	var a := g.spawn_enemy_at(Vector3(0.0, 0.0, -3.0))
	var b := g.spawn_enemy_at(Vector3(0.0, 0.0, -7.0))
	var c := g.spawn_enemy_at(Vector3(0.0, 0.0, -11.0))
	var hit_events: Array = []
	g.enemy_hit.connect(
		func(_p: Vector3, dmg: int, crit: bool) -> void: hit_events.append([dmg, crit])
	)
	g.cast_chain_arc()
	host._check(hit_events.size() == 3, "chain 3 跳各发 1 次 enemy_hit (n=%d)" % hit_events.size())
	var no_crit_dmg_ok := true
	for ev in hit_events:
		var dmg: int = ev[0]
		# 无暴击档每跳 = round(11×0.7^k) → 11/8/5；暴击档 = floor(每跳×1.5) → 16/12/7。
		if not (dmg == 11 or dmg == 8 or dmg == 5 or dmg == 16 or dmg == 12 or dmg == 7):
			no_crit_dmg_ok = false
	host._check(no_crit_dmg_ok, "chain 每跳伤害符合衰减×暴伤档位")
	host._check(not a.is_dead() and not b.is_dead() and not c.is_dead(), "chain 三敌存活（非秒杀）")
	# nuke 每目标独立判定：范围内 3 敌（a 距 3m 也在半径内）各受 floor(11×4)=44 → 秒杀。
	var n1 := g.spawn_enemy_at(Vector3(2.0, 0.0, 0.0))
	var n2 := g.spawn_enemy_at(Vector3(-2.0, 0.0, 0.0))
	var nuke_events: Array = [0]
	g.enemy_hit.connect(
		func(_p: Vector3, dmg: int, _c: bool) -> void:
			if dmg >= 40:
				nuke_events[0] += 1
	)
	g.cast_aoe_nuke()
	host._check(n1.is_dead() and n2.is_dead(), "nuke 两目标均被 44 伤秒杀")
	host._check(nuke_events[0] == 3, "nuke 每目标独立 enemy_hit（含半径内 a，n=3）")
	g.free()


# ------------------------------------------------------------------ 升级卡消费


func test_levelup() -> void:
	print("[m8-levelup]")
	var g: BoomGame = host._new_game()
	host._check(not g.apply_level_upgrade(BoomStats.KIND_DMG), "无升级点拒绝消费")
	g.pending_upgrades = 3
	host._check(g.apply_level_upgrade(BoomStats.KIND_CRIT), "消费暴击率卡")
	host._check(g.stats.crit_stacks == 1, "暴击率堆叠 +1")
	host._check(g.apply_level_upgrade(BoomStats.KIND_CRIT_DMG), "消费暴伤卡")
	host._check(is_equal_approx(g.stats.crit_dmg_mult(), 1.65), "重复获得直接相加 → 165%")
	host._check(g.apply_level_upgrade(BoomStats.KIND_SPEED), "消费移速卡")
	host._check(absf(g.player.move_speed - 5.4 * 1.08) < 0.001, "移速升级落地 ×1.08")
	host._check(not g.apply_level_upgrade(BoomStats.KIND_DMG), "点数耗尽拒绝")
	host._check(g.stats.total_stacks() == 3, "总档数 = 3（heal 不计）")
	# 回灯（§4.2）：一次性回满，不增上限、不进堆叠。
	g.pending_upgrades = 1
	g.player.hp = 17
	host._check(g.apply_level_upgrade(BoomStats.KIND_HEAL), "消费回灯卡")
	host._check(g.player.hp == 50 and g.player.max_hp == 50, "回灯后满血且上限不变")
	host._check(g.stats.total_stacks() == 3, "回灯不进堆叠")
	# restart 清空成长状态。
	g.restart()
	host._check(g.stats.total_stacks() == 0 and g.pending_upgrades == 0, "restart 清空成长状态")
	host._check(g.player.max_hp == 50, "restart 机体回默认 50")
	g.free()


# ------------------------------------------------------------------ 升级卡面板


func test_levelup_ui() -> void:
	print("[m8-levelup-ui]")
	var panel := BoomLevelUpPanel.new()
	root_add(panel)
	seed(20260902)
	# 满血：卡池无 heal；3 张不重复（§4.2/§11.3）。
	for i in 20:
		panel.open_with(1.0)
		var kinds := panel.current_kinds()
		host._check(kinds.size() == BoomLevelUpPanel.CARD_COUNT, "每轮 3 张卡")
		var distinct := {}
		var no_heal := true
		for k in kinds:
			distinct[k] = true
			if k == BoomStats.KIND_HEAL:
				no_heal = false
		host._check(distinct.size() == 3, "3 张卡不重复")
		host._check(no_heal, "满血不出回灯卡")
	# 受伤：卡池含 heal（多轮抽样必出现）。
	var seen_heal := false
	for i in 40:
		panel.open_with(0.5)
		if panel.current_kinds().has(BoomStats.KIND_HEAL):
			seen_heal = true
	host._check(seen_heal, "受伤时回灯卡可入池")
	# 选择回调：本轮未展示的 kind 拒绝（满血重开一轮，保证 heal 不在池内）。
	var chosen: Array = [""]
	panel.card_chosen.connect(func(k: String) -> void: chosen[0] = k)
	panel.open_with(1.0)
	var kinds := panel.current_kinds()
	panel.choose("heal")
	host._check(chosen[0] == "", "未展示的 kind 不触发选择")
	panel.choose(kinds[0])
	host._check(chosen[0] == kinds[0], "点卡触发 card_chosen(kind)")
	panel.free()


# ------------------------------------------------------------------ 属性面板


func test_stats_panel() -> void:
	print("[m8-statspanel]")
	var g: BoomGame = host._new_game()
	g.stats.dmg_stacks = 2  # 最终攻击力 12
	g.player.hp = 42
	var panel := BoomStatsPanel.new()
	panel.provider = g.stats_snapshot
	root_add(panel)
	panel.open()
	host._check(panel.visible, "面板可打开")
	# 数值必须与实际战斗快照一致（§12.3/§14）。
	var labels: Dictionary = panel.get("_value_labels")
	host._check((labels["base_attack"] as Label).text == "10", "面板基础攻击力 = 10")
	host._check((labels["final_attack"] as Label).text == "12", "面板最终攻击力 = 12（同源快照）")
	host._check((labels["hp"] as Label).text == "42 / 50", "面板 HP = 42 / 50")
	host._check((labels["crit_dmg_pct"] as Label).text == "150%", "面板暴伤 150%")
	host._check((labels["dodge_pct"] as Label).text == "0%", "面板闪避 0%")
	# 血条比例填充：42/50 ≈ 84%。
	var fill: ColorRect = panel.get("_hp_fill")
	host._check(absf(fill.size.x - 556.0 * 0.84) < 1.0, "面板血条按比例填充")
	var closed_box: Array = [0]
	panel.closed.connect(func() -> void: closed_box[0] += 1)
	panel.close()
	host._check(not panel.visible and closed_box[0] == 1, "关闭面板发 closed 信号")
	panel.free()
	g.free()
	# main 层：打开属性面板 → 树暂停；关闭 → 恢复（§12.2）。
	var m: Node = host._main
	var sim: BoomGame = m.get("sim")
	if sim == null or not sim.match_started or sim.is_over:
		print("  skip: main 对局未开战，跳过暂停断言")
		return
	m.call("_open_stats_panel")
	host._check(m.get_tree().paused, "属性面板打开时 SceneTree.paused = true")
	host._check((m.get("_stats_panel") as Control).visible, "属性面板已显示")
	m.call("_on_stats_panel_closed")
	host._check(not m.get_tree().paused, "关闭面板后战斗恢复")


# ------------------------------------------------------------------ 动作连续性


## [m8-motion] 真实战斗状态机驱动的动作连续性：命中落在视觉出手阶段、
## 攻速强化保持阶段同步、受击不被普攻立即覆盖、挥击中切枪复位干净。
func test_motion() -> void:
	print("[m8-motion]")
	seed(20260902)
	# --- 命中时机：前摇零命中，恰好 1 次命中发生在 ACTIVE，swing 逐帧与 FSM 同步。
	var g: BoomGame = host._new_game()
	g.set_weapon("greatsword")
	g.player.invuln_left = 10.0  # 屏蔽接触伤害，专注挥击 FSM
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -2.7))
	var hit_states: Array = []
	g.enemy_hit.connect(
		func(_p: Vector3, _d: int, _c: bool) -> void: hit_states.append(g._swing_state)
	)
	var anim = g.player.get("_anim")
	var saw_windup := false
	var saw_active := false
	var saw_recover := false
	var vis_ok := true
	var windup_steps: int = 0
	for i in 300:
		g.step(DT)
		var st: int = g._swing_state
		if st == g.SwingState.WINDUP:
			saw_windup = true
			windup_steps += 1
		elif st == g.SwingState.ACTIVE:
			saw_active = true
		elif st == g.SwingState.RECOVER:
			saw_recover = true
		if anim != null and anim.animation == "swing":
			var f: int = anim.frame
			if st == g.SwingState.WINDUP and f > 1:
				vis_ok = false
			elif st == g.SwingState.ACTIVE and f != 2:
				vis_ok = false
			elif st == g.SwingState.RECOVER and f < 3:
				vis_ok = false
		if st == g.SwingState.NONE and saw_active and saw_recover:
			break
	host._check(saw_windup and saw_active and saw_recover, "挥击 FSM 三阶段全部出现")
	host._check(vis_ok, "swing 逐帧与 FSM 阶段同步（前摇 0-1 / 出手 2 / 收招 3-4）")
	host._check(
		hit_states.size() == 1 and int(hit_states[0]) == g.SwingState.ACTIVE,
		"命中恰好 1 次且落在 ACTIVE 窗口 (n=%d)" % hit_states.size()
	)
	host._check(jelly.is_dead(), "弧斩命中击杀 W1 目标")
	g.free()
	# --- 攻速强化：前摇按攻速缩短，命中仍在 ACTIVE 边界出手。
	var g2: BoomGame = host._new_game()
	g2.set_weapon("greatsword")
	g2.player.invuln_left = 10.0
	g2.stats.aspd_stacks = 2  # 攻速 ×1.2 → 前摇 0.32/1.2 ≈ 0.267s
	g2.spawn_enemy_at(Vector3(0.0, 0.0, -2.7))
	var hit2: Array = []
	g2.enemy_hit.connect(func(_p: Vector3, _d: int, _c: bool) -> void: hit2.append(g2._swing_state))
	var windup_steps2: int = 0
	for i in 300:
		g2.step(DT)
		if g2._swing_state == g2.SwingState.WINDUP:
			windup_steps2 += 1
		if hit2.size() > 0:
			break
	host._check(
		windup_steps2 > 0 and windup_steps2 < windup_steps,
		"攻速 ×1.2 前摇步数缩短 (%d → %d)" % [windup_steps, windup_steps2]
	)
	host._check(hit2.size() == 1 and int(hit2[0]) == g2.SwingState.ACTIVE, "攻速强化下命中仍落在 ACTIVE")
	g2.free()
	# --- 受击不被普攻立即覆盖：hurt 播放后下一逻辑帧仍保持 hurt。
	var g3: BoomGame = host._new_game()
	g3.set_weapon("greatsword")
	g3.spawn_enemy_at(Vector3(0.0, 0.0, -2.7))
	var anim3 = g3.player.get("_anim")
	host._check(anim3 != null, "玩家 2D 动画层已构建")
	var entered := false
	for i in 60:
		g3.step(DT)
		if g3._swing_state == g3.SwingState.WINDUP:
			entered = true
			break
	host._check(entered, "敌人进入挥程 → 前摇已启动")
	g3.player.invuln_left = 0.0
	var hp3: int = g3.player.hp
	g3._damage_player(Vector3.ZERO)
	host._check(g3.player.hp < hp3, "前摇中受击扣血")
	if anim3 != null:
		host._check(anim3.animation == "hurt", "受击切换 hurt 动画")
		g3.step(DT)
		host._check(anim3.animation == "hurt", "下一逻辑帧 hurt 未被挥击帧覆盖")
	# --- 挥击中切枪：FSM 复位 + 视觉层重建无残留。
	g3.set_weapon("bubble")
	host._check(g3._swing_state == g3.SwingState.NONE, "切枪复位挥击 FSM")
	host._check(
		g3.player.anim_form == "bubble" and g3.player.visual_id == "night_ruler",
		"切枪后形态/视觉配置回归 bubble/night_ruler"
	)
	if anim3 != null:
		host._check(anim3.animation != "swing", "swing 动画无滞留")
	host._check(g3.player.get("_weapon_anim") != null, "武器视觉层已按新配置重建")
	g3.free()


## 兼容 m7 分册风格：把节点挂到 SceneTree root（测试后由调用方 free）。
func root_add(node: Node) -> void:
	host.root.add_child(node)
