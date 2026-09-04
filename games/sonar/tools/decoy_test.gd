extends SceneTree
## decoy_test.gd — S1-07 Commit 8 诱饵与干扰 + 谱线细节 无头验收
## （§8.1-§8.6 + §14.4 CM-01..05 + §6.1 谱线 / §7.4 w_c 分类）。
##
## 覆盖：
##   CM-01  玩家与敌方均能经 CountermeasureSystem 发射诱饵（同一类，origin
##          只是 TruthEntity；绝不因 side 区分能力）。
##   CM-02  有限库存（ready_rounds 用尽拒发）/ 冷却 / 激活延时 / 有限寿命。
##   CM-03  诱饵作为普通 AcousticContact 进 adapter：同一条声学采样链出
##          return，谱特征来自其 AcousticProfile（激活前静默由 World 控制）。
##   CM-04  Seeker 不读 is_decoy：诱饵 return 与潜艇 return 结构同键；
##          SeekerTrack 摘要/SeekerReturn 无任何类型/Truth 字段。
##   CM-05  固定 seed 可复现；诱饵近/强/谱稳 → score 竞争拉走锁定
##          （不读 is_decoy，纯声学竞争）；World 集成（激活事件/到期移除）。
##   SPEC   §6.1 鱼雷运行噪声谱线随模式（QUIET/CRUISE/HIGH 不同谱线）；
##          §7.4 w_c 分类一致性：稳定谱保持高、抖动假峰被稀释。
##
## 全部确定性（固定 seed），可无头运行：
##   godot --headless --path games/sonar --script res://tools/decoy_test.gd

const DT: float = 0.5
const SEED: int = 20260904

var _ret_seq: int = 1


func _initialize() -> void:
	var fails: Array = []
	_cm_01_launchers(fails)
	_cm_02_budget_cooldown_life(fails)
	_cm_03_04_acoustic_contact_no_leak(fails)
	_cm_05_pull_lock_and_determinism(fails)
	_world_integration(fails)
	_spec_01_torpedo_tonals(fails)
	_spec_02_classification(fails)
	_finish(fails)


## ---- CM-01：玩家与敌方均能发射（同一类，origin 任意 TruthEntity）----
func _cm_01_launchers(fails: Array) -> void:
	var cm := _mk_cm()
	var own := _mk_truth("OWN", 0.0, 0.0, "blue")
	var enemy := _mk_truth("E1", 5000.0, 5000.0, "red")
	var d1: Decoy = cm.launch(_mk_prog(), own, 100.0, _rng(1), 70.0, 70.0)
	_assert_bool(fails, "CM-01a player launch", d1 != null, true)
	var cm2 := _mk_cm()
	var d2: Decoy = cm2.launch(_mk_prog(), enemy, 100.0, _rng(2), 70.0, 70.0)
	_assert_bool(fails, "CM-01b enemy launch", d2 != null, true)
	if d2 != null:
		_assert_bool(fails, "CM-01c spawns at origin", d2.position_east_m == 5000.0, true)


