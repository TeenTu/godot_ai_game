## 评审 Patch F 失败测试（PF-01..04）：
## PF-01 P1-08 swept fuze：连续碰撞最近通过（单 tick 穿越两端点均在半径外仍触发；
##        半径外扫过不误触；垂直深度分量纳入 3D 判定）
## PF-02 P1-10 长局刷新：瀑布行/告警证据封顶后仍持续更新（sequence 驱动，
##        不再按数组长度比较）
## PF-03 P0-08/AT-17 e2e 反击链：s1_combat 正式场景 auto_measurements=false，
##        本艇机动 → 敌 doctrine 反击 → 玩家收到 INTERCEPT 证据 + ThreatTrack，
##        全程无 Truth 泄漏
extends SceneTree

const SEED := 20260905
const DT := 0.5

var _pass: int = 0


func _init() -> void:
	var fails: Array = []
	_pf_01a_swept_unit(fails)
	_pf_01b_swept_crossing(fails)
	_pf_01c_swept_miss(fails)
	_pf_01d_swept_vertical(fails)
	_pf_02a_waterfall_seq(fails)
	_pf_02b_alert_seq(fails)
	_pf_03_e2e_counterfire(fails)
	for f in fails:
		print("[FAIL] " + f)
	print("passed=%d failed=%d" % [_pass, _pass + fails.size()])
	if fails.is_empty():
		print("result=PASS")
	else:
		print("result=FAIL")
	quit(0 if fails.is_empty() else 1)


func _assert_bool(fails: Array, name: String, cond: bool, want: bool) -> void:
	if cond == want:
		_pass += 1
		print("[ok] %s" % name)
	else:
		fails.append("%s (got %s want %s)" % [name, str(cond), str(want)])


func _assert_near(fails: Array, name: String, v: float, want: float, tol: float) -> void:
	if absf(v - want) <= tol:
		_pass += 1
		print("[ok] %s" % name)
	else:
		fails.append("%s (got %.3f want %.3f±%.3f)" % [name, v, want, tol])


## ---- PF-01a：swept 最近通过纯函数 ----
func _pf_01a_swept_unit(fails: Array) -> void:
	# 横向 14.2m 穿越：线段最近通过 = 14.2（两端点各 ~15.6 > 15）。
	var p0 := Vector3(-6.45, 14.2, 0.0)
	var p1 := Vector3(6.45, 14.2, 0.0)
	_assert_near(
		fails, "PF-01a1 swept min lateral", FuzeController.swept_min_distance_m(p0, p1), 14.2, 0.01
	)
	# 半径外扫过（横向 30m）。
	_assert_near(
		fails,
		"PF-01a2 swept min far",
		FuzeController.swept_min_distance_m(Vector3(-6.45, 30, 0), Vector3(6.45, 30, 0)),
		30.0,
		0.01
	)
	# 垂直分量：正上方 60m 掠过。
	_assert_near(
		fails,
		"PF-01a3 swept min vertical",
		FuzeController.swept_min_distance_m(Vector3(-6.45, 0, 60), Vector3(6.45, 0, 60)),
		60.0,
		0.01
	)
	# 静止相对（零位移）退化为端点距离。
	_assert_near(
		fails,
		"PF-01a4 degenerate point",
		FuzeController.swept_min_distance_m(Vector3(3, 4, 0), Vector3(3, 4, 0)),
		5.0,
		0.01
	)


## 构造直航考核场：本艇远离弹道；静止安静靶由测试放置。
func _mk_fuzetest_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED + 11
	sc["targets"] = []
	sc["enemy_spawn"] = {}
	sc["own_ship"]["position_east_m"] = 0.0
	sc["own_ship"]["position_north_m"] = -2000.0
	sc["own_ship"]["speed_kn"] = 0.0
	var w := World.new()
	w.load_scenario(sc)
	return w


func _place_quiet_target(w: World, e: float, n: float, depth: float) -> RefCounted:
	var t := TruthEntity.new()
	(
		t
		. from_dict(
			{
				"id": "sweep_tgt",
				"side": "red",
				"platform_type": "surface",
				"position_east_m": e,
				"position_north_m": n,
				"depth_m": depth,
				"course_deg": 0.0,
				"speed_kn": 0.0,
				"acoustic": {"broadband_base_level_db": 95.0, "tonal_lines": []},
			}
		)
	)
	w.world["targets"].append(t)
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 95.0, "tonal_lines": []})
	w.world["target_acs"][str(t.id)] = ac
	return t


