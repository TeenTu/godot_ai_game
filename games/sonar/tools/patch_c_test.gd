## 评审 Patch C 失败测试（PC-01..05）：
## PC-01 P0-06 统一声场：World.acoustic_scene_emitters/acs 含敌方鱼雷影子，
##        OperatorSonar 走 UI 合并路径能出鱼雷 BB 峰
## PC-02 P1-04.5 已探测样本显示幅度下限（SE<=0 不再 amp<=0 隐形）
## PC-03 P1-06 谱线不复制 Truth：逐线 TL/N/P_d + 频偏/幅度噪声 + 丢线
## PC-04 P1-07 主动回波历元一致：方位/SE 用发射历元快照，timestamp/available_time
## PC-05 P1-12 己方可声学可见但安全：seeker 拒绝 OWN + 引信独立保险
extends SceneTree

const SEED := 20260904

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	var fails: Array = []
	_pc_01_scene_emitters(fails)
	_pc_01b_sonar_row(fails)
	_pc_02_display_floor(fails)
	_pc_03_spectral_lines(fails)
	_pc_04_echo_epoch(fails)
	_pc_05_own_safety(fails)
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


func _mk_threat_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED + 1
	sc["targets"] = []
	sc["own_acoustic"]["broadband_base_level_db"] = 160.0
	sc["own_ship"]["speed_kn"] = 0.0
	var b: float = deg_to_rad(45.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 43.0,
		"bearing_max_deg": 47.0,
		"range_min_m": 1500.0,
		"range_mode_m": 1800.0,
		"range_max_m": 2000.0,
		"speed_min_kn": 5.0,
		"speed_max_kn": 8.0,
		"min_separation_m": 800.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 1500.0,
			"position_north_m": cos(b) * 1500.0,
			"course_deg": 225.0,
			"speed_kn": 6.0,
			"depth_m": 70.0
		},
		"doctrine":
		{
			"sensor_false_alarm_rate": 0.0,
			"counterfire_probability": 1.0,
			"reaction_delay_min_s": 3.0,
			"reaction_delay_max_s": 15.0,
			"sample_interval_s": 2.0
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


func _mk_target_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED + 2
	sc["enemy_spawn"] = {}
	var w := World.new()
	w.load_scenario(sc)
	return w


## ---- PC-01a：统一声场含敌方鱼雷影子 ----
func _pc_01_scene_emitters(fails: Array) -> void:
	var w := _mk_threat_world()
	var found: bool = false
	for i in range(1200):
		w.run_steps(1)
		if w.enemy_weapons != null and not w.enemy_weapons.torpedoes.is_empty():
			found = true
			break
	_assert_bool(fails, "PC-01a1 enemy torpedo in water", found, true)
	if not found:
		return
	var scene: Array = w._acoustic_scene_emitters()
	var ids: Array = []
	for e in scene:
		ids.append(str(e.id))
	_assert_bool(
		fails, "PC-01a2 scene has enemy torpedo (ids=%s)" % str(ids), ids.has("ET01"), true
	)
	var acs: Dictionary = w._acoustic_scene_acs()
	_assert_bool(
		fails, "PC-01a3 scene acs has ET01 profile", acs.has("ET01") and acs["ET01"] != null, true
	)


## ---- PC-01b：OperatorSonar 经合并声场出鱼雷 BB 峰 ----
func _pc_01b_sonar_row(fails: Array) -> void:
	var w := _mk_threat_world()
	var found: bool = false
	for i in range(1200):
		w.run_steps(1)
		if w.enemy_weapons != null and not w.enemy_weapons.torpedoes.is_empty():
			found = true
			break
	if not found:
		_assert_bool(fails, "PC-01b0 enemy torpedo in water", false, true)
		return
	var sh: RefCounted = w.enemy_weapons.torpedoes[0]
	# 等鱼雷逼近到稳健探测距离（CRUISE SL=128dB，远距 SE 弱属正常标定）。
	for j in range(2400):
		var dd: float = (
			NavUtils
			. distance(
				float(w.world["own"].position_east_m),
				float(w.world["own"].position_north_m),
				float(sh.pos_east_m),
				float(sh.pos_north_m),
			)
		)
		if dd < 600.0:
			break
		w.run_steps(1)
	var op := OperatorSonar.new()
	op.setup({"env": w.world["env"], "own": w.world["own"], "rng": w.world["rng"]})
	var scene: Array = w._acoustic_scene_emitters()
	var acs: Dictionary = w.world["target_acs"].duplicate()
	acs.merge(w._acoustic_scene_acs())
	# UI 合并路径（main_ui._op_step 同一表达式）。
	op.update(w.sim_time, w.world["targets"] + scene, acs)
	var row: Dictionary = op.bb_rows[op.bb_rows.size() - 1]
	var brg_ok: bool = false
	for p in row["peaks"]:
		var brg: float = float(p["bearing_deg"])
		var truth: float = (
			NavUtils
			. true_to_display(
				float(w.world["own"].course_deg),
				(
					NavUtils
					. bearing_to_true(
						float(w.world["own"].position_east_m),
						float(w.world["own"].position_north_m),
						float(sh.pos_east_m),
						float(sh.pos_north_m),
					)
				),
			)
		)
		if absf(NavUtils.angle_diff(brg, truth)) < 10.0:
			brg_ok = true
			break
	_assert_bool(fails, "PC-01b1 sonar BB peak at torpedo bearing", brg_ok, true)


## ---- PC-02：已探测样本显示幅度下限 ----
func _pc_02_display_floor(fails: Array) -> void:
	var amp_low: float = OperatorSonar.display_amp_db(-5.0)
	var amp_hi: float = OperatorSonar.display_amp_db(80.0)
	_assert_bool(fails, "PC-02a negative SE amp positive (%.2f)" % amp_low, amp_low > 0.0, true)
	_assert_bool(fails, "PC-02b amp capped (%.2f)" % amp_hi, amp_hi <= 30.0, true)


## ---- PC-03：谱线观测不复制 Truth 声纹 ----
func _pc_03_spectral_lines(fails: Array) -> void:
	var w := _mk_target_world()
	var adapter := TorpedoSensorAdapter.new()
	adapter.bind(w.world["env"], w.world["depth_model"], [], {})
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	adapter.set_rng(rng)
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 185.0
	ac.speed_noise_a = 0.0
	ac.tonal_lines = [
		{"freq_hz": 1200.0, "level_db": 185.0},
		{"freq_hz": 2400.0, "level_db": 180.0},
	]
	var c := TruthEntity.new()
	c.id = "TGT"
	c.position_east_m = 0.0
	c.position_north_m = 2000.0
	c.depth_m = 60.0
	c.speed_kn = 6.0
	adapter.contacts = [c]
	adapter.contact_acs = {"TGT": ac}
	var prof := TorpedoAcousticProfile.make_default()
	var rets: Array = adapter.sample_passive(0.0, 0.0, 60.0, 40.0, 0.0, prof, 100.0)
	_assert_bool(fails, "PC-03a passive return produced", rets.size() >= 1, true)
	if rets.is_empty():
		return
	var sf: Dictionary = rets[0].spectral_features
	var obs: Array = sf.get("tonal_hz", [])
	_assert_bool(fails, "PC-03b observed tonals present", obs.size() >= 1, true)
	if obs.is_empty():
		return
	# 观测谱线必须经过声学处理：幅度明显衰减（TL+N_eff 已扣除），
	# 频率带抖动（非逐字节复制 Truth）。
	var degraded: bool = false
	for o2 in obs:
		var f2: float = float(o2["freq_hz"])
		var lv2: float = float(o2["level_db"])
		if absf(f2 - 1200.0) < 5.0 and lv2 < 184.0 and lv2 > 0.0:
			degraded = true
		if absf(f2 - 2400.0) < 5.0 and lv2 < 179.0 and lv2 > 0.0:
			degraded = true
	var freq_exact: bool = false
	for o3 in obs:
		var f3: float = float(o3["freq_hz"])
		if absf(f3 - 1200.0) < 1e-6 or absf(f3 - 2400.0) < 1e-6:
			freq_exact = true
	_assert_bool(fails, "PC-03c lines acoustically degraded", degraded, true)
	_assert_bool(fails, "PC-03d freq not byte-copied", not freq_exact, true)


## ---- PC-04：主动回波历元一致 ----
func _pc_04_echo_epoch(fails: Array) -> void:
	var w := _mk_target_world()
	var adapter := TorpedoSensorAdapter.new()
	adapter.bind(w.world["env"], w.world["depth_model"], [], {})
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 9
	adapter.set_rng(rng)
	var ac := AcousticProfile.new()
	ac.active_target_strength_db = 14.0
	var c := TruthEntity.new()
	c.id = "TGT"
	c.position_east_m = 0.0
	c.position_north_m = 300.0
	c.depth_m = 60.0
	c.speed_kn = 0.0
	adapter.contacts = [c]
	adapter.contact_acs = {"TGT": ac}
	var prof := TorpedoAcousticProfile.make_default()
	prof.active_source_level_db = 220.0  # 测试标定：保证 Pd≈1（历元断言用）
	# 发射历元：鱼雷在原点，目标正北 300m。
	adapter.schedule_active_echoes("T01", 0.0, 0.0, 0.0, prof, 100.0, "T01-P001")
	# 之后鱼雷和目标都大幅移动（到达时几何完全不同）。
	c.position_east_m = 2500.0
	c.position_north_m = 2500.0
	var tau: float = AcousticService.echo_travel_time_s(300.0)
	var rets: Array = adapter.collect_due_active_returns(
		"T01", 800.0, 400.0, 60.0, 40.0, prof, 100.0 + tau + 1.0
	)
	_assert_bool(fails, "PC-04a echo returned", rets.size() == 1, true)
	if rets.is_empty():
		return
	var r: SeekerReturn = rets[0]
	var brg_err: float = absf(NavUtils.angle_diff(r.bearing_deg, 0.0))
	_assert_bool(
		fails, "PC-04b bearing from emit epoch (%.1f deg)" % r.bearing_deg, brg_err < 2.0, true
	)
	_assert_bool(fails, "PC-04c timestamp = emit epoch", absf(r.timestamp - 100.0) < 1e-6, true)
	_assert_bool(fails, "PC-04d available_time set", r.available_time >= 100.0 + tau - 1.0, true)
	var re: float = r.range_m
	# sigma = range_ref*0.02 + 30/SE（collect 同源），300m 处约 6-40m。
	_assert_bool(fails, "PC-04e range from emit epoch (%.0f m)" % re, absf(re - 300.0) < 45.0, true)


## ---- PC-05：己方声学可见但安全 ----
func _pc_05_own_safety(fails: Array) -> void:
	var w := _mk_target_world()
	# PC-05a：玩家 seeker 适配器含本艇声源 + OWN token。
	var ad: TorpedoSensorAdapter = w.torpedo_ctx.sensor_adapter
	var own: TruthEntity = w.world["own"]
	var has_own: bool = false
	for c in ad.contacts:
		if str(c.id) == str(own.id):
			has_own = true
			break
	_assert_bool(fails, "PC-05a1 adapter contacts include own ship", has_own, true)
	_assert_bool(
		fails, "PC-05a2 own token OWN", str(ad.contact_tokens.get(str(own.id), "")) == "OWN", true
	)
	# 直接采样本艇方向：return 应带 OWN token。
	var ac_own: RefCounted = AcousticProfile.new()
	ac_own.broadband_base_level_db = 185.0
	ac_own.speed_noise_a = 0.0
	var ad2 := TorpedoSensorAdapter.new()
	ad2.bind(w.world["env"], w.world["depth_model"], [own], {str(own.id): ac_own})
	ad2.contact_tokens = {str(own.id): "OWN"}
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 11
	ad2.set_rng(rng)
	var prof := TorpedoAcousticProfile.make_default()
	var rets: Array = ad2.sample_passive(0.0, 0.0, 60.0, 40.0, 0.0, prof, 10.0)
	var own_ret: SeekerReturn = null
	for r in rets:
		if str(r.source_token) == "OWN":
			own_ret = r
			break
	_assert_bool(fails, "PC-05a3 own returns carry OWN token", own_ret != null, true)
	# PC-05a4：torpedo 拒绝 OWN return（事件 + 不进航迹）。
	var tp: Torpedo = w.weapons.fire_bearing_only(90.0, 0.0, 0.0, w.sim_time, 50.0)
	_assert_bool(fails, "PC-05a4 launch ok", tp != null, true)
	if tp != null and own_ret != null:
		var evs: Array = []
		tp.event_occurred.connect(func(id, ev, detail): evs.append(ev))
		tp._record_seeker_returns([own_ret])
		var rejected: bool = evs.has("CONTACT_REJECTED_SAFETY")
		var in_tracks: bool = false
		if tp._seeker != null:
			for t in tp._seeker.tracks:
				in_tracks = true
		_assert_bool(fails, "PC-05a5 safety rejection event", rejected, true)
		_assert_bool(fails, "PC-05a6 OWN not in seeker tracks", not in_tracks, true)
	# PC-05b：引信独立安全保险——本艇上方不起爆，敌目标上方照常起爆。
	var tp2: Torpedo = w.weapons.fire_bearing_only(90.0, 0.0, 0.0, w.sim_time, 50.0)
	if tp2 != null:
		w.run_steps(10)  # 出管入水 + 解保时间
		var evs2: Array = []
		tp2.event_occurred.connect(func(id, ev, detail): evs2.append(ev))
		tp2.fuze_state = tp2.FuzeState.ARMED
		tp2.traveled_m = 5000.0
		tp2.pos_east_m = 5.0
		tp2.pos_north_m = 0.0
		tp2.actual_depth_m = float(w.world["own"].depth_m)
		w._fuze_step_torpedo(tp2, w.world["targets"], true)
		_assert_bool(fails, "PC-05b1 no detonation on own ship", not tp2.is_dead(), true)
		_assert_bool(fails, "PC-05b2 safety inhibit event", evs2.has("FUZE_SAFETY_INHIBIT"), true)
	# 敌目标上方照常起爆（安全保险只对本侧生效）。
	var w3 := _mk_target_world()
	var tgt: TruthEntity = w3.world["targets"][0]
	var tp3: Torpedo = (
		w3
		. weapons
		. fire_bearing_only(
			NavUtils.bearing_to_true(
				0.0, 0.0, float(tgt.position_east_m), float(tgt.position_north_m)
			),
			0.0,
			0.0,
			w3.sim_time,
			50.0,
		)
	)
	if tp3 != null:
		w3.run_steps(10)  # 出管入水 + 解保时间
		tp3.fuze_state = tp3.FuzeState.ARMED
		tp3.traveled_m = 5000.0
		tp3.pos_east_m = float(tgt.position_east_m)
		tp3.pos_north_m = float(tgt.position_north_m)
		tp3.actual_depth_m = float(tgt.depth_m)
		w3._fuze_step_torpedo(tp3, w3.world["targets"], true)
		_assert_bool(fails, "PC-05b3 detonation on enemy still works", tp3.is_dead(), true)
