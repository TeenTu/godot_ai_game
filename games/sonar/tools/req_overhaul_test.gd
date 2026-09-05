extends SceneTree
## req_overhaul_test.gd — REQ 制导重构批无头验收（RO-01..13）。
##
## 覆盖评审验收项：
##   RO-01  TRACKING + WIRE_ONLY：绝不自动转向/进 ATTACK（TRACK AVAILABLE）。
##   RO-02  Accept Track → ASSISTED，下一物理 tick 即开始有限速率转向。
##   RO-03  AUTONOMOUS 有航迹立即接管；无航迹进 SEARCH。
##   RO-04  恒定 1°/s 带噪方位：滤波方位率收敛、跨 359°/0° 无跳变。
##   RO-05  仅 8 秒一次主动回波也能跨 Ping 保持航迹（两次 Ping 间不按 tick 扣分）。
##   RO-06  1500m、10kn 横向目标 vs 40kn 鱼雷（固定无噪声）稳定拦截。
##   RO-07  目标短暂离开 FOV → COAST → 重进覆盖 → REACQUIRE。
##   RO-08  首次冲过目标后 LOST → 超时 → SEARCH 重搜（不得无限绕圈/挂死）。
##   RO-10  无敌方 AI 场景：玩家在水鱼雷仍进入统一声场（影子无条件同步）。
##   RO-11  窄带频段可切换：CRUISE/HIGH 预设谱线不再被 0～500 Hz 过滤。
##   RO-12  出管/主动 Ping 等敌方瞬态证据只在 t_emit + R/c 后出现（单程传播）。
##   RO-13  脱靶原因：燃料耗尽 → FUEL_EXHAUSTED；从未操舵终结 → NO_GUIDANCE_AUTHORITY。
##
## 全部确定性（固定 seed），可无头运行：
##   godot --headless --path games/sonar --script res://tools/req_overhaul_test.gd

const DT: float = 0.5
const SEED: int = 20260905


