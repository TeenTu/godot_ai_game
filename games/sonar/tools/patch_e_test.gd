extends SceneTree
## patch_e_test.gd — 评审 Patch E 无头验收（P1-01/P1-03/P0-08/P2-01）。
##
## 覆盖：
##   PE-01  P1-01 命令拒绝具体原因（WIRE CUT / LAUNCHING / NO CANDIDATE）
##          + 五正交状态逐帧呈现（Recv/TX/Trk/Auth/Steer）。
##   PE-02  P1-03 武器卡生命周期：_rebuild 保留 header；无候选 Accept 禁用；
##          事件日志一行一事件（不用 " | " 拼接）；真实事件名映射。
##   PE-03  P0-08 combat scenario：s1_combat.json 装配 enemy_spawn/doctrine/
##          countermeasures；UI 同配置（auto_measurements=false）端到端可跑。
##   PE-04  P2-01 搜索扫掠连续初始化：进入 SEARCH 时从当前航向开始，
##          不跳到全局相位；随后扫掠持续推进。
##   PE-05  P1-03 侧栏宽度契约常量与钳制（300/340/420）。
##   PE-06  P1-03.5 候选摘要含 bearing_sigma_deg。
##
## godot --headless --path games/sonar --script res://tools/patch_e_test.gd

const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_pe_01_reject_reasons(fails)
	_pe_02_panel_lifecycle(fails)
	_pe_03_combat_scenario(fails)
	_pe_04_search_continuity(fails)
	_pe_05_sidebar_contract(fails)
	_pe_06_summary_sigma(fails)
	_finish(fails)


func _assert_bool(fails: Array, name: String, ok: bool, expected: bool) -> void:
	if ok != expected:
		fails.append("%s: got %s expected %s" % [name, str(ok), str(expected)])


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("patch_e_test result=PASS")
	else:
		print("patch_e_test result=FAIL (%d)" % fails.size())
		for f in fails:
			print("  FAIL: " + f)
	quit(1 if not fails.is_empty() else 0)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	var w := World.new()
	w.load_scenario(sc)
	return w


