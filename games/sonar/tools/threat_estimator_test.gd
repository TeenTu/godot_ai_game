extends SceneTree
## threat_estimator_test.gd — S109 §4 估计与信息边界单元验收（AT-10/11/12/15/16）。
##
##   EST-10  单次被动方位 → 位置未收敛（大误差扇区，禁伪精确点，AT-10）。
##   EST-11  本艇两腿机动（正横穿越）+ 多时刻带噪方位 → 估计收敛、95% 覆盖率
##           在 MC 设计区间、平均位置误差有界（AT-11）。
##   EST-12  无新证据 → COASTING；位置协方差随时间不减小（AT-12）。
##   EST-15  距离离谱回波/无 range DTO → 门控拒绝，协方差不被人为缩小（AT-15）。
##   EST-16  主动 DTO 结构上无 target_id/内核身份，关联只用可观测量（AT-16）。
##   EST-AMB 两近方位航迹等价候选 → 歧义拒绝融合（§4.4）。

const COV95_CHI2: float = 5.991


func _initialize() -> void:
	var fails: Array = []
	_est_10(fails)
	_est_11(fails)
	_est_12(fails)
	_est_15(fails)
	_est_16(fails)
	_est_amb(fails)
	_finish(fails)


func _est_10(fails: Array) -> void:
	var est := TorpedoThreatEstimator.new()
	est.init_from_bearing(90.0, 2.0, 0.0, 0.0, 10.0)
	var el: Dictionary = est.ellipse_95()
	_assert(fails, not est.converged(), "EST-10 single bearing: not converged")
	_assert(
		fails,
		float(el["axis_a_m"]) > 3000.0,
		"EST-10 along-LOB uncertainty stays large (a=%.0f)" % float(el["axis_a_m"])
	)
	var mgr := _mk_mgr_with_track(90.0, 2.0, 10.0)
	var snap: Dictionary = mgr.estimate_snapshot(mgr.tracks()[0])
	_assert(
		fails,
		snap["position_mean_e_m"] == null and not bool(snap["converged"]),
		"EST-10 snapshot withholds pseudo-precise point"
	)


func _est_11(fails: Array) -> void:
	# AT-11 物理口径：纯方位+速度未知先验下，沿 LOB 可观测性要求本艇机动
	# "横越正横"——本场景真目标固定 (1000, 3000)；本艇两腿（90°×30 帧 →
	# 000°×70 帧，10 kn）在 t≈883s 正横通过（CPA≈543m），方位总摆幅≈156°，
	# 两条 LOB 交角≈90° → 距离向信息充分；方位噪声 σ=1°。
	var tgt := Vector2(1000.0, 3000.0)
	var covered: int = 0
	var converged_cnt: int = 0
	var pos_err_sum: float = 0.0
	var runs: int = 30
	for k in range(runs):
		var rng := RandomNumberGenerator.new()
		rng.seed = 777000 + k
		var est := TorpedoThreatEstimator.new()
		var own := Vector2.ZERO
		var spd: float = 5.144  # 10 kn
		var t: float = 0.0
		var first: bool = true
		for i in range(100):
			# 每 10s 一帧；30 帧后由 090° 转 000°（两腿基线，正横穿越）。
			var crs_deg: float = 90.0 if i < 30 else 0.0
			var obs_now: Vector2 = own
			# 参数序 = (观测者, 目标)——先本艇后目标，勿反。
			var brg_true: float = NavUtils.bearing_to_true(
				float(obs_now.x), float(obs_now.y), float(tgt.x), float(tgt.y)
			)
			var z: float = NavUtils.wrap360(brg_true + rng.randfn(0.0, 1.0))
			if first:
				est.init_from_bearing(z, 1.0, float(obs_now.x), float(obs_now.y), t)
				first = false
			else:
				est.predict(t)
				est.bearing_update(z, 1.0, float(obs_now.x), float(obs_now.y))
			# 航向=真北顺时针：东分量=sin、北分量=cos。
			var b := Vector2(sin(deg_to_rad(crs_deg)), cos(deg_to_rad(crs_deg)))
			own += b * spd * 10.0
			t += 10.0
		var err := Vector2(float(est.position().x) - tgt.x, float(est.position().y) - tgt.y)
		pos_err_sum += err.length()
		# 95% 置信椭圆覆盖 = 马氏距离² ≤ 5.991（用位置块 P）。
		var det: float = est.p11 * est.p22 - est.p12 * est.p12
		if det > 1e-9:
			var d2: float = (
				(est.p22 * err.x * err.x - 2.0 * est.p12 * err.x * err.y + est.p11 * err.y * err.y)
				/ det
			)
			if d2 <= COV95_CHI2:
				covered += 1
		if est.converged():
			converged_cnt += 1
	var cov_rate: float = float(covered) / float(runs)
	_assert(
		fails,
		cov_rate >= 0.7 and cov_rate <= 1.0,
		"EST-11 95%% coverage in MC band: %.2f" % cov_rate
	)
	_assert(
		fails,
		float(converged_cnt) / float(runs) >= 0.7,
		"EST-11 MC converged fraction %.2f" % (float(converged_cnt) / float(runs))
	)
	var mean_pos_err: float = pos_err_sum / float(runs)
	_assert(fails, mean_pos_err < 800.0, "EST-11 mean position err %.0fm < 800" % mean_pos_err)


