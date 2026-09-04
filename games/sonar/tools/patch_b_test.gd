extends SceneTree
## patch_b_test.gd — 评审 Patch B 回归（Seeker 滤波/关联/状态机/主动链）。
##
## 覆盖（评审文档 §二 P0-02/03/04/09，§六 AT-03..07/AT-18 子集）：
##   PB-01（P0-03）SeekerTrack 标准 alpha-beta：恒 1°/s 序列稳态方位率收敛、
##         359°→0° 跨界无跳变（旧实现方位率被拉向 0、漏预测项）。
##   PB-02（P0-04）同扫描 Return×Track 一对一关联：一条 return 与一条 track
##         在一个 scan 内最多使用一次（旧实现允许双 return 重复更新同航迹）。
##   PB-03（P0-02.5）accept_seeker_track 成功 → guidance_authority=ASSISTED。
##   PB-04（P0-02.4）authorize_autonomy 无锁 → 进入 SEARCH 并实际扫掠。
##   PB-05（P0-02.2/3）无导线程序（wire_guidance_enabled=false）主程序距离
##         自主触发必须生效 → AUTONOMOUS + SEARCH + 扫掠（旧实现只有 fallback
##         能推进自主 → 永久直航）。
##   PB-06（P0-02.7）ATTACK 只表示 seeker 实际拥有操舵权：WIRE_ONLY 下即使
##         seeker TRACKING 也不进 ATTACK。
##   PB-07（P0-09）主动链：Ping 事件带 ping_id → FOV 内目标回波携带同一
##         ping_id；无回波 ping 在监听窗后 LISTEN_COMPLETE_NO_RETURN；
##         FOV 外目标不排程回波（旧实现全向排程）。
##
## godot --headless --path games/sonar --script res://tools/patch_b_test.gd

const DT: float = 0.5
const SEED: int = 20260904

var _ret_seq: int = 1


func _initialize() -> void:
	var fails: Array = []
	_pb_01_alpha_beta_filter(fails)
	_pb_02_scan_level_association(fails)
	_pb_03_accept_track_assisted(fails)
	_pb_04_authorize_enters_search(fails)
	_pb_05_nowire_program_autonomy(fails)
	_pb_06_attack_requires_authority(fails)
	_pb_07_active_ping_chain(fails)
	_finish(fails)


## ---- PB-01：alpha-beta 滤波（恒 1°/s + 跨界）----
func _pb_01_alpha_beta_filter(fails: Array) -> void:
	var t := SeekerTrack.create()
	var now: float = 100.0
	var rates: Array = []
	for i in range(60):
		var z: float = NavUtils.wrap360(350.0 + float(i))  # 1°/s，跨界 359→0
		var r := _mk_ret(z, 20.0, now)
		t.update_with_return(r, now, _track_cfg())
		now += 1.0
		rates.append(t.bearing_rate_deg_s)
	var true_brg: float = NavUtils.wrap360(350.0 + 59.0)
	var pos_err: float = absf(NavUtils.wrap180(t.bearing_estimate_deg - true_brg))
	var rate_err: float = absf(t.bearing_rate_deg_s - 1.0)
	_assert_bool(
		fails,
		"PB-01a steady-state rate ~1 deg/s (got %.2f)" % t.bearing_rate_deg_s,
		rate_err <= 0.25,
		true
	)
	_assert_bool(fails, "PB-01b position error small (%.2f)" % pos_err, pos_err <= 2.0, true)
	# 无跳变：跨界后方位率不尖峰（旧实现 rate→0 或尖峰）。首更新无先验
	# （rate=0）不计入。
	var max_rate: float = 0.0
	for i in range(1, rates.size()):
		max_rate = maxf(max_rate, absf(float(rates[i]) - 1.0))
	_assert_bool(fails, "PB-01c no wrap spike (max dev %.2f)" % max_rate, max_rate <= 0.9, true)