## ---- CM-02：库存/冷却/激活延时/寿命 ----
func _cm_02_budget_cooldown_life(fails: Array) -> void:
	var cm := _mk_cm()  # ready 2, cooldown 10
	var own := _mk_truth("OWN", 0.0, 0.0, "blue")
	var d1: Decoy = cm.launch(_mk_prog(), own, 100.0, _rng(3), 70.0, 70.0)
	_assert_bool(fails, "CM-02a first ok", d1 != null, true)
	var d2: Decoy = cm.launch(_mk_prog(), own, 101.0, _rng(3), 70.0, 70.0)
	_assert_bool(fails, "CM-02b cooldown blocks", d2 == null, true)
	var d3: Decoy = cm.launch(_mk_prog(), own, 111.0, _rng(3), 70.0, 70.0)
	_assert_bool(fails, "CM-02c after cooldown ok", d3 != null, true)
	var d4: Decoy = cm.launch(_mk_prog(), own, 200.0, _rng(3), 70.0, 70.0)
	_assert_bool(fails, "CM-02d rounds exhausted", d4 == null, true)
	# 激活延时 + 寿命
	var rng := _rng(9)
	var d: Decoy = Decoy.new()
	d.deploy(_mk_prog(), own, 70.0, 70.0)
	d.bind_signature(_mk_ac(200.0, true))
	var just: bool = d.step(1.0)
	_assert_bool(fails, "CM-02e silent before delay", not d.activated and not just, true)
	just = d.step(1.5)
	_assert_bool(fails, "CM-02f activates at delay", d.activated and just, true)
	var expired_seen: bool = false
	for i in range(200):
		d.step(1.0)
		if d.expired:
			expired_seen = true
			break
	_assert_bool(fails, "CM-02g finite lifetime", expired_seen, true)


