extends SceneTree
## s1_11_batch6_test.gd — S1-11 Batch 6：自动锁定 / 脱锁重搜 / 深度概率 / 终局胜利。
##
##   B6-09 (AT-09) 稳定捕获后自动进入 LOCKED_ATTACK，无需 Accept/Authorize；
##   B6-08 (AT-08) 候选未稳定时（ACQUIRING）不向候选转弯；
##   B6-10 (AT-10) 已锁对象有连续性保护，不在多个候选间每帧换锁；
##   B6-13/14 (AT-13/14) 短时漏测先进 COAST，持续跌落才 LOST_REACQUIRE；
##   B6-15/16 (AT-15/16) 重搜围绕最后**估计**方位，线导有效时重画可切回 TRANSIT；
##   B6-27..31 (AT-27..31) DepthEstimator：默认未知 / 层证据更新 / 去重 / 衰减 /
##          二维主动测距不生成精确深度；
##   B6-32 (AT-32) 鱼雷导线回传更新所关联接触深度；断线停止新回传；
##   B6-33 (AT-33) AUTO 深度仅在置信度达标时换层（有限垂速执行）；
##   B6-40 (AT-40) 玩家鱼雷命中任务敌方目标 → 立即胜利且 mission_ended 恰好一次。

const SEED: int = 20260910


func _initialize() -> void:
	var fails: Array = []
	_b6_09(fails)
	_b6_10(fails)
	_b6_13_14(fails)
	_b6_15_16(fails)
	_b6_27_31(fails)
	_b6_32(fails)
	_b6_33(fails)
	_b6_40(fails)
	_finish(fails)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []
	var w := World.new()
	w.load_scenario(sc)
	return w


## 跑起来的一枚自治鱼雷（TRANSIT，导线正常）。
func _mk_running_torpedo(w: World) -> Torpedo:
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	tp.authorize_autonomy()
	return tp


func _mk_return(id: int, t: float, brg: float, se: float, mode: String = "PASSIVE") -> SeekerReturn:
	var r := SeekerReturn.new()
	r.return_id = id
	r.timestamp = t
	r.available_time = t
	r.sensor_mode = mode
	r.detected = true
	r.bearing_deg = brg
	r.bearing_sigma_deg = 1.0
	r.signal_excess_db = se
	r.detection_probability = 1.0
	r.depth_relation = "SAME_LAYER"
	return r


## 逐秒喂回波并推进相位机 / 任务态；返回首次进入 ACQUIRING 的时刻快照。
func _drive(tp: Torpedo, n: int, t0: float, brg: float, se: float) -> Dictionary:
	var rid: int = 1000
	var acq: Dictionary = {}
	for i in range(n):
		var now: float = t0 + float(i) * 1.0
		tp._seeker.process_returns([_mk_return(rid, now, brg, se)], now)
		tp._seeker.update(now)
		tp._advance_lock_state()
		# 每轮都推进制导：锁定后（TRACKING/LOCKED_ATTACK）才会真正置 _ever_guidance_engaged。
		tp._advance_guidance(now)
		if acq.is_empty() and int(tp._seeker.phase) == TorpedoSeeker.Phase.ACQUIRING:
			acq = {
				"phase": tp._seeker.phase,
				"mission": tp.mission_state,
				"guidance": tp._guidance_mode,
				"t": now,
			}
		rid += 1
	return acq


