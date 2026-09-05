extends SceneTree
## req2_test.gd — 第二轮 REQ 无头验收（R2-01..R2-10，对应需求验收 1~10）。
##
##   R2-01  浅水攻击定深：程序 initial_depth_m 生效（有限速率升降、到达后
##          保持不被层带提示回拉）；UPPER/LOWER 换层仍可用。
##   R2-02  LOS 滤波：真方位 1°/s 输入 → 滤波率收敛 ~1°/s（自身 6°/s 转率
##          不再叠加）；跨 0° 无跳变。
##   R2-03  转向积分：1°/s 命令持续 10s，dt=0.1/0.5/1.0 均约转 10°；饱和
##          判定对未饱和命令。
##   R2-04  主动距离率：8s 间隔测距 → 距离率稳定（不混用被动时刻）；
##          heard=true 不记 active miss；active-only 航迹不被空被动扫描抽干。
##   R2-05  COAST：出 FOV → COAST → 超时 LOST；无新测量绝不重锁；有新
##          测量可 REACQUIRE。
##   R2-06  World 全流程：1500m、10kn 横向目标、40kn 鱼雷、同深、固定几何
##          → 实际起爆 + 目标 sunk（不只断言 CPA）。
##   R2-07  连续引信几何：相对运动 swept 触发、相对静止直用间距、垂直门限
##          同一时刻同判（拼接不同时刻最小值不得触发）。
##   R2-08  Track 关联：历史行按该时刻预测方位关联；全局关联可切换接触。
##   R2-09  TRUE 模式 Mark：艇艏 90°、峰相对 30° → 两种模式均生成 120°；
##          重叠峰选最近峰；测得频率保留。
##   R2-10  操舵来源：读实际命令来源（WIRE_ONLY 不显示 SEEKER_TRACK）。
##
## godot --headless --path games/sonar --script res://tools/req2_test.gd

const DT: float = 0.5
const SEED: int = 20260906


