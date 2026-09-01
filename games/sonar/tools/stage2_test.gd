extends SceneTree
## stage2_test.gd — 阶段二：Track/Tracker/TMA 纯逻辑无头单元测试。
##
## 运行：godot --headless --path games/sonar --script res://tools/stage2_test.gd
## 覆盖需求文档"阶段 2"验收标准，固定种子可复现。
## 通过则输出 "STAGE2 TEST PASS"，非零退出码则失败。

var _failures: int = 0
var _rng: RandomNumberGenerator = null


func _init() -> void:
	print("=== STAGE2 TEST ===")
	_rng = RandomNumberGenerator.new()
	_rng.seed = 20260902

	_test_track_lob_origin()
	_test_tracker_association_and_lost()
	_test_tma_constant_course_multiple_solutions()
	_test_tma_own_maneuver_converges()
	_test_tma_solver_refines()
	_test_target_turn_breaks_uniform_model()
	_test_dot_stack()

	if _failures == 0:
		print("STAGE2 TEST PASS")
		quit(0)
	else:
		print("STAGE2 TEST FAILED: %d failures" % _failures)
		quit(1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  [ok] " + msg)
	else:
		_failures += 1
		print("  [FAIL] " + msg)


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


# ---------- 测试 1：LOB 起点 = 历史本艇位置 ----------


func _test_track_lob_origin() -> void:
	print("[track LOB origin]")
	# 用 TruthEntity 推进，确认 Track 保存的是"测量时本艇位置"
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 0.0, "speed_kn": 8.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{
			"position_east_m": 5000.0,
			"position_north_m": 5000.0,
			"course_deg": 180.0,
			"speed_kn": 10.0
		}
	)

	var tracker := Tracker.new()
	tracker.set_rng(_rng)
	var first: Measurement = _make_measurement(own, target, 10.0)
	var track := tracker.mark(first, "S")
	_check(track.track_id == "S01", "first mark -> S01, got " + track.track_id)

	# 推进本艇，再追加一条测量
	own.advance(30.0)
	target.advance(30.0)
	var second: Measurement = _make_measurement(own, target, 40.0)
	var associated: Track = tracker.feed(second)
	_check(associated == track, "second measurement associates to same track")

	# 关键：Track 保存的 observer 位置 = 测量时本艇位置，而不是当前本艇位置
	var m0: Measurement = track.first_measurement()
	var m1: Measurement = track.latest_measurement()
	# 测量时本艇已经移动，两条测量的 observer 位置必须不同
	var d_obs: float = NavUtils.distance(
		m0.observer_east_m, m0.observer_north_m, m1.observer_east_m, m1.observer_north_m
	)
	_check(d_obs > 100.0, "observer positions differ across measurements (%.0fm apart)" % d_obs)
	# 第一条测量的 observer 位置 = 初始本艇位置 (0,0)
	_check(
		_approx(m0.observer_east_m, 0.0, 1.0) and _approx(m0.observer_north_m, 0.0, 1.0),
		(
			"first LOB origin = historical own position (0,0), got (%.0f,%.0f)"
			% [m0.observer_east_m, m0.observer_north_m]
		)
	)
	# 第二条测量的 observer 位置应接近 30 秒后本艇位置（航向0、8kn → 北移 30*8*0.514≈123m）
	_check(
		_approx(m1.observer_north_m, 30.0 * NavUtils.kn_to_ms(8.0), 5.0),
		"second LOB origin = own position at that measurement time, got %.0f" % m1.observer_north_m
	)


func _make_measurement(own: TruthEntity, target: TruthEntity, ts: float) -> Measurement:
	var m := Measurement.new()
	m.timestamp = ts
	m.observer_east_m = own.position_east_m
	m.observer_north_m = own.position_north_m
	m.measured_bearing_deg = NavUtils.bearing_to_true(
		own.position_east_m, own.position_north_m, target.position_east_m, target.position_north_m
	)
	m.bearing_sigma_deg = 2.0
	m.detection_probability = 1.0
	return m


# ---------- 测试 2：Tracker 关联与失去接触 ----------