## ---- PF-01b：单 tick 穿越触发（两端点均在 15m 半径外）----
## 40kn=20.576 m/s，dt=0.5 → 10.288m/步。先直航到 traveled≥300 解保，
## 再把静止靶放在前方第 4.5 步处（CPA 居中）：网格端点 dx=±5.144m，
## 端点距离 = sqrt(5.144² + 14.5²) ≈ 15.39 > 15（旧逐点检查不触发），
## swept 最近通过 = 14.5 < 15（必须触发）。
func _pf_01b_swept_crossing(fails: Array) -> void:
	var w := _mk_fuzetest_world()
	var tp: Torpedo = w.weapons.fire_manual(90.0, 0.0, -14.5, 0.0, 50.0)
	w.run_steps(2)
	tp.passive_receiver_on = false  # 保持直航（安静靶本就听不见；双保险）
	var steps: int = 0
	while tp.traveled_m < 320.0 and steps < 200:
		w.run_steps(1)
		steps += 1
	var x0: float = tp.pos_east_m
	var step_len: float = tp.speed_kn * NavUtils.KNOT_TO_MS * float(w.world["dt"])
	var half: float = step_len * 0.5
	var tgt_x: float = x0 + 4.0 * step_len + half
	var tgt: RefCounted = _place_quiet_target(w, tgt_x, 0.0, 50.0)
	var detonated: bool = false
	var min_pass: float = INF
	for i in range(40):
		w.run_steps(1)
		if tp.is_dead():
			detonated = true
			if not w._detonations.is_empty():
				min_pass = float(w._detonations[-1].get("min_pass_distance_m", INF))
			break
	_assert_bool(fails, "PF-01b1 crossing triggers swept fuze", detonated, true)
	if detonated:
		_assert_near(fails, "PF-01b2 min pass = lateral offset", min_pass, 14.5, 0.6)
		_assert_bool(fails, "PF-01b3 target sunk", str(tgt.damage_state) == "sunk", true)


## ---- PF-01c：半径外扫过绝不触发 ----
func _pf_01c_swept_miss(fails: Array) -> void:
	var w := _mk_fuzetest_world()
	var tp: Torpedo = w.weapons.fire_manual(90.0, 0.0, -14.5, 0.0, 50.0)
	w.run_steps(2)
	tp.passive_receiver_on = false
	while tp.traveled_m < 320.0:
		w.run_steps(1)
	var x0: float = tp.pos_east_m
	var step_len: float = tp.speed_kn * NavUtils.KNOT_TO_MS * DT
	var tgt: RefCounted = _place_quiet_target(w, x0 + 4.5 * step_len, 0.0, 50.0)
	# 横向偏移 = 15.5（路径 y=-14.5 → 靶 y=1.0）。
	tgt.position_north_m = 1.0
	var detonated: bool = false
	for i in range(40):
		w.run_steps(1)
		if tp.is_dead():
			detonated = true
			break
	_assert_bool(fails, "PF-01c1 outside radius no trigger", detonated, false)
	_assert_bool(fails, "PF-01c2 target intact", str(tgt.damage_state) == "ok", true)


## ---- PF-01d：垂直深度分量纳入（正下方/上方掠过不触发）----
func _pf_01d_swept_vertical(fails: Array) -> void:
	var w := _mk_fuzetest_world()
	var tp: Torpedo = w.weapons.fire_manual(90.0, 0.0, -14.5, 0.0, 50.0)
	w.run_steps(2)
	tp.passive_receiver_on = false
	while tp.traveled_m < 320.0:
		w.run_steps(1)
	var x0: float = tp.pos_east_m
	var step_len: float = tp.speed_kn * NavUtils.KNOT_TO_MS * DT
	# 横向 0m（正对穿越）但深度差 60m → 3D 最近通过 60m > 15m。
	var tgt: RefCounted = _place_quiet_target(w, x0 + 4.5 * step_len, -14.5, 110.0)
	var detonated: bool = false
	for i in range(40):
		w.run_steps(1)
		if tp.is_dead():
			detonated = true
			break
	_assert_bool(fails, "PF-01d1 vertical offset no trigger", detonated, false)


## ---- PF-02a：瀑布行封顶后 sequence 仍驱动刷新 ----
func _pf_02a_waterfall_seq(fails: Array) -> void:
	var w := _mk_fuzetest_world()
	var tgt := _place_quiet_target(w, 800.0, 0.0, 50.0)
	# 响亮靶保证每行都有探测峰（覆盖 target_acs 频谱）。
	var sc_ac: Dictionary = {
		"broadband_base_level_db": 165.0,
		"speed_noise_a": 0.0,
		"tonal_lines": [{"freq_hz": 120.0, "level_db": 150.0}],
		"turns_per_knot": 1,
		"blade_count": 5,
	}
	var ac := AcousticProfile.new()
	ac.from_dict(sc_ac)
	w.world["target_acs"][str(tgt.id)] = ac
	var op := OperatorSonar.new()
	op.setup({"env": w.world["env"], "own": w.world["own"], "rng": w.world["rng"]})
	var sim: float = 0.0
	for i in range(650):
		sim += OperatorSonar.ROW_INTERVAL_S
		op.update(sim, w.world["targets"], w.world["target_acs"])
	_assert_bool(fails, "PF-02a1 seq monotonic >600", op.waterfall_seq > 600, true)
	_assert_bool(fails, "PF-02a2 rows capped at 600", op.bb_rows.size() <= 600, true)
	_assert_near(fails, "PF-02a3 newest row kept", float(op.bb_rows[-1]["t"]), sim, 0.01)
	# OperatorPanel：size 恒 600 但 seq 前进 → 仍刷新（不冻结）。
	var panel := OperatorPanel.new()
	panel.refresh(op)
	var seq1: int = panel._last_wf_seq
	op.update(sim + OperatorSonar.ROW_INTERVAL_S, w.world["targets"], w.world["target_acs"])
	panel.refresh(op)
	_assert_bool(fails, "PF-02a4 panel tracks seq after cap", panel._last_wf_seq != seq1, true)


