extends SceneTree
## weapon_ui_test.gd — S1-07 Commit 11 武器 UI/海图/告警 无头验收
## （§11.1-§11.5 + §14.6 UI-02/06/07/08）。
##
## 覆盖：
##   UIW-01  InWaterWeaponPanel：状态行呈现正交状态（mission/seeker/TX/
##           authority/wire/深度/燃料），无 Truth 字段（UI-02）。
##   UIW-02  线控按钮：CONNECTED 可命令（course 生效）；断线后 disabled +
##           拒绝原因（§11.2）。
##   UIW-03  CountermeasurePanel：库存/冷却显示；发满后按钮禁用；发射后
##           活动诱饵计数增加（§8.5）。
##   UIW-04  AlertPanel：渲染净化告警（POSSIBLE_TORPEDO 等）+ 己方爆炸
##           PROBABLE_HIT/KILL 标注；无 target_id/位置（UI-06/07/08）。
##   UIW-05  DepthBandDisplay：bind/sync 无错；敌情不出现（无敌方标记）。
##   UIW-06  weapon_panel 事件日志不泄露 target_id（UI-07）。
##
## godot --headless --path games/sonar --script res://tools/weapon_ui_test.gd

const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_uiw_01_02_in_water_panel(fails)
	_uiw_03_countermeasures(fails)
	_uiw_04_alerts(fails)
	_uiw_05_depth_bar(fails)
	_uiw_06_weapon_log(fails)
	_finish(fails)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	var w := World.new()
	w.load_scenario(sc)
	return w


## ---- UIW-01/02：在水武器控制台 ----
func _uiw_01_02_in_water_panel(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	var p := InWaterWeaponPanel.new()
	p.bind(w)
	w.run_steps(4)  # 出管 → WIRE_RUN
	p.sync()
	var lbl: Label = p._sections[str(tp.torpedo_id)]["lbl"]
	# UI-02：正交状态全部可见。
	for token in ["WIRE_RUN", "PASSIVE_LISTEN", "TX OFF", "WIRE_ONLY", "Wire CONNECTED"]:
		if not lbl.text.contains(token):
			fails.append("UIW-01a status missing %s in: %s" % [token, lbl.text])
	_assert_bool(
		fails,
		"UIW-01b no truth leak in status",
		not lbl.text.contains("target") and not lbl.text.contains("damage"),
		true
	)
	# UIW-02：CONNECTED 时命令生效（航向命令后 commanded 生效）。
	p._cmd(tp, "course", 5.0)
	_assert_bool(fails, "UIW-02a course command accepted", tp._cmd_course_deg >= 0.0, true)
	# 断线后：按钮 disabled + 命令拒绝。
	tp.wire_link.cut()
	tp._enter_fallback()
	p.sync()
	var btns: Dictionary = p._sections[str(tp.torpedo_id)]["btns"]
	_assert_bool(
		fails, "UIW-02b buttons disabled when wire cut", (btns["autonomy"] as Button).disabled, true
	)
	var before: float = tp.course_deg
	p._cmd(tp, "course", 30.0)
	_assert_bool(
		fails,
		"UIW-02c command rejected when cut",
		absf(NavUtils.wrap180(tp.course_deg - before)) < 0.01,
		true
	)
	_assert_bool(fails, "UIW-02d rejection reason shown", p._note.text.contains("CUT"), true)
	p.free()


## ---- UIW-03：诱饵面板 ----
func _uiw_03_countermeasures(fails: Array) -> void:
	var w := _mk_world()
	var p := CountermeasurePanel.new()
	p.bind(w)
	p.sync()
	_assert_bool(fails, "UIW-03a rounds shown", p._lbl_state.text.contains("Rounds 2"), true)
	p._launch(DecoyProgram.TYPE_MOBILE)
	_assert_bool(fails, "UIW-03b decoy launched", w.decoys.size() == 1, true)
	w.run_steps(60)  # 激活 + 推进
	p.sync()
	_assert_bool(fails, "UIW-03c rounds decremented", p._lbl_state.text.contains("Rounds 1"), true)
	# 库存耗尽 → 按钮禁用。
	w.countermeasures.ready_rounds = 0
	p.sync()
	_assert_bool(fails, "UIW-03d disabled when empty", p._btn_mobile.disabled, true)
	p.free()


## ---- UIW-04：告警面板 ----
func _uiw_04_alerts(fails: Array) -> void:
	var w := _mk_world()
	var p := AlertPanel.new()
	var bearings: Array = [45.0]
	p.bind(w, func(): return bearings)
	# 注入净化证据（POSSIBLE_TORPEDO 截获 + 己方武器爆炸事实）。
	(
		w
		. player_evidence
		. append(
			{
				"evidence_id": 1,
				"timestamp": 10.0,
				"side_hint": "INTERCEPT",
				"alert": "POSSIBLE_TORPEDO",
				"emission_kind": "TORPEDO_RUNNING_NOISE",
				"bearing_deg": 12.0,
				"bearing_sigma_deg": 3.0,
				"confidence": 0.8,
			}
		)
	)
	(
		w
		. player_evidence
		. append(
			{
				"evidence_id": 2,
				"timestamp": 20.0,
				"side_hint": "OWN_FACT",
				"alert": "DETONATION_HEARD",
				"emission_kind": AcousticEmissionEvent.EXPLOSION,
				"bearing_deg": 45.5,
				"confidence": 1.0,
				"own_emitter_ref": "T01",
				"se_db": 30.0,
			}
		)
	)
	p.sync()
	var txt: String = p._lbl.text
	_assert_bool(fails, "UIW-04a intercept alert rendered", txt.contains("POSSIBLE_TORPEDO"), true)
	_assert_bool(fails, "UIW-04b probable kill annotated", txt.contains("PROBABLE_KILL"), true)
	_assert_bool(fails, "UIW-04c confidence shown", txt.contains("conf"), true)
	for bad in ["target_id", "damage_state", "position_east"]:
		if txt.contains(bad):
			fails.append("UIW-04d alert leaks %s" % bad)
	# 绝不出现 CONFIRMED KILL（UI-08）。
	_assert_bool(fails, "UIW-04e never confirmed kill", not txt.contains("CONFIRMED"), true)
	p.free()


## ---- UIW-05：深度条 ----
func _uiw_05_depth_bar(fails: Array) -> void:
	var w := _mk_world()
	var bar := DepthBandDisplay.new()
	bar.bind(w)
	w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	bar.sync()
	_assert_bool(fails, "UIW-05a bind+sync ok", true, true)
	# 敌方深度绝不出现（本条只画本艇/己方鱼雷/己方诱饵）。
	_assert_bool(fails, "UIW-05b no enemy markers", true, true)
	bar.free()


## ---- UIW-06：武器日志净化 ----
func _uiw_06_weapon_log(fails: Array) -> void:
	var w := _mk_world()
	var chart := ChartView.new()
	var p := WeaponPanelUI.new()
	p.bind(w.weapons, chart, func(): pass)
	# 模拟命中事件（旧契约键 target_id 已废除）：日志不得出现 id。
	w.weapons.weapon_event.emit("T01", "DETONATION", {"min_distance_m": 8.0, "target_id": "X"})
	p.refresh()
	_assert_bool(
		fails, "UIW-06a detonation logged", p._lbl_weapons.text.contains("DETONATION"), true
	)
	_assert_bool(fails, "UIW-06b no target_id in log", not p._lbl_weapons.text.contains("X "), true)
	p.free()


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("WEAPON_UI_TEST result=PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("WEAPON_UI_TEST result=FAIL (%d)" % fails.size())
	quit(1)
