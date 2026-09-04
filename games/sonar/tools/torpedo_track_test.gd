extends SceneTree
## torpedo_track_test.gd — S1-07 Commit 7 SeekerTrack + Guidance 无头验收
## （§7.1-§7.8 + §14.2 WPN-SEEK-06..13）。
##
## 覆盖：
##   SEEK-06  单次 return 不立即稳定锁定（lock < acquire_threshold）。
##   SEEK-07  连续 return：SEARCH → ACQUIRING → TRACKING（滞回阈值）。
##   SEEK-08  连续 miss（源消失/出 FOV）→ lock 衰减 → LOST。
##   SEEK-09  LOST 后重搜扇区围绕最后预测方位（绝不跟随 Truth）；Torpedo 在
##            LOST 中转向仍受 turn rate 限制、不指向真实目标方位。
##   SEEK-10  目标重回声场 → REACQUIRE → TRACKING。
##   SEEK-11  多目标 score 竞争：质量优先；高 SE 持续命中可翻转；
##            continuity bonus 不永久护锁。
##   SEEK-12  Guidance/Track API 只接受 SeekerReturn/SeekerTrack——净化摘要
##            无 target_id/Truth 字段。
##   SEEK-13  转向受 max_turn_rate 限制（无瞬时指向）。
##   WIRE     WIRE_ONLY 下即使持续听到目标也不擅自转向。
##   SWEEP    SEARCH 无目标时按程序扇区 SNAKE 扫掠（限速率、不出扇区+容差）。
##
## 全部确定性（合成 return 固定序列 + 固定 seed RNG），可无头运行：
##   godot --headless --path games/sonar --script res://tools/torpedo_track_test.gd

const DT: float = 0.5
const SEED: int = 20260904
const RATE_EPS: float = 0.6  # 转向率断言容差（度/步）

var _ret_seq: int = 1


func _initialize() -> void:
	var fails: Array = []
	_trk_06_single_no_lock(fails)
	_trk_07_08_acquire_then_lost(fails)
	_trk_10_reacquire(fails)
	_trk_11_score_competition(fails)
	_trk_12_sanitized_api(fails)
	_trk_13_09_turn_rate_and_lost_not_truth(fails)
	_wire_only_no_steer(fails)
	_sweep_search_sector(fails)
	_finish(fails)


## ---- SEEK-06：单次 return 不立即锁定 ----
func _trk_06_single_no_lock(fails: Array) -> void:
	var s := _mk_seeker()
	s.process_returns([_mk_ret(30.0, 20.0, 100.0)], 100.0)
	s.update(100.0)
	if s.tracks.size() != 1:
		fails.append("SEEK-06a expected 1 track got %d" % s.tracks.size())
	var t: SeekerTrack = s.tracks[0]
	_assert_bool(fails, "SEEK-06b single return below acquire", t.lock_quality < 0.65, true)
	_assert_bool(fails, "SEEK-06c phase stays SEARCH", s.phase == TorpedoSeeker.Phase.SEARCH, true)
	_assert_bool(fails, "SEEK-06d no selection", s.selected_track_id == -1, true)


## ---- SEEK-07/08：连续命中捕获 → 连续 miss 丢失 ----
func _trk_07_08_acquire_then_lost(fails: Array) -> void:
	var s := _mk_seeker()
	var now: float = 100.0
	var saw_acquiring: bool = false
	var tracking: bool = false
	for i in range(10):
		s.process_returns([_mk_ret(30.0 + 0.1 * i, 20.0, now)], now)
		now += 1.0
		s.update(now)
		if s.phase == TorpedoSeeker.Phase.ACQUIRING:
			saw_acquiring = true
		if s.phase == TorpedoSeeker.Phase.TRACKING:
			tracking = true
			break
	_assert_bool(fails, "SEEK-07a passed through ACQUIRING", saw_acquiring, true)
	_assert_bool(fails, "SEEK-07b reached TRACKING", tracking, true)
	# miss：源消失（无 return），每 1.2s 窗口 β_miss 惩罚 → drop 以下 → LOST。
	var lost: bool = false
	for i in range(12):
		now += 1.2
		s.update(now)
		if s.phase == TorpedoSeeker.Phase.LOST:
			lost = true
			break
	_assert_bool(fails, "SEEK-08 consecutive miss -> LOST", lost, true)