## ---- PF-02b：告警证据封顶后仍更新 ----
func _pf_02b_alert_seq(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var panel := AlertPanel.new()
	panel.bind(w, Callable())
	for i in range(257):
		w.player_evidence.append(
			{"evidence_id": i, "alert": "TEST_%d" % i, "timestamp": float(i), "confidence": 0.5}
		)
	while w.player_evidence.size() > 256:
		w.player_evidence.pop_front()
	panel.sync()
	var txt1: String = panel._lbl.text
	_assert_bool(fails, "PF-02b1 newest shown at cap", txt1.contains("TEST_256"), true)
	# 追加一条（封顶裁剪后 size 不变 256）→ 面板必须更新（旧实现冻结）。
	w.player_evidence.append(
		{"evidence_id": 257, "alert": "TEST_257", "timestamp": 257.0, "confidence": 0.5}
	)
	while w.player_evidence.size() > 256:
		w.player_evidence.pop_front()
	panel.sync()
	var txt2: String = panel._lbl.text
	_assert_bool(fails, "PF-02b2 updates after cap", txt2.contains("TEST_257"), true)
	_assert_bool(fails, "PF-02b3 text actually changed", txt2 != txt1, true)


## ---- PF-03：s1_combat e2e 反击链（AT-17 来袭半环）----
## 玩家发射 → 敌截获 LAUNCH_TRANSIENT（P0-01/P0-06 链）→ doctrine 反击 →
## 玩家收到 INTERCEPT 证据 + ThreatTrack，全程无 Truth 泄漏。
## （发现接触→TMA→发射命中半环由 s107_integrated_test INT-A/B 覆盖。）
func _pf_03_e2e_counterfire(fails: Array) -> void:
	var sc: Dictionary = ConfigLoader.load_scenario("s1_combat")
	sc["seed"] = SEED + 3
	var w := World.new()
	w.load_scenario(sc)
	w.auto_measurements = false  # 与 main_ui 相同配置（AT-08/AT-17 前提）
	# 玩家对 enemy_1 方位发射（真实 WeaponSystem 入口，无测试捷径注入）。
	w.run_steps(20)
	var enemy: TruthEntity = w.world["targets"][0]
	var brg: float = (
		NavUtils
		. bearing_to_true(
			float(w.world["own"].position_east_m),
			float(w.world["own"].position_north_m),
			float(enemy.position_east_m),
			float(enemy.position_north_m),
		)
	)
	var tp: Torpedo = w.weapons.fire_manual(brg, 0.0, 0.0, w.sim_time, 50.0)
	_assert_bool(fails, "PF-03a0 player torpedo launched", tp != null, true)
	var fired: bool = false
	var ev_found: bool = false
	for i in range(2000):
		w.run_steps(1)
		if w.enemy_weapons != null and not w.enemy_weapons.torpedoes.is_empty():
			fired = true
		for e in w.player_evidence:
			if (
				str(e.get("side_hint", "")) == "INTERCEPT"
				and str(e.get("threat_track_id", "")) != ""
			):
				ev_found = true
				break
		if fired and ev_found and w.sim_time > 120.0:
			break
	_assert_bool(fails, "PF-03a1 enemy doctrine counterfires", fired, true)
	_assert_bool(fails, "PF-03a2 INTERCEPT evidence with ThreatTrack", ev_found, true)
	# 信息隔离：INTERCEPT 证据绝不含 Truth 字段。
	var leak: bool = false
	for e in w.player_evidence:
		if str(e.get("side_hint", "")) != "INTERCEPT":
			continue
		for k in ["target_id", "truth_range_m", "range_m", "position_east_m_target", "truth_pos"]:
			if e.has(k):
				leak = true
	_assert_bool(fails, "PF-03a3 no Truth leak in evidence", leak, false)
	# 长局不冻结：仿真持续前进（后接 AT-14 长局刷新回归）。
	_assert_bool(fails, "PF-03a4 sim advanced", w.sim_time > 120.0, true)
