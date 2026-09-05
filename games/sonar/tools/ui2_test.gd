extends SceneTree
## ui2_test.gd — S1-01 面板补全 + S1-08 人机工效 无头验收（REQ-UI-03/04）。
##
## UI2-1  ActiveSonarCard FIT_MODES 索引 bug：fit_mode=AUTO 必须显示选中
##        第 0 项（旧 maxi(fi,1) 把 AUTO 误显示为 ASSISTED）。
## UI2-2  CountermeasurePanel：JAMMER 频带提示（profile band 显示在面板，
##        发射前可见）；冷却行为不变。
## UI2-3  AlertPanel 告警分组 + 战果分级汇总（THREAT/CM/BDA 前缀 +
##        BDA summary 行；仍无 target_id/Truth 泄露）。
## UI2-4  StartMenu 教程/简报（REQ-UI-04）：含操作流程教学与 seed 说明。
##
## godot --headless --path games/sonar --script res://tools/ui2_test.gd


func _initialize() -> void:
	var fails: Array = []
	_ui2_1_fit_modes_index(fails)
	_ui2_2_cm_band_hint(fails)
	_ui2_3_alert_groups_bda(fails)
	_ui2_4_start_menu_tutorial(fails)
	_finish(fails)


## ---- UI2-1：FIT_MODES 同步索引 ----
func _ui2_1_fit_modes_index(fails: Array) -> void:
	var card := ActiveSonarCard.new()
	card.set_data({"fit_mode": "AUTO", "tma": {}})
	_assert_bool(fails, "UI2-1a AUTO shows index 0", card._opt_fit_mode.selected == 0, true)
	card.set_data({"fit_mode": "MANUAL", "tma": {}})
	_assert_bool(fails, "UI2-1b MANUAL shows index 2", card._opt_fit_mode.selected == 2, true)
	card.set_data({"fit_mode": "ASSISTED", "tma": {}})
	_assert_bool(fails, "UI2-1c ASSISTED shows index 1", card._opt_fit_mode.selected == 1, true)
	card.set_data({"fit_mode": "GARBAGE", "tma": {}})
	_assert_bool(
		fails, "UI2-1d unknown falls back ASSISTED", card._opt_fit_mode.selected == 1, true
	)


## ---- UI2-2：CountermeasurePanel JAMMER 频带提示 ----
func _ui2_2_cm_band_hint(fails: Array) -> void:
	var w := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	w.load_scenario(sc)
	# REQ-CM-04：画像来自配置（此处直注入，等价 own_ship.countermeasures.profiles）。
	w.countermeasures.profiles[DecoyProgram.TYPE_JAMMER] = {
		"band_min_hz": 800.0,
		"band_max_hz": 1200.0,
	}
	var p := CountermeasurePanel.new()
	p.bind(w)
	p.sync()
	var txt: String = p._lbl_state.text
	_assert_bool(
		fails, "UI2-2a jammer band hint shown", txt.contains("JAMMER band 800–1200 Hz"), true
	)
	_assert_bool(fails, "UI2-2b rounds/cooldown still shown", txt.contains("Rounds"), true)
	# 无 band 配置时不显示频带行（不虚构）。
	var w2 := World.new()
	w2.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var p2 := CountermeasurePanel.new()
	p2.bind(w2)
	p2.sync()
	_assert_bool(
		fails,
		"UI2-2c no band configured no hint",
		not p2._lbl_state.text.contains("JAMMER band"),
		true
	)


## ---- UI2-3：AlertPanel 分组 + BDA 汇总 ----
func _ui2_3_alert_groups_bda(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	(
		w
		. player_evidence
		. append(
			{
				"evidence_id": 1,
				"timestamp": 10.0,
				"alert": "POSSIBLE_TORPEDO",
				"bearing_deg": 45.0,
				"confidence": 0.8,
			}
		)
	)
	w.player_evidence.append(
		{"evidence_id": 2, "timestamp": 20.0, "alert": "DECOY_DEPLOYED", "confidence": 1.0}
	)
	# 己方爆炸 + 与在跟航迹方位一致 + 高 SE → PROBABLE_KILL（§10.4 分级）。
	(
		w
		. player_evidence
		. append(
			{
				"evidence_id": 3,
				"timestamp": 30.0,
				"alert": "DETONATION_HEARD",
				"emission_kind": AcousticEmissionEvent.EXPLOSION,
				"side_hint": "OWN_FACT",
				"bearing_deg": 46.0,
				"se_db": 25.0,
				"confidence": 1.0,
			}
		)
	)
	var p := AlertPanel.new()
	p.bind(w, func() -> Array: return [46.0])
	p.sync()
	var txt: String = p._lbl.text
	_assert_bool(
		fails, "UI2-3a BDA summary line", txt.contains("BDA summary: 1×PROBABLE_KILL"), true
	)
	_assert_bool(fails, "UI2-3b threat group tagged", txt.contains("THREAT"), true)
	_assert_bool(fails, "UI2-3c countermeasure group tagged", txt.contains("CM T+20s"), true)
	_assert_bool(fails, "UI2-3d kill graded on row", txt.contains("BDA T+30s PROBABLE_KILL"), true)
	_assert_bool(
		fails, "UI2-3e no truth leak", not txt.contains("target") and not txt.contains("ET-"), true
	)


## ---- UI2-4：StartMenu 教程/简报 ----
func _ui2_4_start_menu_tutorial(fails: Array) -> void:
	var menu := StartMenu.new()
	menu._ready()  # 无头环境直接构建 UI（不入树、无需等帧）
	var found: Label = null
	for c in menu.get_children():
		for cc in c.get_children():
			if cc is Label and str(cc.text).contains("教程"):
				found = cc
	if found == null:
		for c in menu.get_children():
			for cc in c.get_children():
				for ccc in cc.get_children():
					if ccc is Label and str(ccc.text).contains("教程"):
						found = ccc
	if found == null:
		fails.append("UI2-4a tutorial briefing label not found")
	else:
		var t: String = found.text
		for token in ["Mark", "TMA", "System", "Countermeasures", "seed", "ASSISTED/FULL_AUTO"]:
			if not t.contains(token):
				fails.append("UI2-4a tutorial missing %s" % token)
		_assert_bool(fails, "UI2-4a tutorial content checked", true, true)
	menu.free()


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	for f in fails:
		print("UI2_FAIL ", f)
	if fails.is_empty():
		print("UI2_TEST result=PASS")
	else:
		print("UI2_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