# ---------------- B6-09/08：稳定捕获自动锁定，ACQUIRING 不转向 ----------------
func _b6_09(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = _mk_running_torpedo(w)
	_assert(fails, "B6-09a starts in TRANSIT", tp.mission_state_name(), "TRANSIT")
	_assert(fails, "B6-09b authority autonomous", tp.guidance_authority_name(), "AUTONOMOUS")
	# 单次回波绝不锁定（≥2 个独立时刻的有效证据 + 稳定门限）。
	tp._seeker.process_returns([_mk_return(1, 1.0, 0.0, 22.0)], 1.0)
	tp._seeker.update(1.0)
	tp._advance_lock_state()
	_assert(fails, "B6-09c single return does not lock", tp.mission_state_name(), "TRANSIT")
	_assert(fails, "B6-09d single return not tracking", int(tp._seeker.phase), 0)
	# 连续证据 → ACQUIRING（仍不操舵）→ TRACKING → 自动 LOCKED_ATTACK。
	var acq: Dictionary = _drive(tp, 8, 2.0, 0.0, 22.0)
	_assert(fails, "B6-08a acquiring reached", not acq.is_empty(), true)
	if not acq.is_empty():
		_assert(
			fails,
			"B6-08b acquiring state entered",
			int(acq["mission"]),
			Torpedo.MissionState.ACQUIRING
		)
		_assert(fails, "B6-08c no steering while acquiring", int(acq["guidance"]), 0)
	_assert(fails, "B6-09e auto locked", tp.mission_state_name(), "LOCKED_ATTACK")
	# 无需玩家 Accept/Authorize：辅助航迹未指定、权限由稳定捕获自动生效。
	_assert(fails, "B6-09f no accept needed", tp._assist_track_id, -1)
	_assert(
		fails,
		"B6-09g guidance engaged from lock only",
		tp._guidance_authorized() and tp._ever_guidance_engaged,
		true
	)


# ---------------- B6-10：连续性保护（不每帧换锁） ----------------
func _b6_10(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = _mk_running_torpedo(w)
	_drive(tp, 8, 1.0, 0.0, 22.0)
	_assert(fails, "B6-10a locked", tp.mission_state_name(), "LOCKED_ATTACK")
	var sel: SeekerTrack = tp._seeker.selected_track()
	_assert(fails, "B6-10b selected track exists", sel != null, true)
	if sel == null:
		return
	sel.lock_quality = 0.9
	sel.track_quality = 0.9
	# 更响的竞争候选（诱饵/误报）：分数更高也不得夺锁。
	var rival := SeekerTrack.create()
	rival.bearing_estimate_deg = 20.0
	rival.track_quality = 1.0
	rival.lock_quality = 1.0
	rival.mean_signal_excess_db = 90.0
	rival.classification_match = 1.0
	tp._seeker.tracks.append(rival)
	var sel_id: int = sel.seeker_track_id
	tp._seeker.update(12.0)
	_assert(fails, "B6-10c lock not stolen per frame", tp._seeker.selected_track_id, sel_id)
	_assert(
		fails,
		"B6-10d continuity bonus applied",
		sel.score(tp._seeker._cfg, true) > sel.score(tp._seeker._cfg, false),
		true
	)


# ---------------- B6-13/14：COAST → LOST_REACQUIRE 滞回 ----------------
func _b6_13_14(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = _mk_running_torpedo(w)
	_drive(tp, 8, 1.0, 0.0, 22.0)
	_assert(fails, "B6-13a locked", tp.mission_state_name(), "LOCKED_ATTACK")
	# 短时漏测 → COAST（继续按最后方位预测，不立即大幅转弯重搜）。
	tp._seeker.phase = TorpedoSeeker.Phase.COAST
	tp._advance_lock_state()
	_assert(fails, "B6-13b short miss -> COAST", tp.mission_state_name(), "COAST")
	tp._advance_guidance(20.0)
	_assert(fails, "B6-13c coast keeps last bearing", tp._guidance_mode, 1)
	# 恢复 → 回到 LOCKED_ATTACK。
	tp._seeker.phase = TorpedoSeeker.Phase.TRACKING
	tp._advance_lock_state()
	_assert(fails, "B6-13d recovered -> locked", tp.mission_state_name(), "LOCKED_ATTACK")
	# 持续漏测（确认 LOST）→ LOST_REACQUIRE。
	tp._seeker.phase = TorpedoSeeker.Phase.LOST
	tp._advance_lock_state()
	_assert(fails, "B6-14a sustained miss -> reacquire", tp.mission_state_name(), "LOST_REACQUIRE")
	# LOST_REACQUIRE → TRANSIT：线导有效时重画航线。
	var state := TorpedoRouteState.new()
	state.replace_from(
		Vector2(float(tp.pos_east_m), float(tp.pos_north_m)), [Vector2(1000.0, 1000.0)]
	)
	_assert(fails, "B6-16a reroute accepted", tp.update_route(state), true)
	_assert(fails, "B6-16b reroute -> TRANSIT", tp.mission_state_name(), "TRANSIT")
	_assert(fails, "B6-16c still listening (passive rx on)", bool(tp.passive_receiver_on), true)


# ---------------- B6-15：重搜围绕最后估计方位（非 Truth） ----------------
func _b6_15_16(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = _mk_running_torpedo(w)
	_drive(tp, 8, 1.0, 0.0, 22.0)
	tp._seeker.phase = TorpedoSeeker.Phase.LOST
	tp._advance_lock_state()
	_assert(fails, "B6-15a in reacquire", tp.mission_state_name(), "LOST_REACQUIRE")
	var last_est: float = tp._seeker._lost_bearing_deg
	_assert(fails, "B6-15b last estimate kept", last_est >= 0.0, true)
	tp._advance_guidance(60.0)
	_assert(fails, "B6-15c search on course mode", tp._guidance_mode, 1)
	var sec: Dictionary = tp._seeker.reacquire_sector(float(tp.program.search_half_angle_deg))
	var sec_half: float = float(sec["half_angle_deg"])
	var sec_center: float = float(sec["center_deg"])
	_assert(
		fails,
		"B6-15d sector centred on last estimate",
		absf(NavUtils.wrap180(sec_center - last_est)) < 1e-6,
		true
	)
	_assert(fails, "B6-15e sector widened for reacquire", sec_half > 60.0, true)
	var off: float = absf(NavUtils.wrap180(tp._guidance_course_deg - sec_center))
	_assert(
		fails,
		"B6-15f search course inside sector (off=%.1f half=%.1f)" % [off, sec_half],
		off <= sec_half + 1e-6,
		true
	)


# ---------------- B6-27..31：深度概率估计器 ----------------
func _b6_27_31(fails: Array) -> void:
	var est := DepthEstimator.new()
	var base: Dictionary = est.result(0.0)
	_assert(fails, "B6-27a default unknown", str(base["dominant"]), "UNKNOWN")
	_assert(fails, "B6-27b no fake confidence", float(base["confidence"]), 0.0)
	_assert(fails, "B6-27c no interval without measurement", base["depth_interval_m"].size(), 0)
	_assert(fails, "B6-27d display says unknown", UiText.depth_band_summary({}), "深度未知")
	# AT-28：二维主动 bearing+range 不是垂向证据，绝不生成精确深度。
	var bad := DepthEvidence.make(
		"ACT:1", 1.0, DepthEvidence.SRC_ACTIVE_2D, "hull_active", {DepthEstimator.UPPER: 1.0}, ""
	)
	_assert(fails, "B6-28a 2d active evidence unusable", bad.is_usable(), false)
	_assert(fails, "B6-28b estimator rejects it", est.update(bad, 1.0), false)
	_assert(fails, "B6-28c still unknown", str(est.result(1.0)["dominant"]), "UNKNOWN")
	# AT-29：合法层带证据更新概率并记录来源/时间/证据数。
	var ev := DepthEvidence.make(
		"WIRE:1", 10.0, DepthEvidence.SRC_TORPEDO_WIRE, "TK01", {DepthEstimator.UPPER: 1.0}, "UPPER"
	)
	_assert(fails, "B6-29a evidence accepted", est.update(ev, 10.0), true)
	# UNKNOWN 先验（1.2）> 单条层似然（1.0）：单次证据不足以塌缩为确定层，
	# 必须有第二条独立证据佐证（§7.3 防"少量证据即确定层"）。
	_assert(
		fails,
		"B6-29a2 single evidence not conclusive",
		str(est.result(10.0)["dominant"]),
		"UNKNOWN"
	)
	est.update(
		DepthEvidence.make(
			"WIRE:1b",
			10.5,
			DepthEvidence.SRC_TORPEDO_WIRE,
			"TK01",
			{DepthEstimator.UPPER: 1.0},
			"UPPER"
		),
		10.5
	)
	var r1: Dictionary = est.result(10.5)
	_assert(fails, "B6-29b dominant upper", str(r1["dominant"]), "UPPER_LIKELY")
	_assert(fails, "B6-29c confidence above gate", float(r1["confidence"]) > 0.55, true)
	_assert(fails, "B6-29d evidence counted", int(r1["evidence_count"]), 2)
	_assert(
		fails, "B6-29e source recorded", str(r1["source_summary"]).contains("TORPEDO_WIRE"), true
	)
	_assert(fails, "B6-29f updated time recorded", float(r1["updated_time"]), 10.5)
	_assert(
		fails, "B6-29g chinese display", str(UiText.depth_band_summary(r1)).contains("可能上层"), true
	)
	_assert(
		fails,
		"B6-29h source label says wire",
		UiText.depth_source(DepthEvidence.SRC_TORPEDO_WIRE),
		"鱼雷回传"
	)
	# AT-30：同一 evidence_id 只计一次。
	_assert(fails, "B6-30a duplicate rejected", est.update(ev, 11.0), false)
	_assert(fails, "B6-30b count unchanged", int(est.result(11.0)["evidence_count"]), 2)
	# AT-31：陈旧证据衰减，不永久高置信。
	var fresh: Dictionary = est.result(11.0)
	var stale: Dictionary = est.result(11.0 + DepthEstimator.HALF_LIFE_S * 3.0)
	_assert(
		fails,
		"B6-31a decays over time",
		float(stale["confidence"]) < float(fresh["confidence"]),
		true
	)
	_assert(fails, "B6-31b eventually unknown", str(stale["dominant"]), "UNKNOWN")
	# 明确垂向测量（带 sigma）才给区间 + 无 Truth 键。
	var meas := DepthEvidence.make(
		"SEEK:9", 20.0, DepthEvidence.SRC_SEEKER, "seeker", {DepthEstimator.LOWER: 1.0}, "LOWER"
	)
	meas.depth_observed_m = 110.0
	meas.depth_sigma_m = 15.0
	var est2 := DepthEstimator.new()
	est2.update(meas, 20.0)
	var r2: Dictionary = est2.result(20.0)
	_assert(
		fails, "B6-28d interval only with vertical measurement", r2["depth_interval_m"].size(), 2
	)
	_assert(
		fails,
		"B6-28e interval text",
		str(UiText.depth_band_summary(r2)).contains("可能 80–140m"),
		true
	)
	for k in DepthEvidence.forbidden_keys():
		_assert(fails, "B6-28f no truth key %s" % k, meas.to_dict().has(k), false)


# ---------------- B6-32：导线回传更新所关联接触 ----------------
func _b6_32(fails: Array) -> void:
	var w := _mk_world()
	var tracker := Tracker.new()
	var m := Measurement.new()
	m.measurement_id = 1
	m.timestamp = 0.0
	m.sensor_id = "hull_broadband"
	m.detected = true
	m.evidence_id = "E1"
	m.observer_east_m = 0.0
	m.observer_north_m = 0.0
	m.measured_bearing_deg = 0.0
	m.bearing_sigma_deg = 2.0
	var track: Track = tracker.mark(m, "S")
	_assert(fails, "B6-32a contact track created", track != null, true)
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(4)
	# 鱼雷在正北 1500m 处，主动回波给出"正北 1500m"的位置观测（含层带提示）。
	tp.pos_east_m = 0.0
	tp.pos_north_m = 1500.0
	var r := _mk_return(7, 10.0, 0.0, 25.0, "ACTIVE")
	r.range_m = 1500.0
	r.range_sigma_m = 30.0
	r.depth_band_hint = "UPPER"
	tp.seeker_returns.append(r)
	var relay := WireDepthRelay.new()
	_assert(fails, "B6-32b relay accepted", relay.advance(w, tracker, 10.0) >= 1, true)
	# 第二条独立回波（同层提示）佐证，越过 UNKNOWN 先验门限。
	var r1b := _mk_return(9, 11.0, 0.0, 25.0, "ACTIVE")
	r1b.range_m = 1500.0
	r1b.range_sigma_m = 30.0
	r1b.depth_band_hint = "UPPER"
	tp.seeker_returns.append(r1b)
	_assert(fails, "B6-32b2 second relay accepted", relay.advance(w, tracker, 11.0) >= 1, true)
	var s: Dictionary = track.depth_estimate_summary(11.0)
	_assert(fails, "B6-32c associated contact updated", str(s.get("dominant", "")), "UPPER_LIKELY")
	_assert(
		fails,
		"B6-32d source is torpedo wire",
		str(s.get("source_summary", "")).contains("TORPEDO_WIRE"),
		true
	)
	_assert(
		fails, "B6-32e association recorded", relay.associated_track(str(tp.torpedo_id)) != "", true
	)
	var before: int = int(s.get("evidence_count", 0))
	# 断线后停止新回传（已有估计继续按时间衰减）。
	tp.wire_link.cut()
	var r2 := _mk_return(12, 20.0, 0.0, 25.0, "ACTIVE")
	r2.range_m = 1500.0
	r2.range_sigma_m = 30.0
	r2.depth_band_hint = "LOWER"
	tp.seeker_returns.append(r2)
	_assert(fails, "B6-32f no new relay after cut", relay.advance(w, tracker, 20.0), 0)
	var s2: Dictionary = track.depth_estimate_summary(20.0)
	_assert(fails, "B6-32g count unchanged after cut", int(s2.get("evidence_count", 0)), before)
	_assert(fails, "B6-32h layer unchanged after cut", str(s2.get("dominant", "")), "UPPER_LIKELY")
	var s3: Dictionary = track.depth_estimate_summary(20.0 + DepthEstimator.HALF_LIFE_S * 4.0)
	_assert(
		fails,
		"B6-32i existing estimate decays",
		float(s3.get("confidence", 0.0)) < float(s2.get("confidence", 0.0)),
		true
	)


# ---------------- B6-33：AUTO 深度置信度门 ----------------
func _b6_33(fails: Array) -> void:
	var w := _mk_world()
	var tp: Torpedo = _mk_running_torpedo(w)
	_drive(tp, 8, 1.0, 0.0, 22.0)
	_assert(fails, "B6-33a locked", tp.mission_state_name(), "LOCKED_ATTACK")
	var tr: SeekerTrack = tp._seeker.selected_track()
	if tr == null:
		_assert(fails, "B6-33b selected track", false, true)
		return
	_assert(fails, "B6-33b default policy auto", tp.depth_policy(), "AUTO")
	# 走真实玩家路径把 AUTO 复位（清掉发射程序写入的显式定深）。
	_assert(fails, "B6-33b2 policy auto accepted", tp.command_depth_policy("AUTO"), true)
	tp.commanded_depth_band = "UPPER"
	tr.depth_band_hint = "LOWER"
	tr.lock_quality = 0.20
	tr.consecutive_hits = 1
	tp._advance_guidance(30.0)
	_assert(fails, "B6-33c low confidence does not chase", tp.commanded_depth_band, "UPPER")
	tr.lock_quality = 0.95
	tr.consecutive_hits = 5
	tp._advance_guidance(31.0)
	_assert(fails, "B6-33d confident switches layer", tp.commanded_depth_band, "LOWER")
	_assert(fails, "B6-33e auto source", tp.depth_command_source, "AUTO")
	# 有限垂速：一层 depth 变化不大于 max_vertical_speed * dt。
	tp.commanded_depth_m = 180.0
	var z0: float = float(tp.actual_depth_m)
	w.run_steps(1)
	var dz: float = absf(float(tp.actual_depth_m) - z0)
	_assert(
		fails,
		"B6-33f vertical rate limited (%.3f <= %.3f)" % [dz, tp.max_vertical_speed_m_s * 0.5],
		dz <= tp.max_vertical_speed_m_s * 0.5 + 1e-6,
		true
	)
	# 玩家覆盖：显式"上层"是唯一简化覆盖，AUTO 不再覆盖它。
	tp.command_depth_policy("UPPER")
	tp._advance_guidance(32.0)
	_assert(fails, "B6-33g player override kept", tp.commanded_depth_band, "UPPER")
	_assert(fails, "B6-33h override source", tp.depth_command_source, "PLAYER")


# ---------------- B6-40：玩家鱼雷命中任务目标 → 立即胜利 ----------------
func _b6_40(fails: Array) -> void:
	var w := _mk_world()
	# 固定几何：任务目标静止在正北 900m、与本艇同层。
	var tgt := TruthEntity.new()
	tgt.id = "mission_target"
	tgt.side = "red"
	tgt.platform_type = "submarine"
	tgt.position_east_m = 0.0
	tgt.position_north_m = 900.0
	tgt.depth_m = 70.0
	tgt.speed_kn = 0.0
	w.world["targets"].append(tgt)
	w._weapon_contacts.append(tgt)
	w.world["target_acs"][tgt.id] = AcousticProfile.new()
	var ends: Array = []
	w.mission_ended.connect(func(r: Dictionary): ends.append(r))
	var prog := WeaponProgram.make_manual(0.0)
	prog.speed_mode = WeaponProgram.SpeedMode.HIGH
	prog.warhead_arm_distance_m = 50.0
	var tp: Torpedo = w.weapons.fire_program(
		prog,
		float(w.world["own"].position_east_m),
		float(w.world["own"].position_north_m),
		0.0,
		70.0
	)
	_assert(fails, "B6-40a torpedo launched", tp != null, true)
	if tp == null:
		return
	for i in range(400):
		w.run_steps(1)
		if not w.is_mission_running():
			break
	_assert(fails, "B6-40b mission ended", w.is_mission_running(), false)
	_assert(fails, "B6-40c exactly once", ends.size(), 1)
	if ends.size() >= 1:
		_assert(fails, "B6-40d victory state", int(ends[0].get("state", -1)), 2)
		_assert(fails, "B6-40e reason", str(ends[0].get("reason", "")), "TARGET_DESTROYED")
	_assert(fails, "B6-40f mission state name", w.mission_state_name(), "PLAYER_VICTORY")
	_assert(fails, "B6-40g target sunk", str(tgt.damage_state), "sunk")
	_assert(fails, "B6-40h own ship intact", str(w.world["own"].damage_state), "ok")
	# 终局后所有命令统一拒绝。
	_assert(fails, "B6-40i commands rejected", w.command_reject_reason(), "MISSION_ENDED")
	_assert(fails, "B6-40j ping rejected", w.issue_ping(), false)
	_assert(fails, "B6-40k second end rejected", w.end_mission(1, "OVERWRITE"), false)
	_assert(fails, "B6-40l first reason preserved", w.mission_end_reason, "TARGET_DESTROYED")


func _assert(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH6 TEST PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("S1-11 BATCH6 TEST FAIL (%d)" % fails.size())
	quit(1)