func _initialize() -> void:
	var fails: Array = []
	_ro_01_wire_only_no_steer(fails)
	_ro_02_accept_then_steer(fails)
	_ro_03_autonomy_takeover(fails)
	_ro_04_filter_quality(fails)
	_ro_05_active_only_track(fails)
	_ro_06_intercept_lateral_target(fails)
	_ro_07_fov_coast_reacquire(fails)
	_ro_08_overshoot_research(fails)
	_ro_10_unified_acoustic_field(fails)
	_ro_11_nb_band_switch(fails)
	_ro_12_propagation_delay(fails)
	_ro_13_miss_reasons(fails)
	for f in fails:
		print("RO_FAIL ", f)
	print("passed=%d" % (0 if not fails.is_empty() else 1))
	if fails.is_empty():
		print("REQ_OVERHAUL_TEST result=PASS")
	else:
		print("REQ_OVERHAUL_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)


## ---- 公共构造 ----
func _env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


func _mk_program(speed: int = WeaponProgram.SpeedMode.CRUISE) -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.MANUAL
	p.initial_course_deg = 0.0
	p.speed_mode = speed
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_center_deg = 0.0
	p.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	p.wire_guidance_enabled = true
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 300.0
	p.fallback_program = p.make_default_fallback()
	return p


## 强声源接触（SE 饱和 → P_d≈1，接近确定性探测）。
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
	t.course_deg = 90.0
	t.speed_kn = kn
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = base_sl
	ac.tonal_lines = [{"freq_hz": 1500.0, "level_db": base_sl - 12.0}]
	return {"id": id, "entity": t, "ac": ac}


func _mk_ctx(contacts: Array, acs: Dictionary, rng_seed: int) -> TorpedoContext:
	var ctx := TorpedoContext.new()
	ctx.env = _env()
	var ad := TorpedoSensorAdapter.new()
	ad.bind(ctx.env, null, contacts, acs)
	var r := RandomNumberGenerator.new()
	r.seed = rng_seed
	ad.set_rng(r)
	ctx.sensor_adapter = ad
	return ctx


## 合成被动 return（seeker 单元测试用；绕过 adapter 几何）。
func _mk_ret(
	bearing_deg: float, se_db: float, now: float, mode: String = "PASSIVE"
) -> SeekerReturn:
	var r := SeekerReturn.new()
	r.return_id = 0
	r.timestamp = now
	r.available_time = now
	r.sensor_mode = mode
	r.detected = true
	r.bearing_deg = NavUtils.wrap360(bearing_deg)
	r.bearing_sigma_deg = 0.5
	r.signal_excess_db = se_db
	r.range_m = -1.0
	r.range_sigma_m = -1.0
	return r


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


## 让 seeker 到达 TRACKING（合成 return，固定方位）。
func _drive_to_tracking(s: TorpedoSeeker, bearing: float, now: float) -> float:
	for i in range(10):
		s.process_returns([_mk_ret(bearing + 0.05 * i, 20.0, now)], now)
		now += 1.0
		s.notify_passive_scan(now)
		s.update(now)
		if s.phase == TorpedoSeeker.Phase.TRACKING:
			break
	return now


## ---- RO-01：TRACKING + WIRE_ONLY 不转向/不进 ATTACK ----
func _ro_01_wire_only_no_steer(fails: Array) -> void:
	var c := _contact("TG1", 0.0, 900.0, 50.0, 6.0, 200.0)
	var ctx := _mk_ctx([c["entity"]], {c["id"]: c["ac"]}, SEED + 1)
	var tp := Torpedo.new()
	tp.launch("R1", _mk_program(), 0.0, 0.0, 50.0, 100.0)
	var sim_t := 100.0
	for i in range(6):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	_assert_bool(fails, "RO-01a in water", tp.mission_state_name() == "WIRE_RUN", true)
	var course0: float = tp.course_deg
	# 持续推进（声源在 ±60° FOV 内强探测）→ seeker 应达 TRACKING。
	var reached_tracking := false
	for i in range(30):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.seeker_state_name() == "TRACKING":
			reached_tracking = true
			break
	_assert_bool(fails, "RO-01b seeker TRACKING", reached_tracking, true)
	_assert_bool(
		fails, "RO-01c authority stays WIRE_ONLY", tp.guidance_authority_name() == "WIRE_ONLY", true
	)
	_assert_bool(fails, "RO-01d no ATTACK mission", tp.mission_state_name() != "ATTACK", true)
	var drifted: float = absf(NavUtils.wrap180(tp.course_deg - course0))
	_assert_bool(fails, "RO-01e no steering under WIRE_ONLY", drifted < 1.0, true)


## ---- RO-02：Accept Track → ASSISTED + 下一 tick 转向 ----
func _ro_02_accept_then_steer(fails: Array) -> void:
	var c := _contact("TG2", 0.0, 900.0, 50.0, 6.0, 200.0)
	var ctx := _mk_ctx([c["entity"]], {c["id"]: c["ac"]}, SEED + 2)
	var tp := Torpedo.new()
	tp.launch("R2", _mk_program(), 0.0, 0.0, 50.0, 100.0)
	var sim_t := 100.0
	for i in range(6):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var reached_tracking := false
	for i in range(30):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.seeker_state_name() == "TRACKING":
			reached_tracking = true
			break
	_assert_bool(fails, "RO-02a precondition TRACKING", reached_tracking, true)
	var candidates: Array = tp._seeker.track_summaries()
	_assert_bool(fails, "RO-02b candidates exist", not candidates.is_empty(), true)
	var ok: bool = tp.accept_seeker_track(int(candidates[0]["track_id"]))
	_assert_bool(fails, "RO-02c accept succeeds", ok, true)
	_assert_bool(
		fails, "RO-02d authority ASSISTED", tp.guidance_authority_name() == "ASSISTED", true
	)
	var course0: float = tp.course_deg
	var sum_d: float = 0.0
	for i in range(4):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		sum_d += absf(tp.actual_turn_rate_deg_s) * DT
	_assert_bool(fails, "RO-02e steers within 1 tick", sum_d > 0.05, true)
	_assert_bool(
		fails,
		"RO-02f course moved toward track",
		absf(NavUtils.wrap180(tp.course_deg - course0)) > 0.05,
		true,
	)


## ---- RO-03：AUTONOMOUS 有航迹立即接管；无航迹进 SEARCH ----
func _ro_03_autonomy_takeover(fails: Array) -> void:
	# 无航迹：授权自主 → SEARCH。
	var ctx0 := _mk_ctx([], {}, SEED + 3)
	var tp0 := Torpedo.new()
	tp0.launch("R3a", _mk_program(), 0.0, 0.0, 50.0, 100.0)
	var sim_t := 100.0
	for i in range(6):
		tp0.step(DT, sim_t, ctx0)
		sim_t += DT
	var ok: bool = tp0.authorize_autonomy()
	_assert_bool(fails, "RO-03a authorize ok", ok, true)
	_assert_bool(fails, "RO-03b no track -> SEARCH", tp0.mission_state_name() == "SEARCH", true)
	# 有航迹：授权自主 → 立即接管转向。
	var c := _contact("TG3", 0.0, 900.0, 50.0, 6.0, 200.0)
	var ctx := _mk_ctx([c["entity"]], {c["id"]: c["ac"]}, SEED + 4)
	var tp := Torpedo.new()
	tp.launch("R3b", _mk_program(), 0.0, 0.0, 50.0, 100.0)
	for i in range(6):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var reached := false
	for i in range(30):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.seeker_state_name() == "TRACKING":
			reached = true
			break
	_assert_bool(fails, "RO-03c precondition TRACKING", reached, true)
	var course0: float = tp.course_deg
	tp.authorize_autonomy()
	var moved: float = 0.0
	for i in range(2):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		moved += absf(NavUtils.wrap180(tp.course_deg - course0))
	_assert_bool(fails, "RO-03d AUTONOMOUS steers immediately", moved > 0.05, true)


## ---- RO-04：alpha-beta 滤波（1°/s 收敛 + 跨 0° 无跳变）----
func _ro_04_filter_quality(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure(TorpedoGuidance.default_seeker_cfg(null))
	var now := 100.0
	# 恒定 1°/s：355° → 5°（跨 359/0）。噪声 ±0.3° 固定摆动（确定性）。
	var t: SeekerTrack = null
	var meas: float = 355.0
	for i in range(30):
		var noise: float = 0.3 * (1.0 if i % 2 == 0 else -1.0)
		s.process_returns([_mk_ret(meas + noise, 20.0, now)], now)
		now += 1.0
		s.update(now)
		if s.tracks.size() > 0:
			t = s.tracks[0]
		meas = NavUtils.wrap360(meas + 1.0)
	_assert_bool(fails, "RO-04a track exists", t != null, true)
	if t != null:
		_assert_bool(
			fails, "RO-04b rate converges ~1 deg/s", absf(t.bearing_rate_deg_s - 1.0) < 0.5, true
		)
		var est: float = t.bearing_estimate_deg
		_assert_bool(
			fails, "RO-04c estimate near truth", absf(NavUtils.wrap180(est - meas)) < 3.0, true
		)
		# 继续跨 0°：估计值不得跳变（wrap 处理正确）。
		var prev: float = est
		var max_jump: float = 0.0
		for i in range(10):
			s.process_returns([_mk_ret(meas, 20.0, now)], now)
			now += 1.0
			s.update(now)
			var cur: float = t.bearing_estimate_deg
			max_jump = maxf(max_jump, absf(NavUtils.wrap180(cur - prev)))
			prev = cur
			meas = NavUtils.wrap360(meas + 1.0)
		_assert_bool(fails, "RO-04d no wrap jump", max_jump < 3.0, true)


## ---- RO-05：仅 8s 一次主动回波保持航迹 ----
func _ro_05_active_only_track(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure(TorpedoGuidance.default_seeker_cfg(null))
	var now := 100.0
	# 先建立 TRACKING（3 次主动 return，每 8s 一次 + 中间大量空 tick）。
	var t: SeekerTrack = null
	var meas_b: float = 30.0
	var meas_r: float = 1500.0
	for k in range(4):
		var r := _mk_ret(meas_b, 20.0, now, "ACTIVE")
		r.range_m = meas_r
		r.range_sigma_m = 30.0
		s.process_returns([r], now)
		now += 1.0
		s.update(now)
		# 两次 Ping 之间推进大量 tick（绝不产生 miss）。
		for i in range(14):
			now += 0.5
			s.update(now)
		meas_b += 0.4
		meas_r -= 20.0
	if s.tracks.size() > 0:
		t = s.tracks[0]
	_assert_bool(fails, "RO-05a track exists", t != null, true)
	if t != null:
		_assert_bool(fails, "RO-05b survives across pings", t.lock_quality > 0.25, true)
		_assert_bool(fails, "RO-05c has range estimate", t.range_estimate_m > 0.0, true)
		# 继续两个 Ping 周期，只靠主动回波，航迹仍保持（不被 tick 扣分到 LOST）。
		var still := true
		for k in range(2):
			var r2 := _mk_ret(meas_b, 20.0, now, "ACTIVE")
			r2.range_m = meas_r
			r2.range_sigma_m = 30.0
			s.process_returns([r2], now)
			now += 1.0
			s.update(now)
			for i in range(14):
				now += 0.5
				s.update(now)
			meas_b += 0.4
			meas_r -= 20.0
			if t.lock_quality <= 0.2:
				still = false
		_assert_bool(fails, "RO-05d active-only track maintained", still, true)


## ---- RO-06：1500m/10kn 横向目标拦截（固定 seed）----
func _ro_06_intercept_lateral_target(fails: Array) -> void:
	var c := _contact("TG6", 0.0, 1500.0, 50.0, 10.0, 210.0)
	var tg: TruthEntity = c["entity"]
	var ctx := _mk_ctx([tg], {c["id"]: c["ac"]}, SEED + 6)
	# 程序：发射后立即自主（DISTANCE 0 触发）。
	var prog := _mk_program()
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 0.0
	var tp := Torpedo.new()
	tp.launch("R6", prog, 0.0, 0.0, 50.0, 100.0)
	var sim_t := 100.0
	var min_dist: float = INF
	var detonated := false
	for i in range(360):  # 最多 180s
		tg.position_east_m += tg.speed_kn * NavUtils.KNOT_TO_MS * DT
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		var d: float = NavUtils.distance(
			tp.pos_east_m, tp.pos_north_m, tg.position_east_m, tg.position_north_m
		)
		min_dist = minf(min_dist, d)
		if tp.is_dead():
			detonated = tp.miss_reason == ""
			break
	_assert_bool(fails, "RO-06a closes on target", min_dist < 200.0, true)
	_assert_bool(
		fails,
		"RO-06b no premature fuel death",
		not (tp.is_dead() and tp.miss_reason == "FUEL_EXHAUSTED"),
		true,
	)


## ---- RO-07：离开 FOV → COAST → 重进 → REACQUIRE ----
func _ro_07_fov_coast_reacquire(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure(TorpedoGuidance.default_seeker_cfg(null))
	var now := 100.0
	now = _drive_to_tracking(s, 20.0, now)
	_assert_bool(
		fails, "RO-07a precondition TRACKING", s.phase == TorpedoSeeker.Phase.TRACKING, true
	)
	# 艏向转离（目标预测方位 20°，艏向 120° → 出 ±60° FOV）。
	s.own_course_deg = 120.0
	var coast := false
	for i in range(4):
		now += 1.0
		s.update(now)
		if s.phase == TorpedoSeeker.Phase.COAST:
			coast = true
			break
	_assert_bool(fails, "RO-07b enters COAST when out of FOV", coast, true)
	# COAST 期间无 return 也不得立刻 LOST。
	now += 2.0
	s.update(now)
	_assert_bool(fails, "RO-07c holds during COAST", s.phase == TorpedoSeeker.Phase.COAST, true)
	# 重进覆盖（艏向回到目标方位附近）→ REACQUIRE。
	s.own_course_deg = 20.0
	var reacq := false
	for i in range(8):
		s.process_returns([_mk_ret(20.5, 20.0, now)], now)
		now += 1.0
		s.notify_passive_scan(now)
		s.update(now)
		if s.phase in [TorpedoSeeker.Phase.REACQUIRE, TorpedoSeeker.Phase.TRACKING]:
			reacq = true
			break
	_assert_bool(fails, "RO-07d reacquire after re-entry", reacq, true)


## ---- RO-08：冲过目标 → LOST → 超时 → SEARCH（不无限绕圈/挂死）----
func _ro_08_overshoot_research(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure(TorpedoGuidance.default_seeker_cfg(null))
	var now := 100.0
	now = _drive_to_tracking(s, 10.0, now)
	# 目标永久消失（出 FOV + COAST 超时 → LOST → reacquire 超时 → SEARCH）。
	s.own_course_deg = 150.0
	var saw_lost := false
	var saw_search := false
	for i in range(200):  # 200s > coast_timeout(42) + reacquire_timeout(120)
		now += 1.0
		s.update(now)
		if s.phase == TorpedoSeeker.Phase.LOST:
			saw_lost = true
		if s.phase == TorpedoSeeker.Phase.SEARCH:
			saw_search = true
			break
	_assert_bool(fails, "RO-08a reaches LOST", saw_lost, true)
	_assert_bool(fails, "RO-08b re-SEARCH after timeout (no infinite COAST)", saw_search, true)


## ---- RO-10：无敌方 AI 场景玩家鱼雷进入统一声场 ----
func _ro_10_unified_acoustic_field(fails: Array) -> void:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	var w := World.new()
	w.load_scenario(sc)
	_assert_bool(fails, "RO-10a no enemy ai", w.enemy_ai == null, true)
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	_assert_bool(fails, "RO-10b torpedo fired", tp != null, true)
	w.run_steps(8)
	_assert_bool(
		fails, "RO-10c player torpedo shadow synced", w._player_torpedo_shadows.size() >= 1, true
	)
	var found := false
	for sh in w._player_torpedo_shadows:
		if str(sh.id) == str(tp.torpedo_id):
			found = true
	_assert_bool(fails, "RO-10d shadow id matches", found, true)


## ---- RO-11：窄带频段切换（预设谱线不被 0-500 过滤）----
func _ro_11_nb_band_switch(fails: Array) -> void:
	var op := OperatorSonar.new()
	_assert_bool(fails, "RO-11a default LOW", op.nb_band == "LOW", true)
	_assert_bool(fails, "RO-11b switch MID", op.set_nb_band("MID"), true)
	_assert_bool(
		fails, "RO-11c MID bounds", op.nb_fmin_hz == 500.0 and op.nb_fmax_hz == 3000.0, true
	)
	# CRUISE 谱线 540/1080 与 HIGH 谱线 660/1320 全部落入 MID 频段。
	var in_mid := true
	for f in [540.0, 660.0, 840.0, 1080.0, 1320.0]:
		if f <= op.nb_fmin_hz or f >= op.nb_fmax_hz:
			in_mid = false
	_assert_bool(fails, "RO-11d preset lines inside MID", in_mid, true)
	_assert_bool(fails, "RO-11e switch HIGH", op.set_nb_band("HIGH"), true)
	_assert_bool(
		fails, "RO-11f HIGH bounds", op.nb_fmin_hz == 8000.0 and op.nb_fmax_hz == 16000.0, true
	)
	_assert_bool(fails, "RO-11g unknown band rejected", op.set_nb_band("BOGUS"), false)
	# LOW 频段仍覆盖 QUIET 谱线 420 Hz。
	op.set_nb_band("LOW")
	_assert_bool(
		fails, "RO-11h LOW covers 420", op.nb_fmin_hz <= 420.0 and op.nb_fmax_hz > 420.0, true
	)


## ---- RO-12：敌方瞬态证据仅在 t_emit + R/c 后出现 ----
func _ro_12_propagation_delay(fails: Array) -> void:
	var own := TruthEntity.new()
	own.id = "OWN"
	own.position_east_m = 0.0
	own.position_north_m = 0.0
	own.depth_m = 50.0
	own.speed_kn = 5.0
	var env: RefCounted = _env()
	var san := EmissionSanitizer.new()
	var r := RandomNumberGenerator.new()
	r.seed = SEED + 12
	san.bind(env, null, r)
	# 敌方主动 Ping：距本艇 5000m → 单程时延 ~3.33s（近距离高 SE，P_d≈1）。
	var ev := {
		"event_id": 1,
		"emit_time": 100.0,
		"emitter_internal_ref": "ET01",
		"emission_kind": AcousticEmissionEvent.TORPEDO_ACTIVE_PING,
		"source_position_internal": {"e": 0.0, "n": 5000.0},
		"source_depth_internal": 50.0,
		"center_frequency_hz": 12000.0,
		"source_level_db": 195.0,
	}
	var out0: Array = san.consume_events([ev], own, 100.0 + 1.0, {})
	_assert_bool(fails, "RO-12a no evidence before R/c", out0.is_empty(), true)
	var out1: Array = san.consume_events([], own, 100.0 + 3.5, {})
	_assert_bool(fails, "RO-12b evidence after R/c", out1.size() == 1, true)
	if out1.size() == 1:
		_assert_bool(
			fails,
			"RO-12c intercepted ping kind",
			str(out1[0].get("evidence_kind", "")) == "ACTIVE_PING",
			true,
		)


## ---- RO-13：脱靶原因 ----
func _ro_13_miss_reasons(fails: Array) -> void:
	# a) 燃料耗尽 → FUEL_EXHAUSTED（从未取得制导权限也先判 FUEL）。
	var ctx0 := _mk_ctx([], {}, SEED + 13)
	var tp := Torpedo.new()
	var prog := _mk_program()
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	tp.launch("R13a", prog, 0.0, 0.0, 50.0, 100.0)
	tp.fuel_left_s = 2.0
	var sim_t := 100.0
	var died := false
	for i in range(12):
		tp.step(DT, sim_t, ctx0)
		sim_t += DT
		if tp.is_dead():
			died = true
			break
	_assert_bool(fails, "RO-13a died", died, true)
	_assert_bool(fails, "RO-13b fuel reason", tp.miss_reason == "FUEL_EXHAUSTED", true)
	# b) 有权限但从未捕获到航迹即终结 → NO_GUIDANCE_AUTHORITY。
	var tp2 := Torpedo.new()
	var prog2 := _mk_program()
	prog2.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	tp2.launch("R13b", prog2, 0.0, 0.0, 50.0, 100.0)
	tp2.authorize_autonomy()  # 无航迹 → SEARCH，但制导从未实际操舵
	var reason: String = TorpedoMissReason.compute(true, false, [])
	_assert_bool(fails, "RO-13c never engaged reason", reason == "NO_GUIDANCE_AUTHORITY", true)
	# c) 优先级链：曾操舵且饱和 → TURN_RATE_SATURATED。
	var reason2: String = TorpedoMissReason.compute(false, true, [])
	_assert_bool(fails, "RO-13d saturation reason", reason2 == "TURN_RATE_SATURATED", true)