## ---- SEEK-10：丢失后目标重回声场 → REACQUIRE → TRACKING ----
func _trk_10_reacquire(fails: Array) -> void:
	var s := _mk_seeker()
	var now: float = 100.0
	for i in range(10):
		s.process_returns([_mk_ret(30.0, 20.0, now)], now)
		now += 1.0
		s.update(now)
	for i in range(12):
		now += 1.2
		s.update(now)
	_assert_bool(fails, "SEEK-10a precondition LOST", s.phase == TorpedoSeeker.Phase.LOST, true)
	var reacq: bool = false
	var retracking: bool = false
	for i in range(8):
		s.process_returns([_mk_ret(32.0, 20.0, now)], now)
		now += 1.0
		s.update(now)
		if s.phase == TorpedoSeeker.Phase.REACQUIRE:
			reacq = true
		if s.phase == TorpedoSeeker.Phase.TRACKING:
			retracking = true
			break
	_assert_bool(fails, "SEEK-10b REACQUIRE", reacq, true)
	_assert_bool(fails, "SEEK-10c re-TRACKING", retracking, true)


## ---- SEEK-11：多目标 score 竞争（质量优先；持续高 SE 翻转；bonus 非永久）----
func _trk_11_score_competition(fails: Array) -> void:
	var s := _mk_seeker()
	var now: float = 100.0
	# A：中等 SE 连续命中（质量高）；B：单次高 SE（质量低）。
	for i in range(4):
		var rs: Array = [_mk_ret(30.0, 15.0, now)]
		if i == 0:
			rs.append(_mk_ret(100.0, 25.0, now))
		s.process_returns(rs, now)
		now += 1.0
		s.update(now)
	# 航迹按方位识别（track id 与 return id 是两个序列，勿混）。
	var id_a: int = -1
	var id_b: int = -1
	for t in s.tracks:
		if absf(NavUtils.wrap180(t.bearing_estimate_deg - 30.0)) < 5.0:
			id_a = t.seeker_track_id
		elif absf(NavUtils.wrap180(t.bearing_estimate_deg - 100.0)) < 5.0:
			id_b = t.seeker_track_id
	_assert_bool(fails, "SEEK-11pre both tracks exist", id_a >= 0 and id_b >= 0, true)
	_assert_bool(fails, "SEEK-11a quality beats loud single", s.selected_track_id == id_a, true)
	# B 持续强命中，A 消失（miss 衰减）→ score 翻转（continuity bonus 非永久）。
	var flipped: bool = false
	for i in range(10):
		var rs: Array = [_mk_ret(100.0 + 0.05 * i, 30.0, now)]
		s.process_returns(rs, now)
		now += 1.2
		s.update(now)
		if s.selected_track_id == id_b:
			flipped = true
			break
	_assert_bool(fails, "SEEK-11b sustained score flips selection", flipped, true)


## ---- SEEK-12：净化 API（无 target_id / Truth 字段）----
func _trk_12_sanitized_api(fails: Array) -> void:
	var s := _mk_seeker()
	var now: float = 100.0
	for i in range(6):
		s.process_returns([_mk_ret(45.0, 20.0, now)], now)
		now += 1.0
		s.update(now)
	var t: SeekerTrack = s.tracks[0]
	var summary: Dictionary = t.to_summary()
	for bad in ["target_id", "truth", "position", "damage_state", "course_deg", "speed_kn"]:
		if summary.has(bad):
			fails.append("SEEK-12a summary leaks key %s" % bad)
	# Guidance 纯函数只吃 track/数值。
	var course: float = TorpedoGuidance.pursuit_course_deg(t, {"lead_time_s": 12.0})
	if course < 0.0 or course >= 360.0:
		fails.append("SEEK-12b pursuit course out of range %s" % str(course))
	var hist_ok: bool = true
	for rid in t.source_history:
		if typeof(rid) != TYPE_INT:
			hist_ok = false
	_assert_bool(fails, "SEEK-12c source_history sanitized ids", hist_ok, true)