func _est_12(fails: Array) -> void:
	var mgr := _mk_mgr_with_track(90.0, 2.0, 10.0)
	var est: TorpedoThreatEstimator = mgr.tracks()[0]["est"]
	var prev_a: float = est.ellipse_95()["axis_a_m"]
	for t in [15.0, 20.0, 25.0, 30.0, 35.0, 40.0]:
		mgr.advance(t)
		var a: float = float(est.ellipse_95()["axis_a_m"])
		_assert(fails, a >= prev_a - 1e-6, "EST-12 covariance never shrinks at t=%.0f" % t)
		prev_a = a
	var st: String = str(mgr.tracks()[0]["state"])
	_assert(fails, st == "COASTING", "EST-12 state COASTING without evidence: %s" % st)


func _est_15(fails: Array) -> void:
	var mgr := _mk_mgr_with_track(90.0, 2.0, 10.0)
	var tr: Dictionary = mgr.tracks()[0]
	var est: TorpedoThreatEstimator = tr["est"]
	# 合法融合先收紧一次（模拟真实测距）。
	var good: Dictionary = _dto(1, 90.0, 2.0, 4000.0, 50.0, 0.0, 0.0)
	var tid: String = mgr.fuse_active_return(good, 10.0)
	_assert(fails, tid != "", "EST-15 setup: in-gate fusion succeeds")
	var a0: float = float(est.ellipse_95()["axis_a_m"])
	var b0: float = float(est.ellipse_95()["axis_b_m"])
	# 离谱距离 → 门控拒绝、协方差不缩、估计不动。
	var bad: Dictionary = _dto(2, 90.0, 2.0, 9000.0, 40.0, 0.0, 0.0)
	var tid2: String = mgr.fuse_active_return(bad, 10.0)
	var a1: float = float(est.ellipse_95()["axis_a_m"])
	var b1: float = float(est.ellipse_95()["axis_b_m"])
	_assert(fails, tid2 == "", "EST-15 out-of-gate rejected: '%s'" % tid2)
	_assert(
		fails, a1 >= a0 - 1e-6 and b1 >= b0 - 1e-6, "EST-15 covariance untouched by rejected echo"
	)
	# 无 range 字段的 DTO 不得进入融合。
	var no_rng := {"bearing_deg": 90.0, "observer_e_m": 0.0, "observer_n_m": 0.0}
	_assert(fails, mgr.fuse_active_return(no_rng, 10.0) == "", "EST-15 DTO without range ignored")