func _test_tracker_association_and_lost() -> void:
	print("[tracker association & lost]")
	var tracker := Tracker.new()
	tracker.set_rng(_rng)
	tracker.set_capacity(3)
	tracker.set_auto_interval(120.0)

	var own := TruthEntity.new()
	own.from_dict({"course_deg": 0.0, "speed_kn": 4.0})
	var t1 := TruthEntity.new()
	t1.from_dict(
		{
			"position_east_m": 4000.0,
			"position_north_m": 4000.0,
			"course_deg": 270.0,
			"speed_kn": 10.0
		}
	)
	var t2 := TruthEntity.new()
	t2.from_dict(
		{
			"position_east_m": -3000.0,
			"position_north_m": 3000.0,
			"course_deg": 90.0,
			"speed_kn": 8.0
		}
	)

	var trk1 := tracker.mark(_make_measurement(own, t1, 0.0), "S")
	var trk2 := tracker.mark(_make_measurement(own, t2, 0.0), "S")
	_check(trk1.track_id == "S01" and trk2.track_id == "S02", "two marks -> S01,S02")

	# 后续测量应关联到正确的航迹（按方位最近邻）
	own.advance(60.0)
	t1.advance(60.0)
	t2.advance(60.0)
	var feed1: Track = tracker.feed(_make_measurement(own, t1, 60.0))
	var feed2: Track = tracker.feed(_make_measurement(own, t2, 60.0))
	_check(feed1 == trk1, "target1 measurement feeds track1")
	_check(feed2 == trk2, "target2 measurement feeds track2")

	# 失去接触：标记 lost 后不得再 feed 到该航迹
	tracker.mark_lost(trk1)
	own.advance(60.0)
	t1.advance(60.0)
	var feed_lost: Track = tracker.feed(_make_measurement(own, t1, 120.0))
	_check(feed_lost != trk1, "lost track does not receive new measurements")
	_check(trk1.state == Track.TrackState.LOST, "track1 state=LOST")

	# 接触编号方案：M 类 Master
	var master := tracker.merge_tracks([trk1, trk2])
	_check(
		master.track_id.begins_with("M"), "master track id starts with M, got " + master.track_id
	)
	_check(master.measurement_history.size() >= 4, "master has merged measurements")


# ---------- 测试 3：单一稳定航向 → 近慢/远快多解 ----------


func _test_tma_constant_course_multiple_solutions() -> void:
	print("[TMA constant course -> near-slow/far-fast ambiguity]")
	# 用"目标沿固定方位径向运动"的纯方位歧义场景：
	# 本艇静止，目标从不同初始距离、不同速度沿同一视线方向（东）匀速远离。
	# 这类目标产生恒定方位的方位序列 → 近慢与远快都能零残差解释同一观测。
	var meas: Array = _gen_radial(6000.0, 9.0, 10, 5.0)
	# 近慢假设：目标较近、较慢
	var r_near: Dictionary = TmaSolver.solve(
		meas, {"p0_e": 3000.0, "p0_n": 0.0, "v_e_ms": NavUtils.kn_to_ms(5.0), "v_n_ms": 0.0}
	)
	# 远快假设：目标较远、较快
	var r_far: Dictionary = TmaSolver.solve(
		meas, {"p0_e": 12000.0, "p0_n": 0.0, "v_e_ms": NavUtils.kn_to_ms(15.0), "v_n_ms": 0.0}
	)
	_check(
		r_near.get("success", false) and r_far.get("success", false),
		"solver succeeds on both hypotheses"
	)
	if r_near.get("success", false) and r_far.get("success", false):
		# 两个不同的运动假设都产生低残差（都能解释同一方位序列）
		_check(
			r_near["rms_residual_deg"] < 0.5 and r_far["rms_residual_deg"] < 0.5,
			(
				"near-slow (rms=%.3f) and far-fast (rms=%.3f) both fit"
				% [r_near["rms_residual_deg"], r_far["rms_residual_deg"]]
			)
		)
		# 但两解的距离、速度差异明显（歧义空间存在）
		_check(
			(
				absf(r_near["range_m"] - r_far["range_m"]) > 2000.0
				and absf(r_near["speed_kn"] - r_far["speed_kn"]) > 2.0
			),
			(
				"near-slow (rng=%.0f,%.0fkn) vs far-fast (rng=%.0f,%.0fkn) differ"
				% [r_near["range_m"], r_near["speed_kn"], r_far["range_m"], r_far["speed_kn"]]
			)
		)


## 生成"目标沿东向视线径向远离"的无噪声方位序列。
func _gen_radial(start_range_m: float, speed_kn: float, count: int, interval_s: float) -> Array:
	var out: Array = []
	var t: float = 0.0
	for i in range(count):
		var rx: float = start_range_m + NavUtils.kn_to_ms(speed_kn) * t
		# 本艇在原点，目标在 (rx, 0) → 方位恒为 90°
		(
			out
			. append(
				{
					"time": t,
					"observer_e": 0.0,
					"observer_n": 0.0,
					"bearing": NavUtils.wrap360(rad_to_deg(atan2(rx, 0.0))),
					"sigma": 0.5,
				}
			)
		)
		t += interval_s
	return out


# ---------- 测试 4：本艇转向后收敛（歧义收窄） ----------