## ---- PE-01：命令拒绝具体原因 + 五正交状态 ----
func _pe_01_reject_reasons(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	# a) LAUNCHING 期命令拒绝 → 原因 LAUNCHING。
	var ok1: bool = tp.command_course(90.0)
	_assert_bool(fails, "PE-01a1 launching rejects", ok1, false)
	_assert_bool(fails, "PE-01a2 reason LAUNCHING", tp.last_cmd_reject_reason == "LAUNCHING", true)
	w.run_steps(4)  # 出管 → WIRE_RUN
	# b) 无候选时 Accept 拒绝 → 原因 NO CANDIDATE（导线连接、seeker 空）。
	var ok2: bool = tp.accept_seeker_track(0)
	_assert_bool(fails, "PE-01b1 accept no candidate rejects", ok2, false)
	_assert_bool(
		fails, "PE-01b2 reason NO CANDIDATE", tp.last_cmd_reject_reason == "NO CANDIDATE", true
	)
	# c) 断线后命令拒绝 → 原因 WIRE CUT（不是统一 rejected (CONNECTED)）。
	tp.wire_link.cut()
	tp._enter_fallback()
	var ok3: bool = tp.command_course(45.0)
	_assert_bool(fails, "PE-01c1 cut rejects", ok3, false)
	_assert_bool(fails, "PE-01c2 reason WIRE CUT", tp.last_cmd_reject_reason == "WIRE CUT", true)
	# d/e 用一根新雷（cut 不可恢复）。
	var tp2: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	var p := InWaterWeaponPanel.new()
	p.bind(w)
	w.run_steps(4)
	p.sync()
	var lbl: Label = p._sections[str(tp2.torpedo_id)]["lbl"]
	for token in ["Recv", "TX", "Trk", "Auth", "Steer"]:
		if not lbl.text.contains(token):
			fails.append("PE-01d orthogonal row missing %s in: %s" % [token, lbl.text])
	# e) TX 行随权威状态逐帧刷新（set_active_tx 后立即反映，不等 phase 变化）。
	tp2.set_active_tx(true)
	p.sync()
	lbl = p._sections[str(tp2.torpedo_id)]["lbl"]
	_assert_bool(
		fails, "PE-01e TX row per-frame refresh", lbl.text.contains("TX WAITING_TRIGGER"), true
	)


## ---- PE-02：武器卡生命周期 / 日志 ----
func _pe_02_panel_lifecycle(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	var p := InWaterWeaponPanel.new()
	p.bind(w)
	p.sync()
	# a) 第二次 _rebuild（鱼雷集合变化）后标题仍在。
	var titles_before: int = _count_titles(p)
	var tp2: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(2)
	p.sync()
	var titles_after: int = _count_titles(p)
	_assert_bool(
		fails, "PE-02a header kept after rebuild", titles_before == 1 and titles_after == 1, true
	)
	# b) 无候选时 Accept 按钮 disabled（候选出现后 enable 在 _refresh_section）。
	var btns: Dictionary = p._sections[str(tp.torpedo_id)]["btns"]
	_assert_bool(
		fails, "PE-02b accept disabled no candidate", (btns["accept"] as Button).disabled, true
	)
	# c) WeaponPanel 事件日志：一行一事件（无 " | " 拼接），真实事件名可读。
	var wp := WeaponPanelUI.new()
	wp.weapons = w.weapons  # 测试脚手架：注入 weapons 使 _refresh 可用
	wp._on_weapon_event(str(tp.torpedo_id), "SEEKER_PHASE", {"state": "TRACKING"})
	wp._on_weapon_event(str(tp.torpedo_id), "TRACK_ACCEPTED", {"track_id": 3})
	var log_txt: String = wp._lbl_weapons.text
	_assert_bool(fails, "PE-02c1 two log lines", log_txt.split("\n").size() >= 3, true)
	_assert_bool(fails, "PE-02c2 no pipe join", not log_txt.contains(" | "), true)
	_assert_bool(fails, "PE-02c3 real event mapped", log_txt.contains("ASSISTED"), true)
	# d) 断线命令失败 → 拒绝原因来自 torpedo.last_cmd_reject_reason。
	tp2.wire_link.cut()
	tp2._enter_fallback()
	p._cmd(tp2, "course", 5.0)
	_assert_bool(
		fails,
		"PE-02d reject reason surfaced",
		(
			p._note.text.contains("WIRE")
			or p._note.text.contains("CUT")
			or p._note.text.contains("BROKEN")
		),
		true
	)


func _count_titles(p: InWaterWeaponPanel) -> int:
	var n: int = 0
	for c in p.get_children():
		if c is Label and (c as Label).text == "In-Water Weapons":
			n += 1
	return n


## ---- PE-03：P0-08 combat scenario ----
func _pe_03_combat_scenario(fails: Array) -> void:
	# a) 场景 JSON 装配完整。
	var sc: Dictionary = ConfigLoader.load_scenario("s1_combat")
	_assert_bool(fails, "PE-03a1 scenario loads", not sc.is_empty(), true)
	_assert_bool(fails, "PE-03a2 has enemy_spawn", sc.has("enemy_spawn"), true)
	_assert_bool(fails, "PE-03a3 has doctrine", sc.get("enemy_spawn", {}).has("doctrine"), true)
	_assert_bool(
		fails, "PE-03a4 has countermeasures", sc.get("enemy_spawn", {}).has("countermeasures"), true
	)
	# b) World 装配：敌方 AI + 出生 red 实体 + 敌方武器链。
	var w := World.new()
	w.load_scenario(sc)
	_assert_bool(fails, "PE-03b1 enemy ai configured", w.enemy_ai != null, true)
	_assert_bool(fails, "PE-03b2 enemy weapon chain", w.enemy_weapons != null, true)
	var found_red: bool = false
	for t in w.world["targets"]:
		if str(t.side) == "red":
			found_red = true
	_assert_bool(fails, "PE-03b3 spawned red target", found_red, true)
	# c) UI 同配置（auto_measurements=false）端到端可跑（不注入测量）。
	w.auto_measurements = false
	w.run_steps(20)
	_assert_bool(fails, "PE-03c1 ui-config ticks", w.sim_time > 0.0, true)
	# 场景选择器：环境变量 SONAR_SCENARIO 覆盖默认（不静默改教程）。
	OS.set_environment("SONAR_SCENARIO", "s1_combat")
	var resolved: String = UiContract.resolve_scenario_name()
	_assert_bool(fails, "PE-03d1 env override", resolved == "s1_combat", true)
	OS.set_environment("SONAR_SCENARIO", "")
	_assert_bool(
		fails,
		"PE-03d2 default tutorial kept",
		UiContract.resolve_scenario_name() == "stage1_basic_passive",
		true
	)


## ---- PE-04：P2-01 搜索扫掠连续初始化 ----
func _pe_04_search_continuity(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = w.weapons.fire_manual(90.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)  # → WIRE_RUN
	# 把仿真时间推进到远离 0 的全局相位（暴露全局相位跳变）。
	for i in range(400):
		w.run_steps(1)
		tp.command_course(90.0)  # 保持直航 90°
	_assert_bool(fails, "PE-04a sim advanced", w.sim_time > 100.0, true)
	var crs_before: float = tp.course_deg
	_assert_bool(fails, "PE-04b1 autonomy ok", tp.authorize_autonomy(), true)
	_assert_bool(fails, "PE-04b2 entered SEARCH", tp.mission_state_name() == "SEARCH", true)
	# 进入 SEARCH 后第一个期望航向应接近当前航向（连续初始化，不跳全局相位）。
	var desired0: float = tp._search_sweep_course(w.sim_time)
	var err0: float = absf(NavUtils.wrap180(desired0 - crs_before))
	_assert_bool(fails, "PE-04c continuity err<25deg", err0 < 25.0, true)
	# 扫掠持续推进（时间前进 → 期望航向变化）。
	var d1: float = tp._search_sweep_course(w.sim_time + 10.0)
	var moved: float = absf(NavUtils.wrap180(d1 - desired0))
	_assert_bool(fails, "PE-04d sweep advances", moved > 0.5, true)


## ---- PE-05：P1-03 侧栏宽度契约 ----
func _pe_05_sidebar_contract(fails: Array) -> void:
	_assert_bool(fails, "PE-05a min 300", UiContract.SIDEBAR_MIN_W == 300.0, true)
	_assert_bool(fails, "PE-05b preferred 340", UiContract.SIDEBAR_PREF_W == 340.0, true)
	_assert_bool(fails, "PE-05c max 420", UiContract.SIDEBAR_MAX_W == 420.0, true)
	_assert_bool(fails, "PE-05d clamp low", UiContract.sidebar_clamp_x(200.0) == 300.0, true)
	_assert_bool(fails, "PE-05e clamp high", UiContract.sidebar_clamp_x(900.0) == 420.0, true)
	_assert_bool(fails, "PE-05f clamp in-range", UiContract.sidebar_clamp_x(360.0) == 360.0, true)


## ---- PE-06：候选摘要含 bearing_sigma_deg（P1-03.5）----
func _pe_06_summary_sigma(fails: Array) -> void:
	var t := SeekerTrack.new()
	var s: Dictionary = t.to_summary()
	_assert_bool(fails, "PE-06a has bearing_sigma_deg", s.has("bearing_sigma_deg"), true)
	_assert_bool(fails, "PE-06b non-negative", float(s["bearing_sigma_deg"]) >= 0.0, true)