## ---- PB-02：同扫描一对一关联 ----
func _pb_02_scan_level_association(fails: Array) -> void:
	var s := _mk_seeker()
	# 两个既有航迹：方位 10° 与 30°。
	s.process_returns([_mk_ret(10.0, 20.0, 100.0), _mk_ret(30.0, 20.0, 100.0)], 100.0)
	_assert_bool(fails, "PB-02a two tracks created", s.tracks.size() == 2, true)
	# 同一扫描两条 return 都落在 track1（10°）门限内、远离 track2（30°）：
	# 一对一 → track1 只更新一次，第二条 return 创建新航迹。
	var out: Dictionary = s.process_returns(
		[_mk_ret(10.5, 20.0, 101.0), _mk_ret(11.5, 20.0, 101.0)], 101.0
	)
	var t1: SeekerTrack = s.tracks[0]
	_assert_bool(
		fails,
		"PB-02b track1 updated once (history=%d)" % t1.source_history.size(),
		t1.source_history.size() == 2,
		true
	)
	_assert_bool(
		fails,
		"PB-02c unassigned return creates new track (new=%d)" % int(out["new_track_ids"].size()),
		int(out["new_track_ids"].size()) == 1,
		true
	)
	_assert_bool(fails, "PB-02d total tracks 3", s.tracks.size() == 3, true)


## ---- PB-03：Accept Track → ASSISTED ----
func _pb_03_accept_track_assisted(fails: Array) -> void:
	var tp := _mk_tp(_wire_only_prog())
	var events := _collect_events(tp)
	var ctx := _mk_ctx_with_contact(45.0, 2500.0, 175.0)
	var sim_t: float = 100.0
	for i in range(60):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var sums: Array = tp._seeker.track_summaries()
	_assert_bool(fails, "PB-03a seeker has track", not sums.is_empty(), true)
	if sums.is_empty():
		return
	var ok: bool = tp.accept_seeker_track(int(sums[0]["track_id"]))
	_assert_bool(fails, "PB-03b accept succeeded", ok, true)
	_assert_bool(
		fails,
		"PB-03c authority ASSISTED (got %s)" % tp.guidance_authority_name(),
		tp.guidance_authority_name() == "ASSISTED",
		true
	)


## ---- PB-04：授权自主无锁 → SEARCH + 扫掠 ----
func _pb_04_authorize_enters_search(fails: Array) -> void:
	var tp := _mk_tp(_wire_only_prog())
	var ctx := _mk_ctx_no_contact()
	var sim_t: float = 100.0
	for i in range(4):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	_assert_bool(fails, "PB-04a in WIRE_RUN", tp.mission_state_name() == "WIRE_RUN", true)
	var ok: bool = tp.authorize_autonomy()
	_assert_bool(fails, "PB-04b authorize accepted", ok, true)
	_assert_bool(
		fails,
		"PB-04c entered SEARCH (got %s)" % tp.mission_state_name(),
		tp.mission_state_name() == "SEARCH",
		true
	)
	# 无目标：SEARCH 扇区扫掠实际改变航向（旧实现无现成路径进扫掠）。
	# P2-01（Patch E）后扫掠自当前航向连续初始化：单步期望变化 = 扫掠率
	# （默认 SNAKE 1.5°/s → 0.75°/步），不再有跳相位造成的 >1°/步 伪影；
	# 断言改为单步持续推进 + 20s 累计净漂移 >5°（语义不变：确实在扫掠）。
	var prev: float = tp.course_deg
	var max_delta: float = 0.0
	var first: float = tp.course_deg
	for i in range(40):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		max_delta = maxf(max_delta, absf(NavUtils.wrap180(tp.course_deg - prev)))
		prev = tp.course_deg
	var net: float = absf(NavUtils.wrap180(prev - first))
	_assert_bool(fails, "PB-04d sweep steering (%.2f)" % max_delta, max_delta > 0.5, true)
	_assert_bool(fails, "PB-04e sweep net drift (%.1f)" % net, net > 5.0, true)