func _est_16(fails: Array) -> void:
	var m := Measurement.new()
	m.measurement_id = 77
	m.timestamp = 12.0
	m.sensor_id = "ACT01"
	m.measured_bearing_deg = 90.0
	m.bearing_sigma_deg = 2.0
	m.measured_range_m = 3500.0
	m.range_sigma_m = 60.0
	m.signal_excess_db = 5.0
	m.detection_probability = 0.9
	var dto: Dictionary = ThreatTrackManager.active_return_dto(m, 100.0, 200.0)
	for k in [
		"target_id",
		"internal_token",
		"emitter_internal_ref",
		"emission_kind",
		"true_range_m",
		"true_bearing_deg",
		"true_course_deg",
		"true_speed_kn",
		"platform_kind",
	]:
		_assert(fails, not dto.has(k), "EST-16 DTO free of forbidden key %s" % k)
	var mgr := _mk_mgr_with_track(90.0, 2.0, 10.0)
	dto["evidence_id"] = 5001
	dto["bearing_deg"] = 90.0
	var tid: String = mgr.fuse_active_return(dto, 10.0)
	_assert(fails, tid != "", "EST-16 association works with observables only")
	_assert(fails, str(mgr.tracks()[0]["state"]) == "RANGE_AIDED", "EST-16 RANGE_AIDED set")


func _est_amb(fails: Array) -> void:
	# 两条近方位（15°间隔）先验航迹；对二者等价距离/方位的回波 → 歧义拒绝。
	var mgr := ThreatTrackManager.new()
	mgr.ingest(_ev(1, 90.0, 10.0), 10.0)
	mgr.ingest(_ev(2, 105.0, 10.0), 10.0)
	_assert(fails, mgr.tracks().size() == 2, "EST-AMB two tracks exist")
	var a0: float = float(
		(mgr.tracks()[0]["est"] as TorpedoThreatEstimator).ellipse_95()["axis_a_m"]
	)
	var b0: float = float(
		(mgr.tracks()[0]["est"] as TorpedoThreatEstimator).ellipse_95()["axis_b_m"]
	)
	var dto: Dictionary = _dto(9, 97.5, 2.0, 4750.0, 50.0, 0.0, 0.0)
	var tid: String = mgr.fuse_active_return(dto, 10.0)
	var a1: float = float(
		(mgr.tracks()[0]["est"] as TorpedoThreatEstimator).ellipse_95()["axis_a_m"]
	)
	var b1: float = float(
		(mgr.tracks()[0]["est"] as TorpedoThreatEstimator).ellipse_95()["axis_b_m"]
	)
	_assert(fails, tid == "", "EST-AMB ambiguous association rejected")
	_assert(fails, a1 >= a0 - 1e-6 and b1 >= b0 - 1e-6, "EST-AMB no track shrank on ambiguity")


# ---------------- helpers ----------------


func _mk_mgr_with_track(brg: float, sigma: float, now: float) -> ThreatTrackManager:
	var mgr := ThreatTrackManager.new()
	mgr.ingest(_ev(1, brg, now, sigma), now)
	return mgr


func _ev(id: int, brg: float, now: float, sigma: float = 2.0) -> Dictionary:
	return {
		"evidence_id": id,
		"evidence_kind": "RUNNING_NOISE",
		"bearing_deg": brg,
		"bearing_sigma_deg": sigma,
		"confidence": 0.8,
		"p_torpedo": 0.8,
		"class_state": "PROBABLE_TORPEDO",
		"observer_e_m": 0.0,
		"observer_n_m": 0.0,
		"timestamp": now,
	}


func _dto(
	id: int, brg: float, sb: float, rng_m: float, sr: float, obs_e: float, obs_n: float
) -> Dictionary:
	return {
		"evidence_id": id,
		"bearing_deg": brg,
		"bearing_sigma_deg": sb,
		"measured_range_m": rng_m,
		"range_sigma_m": sr,
		"observer_e_m": obs_e,
		"observer_n_m": obs_n,
	}


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("THREAT-ESTIMATOR TEST PASS")
		quit(0)
	else:
		print("THREAT-ESTIMATOR TEST FAIL (%d)" % fails.size())
		quit(1)