## ---- CM-03/04：普通 AcousticContact + 无 is_decoy 泄露 ----
func _cm_03_04_acoustic_contact_no_leak(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	# 潜艇与诱饵同强度、近距——返回结构必须同键（仅几何错开以区分两者）。
	var sub := _mk_truth("SUB", 0.0, 800.0, "red")
	var dcy := Decoy.new()
	dcy.id = "DCY-X"
	dcy.position_east_m = 300.0
	dcy.position_north_m = 800.0
	dcy.depth_m = 50.0
	dcy.speed_kn = 6.0
	dcy.activated = true
	var ac_sub: RefCounted = _mk_ac(180.0, true)
	var ac_dcy: RefCounted = _mk_ac(180.0, true)
	var ad := TorpedoSensorAdapter.new()
	ad.bind(env, dm, [sub, dcy], {"SUB": ac_sub, "DCY-X": ac_dcy})
	ad.set_rng(_rng(SEED + 21))
	var prof := TorpedoAcousticProfile.make_default()
	var rs: Array = ad.sample_passive(0.0, 0.0, 50.0, 28.0, 0.0, prof, 100.0)
	_assert_bool(fails, "CM-03a decoy sampled in same chain", rs.size() >= 1, true)
	var keys_sub: Array = []
	var keys_dcy: Array = []
	for r in rs:
		var d: Dictionary = r.to_dict()
		if r.bearing_deg > 10.0 and keys_dcy.is_empty():
			keys_dcy = d.keys()
		elif r.bearing_deg <= 10.0 and keys_sub.is_empty():
			keys_sub = d.keys()
	if not keys_dcy.is_empty() and not keys_sub.is_empty():
		keys_dcy.sort()
		keys_sub.sort()
		_assert_bool(fails, "CM-04a identical return schema", str(keys_dcy) == str(keys_sub), true)
	for r in rs:
		var d: Dictionary = r.to_dict()
		for bad in ["is_decoy", "decoy", "target_id", "damage_state", "platform_type"]:
			if d.has(bad):
				fails.append("CM-04b return leaks key %s" % bad)
		var trk := SeekerTrack.create()
		trk.update_with_return(r, 100.0, {})
		var summary: Dictionary = trk.to_summary()
		for bad in ["is_decoy", "decoy", "target_id", "truth", "position"]:
			if summary.has(bad):
				fails.append("CM-04c summary leaks key %s" % bad)


## ---- CM-05：固定 seed 复现 + 近/强/谱稳诱饵拉走锁定（纯声学竞争）----
func _cm_05_pull_lock_and_determinism(fails: Array) -> void:
	var courses_a: Array = _run_pull_scenario(fails, SEED + 31)
	var courses_b: Array = _run_pull_scenario(fails, SEED + 31)
	_assert_bool(fails, "CM-05a same seed reproducible", str(courses_a) == str(courses_b), true)
	# 拉锁断言在 _run_pull_scenario 内部完成（几何：诱饵更近更强谱稳）。


## 跑一遍拉锁场景，返回每隔 5 步的航向序列；内部断言锁定被诱饵拉走。
func _run_pull_scenario(fails: Array, seed_v: int) -> Array:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	# 真目标 A：较远、中等强度；诱饵 D：方位错开（> 关联门限）、更近更强谱稳。
	var tgt_a := _mk_truth("TG-A", 100.0, 1200.0, "red")
	tgt_a.depth_m = 50.0
	tgt_a.speed_kn = 6.0
	var dcy := Decoy.new()
	dcy.id = "DCY-D"
	dcy.position_east_m = 700.0
	dcy.position_north_m = 800.0
	dcy.depth_m = 50.0
	dcy.speed_kn = 8.0
	dcy.activated = true
	var ad := TorpedoSensorAdapter.new()
	(
		ad
		. bind(
			env,
			dm,
			[tgt_a, dcy],
			{"TG-A": _mk_ac(175.0, true), "DCY-D": _mk_ac(200.0, true)},
		)
	)
	ad.set_rng(_rng(seed_v))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = AcousticEmissionBus.new()
	ctx.sensor_adapter = ad
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	var prog := _mk_program()
	tp.launch("SD", prog, 0.0, 0.0, 50.0, sim_t)
	var courses: Array = []
	var locked: bool = false
	for i in range(360):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if i % 5 == 0:
			courses.append(snappedf(tp.course_deg, 0.01))
		if tp.seeker_state_name() == "TRACKING":
			locked = true
			if courses.size() > 30:
				break
	_assert_bool(fails, "CM-05b precondition TRACKING", locked, true)
	if locked:
		# 净化侧：选中航迹的估计方位应贴近诱饵真方位，远离真目标真方位。
		var brg_a: float = NavUtils.bearing_to_true(
			tp.pos_east_m, tp.pos_north_m, tgt_a.position_east_m, tgt_a.position_north_m
		)
		var brg_d: float = NavUtils.bearing_to_true(
			tp.pos_east_m, tp.pos_north_m, dcy.position_east_m, dcy.position_north_m
		)
		var sel: SeekerTrack = tp._seeker.selected_track()
		if sel != null:
			var off_d: float = absf(NavUtils.wrap180(sel.bearing_estimate_deg - brg_d))
			var off_a: float = absf(NavUtils.wrap180(sel.bearing_estimate_deg - brg_a))
			_assert_bool(
				fails,
				"CM-05c pulled toward decoy (offD=%.1f offA=%.1f)" % [off_d, off_a],
				off_d < 10.0 and off_a > 10.0,
				true,
			)
	return courses


## ---- World 集成：launch_decoy / 激活事件 / 到期移除 / 静默期不进采样集 ----
func _world_integration(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var prog := _mk_prog()
	prog.activation_delay_s = 2.0
	prog.lifetime_s = 8.0
	_assert_bool(fails, "WI-a launch ok", w._launch_decoy(prog), true)
	_assert_bool(fails, "WI-b in decoys list", w.decoys.size() == 1, true)
	# 激活前不进武器采样集（静默）。P0-06：采样集含本艇声源（统一声场），
	# 按成员断言而非计数。
	w.run_steps(1)
	var decoy_id: String = str(w.decoys[0].id)
	var decoy_in: bool = false
	for c in w._weapon_contacts:
		if str(c.id) == decoy_id:
			decoy_in = true
	_assert_bool(
		fails,
		"WI-c silent before activation",
		not decoy_in and w._weapon_contacts.size() >= 1,
		true,
	)
	# 推进至激活（dt 以场景为准）：出现 DECOY_ACTIVATION 事件并进入采样集。
	for i in range(40):
		w.run_steps(1)
		if not w.emission_bus.events_of_kind(AcousticEmissionEvent.DECOY_ACTIVATION).is_empty():
			break
	_assert_bool(
		fails,
		"WI-d activation event recorded",
		not w.emission_bus.events_of_kind(AcousticEmissionEvent.DECOY_ACTIVATION).is_empty(),
		true,
	)
	decoy_in = false
	for c2 in w._weapon_contacts:
		if str(c2.id) == decoy_id:
			decoy_in = true
	_assert_bool(fails, "WI-e decoy enters sampling set", decoy_in, true)
	# 推进至寿命到期：移出活动列表与采样集。
	for i in range(60):
		if w.decoys.is_empty():
			break
		w.run_steps(1)
	_assert_bool(fails, "WI-f expired removed", w.decoys.is_empty(), true)
	decoy_in = false
	for c3 in w._weapon_contacts:
		if str(c3.id) == decoy_id:
			decoy_in = true
	_assert_bool(fails, "WI-g contacts pruned", not decoy_in, true)
	# 等发射器冷却走完（首射后 10s），ready_rounds 还有 1 发 → 第二发可用。
	for i in range(40):
		if w.countermeasures.cooldown_left(w.sim_time) <= 0.0:
			break
		w.run_steps(1)
	var prog2 := _mk_prog()
	_assert_bool(fails, "WI-h second round available", w._launch_decoy(prog2), true)


## ---- SPEC-01：鱼雷运行噪声谱线随速度模式（§6.1）----
func _spec_01_torpedo_tonals(fails: Array) -> void:
	var bus := AcousticEmissionBus.new()
	var tp := Torpedo.new()
	var prog := _mk_program()
	prog.speed_mode = WeaponProgram.SpeedMode.CRUISE
	tp.launch("S1", prog, 0.0, 0.0, 50.0, 100.0)
	var ctx := TorpedoContext.new()
	ctx.emission_bus = bus
	for i in range(6):
		tp.step(DT, 100.0 + DT * i, ctx)
	var ev_cr: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_RUNNING_NOISE)
	_assert_bool(fails, "SPEC-1a running noise emitted", not ev_cr.is_empty(), true)
	if ev_cr.is_empty():
		return
	var tonals_cr: Array = ev_cr[-1].get("tonal_lines", [])
	_assert_bool(fails, "SPEC-1b tonal lines attached", not tonals_cr.is_empty(), true)
	# HIGH 模式谱线不同（位置/强度）。
	var prof := TorpedoAcousticProfile.make_default()
	var t_cr: Array = prof.tonal_lines("CRUISE")
	var t_hi: Array = prof.tonal_lines("HIGH")
	_assert_bool(
		fails,
		"SPEC-1c mode changes spectrum",
		str(t_cr) != str(t_hi) and not t_hi.is_empty(),
		true,
	)


## ---- SPEC-02：谱一致性分类（稳定谱高 / 抖动假峰稀释 / score w_c 生效）----
func _spec_02_classification(fails: Array) -> void:
	var s := _mk_seeker()
	var now: float = 100.0
	# 稳定谱航迹：每次同谱线 → classification_match 保持 1.0。
	for i in range(5):
		s.process_returns([_mk_ret(30.0, 20.0, now, [500.0, 1000.0])], now)
		now += 1.0
		s.update(now)
	_assert_bool(fails, "SPEC-2a stable keeps 1.0", s.tracks[0].classification_match > 0.99, true)
	# 抖动谱航迹（JAMMER 假峰漂移 > 容差）→ 一致性被稀释。
	var s2 := _mk_seeker()
	now = 100.0
	var jitter_sets: Array = [
		[500.0, 1000.0], [560.0, 1060.0], [440.0, 940.0], [570.0, 1070.0], [430.0, 930.0]
	]
	for i in range(5):
		s2.process_returns([_mk_ret(60.0, 20.0, now, jitter_sets[i])], now)
		now += 1.0
		s2.update(now)
	_assert_bool(
		fails,
		"SPEC-2b jitter diluted (%.2f)" % s2.tracks[0].classification_match,
		s2.tracks[0].classification_match < 0.8,
		true,
	)
	# 等质量/等 SE 下，稳定谱 score > 抖动谱 score（w_c 项生效）。
	var cfg := {"w_classification": 0.5}
	var ta := SeekerTrack.create()
	var tb := SeekerTrack.create()
	var t: float = 100.0
	for i in range(4):
		ta.update_with_return(_mk_ret(30.0, 20.0, t, [500.0, 1000.0]), t, cfg)
		tb.update_with_return(_mk_ret(30.0, 20.0, t, jitter_sets[i]), t, cfg)
		t += 1.0
	_assert_bool(
		fails, "SPEC-2c stable outscores jitter", ta.score(cfg, false) > tb.score(cfg, false), true
	)


## ---- helpers ----
func _mk_cm() -> CountermeasureSystem:
	var cm := CountermeasureSystem.new()
	cm.configure({"ready_rounds": 2, "inventory": 2, "launch_cooldown_s": 10.0})
	return cm


func _mk_prog() -> DecoyProgram:
	var p := DecoyProgram.new()
	p.decoy_type = DecoyProgram.TYPE_MOBILE
	p.launch_bearing_deg = 45.0
	p.course_deg = 45.0
	p.speed_kn = 8.0
	p.activation_delay_s = 2.0
	p.lifetime_s = 120.0
	p.signature = _mk_ac(200.0, true)
	return p


func _mk_ac(base_sl: float, with_tonals: bool) -> AcousticProfile:
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = base_sl
	if with_tonals:
		ac.tonal_lines = [
			{"freq_hz": 1500.0, "level_db": base_sl - 12.0},
			{"freq_hz": 3000.0, "level_db": base_sl - 18.0},
		]
	return ac


func _mk_truth(id: String, e: float, n: float, side_v: String) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = id
	t.side = side_v
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = 50.0
	t.speed_kn = 6.0
	return t


func _mk_seeker() -> TorpedoSeeker:
	var s := TorpedoSeeker.new()
	(
		s
		. configure(
			{
				"acquire_threshold": 0.65,
				"stable_track_threshold": 0.80,
				"drop_threshold": 0.25,
				"beta_miss": 0.10,
				"bearing_gate_deg": 12.0,
				"miss_after_s": 1.2,
				"reacquire_timeout_s": 120.0,
			}
		)
	)
	return s


func _mk_ret(bearing: float, se: float, now: float, tonal_freqs: Array = []) -> SeekerReturn:
	var r := SeekerReturn.new()
	r.return_id = _ret_seq
	_ret_seq += 1
	r.detected = true
	r.sensor_mode = "PASSIVE"
	r.timestamp = now
	r.available_time = now
	r.bearing_deg = bearing
	r.bearing_sigma_deg = 2.0
	r.signal_excess_db = se
	r.detection_probability = 0.9
	r.depth_relation = "SAME_LAYER"
	if not tonal_freqs.is_empty():
		var lines: Array = []
		for f in tonal_freqs:
			lines.append({"freq_hz": f, "level_db": 100.0})
		r.spectral_features = {"band_min_hz": 100.0, "band_max_hz": 3000.0, "tonal_hz": lines}
	return r


func _env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


func _depth_model() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world.get("depth_model", null)


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _mk_program() -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.MANUAL
	p.initial_course_deg = 0.0
	p.speed_mode = WeaponProgram.SpeedMode.QUIET
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_center_deg = 0.0
	p.guidance_authority = WeaponProgram.GuidanceAuthority.AUTONOMOUS
	p.wire_guidance_enabled = true
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 3000.0
	p.fallback_program = p.make_default_fallback()
	return p


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	for f in fails:
		print("CM_FAIL ", f)
	if fails.is_empty():
		print("DECOY_TEST result=PASS")
	else:
		print("DECOY_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