## ---- PB-05：无导线程序主程序自主触发（敌方程序形状）----
func _pb_05_nowire_program_autonomy(fails: Array) -> void:
	var prog := WeaponProgram.make_bearing_only(10.0)
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 800.0
	prog.active_enable_mode = WeaponProgram.ActiveEnableMode.TIME
	prog.active_enable_time_s = 3600.0  # 本测不开主动（隔离变量）
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	var tp := _mk_tp(prog)
	var ctx := _mk_ctx_no_contact()
	var sim_t: float = 100.0
	for i in range(200):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.traveled_m >= 900.0:
			break
	_assert_bool(fails, "PB-05a traveled past enable distance", tp.traveled_m >= 900.0, true)
	_assert_bool(
		fails,
		"PB-05b authority AUTONOMOUS (got %s)" % tp.guidance_authority_name(),
		tp.guidance_authority_name() == "AUTONOMOUS",
		true
	)
	_assert_bool(
		fails,
		"PB-05c mission SEARCH/ATTACK (got %s)" % tp.mission_state_name(),
		tp.mission_state_name() == "SEARCH" or tp.mission_state_name() == "ATTACK",
		true
	)
	var prev: float = tp.course_deg
	var max_delta: float = 0.0
	for i in range(40):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		max_delta = maxf(max_delta, absf(NavUtils.wrap180(tp.course_deg - prev)))
		prev = tp.course_deg
	_assert_bool(fails, "PB-05d sweep steering (%.2f)" % max_delta, max_delta > 1.0, true)


## ---- PB-06：ATTACK 需要实际操舵权 ----
func _pb_06_attack_requires_authority(fails: Array) -> void:
	var tp := _mk_tp(_wire_only_prog())
	var ctx := _mk_ctx_with_contact(0.0, 2500.0, 175.0)
	var sim_t: float = 100.0
	var tracking: bool = false
	for i in range(80):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if tp.seeker_state_name() == "TRACKING":
			tracking = true
			break
	_assert_bool(fails, "PB-06a seeker TRACKING", tracking, true)
	if not tracking:
		return
	_assert_bool(
		fails,
		"PB-06b WIRE_ONLY no ATTACK (got %s)" % tp.mission_state_name(),
		tp.mission_state_name() != "ATTACK" and tp.mission_state_name() != "TERMINAL",
		true
	)


## ---- PB-07：主动 Ping 链（ping_id / FOV 门 / NO_RETURN 完成）----
func _pb_07_active_ping_chain(fails: Array) -> void:
	# FOV 内目标：PING → 同 ping_id 回波。
	var tp := _mk_tp(_wire_only_prog())
	var events := _collect_events(tp)
	var ctx := _mk_ctx_with_contact(0.0, 1500.0, 180.0)
	var sim_t: float = 100.0
	for i in range(4):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var on: bool = tp.set_active_tx(true)
	_assert_bool(fails, "PB-07a active ON accepted", on, true)
	var ping_ids: Array = []
	var saw_ping: bool = false
	for i in range(60):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		for ev in events:
			if str(ev.get("event", "")) == "ACTIVE_TX_PING":
				saw_ping = true
				var pid := str(ev.get("detail", {}).get("ping_id", ""))
				if pid != "" and not ping_ids.has(pid):
					ping_ids.append(pid)
	# 回波到达：ACTIVE return 携带同一 ping_id（传播延迟内）。
	var echo_pid: String = ""
	for i in range(80):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		for ev in events:
			if str(ev.get("event", "")) == "ACTIVE_TX_PING":
				var pid2 := str(ev.get("detail", {}).get("ping_id", ""))
				if pid2 != "" and not ping_ids.has(pid2):
					ping_ids.append(pid2)
		for r in tp.seeker_returns:
			if str(r.sensor_mode) == "ACTIVE" and str(r.ping_id) != "":
				echo_pid = str(r.ping_id)
		if echo_pid != "":
			break
	_assert_bool(fails, "PB-07b ping emitted with id", saw_ping and not ping_ids.is_empty(), true)
	_assert_bool(fails, "PB-07c in-FOV echo arrived", echo_pid != "", true)
	_assert_bool(
		fails,
		"PB-07d echo ping_id matches a TX ping",
		echo_pid != "" and ping_ids.has(echo_pid),
		true
	)

	# FOV 外目标（正后方）：不排程回波 → 监听窗后 NO_RETURN 完成。
	var tp2 := _mk_tp(_wire_only_prog())
	var events2 := _collect_events(tp2)
	var ctx2 := _mk_ctx_with_contact(180.0, 1500.0, 180.0)
	var sim_t2: float = 100.0
	for i in range(4):
		tp2.step(DT, sim_t2, ctx2)
		sim_t2 += DT
	tp2.set_active_tx(true)
	var heard: bool = false
	var no_return: bool = false
	for i in range(240):
		tp2.step(DT, sim_t2, ctx2)
		sim_t2 += DT
		for ev in events2:
			var ename := str(ev.get("event", ""))
			if ename == "LISTEN_COMPLETE_NO_RETURN":
				no_return = true
		for r in tp2.seeker_returns:
			if str(r.sensor_mode) == "ACTIVE":
				heard = true
	_assert_bool(fails, "PB-07e behind-FOV no echo", not heard, true)
	_assert_bool(fails, "PB-07f LISTEN_COMPLETE_NO_RETURN emitted", no_return, true)