func _initialize() -> void:
	var fails: Array = []
	_r2_01_shallow_depth(fails)
	_r2_02_los_rate_filter(fails)
	_r2_03_steering_integration(fails)
	_r2_04_range_rate_and_miss(fails)
	_r2_05_coast_no_ghost_relock(fails)
	_r2_06_world_moving_target_detonation(fails)
	_r2_07_fuze_geometry(fails)
	_r2_08_track_association(fails)
	_r2_09_true_mode_mark(fails)
	_r2_10_steering_source(fails)
	for f in fails:
		print("R2_FAIL ", f)
	if fails.is_empty():
		print("REQ2_TEST result=PASS")
	else:
		print("REQ2_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)


## ---- 公共构造 ----
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


func _env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


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


func _contact(
	id: String, e: float, n: float, depth: float, kn: float, base_sl: float, crs: float = 90.0
) -> Dictionary:
	var t := TruthEntity.new()
	t.id = id
	t.side = "red"
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = depth
	t.course_deg = crs
	t.speed_kn = kn
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = base_sl
	ac.tonal_lines = [{"freq_hz": 1500.0, "level_db": base_sl - 12.0}]
	return {"id": id, "entity": t, "ac": ac}


func _mk_ret(
	bearing_deg: float, se_db: float, now: float, mode: String = "PASSIVE", range_m: float = -1.0
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
	r.range_m = range_m
	r.range_sigma_m = 20.0 if range_m >= 0.0 else -1.0
	return r


func _ok(fails: Array, name: String, got: bool, want: bool = true) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got %.3f want %.3f (+-%.3f)" % [name, got, want, tol])
	else:
		print("  [ok] %s" % name)


## ---- R2-01：浅水攻击定深 ----
func _r2_01_shallow_depth(fails: Array) -> void:
	var ctx := _mk_ctx([], {}, SEED + 1)
	var prog := _mk_program()
	prog.initial_depth_m = 12.0
	var tp := Torpedo.new()
	tp.launch("D1", prog, 0.0, 0.0, 50.0, 100.0)
	var sim_t := 100.0
	var min_depth_seen: float = 50.0
	for i in range(80):  # 40s：50→12 需 19s（2m/s 有限速率）
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		min_depth_seen = minf(min_depth_seen, tp.actual_depth_m)
	_ok(
		fails,
		"R2-01a climbs toward 12m",
		tp.actual_depth_m < 13.0,
	)
	_ok(fails, "R2-01b finite climb rate (no teleport)", min_depth_seen > 10.0, true)
	_ok(
		fails,
		"R2-01c explicit hold persists (not cleared)",
		tp.commanded_depth_m >= 11.5 and tp.commanded_depth_m <= 12.5,
		true,
	)
	# 层带换层仍可用（LOWER → 有限下潜）。
	var ok_band: bool = tp.command_depth_band("LOWER")
	_ok(fails, "R2-01d band command accepted", ok_band, true)
	for i in range(20):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	_ok(fails, "R2-01e dives toward LOWER hold", tp.actual_depth_m > 15.0, true)
	# 玩家线控定深命令（REQ-01：可选浅水攻击定深）。
	var tp2 := Torpedo.new()
	tp2.launch("D2", _mk_program(), 0.0, 0.0, 50.0, 100.0)
	for i in range(6):
		tp2.step(DT, sim_t, ctx)
		sim_t += DT
	var ok_depth: bool = tp2.command_depth(8.0)
	_ok(fails, "R2-01f wire depth command accepted", ok_depth, true)
	for i in range(60):
		tp2.step(DT, sim_t, ctx)
		sim_t += DT
	_ok(fails, "R2-01g wire depth reached ~8m", tp2.actual_depth_m < 9.5, true)


## ---- R2-02：LOS 滤波（真方位 1°/s；自转 6°/s 不叠加；跨 0°） ----
func _r2_02_los_rate_filter(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure({})
	s.own_turn_rate_deg_s = 6.0  # 旧字段仍在——但滤波不得消费它
	var now := 0.0
	var brg := 355.0  # 跨 0° 序列
	for i in range(25):
		s.process_returns([_mk_ret(brg, 20.0, now)], now)
		now += 1.0
		brg = NavUtils.wrap360(brg + 1.0)
		s.notify_passive_scan(now)
		s.update(now)
	var t: SeekerTrack = s.tracks[0] if not s.tracks.is_empty() else null
	_ok(fails, "R2-02a track exists", t != null, true)
	if t != null:
		_close(fails, "R2-02b bearing rate ~1 deg/s", t.bearing_rate_deg_s, 1.0, 0.3)
		_close(fails, "R2-02c los rate ~1 (no own-turn double count)", t.los_rate_deg_s, 1.0, 0.3)
		_ok(fails, "R2-02d no 7 deg/s contamination", absf(t.los_rate_deg_s) < 2.5, true)


## ---- R2-03：转向积分（rate_cmd deg/s × dt） ----
func _r2_03_steering_integration(fails: Array) -> void:
	for dt in [0.1, 0.5, 1.0]:
		var tp := Torpedo.new()
		tp.launch("S3", _mk_program(), 0.0, 0.0, 50.0, 0.0)
		tp.mission_state = Torpedo.MissionState.WIRE_RUN
		var steps: int = int(round(10.0 / dt))
		var total := 0.0
		var sim_t := 0.0
		for i in range(steps):
			tp._guidance_mode = Torpedo.GuidanceMode.RATE
			tp._guidance_turn_rate_cmd = 1.0
			var c0: float = tp.course_deg
			tp._apply_steering(dt, sim_t)
			sim_t += dt
			total += absf(NavUtils.wrap180(tp.course_deg - c0))
		_close(fails, "R2-03a dt=%.1f turns ~10 deg in 10s" % dt, total, 10.0, 0.6)
	# 饱和诊断：20°/s 命令 → SAT，实际=omega_max。
	var tp2 := Torpedo.new()
	tp2.launch("S3b", _mk_program(), 0.0, 0.0, 50.0, 0.0)
	tp2.mission_state = Torpedo.MissionState.WIRE_RUN
	tp2._guidance_mode = Torpedo.GuidanceMode.RATE
	tp2._guidance_turn_rate_cmd = 20.0
	tp2._apply_steering(0.5, 0.0)
	_ok(fails, "R2-03b saturated flagged", tp2.turn_saturated, true)
	_close(
		fails,
		"R2-03c actual = omega_max",
		tp2.actual_turn_rate_deg_s,
		tp2._max_turn_rate(),
		0.01,
	)


## ---- R2-04：主动距离率 + miss 机会记账 ----
func _r2_04_range_rate_and_miss(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure({})
	# active-only 航迹：每 8s 一次主动回波（timestamp=发射历元），距离 12.5m/s 递减。
	var now := 0.0
	var rng_m := 1000.0
	for ping in range(5):
		var emit_t: float = now
		now += 2.0  # tau
		s.process_returns([_mk_ret(10.0, 20.0, emit_t, "ACTIVE", rng_m)], now)
		rng_m -= 100.0
		now += 6.0
		# 期间每秒被动扫描（无被动 return）。
		for k in range(6):
			s.notify_passive_scan(now + k * 1.0)
			s.update(now + k * 1.0)
	var t: SeekerTrack = s.tracks[0] if not s.tracks.is_empty() else null
	_ok(fails, "R2-04a active-only track exists", t != null, true)
	if t != null:
		_close(fails, "R2-04b range rate ~ -12.5 m/s", t.range_rate_m_s, -12.5, 4.0)
		_ok(
			fails,
			"R2-04c active-only track NOT drained by empty passive scans",
			t.total_misses == 0 and t.lock_quality > 0.5,
			true,
		)
		# heard=true（该 ping 有回波）→ 不记 active miss。
		var q0: float = t.lock_quality
		s.notify_active_miss(now, now - 8.0)
		_close(fails, "R2-04d heard ping no penalty", t.lock_quality, q0, 1e-6)
		# Ping 发射前已有更新（last_update > emit_t）→ 该航迹无此机会缺口。
		s.notify_active_miss(now, now - 10.0)
		_close(fails, "R2-04e track updated after emit no penalty", t.lock_quality, q0, 1e-6)
		# 陈旧航迹（发射前建立、无任何更新）→ 记一次 active miss。
		var stale := SeekerTrack.create()
		stale.update_with_return(_mk_ret(12.0, 20.0, 1.0), 1.0, {})
		s.tracks.append(stale)
		s.notify_active_miss(now, now - 8.0)
		_ok(fails, "R2-04f stale track penalized once", stale.total_misses == 1, true)


## ---- R2-05：COAST / 无新测量不重锁 ----
func _r2_05_coast_no_ghost_relock(fails: Array) -> void:
	var s := TorpedoSeeker.new()
	s.configure({})
	var now := 0.0
	for i in range(12):
		s.process_returns([_mk_ret(10.0 + 0.1 * i, 20.0, now)], now)
		now += 1.0
		s.notify_passive_scan(now)
		s.update(now)
	_ok(fails, "R2-05a reached TRACKING", s.phase == TorpedoSeeker.Phase.TRACKING, true)
	# 目标离开覆盖（own 转向 120°，预测方位 10° 在 FOV 外）。
	s.own_course_deg = 120.0
	now += 1.0
	s.update(now)
	_ok(fails, "R2-05b out of FOV -> COAST", s.phase == TorpedoSeeker.Phase.COAST, true)
	# COAST 超时 → LOST（无新测量）。
	now += 60.0
	s.update(now)
	_ok(fails, "R2-05c coast timeout -> LOST", s.phase == TorpedoSeeker.Phase.LOST, true)
	# 无新测量：绝不 REACQUIRE。
	now += 10.0
	s.update(now)
	_ok(
		fails,
		"R2-05d no ghost relock without new measurement",
		s.phase == TorpedoSeeker.Phase.LOST,
		true
	)
	# 新测量（FOV 内，连续多拍达捕获阈值）→ REACQUIRE。
	for i in range(8):
		s.process_returns([_mk_ret(125.0 + 0.1 * i, 25.0, now)], now)
		now += 1.0
		s.notify_passive_scan(now)
		s.update(now)
	_ok(
		fails,
		"R2-05e new measurement -> REACQUIRE",
		s.phase in [TorpedoSeeker.Phase.REACQUIRE, TorpedoSeeker.Phase.TRACKING],
		true,
	)


## ---- R2-06：World 全流程——1500m/10kn 横向目标实际起爆 ----
func _r2_06_world_moving_target_detonation(fails: Array) -> void:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	sc["own_ship"]["speed_kn"] = 0.0
	sc["enemy_spawn"] = {
		"bearing_min_deg": 359.0,
		"bearing_max_deg": 1.0,
		"range_min_m": 1500.0,
		"range_mode_m": 1500.0,
		"range_max_m": 1500.0,
		"speed_min_kn": 10.0,
		"speed_max_kn": 10.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": 0.0,
			"position_north_m": 1500.0,
			"course_deg": 90.0,
			"speed_kn": 10.0,
			"depth_m": 70.0
		},
		"acoustic": {"broadband_base_level_db": 170.0},
		"doctrine":
		{
			"sensor_false_alarm_rate": 0.0,
			"evade_trigger_probability": 0.0,
			"decoy_launch_probability": 0.0,
			"layer_change_probability": 0.0,
			"counterfire_probability": 0.0,
			"sample_interval_s": 2.0
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	var tgt: TruthEntity = w.world["targets"][0]
	var tp: Torpedo = w.weapons.fire_bearing_only(0.0, 0.0, 0.0, w.sim_time, 50.0)
	_ok(fails, "R2-06a launched", tp != null, true)
	if tp == null:
		return
	# 主动按 TIME 30s 开（TERMINAL 需测距）；30s 后授权自主。
	tp.program.active_enable_mode = WeaponProgram.ActiveEnableMode.TIME
	tp.program.active_enable_time_s = 30.0
	var authorized := false
	var detonated := false
	var steps := 0
	while steps < 1600 and not detonated:
		w.run_steps(1)
		steps += 1
		if not authorized and tp.traveled_m >= 300.0:
			authorized = tp.authorize_autonomy()
		if tp.is_dead():
			detonated = tp.miss_reason == ""
			break
	_ok(fails, "R2-06b actually detonated (moving target)", detonated, true)
	_ok(fails, "R2-06c target sunk", str(tgt.damage_state) == "sunk", true)
	_ok(fails, "R2-06d debrief ledger records detonation", not w._detonations.is_empty(), true)
	if not detonated:
		print(
			(
				"  [dbg] miss_reason=%s min_pass=%.1f steps=%d"
				% [tp.miss_reason, float(w._fuze_min_pass.get(str(tp.torpedo_id), -1.0)), steps]
			)
		)


## ---- R2-07：连续引信几何（同刻同判 + 相对静止） ----
func _mk_ent(id: String, e: float, n: float, z: float) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = id
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = z
	return t


func _r2_07_fuze_geometry(fails: Array) -> void:
	var fc := FuzeController.new()
	fc.configure(FuzeController.FUZE_CONTACT, 300.0)
	# 相对运动穿越：水平 4.9m、垂直 0 → 触发。
	var tp_prev := Vector3(0, 0, 70)
	var tp_now := Vector3(10, 0, 70)
	var c_prev := Vector3(12, 5, 70)
	var c_now := Vector3(2, -5, 70)
	var contacts: Array = [_mk_ent("C1", c_now.x, c_now.y, c_now.z)]
	var prev_map: Dictionary = {"C1": c_prev}
	var res: Dictionary = fc.check_trigger_swept(tp_now, tp_prev, contacts, prev_map, 15.0)
	_ok(fails, "R2-07a swept crossing triggers", bool(res["triggered"]), true)
	# 相对静止且在半径内 → 直用当前间距触发。
	var res2: Dictionary = fc.check_trigger_swept(
		tp_now, tp_now, contacts, {"C1": Vector3(10, 0, 70)}, 15.0
	)
	_ok(fails, "R2-07b stationary within radius triggers", bool(res2["triggered"]), true)
	# 垂直分量超门限：水平 CPA 时刻 t=0.58，垂直 = 70/40 差 0.58 → 40*0.58=23m
	# 在门内会触发；改用 170m 差（t 时刻 58m > 25m）→ 不触发。
	var c_now_v := Vector3(2, -5, 170)
	var contacts_v: Array = [_mk_ent("C1", c_now_v.x, c_now_v.y, c_now_v.z)]
	var res3: Dictionary = fc.check_trigger_swept(tp_now, tp_prev, contacts_v, {"C1": c_prev}, 15.0)
	_ok(fails, "R2-07c vertical gate blocks same-tick trigger", not bool(res3["triggered"]), true)
	# 同一时刻判定：CPA 时刻垂直距离 > 门限 → 不得用"某刻垂直近 +
	# 另一刻水平近"拼接触发（CPA t=0.58 时垂直 46m > 25m）。
	var c_prev2 := Vector3(30, 5, 20)
	var c_now2 := Vector3(2, -5, 130)
	var contacts2: Array = [_mk_ent("C2", c_now2.x, c_now2.y, c_now2.z)]
	var res4: Dictionary = fc.check_trigger_swept(tp_now, tp_prev, contacts2, {"C2": c_prev2}, 15.0)
	_ok(fails, "R2-07d no cross-time stitching trigger", not bool(res4["triggered"]), true)


## ---- R2-08：Track 关联（历史行预测 + 全局切换） ----
func _r2_08_track_association(fails: Array) -> void:
	var tr := Tracker.new()
	var mk := func(t: float, brg: float) -> Measurement:
		var m := Measurement.new()
		m.timestamp = t
		m.measured_bearing_deg = brg
		m.bearing_sigma_deg = 0.5
		m.detected = true
		return m
	# Track A：方位 10°/5°/0°（-1°/s 递减）。
	var a1: Measurement = mk.call(0.0, 10.0)
	var ta: Track = tr.mark(a1, "S")
	tr.feed_evidence_group([mk.call(10.0, 5.0)], "", 8.0)
	tr.feed_evidence_group([mk.call(20.0, 0.0)], "", 8.0)
	# 历史行 t=35：预测方位 = 0 + (-0.5)*15 = -7.5（只比最新方位 0 差 14 > 8
	# 会关联失败；预测参与后差 6.5 ≤ 8 → 关联成功）。
	var hist: Measurement = mk.call(35.0, -14.0)
	var got: Track = tr.feed_evidence_group([hist], "", 8.0)
	_ok(fails, "R2-08a historical row associates via prediction", got == ta, true)
	# 全局关联可切换：远处新证据（与 A 差 >8°）→ 不并入 A。
	var far: Measurement = mk.call(40.0, 60.0)
	var got2: Track = tr.feed_evidence_group([far], "", 8.0)
	_ok(fails, "R2-08b far evidence not forced into A", got2 == null, true)


## ---- R2-09：TRUE 模式 Mark + 最近峰 ----
func _r2_09_true_mode_mark(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var wd: Dictionary = w.world
	wd["own"].course_deg = 90.0
	var op := OperatorSonar.new()
	op.setup(wd)
	# 行：course=90；两个重叠峰（display 28 / 33），输入 31 → 最近峰 33。
	var row: Dictionary = {
		"t": 100.0,
		"array_id": "BOW",
		"course": 90.0,
		"peaks":
		[
			{"bearing_deg": 28.0, "se_db": 20.0, "freqs_hz": [240.0]},
			{"bearing_deg": 33.0, "se_db": 18.0, "freqs_hz": [1500.0]},
		],
	}
	var m_rel: Measurement = op.create_mark(31.0, 100.0, "", false, row)
	_close(
		fails, "R2-09a rel: nearest peak 33 -> true 123", m_rel.measured_bearing_deg, 123.0, 1e-6
	)
	var m_true: Measurement = op.create_mark(123.0, 100.0, "", true, row)
	_close(
		fails,
		"R2-09b true: display-converted (not raw relative)",
		m_true.measured_bearing_deg,
		123.0,
		1e-6,
	)
	# 艇艏 90°、峰相对 30°：两种模式均生成 120° Mark。
	var row2: Dictionary = {
		"t": 110.0,
		"array_id": "BOW",
		"course": 90.0,
		"peaks": [{"bearing_deg": 30.0, "se_db": 20.0, "freqs_hz": [300.0]}],
	}
	var ma: Measurement = op.create_mark(30.0, 110.0, "", false, row2)
	_close(fails, "R2-09c rel mode -> 120", ma.measured_bearing_deg, 120.0, 1e-6)
	var mb: Measurement = op.create_mark(120.0, 110.0, "", true, row2)
	_close(fails, "R2-09d true mode -> 120", mb.measured_bearing_deg, 120.0, 1e-6)
	# 测得频率保留。
	_ok(
		fails,
		"R2-09e measured frequencies preserved",
		not mb.detected_frequencies.is_empty() and float(mb.detected_frequencies[0]) == 300.0,
		true,
	)


## ---- R2-10：操舵来源读实际命令来源 ----
func _r2_10_steering_source(fails: Array) -> void:
	var tp := Torpedo.new()
	tp.launch("SS", _mk_program(), 0.0, 0.0, 50.0, 0.0)
	tp.mission_state = Torpedo.MissionState.ATTACK
	tp._guidance_mode = Torpedo.GuidanceMode.NONE
	var st: SeekerBeamState = SeekerBeamState.new_from(tp)
	_ok(
		fails,
		"R2-10a WIRE_ONLY/ATTACK no SEEKER_TRACK label",
		st.steering_source != "SEEKER_TRACK",
		true,
	)
	tp.guidance_authority = Torpedo.GuidanceAuthority.AUTONOMOUS
	tp._guidance_mode = Torpedo.GuidanceMode.RATE
	var st2: SeekerBeamState = SeekerBeamState.new_from(tp)
	_ok(
		fails,
		"R2-10b actual RATE guidance -> SEEKER_TRACK",
		st2.steering_source == "SEEKER_TRACK",
		true
	)