func _test_tma_own_maneuver_converges() -> void:
	print("[TMA own maneuver -> ambiguity narrows]")
	# 关键可观测性性质：本艇做机动后，方位序列不再能被"任意径向运动"解释，
	# 歧义从"连续解流形"收窄为有限/更窄的解集。
	# 验证方式：对径向场景（本艇静止），从近/远起点求得的两个解都零残差（歧义宽）；
	# 对同一目标但本艇机动后的场景，同样从近/远起点求解，两解应更接近真实（歧义收窄）。
	var meas_still: Array = _gen_radial(8000.0, 10.0, 14, 5.0)
	var meas_maneuver: Array = _gen_maneuver_radial(8000.0, 10.0, 14, 5.0, 40.0, 120.0)
	# 本艇静止：近/远起点 → 两个明显不同的解（歧义宽）
	var ns_still: Dictionary = TmaSolver.solve(
		meas_still, {"p0_e": 4000.0, "p0_n": 0.0, "v_e_ms": 0.0, "v_n_ms": 0.0}
	)
	var fs_still: Dictionary = TmaSolver.solve(
		meas_still, {"p0_e": 14000.0, "p0_n": 0.0, "v_e_ms": 0.0, "v_n_ms": 0.0}
	)
	_check(
		(
			ns_still.get("success", false)
			and fs_still.get("success", false)
			and absf(ns_still["range_m"] - fs_still["range_m"]) > 2000.0
		),
		"still-own: near/far starts yield widely different solutions (ambiguity wide)"
	)
	# 本艇机动：近/远起点 → 解应收敛到更接近真实(8000m)的范围
	var ns_man: Dictionary = TmaSolver.solve(
		meas_maneuver, {"p0_e": 4000.0, "p0_n": 0.0, "v_e_ms": 0.0, "v_n_ms": 0.0}
	)
	var fs_man: Dictionary = TmaSolver.solve(
		meas_maneuver, {"p0_e": 14000.0, "p0_n": 0.0, "v_e_ms": 0.0, "v_n_ms": 0.0}
	)
	_check(ns_man.get("success", false) and fs_man.get("success", false), "maneuver solve succeeds")
	if ns_man.get("success", false) and fs_man.get("success", false):
		var spread_man: float = absf(ns_man["range_m"] - fs_man["range_m"])
		var spread_still: float = absf(ns_still["range_m"] - fs_still["range_m"])
		_check(
			spread_man < spread_still,
			"own maneuver narrows solution spread (%.0fm -> %.0fm)" % [spread_still, spread_man]
		)


## 生成"目标径向远离 + 本艇中途机动"的方位序列（无噪声）。
func _gen_maneuver_radial(
	start_range_m: float,
	speed_kn: float,
	count: int,
	interval_s: float,
	turn_at: float,
	new_course: float
) -> Array:
	var out: Array = []
	var own := Vector2(0, 0)
	var tgt := Vector2(start_range_m, 0)
	var own_c: float = 0.0
	var t: float = 0.0
	for i in range(count):
		if turn_at > 0.0 and t > turn_at:
			own_c = new_course
		var d: Vector2 = tgt - own
		(
			out
			. append(
				{
					"time": t,
					"observer_e": own.x,
					"observer_n": own.y,
					"bearing": NavUtils.wrap360(rad_to_deg(atan2(d.x, d.y))),
					"sigma": 0.5,
				}
			)
		)
		# 本艇以 6kn 沿 own_c 运动
		own += (
			Vector2(sin(deg_to_rad(own_c)), cos(deg_to_rad(own_c)))
			* NavUtils.kn_to_ms(6.0)
			* interval_s
		)
		# 目标向东远离
		tgt += Vector2(NavUtils.kn_to_ms(speed_kn) * interval_s, 0.0)
		t += interval_s
	return out


# ---------- 测试 5：solver 从 TMA 尺起点细化到低残差 ----------


func _test_tma_solver_refines() -> void:
	print("[TMA solver refines from a near-solution start]")
	# solver 的角色是"从玩家 TMA 尺（接近解的起点）局部细化"。
	# 验证：从真实解附近出发，solver 收敛到低残差解，且 range/speed 与真实接近。
	var meas: Array = _gen_maneuver_radial(8000.0, 10.0, 16, 5.0, 40.0, 120.0)
	var truth := {"p0_e": 8000.0, "p0_n": 0.0, "v_e_ms": NavUtils.kn_to_ms(10.0), "v_n_ms": 0.0}
	var r: Dictionary = TmaSolver.solve(meas, truth)
	_check(r.get("success", false), "solver succeeds from near-solution start")
	if r.get("success", false):
		_check(
			r["rms_residual_deg"] < 1.0,
			"solver reaches low residual (%.3f deg)" % r["rms_residual_deg"]
		)
		_check(
			absf(r["speed_kn"] - 10.0) < 3.0,
			"solver recovers target speed near truth (%.1f kn)" % r["speed_kn"]
		)