## ================= helpers =================


func _track_cfg() -> Dictionary:
	return {"bearing_smoothing": 0.45, "rate_smoothing": 0.30}


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


func _mk_ret(bearing: float, se: float, now: float, range_m: float = -1.0) -> SeekerReturn:
	var r := SeekerReturn.new()
	r.return_id = _ret_seq
	_ret_seq += 1
	r.detected = true
	r.sensor_mode = "ACTIVE" if range_m >= 0.0 else "PASSIVE"
	r.timestamp = now
	r.available_time = now
	r.bearing_deg = bearing
	r.bearing_sigma_deg = 2.0
	r.signal_excess_db = se
	r.detection_probability = 0.9
	r.range_m = range_m
	r.range_sigma_m = 20.0 if range_m >= 0.0 else -1.0
	r.depth_relation = "SAME_LAYER"
	return r


func _wire_only_prog() -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.MANUAL
	p.initial_course_deg = 0.0
	p.speed_mode = WeaponProgram.SpeedMode.QUIET
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_center_deg = 0.0
	p.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	p.wire_guidance_enabled = true
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 3000.0
	p.fallback_program = p.make_default_fallback()
	return p


func _mk_tp(prog: WeaponProgram) -> Torpedo:
	var tp := Torpedo.new()
	tp.launch("PB", prog, 0.0, 0.0, 50.0, 100.0)
	return tp


func _env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


func _depth_model() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world.get("depth_model", null)


func _mk_ctx_with_contact(bearing: float, range_m: float, base_sl: float) -> RefCounted:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var b: float = deg_to_rad(bearing)
	var t := TruthEntity.new()
	t.id = "TGT"
	t.side = "red"
	t.platform_type = "submarine"
	t.position_east_m = sin(b) * range_m
	t.position_north_m = cos(b) * range_m
	t.depth_m = 50.0
	t.course_deg = 0.0
	t.speed_kn = 0.0
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = base_sl
	ac.tonal_lines = [{"freq_hz": 1500.0, "level_db": base_sl - 12.0}]
	var ad := TorpedoSensorAdapter.new()
	ad.bind(env, dm, [t], {"TGT": ac})
	var r := RandomNumberGenerator.new()
	r.seed = SEED
	ad.set_rng(r)
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = AcousticEmissionBus.new()
	ctx.sensor_adapter = ad
	return ctx


func _mk_ctx_no_contact() -> RefCounted:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var ad := TorpedoSensorAdapter.new()
	ad.bind(env, dm, [], {})
	var r := RandomNumberGenerator.new()
	r.seed = SEED
	ad.set_rng(r)
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = AcousticEmissionBus.new()
	ctx.sensor_adapter = ad
	return ctx


func _collect_events(tp: Torpedo) -> Array:
	var events: Array = []
	tp.event_occurred.connect(
		func(id: String, ev: String, detail: Dictionary) -> void:
			events.append({"id": id, "event": ev, "detail": detail})
	)
	return events


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("PATCH_B_TEST result=PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("PATCH_B_TEST result=FAIL (%d)" % fails.size())
	quit(1)