## ---- SEEK-13/09：整合——有限转向率捕获；丢源后 LOST 重搜不跟 Truth ----
func _trk_13_09_turn_rate_and_lost_not_truth(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var contact: Dictionary = _contact("TG-A", 200.0, 800.0, 50.0, 6.0, 200.0)
	var adapter := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
	adapter.set_rng(_rng(SEED + 7))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = AcousticEmissionBus.new()
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	var prog := _mk_program(WeaponProgram.GuidanceAuthority.AUTONOMOUS)
	tp.launch("S7", prog, 0.0, 0.0, 50.0, sim_t)
	var tracking: bool = false
	var max_delta: float = 0.0
	var prev_course: float = 0.0
	for i in range(80):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		var d: float = absf(NavUtils.wrap180(tp.course_deg - prev_course))
		max_delta = maxf(max_delta, d)
		prev_course = tp.course_deg
		if tp.seeker_state_name() == "TRACKING":
			tracking = true
			break
	_assert_bool(fails, "SEEK-13a integrated TRACKING", tracking, true)
	_assert_bool(
		fails,
		"SEEK-13b turn rate limited (%.2f/step)" % max_delta,
		max_delta <= tp.max_turn_rate_deg_s * DT + RATE_EPS,
		true,
	)
	# SEEK-09：撤源 → miss → LOST；LOST 中转向仍限速率且不指向 Truth 方位。
	adapter.contacts = []
	var lost: bool = false
	var max_delta2: float = 0.0
	prev_course = tp.course_deg
	for i in range(60):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		max_delta2 = maxf(max_delta2, absf(NavUtils.wrap180(tp.course_deg - prev_course)))
		prev_course = tp.course_deg
		if tp.seeker_state_name() == "LOST":
			lost = true
			break
	for i in range(40):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		max_delta2 = maxf(max_delta2, absf(NavUtils.wrap180(tp.course_deg - prev_course)))
		prev_course = tp.course_deg
	_assert_bool(fails, "SEEK-09a source removed -> LOST", lost, true)
	_assert_bool(
		fails,
		"SEEK-09b lost-phase turn still rate limited",
		max_delta2 <= tp.max_turn_rate_deg_s * DT + RATE_EPS,
		true,
	)
	# Truth 方位（真源固定在 (200,800)）：鱼雷在 LOST 重搜中绝不满舵直指真源。
	var true_brg: float = NavUtils.bearing_to_true(tp.pos_east_m, tp.pos_north_m, 200.0, 800.0)
	var off: float = absf(NavUtils.wrap180(tp.course_deg - true_brg))
	_assert_bool(fails, "SEEK-09c not homing truth (%.1f off)" % off, off > 5.0, true)
	# SEEK-10b：目标重回声场 → REACQUIRE/TRACKING。
	adapter.contacts = [contact["entity"]]
	var relocked: bool = false
	for i in range(60):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.seeker_state_name() == "TRACKING":
			relocked = true
			break
	_assert_bool(fails, "SEEK-10d in-water reacquire", relocked, true)


## ---- WIRE_ONLY：持续听到目标也不擅自转向 ----
func _wire_only_no_steer(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var contact: Dictionary = _contact("TG-B", 200.0, 800.0, 50.0, 6.0, 200.0)
	var adapter := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
	adapter.set_rng(_rng(SEED + 11))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = AcousticEmissionBus.new()
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	var prog := _mk_program(WeaponProgram.GuidanceAuthority.WIRE_ONLY)
	tp.launch("S8", prog, 0.0, 0.0, 50.0, sim_t)
	var tracking: bool = false
	var max_dev: float = 0.0
	for i in range(100):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		max_dev = maxf(max_dev, absf(NavUtils.wrap180(tp.course_deg - 0.0)))
		if tp.seeker_state_name() == "TRACKING":
			tracking = true
			break
	_assert_bool(fails, "WIRE-a hears target (TRACKING)", tracking, true)
	_assert_bool(
		fails, "WIRE-b never steers on its own (%.2f max dev)" % max_dev, max_dev <= 0.5, true
	)


## ---- SEARCH 扫掠：fallback 后无目标，SNAKE 扇区扫掠（限速率、不出扇区）----
func _sweep_search_sector(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var adapter := _mk_adapter(env, dm, [], {})
	adapter.set_rng(_rng(SEED + 13))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = AcousticEmissionBus.new()
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	var prog := _mk_program(WeaponProgram.GuidanceAuthority.AUTONOMOUS)
	prog.search_center_deg = 0.0
	prog.search_half_angle_deg = 45.0
	tp.launch("S9", prog, 0.0, 0.0, 50.0, sim_t)
	for i in range(6):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	tp.cut_wire()  # → fallback → SEARCH + 预设扇区扫掠
	var entered_search: bool = false
	var max_dev: float = 0.0
	var max_delta: float = 0.0
	var prev_course: float = tp.course_deg
	var direction_flips: int = 0
	var prev_err: float = 0.0
	for i in range(360):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.mission_state_name() == "SEARCH":
			entered_search = true
		var err: float = NavUtils.wrap180(tp.course_deg - prog.search_center_deg)
		max_dev = maxf(max_dev, absf(err))
		max_delta = maxf(max_delta, absf(NavUtils.wrap180(tp.course_deg - prev_course)))
		if absf(err) > 1.0 and err * prev_err < 0.0:
			direction_flips += 1
		if absf(err) > 1.0:
			prev_err = err
		prev_course = tp.course_deg
	_assert_bool(fails, "SWEEP-a entered SEARCH", entered_search, true)
	_assert_bool(fails, "SWEEP-b stays in sector (%.1f)" % max_dev, max_dev <= 45.0 + 15.0, true)
	_assert_bool(
		fails,
		"SWEEP-c rate limited (%.2f/step)" % max_delta,
		max_delta <= tp.max_turn_rate_deg_s * DT + RATE_EPS,
		true,
	)
	_assert_bool(fails, "SWEEP-d sweeps back and forth", direction_flips >= 1, true)


## ---- helpers ----
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


func _mk_ret(
	bearing: float, se: float, now: float, range_m: float = -1.0, sigma: float = 2.0
) -> SeekerReturn:
	var r := SeekerReturn.new()
	r.return_id = _ret_seq
	_ret_seq += 1
	r.detected = true
	r.sensor_mode = "ACTIVE" if range_m >= 0.0 else "PASSIVE"
	r.timestamp = now
	r.available_time = now
	r.bearing_deg = bearing
	r.bearing_sigma_deg = sigma
	r.signal_excess_db = se
	r.detection_probability = 0.9
	r.range_m = range_m
	r.range_sigma_m = 20.0 if range_m >= 0.0 else -1.0
	r.depth_relation = "SAME_LAYER"
	return r


func _env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


func _depth_model() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world.get("depth_model", null)


func _mk_adapter(
	env_ref: RefCounted, dm: RefCounted, contacts_arr: Array, acs: Dictionary
) -> TorpedoSensorAdapter:
	var ad := TorpedoSensorAdapter.new()
	ad.bind(env_ref, dm, contacts_arr, acs)
	return ad


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _contact(
	id: String, e: float, n: float, depth: float, kn: float, base_sl: float
) -> Dictionary:
	var t := TruthEntity.new()
	t.id = id
	t.side = "red"
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = depth
	t.course_deg = 0.0
	t.speed_kn = kn
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = base_sl
	ac.tonal_lines = [{"freq_hz": 1500.0, "level_db": base_sl - 12.0}]
	return {"id": id, "entity": t, "ac": ac}


func _mk_program(authority: int) -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.MANUAL
	p.initial_course_deg = 0.0
	p.speed_mode = WeaponProgram.SpeedMode.QUIET
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_center_deg = 0.0
	p.guidance_authority = authority
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
		print("TRK_FAIL ", f)
	if fails.is_empty():
		print("TORPEDO_TRACK_TEST result=PASS")
	else:
		print("TORPEDO_TRACK_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