# ---------- 测试 6：目标转向 → 旧匀速模型失效 ----------


func _test_target_turn_breaks_uniform_model() -> void:
	print("[target turn invalidates old uniform model]")
	# 目标从 (0,6000) 向南(180°) 穿过观测者附近，40s 后转向西(270°)。
	# 用转向前的测量拟合一个匀速解，再用这个解预测转向后的方位，残差应变大 → 旧模型失效。
	var meas: Array = _gen_target_turn(6000.0, 10.0, 34, 5.0, 40.0)
	# 分离转向前后
	var before: Array = []
	var after: Array = []
	for m in meas:
		if m["time"] <= 40.0:
			before.append(m)
		else:
			after.append(m)
	_check(before.size() >= 4 and after.size() >= 4, "enough measurements before and after turn")
	# 用转向前的数据拟合匀速解
	var pre_start := {
		"p0_e": 0.0, "p0_n": 6000.0, "v_e_ms": 0.0, "v_n_ms": -NavUtils.kn_to_ms(10.0)
	}
	var r_pre: Dictionary = TmaSolver.solve(before, pre_start)
	_check(r_pre.get("success", false), "pre-turn uniform fit succeeds")
	if r_pre.get("success", false) and after.size() >= 4:
		# 用该解预测转向后测量的方位残差
		var pred: Array = (
			TmaSolver
			. residuals_at(
				after,
				r_pre["t0"],
				r_pre["p0_e"],
				r_pre["p0_n"],
				r_pre["v_e_ms"],
				r_pre["v_n_ms"],
			)
		)
		var post_rms: float = _calc_rms(pred)
		# 转向后残差应变大（旧匀速解无法解释新运动）
		_check(
			post_rms > 2.0,
			"old uniform model fails to predict post-turn bearings (rms %.1f deg)" % post_rms
		)
		# 对照组：转向前的残差应小（同一解确实拟合了转向前的数据）
		var pre_res: Array = TmaSolver.residuals_at(
			before, r_pre["t0"], r_pre["p0_e"], r_pre["p0_n"], r_pre["v_e_ms"], r_pre["v_n_ms"]
		)
		_check(
			_calc_rms(pre_res) < 2.0,
			"same solution fits pre-turn bearings well (rms %.1f deg)" % _calc_rms(pre_res)
		)


## 生成"目标先向南(180°)后转向西(270°)"的方位序列。
func _gen_target_turn(
	start_range_m: float, speed_kn: float, count: int, interval_s: float, turn_at: float
) -> Array:
	var out: Array = []
	var own := Vector2(0, 0)
	var tgt := Vector2(0, start_range_m)
	var tgt_c: float = 180.0
	var t: float = 0.0
	for i in range(count):
		if turn_at > 0.0 and t > turn_at:
			tgt_c = 270.0  # 转向西
		var d: Vector2 = tgt - own
		(
			out
			. append(
				{
					"time": t,
					"observer_e": own.x,
					"observer_n": own.y,
					"bearing": NavUtils.wrap360(rad_to_deg(atan2(d.x, d.y))),
					"sigma": 0.3,
				}
			)
		)
		tgt += (
			Vector2(sin(deg_to_rad(tgt_c)), cos(deg_to_rad(tgt_c)))
			* NavUtils.kn_to_ms(speed_kn)
			* interval_s
		)
		t += interval_s
	return out


func _calc_rms(entries: Array) -> float:
	var s: float = 0.0
	for e in entries:
		s += e["residual_deg"] * e["residual_deg"]
	return sqrt(s / float(maxi(entries.size(), 1)))


func _test_dot_stack() -> void:
	print("[dot stack]")
	var meas: Array = _gen_maneuver_radial(8000.0, 10.0, 12, 5.0, 40.0, 120.0)
	var r: Dictionary = TmaSolver.solve(
		meas, {"p0_e": 8000.0, "p0_n": 0.0, "v_e_ms": NavUtils.kn_to_ms(10.0), "v_n_ms": 0.0}
	)
	if not r.get("success", false):
		_check(false, "dot stack: solver failed")
		return
	var stack := DotStack.new()
	stack.compute(meas, r["p0_e"], r["p0_n"], r["v_e_ms"], r["v_n_ms"], r["t0"])
	_check(stack.residual_entries.size() == meas.size(), "dot stack has one entry per measurement")
	# 解算后的残差应接近 0（拟合良好）
	_check(
		stack.rms_residual_deg() < 1.0,
		"dot stack rms small after fit (%.3f)" % stack.rms_residual_deg()
	)
	# 最新点 age_rank=0
	var latest: Dictionary = stack.latest()
	_check(latest.get("age_rank", -1) == 0, "latest entry has age_rank 0")
