extends SceneTree
## play_test.gd — CI 冒烟测试（确定性，供 deploy.yml 的 smoke test 使用）。
##
## 运行：godot --headless --path games/sonar --script res://tools/play_test.gd
## 必须输出 "PLAY_TEST result=PASS" 才算通过（CI grep 此字符串）。
## 阶段一：验证仿真内核能稳定跑完一个固定种子场景并产出合理测量流，
## 同时确认核心模块无编译错误（nav_utils / 声学 / 传感器 / world）。
## 阶段二：验证 Track/Tracker 关联与 TMA 求解链路能跑通（无编译错误）。


func _init() -> void:
	_run()


func _run() -> void:
	# 1) 编译检查：NavUtils 可调用
	var probe: float = NavUtils.wrap360(370.0)
	if absf(probe - 10.0) > 0.001:
		print("PLAY_TEST result=FAIL (nav_utils)")
		quit(1)
		return

	# 2) 跑固定种子场景，确认能产出测量
	var scenario: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	if scenario.is_empty():
		print("PLAY_TEST result=FAIL (scenario load)")
		quit(1)
		return

	var w := World.new()
	w.load_scenario(scenario)
	w.run_steps(int(scenario.get("duration", 30.0) / scenario.get("dt", 0.5)))

	if w.measurement_count() <= 0:
		print("PLAY_TEST result=FAIL (no measurements)")
		quit(1)
		return

	print("sonar smoke: %d measurements, sim_time=%.1fs" % [w.measurement_count(), w.sim_time])

	# 3) 阶段二链路冒烟：Track/Tracker 关联 + TMA 求解 + DotStack（无编译错误）
	if not _stage2_smoke():
		quit(1)
		return

	# 4) 阶段三 UI 冒烟：实例化 SonarUI，走几帧，验证 UI 构建 + 仿真推进 + 关联
	if not await _stage3_smoke():
		quit(1)
		return

	# 5) TMA 自动拟合验收测试（需求文档第十二节核心场景）
	if not _stage_tma_auto():
		quit(1)
		return

	print("PLAY_TEST result=PASS")
	quit(0)


## 阶段三冒烟：SonarUI 挂树走帧，验证无编译错误且仿真/接触链路工作。
func _stage3_smoke() -> bool:
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	# headless --script 下引擎不自动调节点 _process，这里显式推进仿真
	for i in range(12):
		ui._process(0.5)
	if ui.world == null:
		print("PLAY_TEST result=FAIL (stage3 ui world is null)")
		return false
	if ui.world.sim_time <= 0.0:
		print(
			(
				"PLAY_TEST result=FAIL (stage3 ui world did not advance: sim_time=%.1f meas=%d)"
				% [ui.world.sim_time, ui.world.measurements.size()]
			)
		)
		return false
	if ui.tracker.count() <= 0:
		print("PLAY_TEST result=FAIL (stage3 no tracks created)")
		return false
	var track_count: int = ui.tracker.count()
	var sim_time: float = ui.world.sim_time

	# TMA 拟合链路冒烟：推进足够测量后选中接触再 Auto Fit，验证 last_fit 与注入
	for i in range(120):
		ui._process(0.5)
	if ui.selected_track_id == "":
		for t in ui.tracker.all_tracks():
			if t.state == Track.TrackState.ACTIVE:
				ui.selected_track_id = t.track_id
				break
	ui._dirty = true
	ui._rebuild_display_data()
	ui._on_fit_tma()
	var fit_ok: bool = (
		not ui.last_fit.is_empty()
		and bool(ui.last_fit.get("success", false))
		and not ui._chart.fit_hypotheses.is_empty()
		and not ui._chart.fit_ticks.is_empty()
		and not ui._bt_plot.model_curves.is_empty()
		and not ui._res_plot.residuals.is_empty()
	)
	if not fit_ok:
		print("PLAY_TEST result=FAIL (stage3 fit flow: last_fit/injection incomplete)")
		return false
	var hyp_count: int = int(ui.last_fit.get("hypothesis_count", 0))
	var fit_status: String = str(ui.last_fit.get("status", "?"))

	ui.queue_free()
	await process_frame
	print(
		(
			"sonar stage3 smoke: sim_time=%.1fs tracks=%d fit=%s hyps=%d"
			% [sim_time, track_count, fit_status, hyp_count]
		)
	)
	return true


## 阶段二冒烟：构造固定场景 → Tracker 关联 → TMA 求解 → DotStack。
func _stage2_smoke() -> bool:
	# 静止本艇，目标自北向南匀速（真方位 180°），产生恒定方位序列。
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 0.0, "speed_kn": 0.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{"position_east_m": 0.0, "position_north_m": 6000.0, "course_deg": 180.0, "speed_kn": 10.0}
	)

	var tracker := Tracker.new()
	var first := _make_measurement(own, target, 0.0)
	var track: Track = tracker.mark(first, "S")
	if track.track_id != "S01":
		print("PLAY_TEST result=FAIL (stage2 tracker mark: got " + track.track_id + ")")
		return false

	# 生成 12 条 5s 间隔的测量并喂给 tracker
	var meas: Array = []
	for i in range(12):
		own.advance(5.0)
		target.advance(5.0)
		var m := _make_measurement(own, target, 5.0 * (i + 1))
		(
			meas
			. append(
				{
					"time": m.timestamp,
					"observer_e": m.observer_east_m,
					"observer_n": m.observer_north_m,
					"bearing": m.measured_bearing_deg,
					"sigma": m.bearing_sigma_deg,
				}
			)
		)
		var assoc: Track = tracker.feed(m)
		if assoc != track:
			print("PLAY_TEST result=FAIL (stage2 tracker feed lost association)")
			return false

	# TMA 求解：从真实解附近起手，应收敛到低残差
	var start := {"p0_e": 0.0, "p0_n": 6000.0, "v_e_ms": 0.0, "v_n_ms": -NavUtils.kn_to_ms(10.0)}
	var r: Dictionary = TmaSolver.solve(meas, start)
	if not r.get("success", false) or float(r.get("rms_residual_deg", 999.0)) > 0.5:
		print(
			(
				"PLAY_TEST result=FAIL (stage2 TMA solve: rms=%.3f)"
				% float(r.get("rms_residual_deg", -1.0))
			)
		)
		return false

	# DotStack 冒烟
	var stack := DotStack.new()
	stack.compute(meas, r["p0_e"], r["p0_n"], r["v_e_ms"], r["v_n_ms"], r["t0"])
	if stack.rms_residual_deg() > 0.5:
		print("PLAY_TEST result=FAIL (stage2 dot stack rms=%.3f)" % stack.rms_residual_deg())
		return false

	print(
		"sonar stage2 smoke: track=%s tma_rms=%.3f" % [track.track_id, float(r["rms_residual_deg"])]
	)
	return true


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


# =====================================================================
#  TMA 自动拟合验收测试（需求文档第十二节）
# =====================================================================


## 生成一条测量字典（可加高斯噪声）。
func _gen_meas(
	own: TruthEntity, target: TruthEntity, ts: float, sigma: float, rng: RandomNumberGenerator
) -> Dictionary:
	var noise: float = 0.0
	if rng != null and sigma > 0.0:
		noise = rng.gauss_fn(0.0, sigma)
	var brg: float = NavUtils.bearing_to_true(
		own.position_east_m, own.position_north_m, target.position_east_m, target.position_north_m
	)
	# sigma=0 表示"无噪声"测试场景；σθ 必须 > 0，声明为小值 0.1°
	var sig: float = 0.1 if sigma <= 0.0 else sigma
	return {
		"time": ts,
		"observer_e": own.position_east_m,
		"observer_n": own.position_north_m,
		"bearing": NavUtils.wrap360(brg + noise),
		"sigma": sig,
	}


## 场景收集器：每 interval_s 收一条测量，可选在中途转向本艇/目标。
func _collect(
	own: TruthEntity,
	target: TruthEntity,
	duration_s: float,
	interval_s: float,
	sigma: float,
	rng: RandomNumberGenerator,
	own_turn_at_s: float = -1.0,
	own_new_course: float = 0.0,
	tgt_turn_at_s: float = -1.0,
	tgt_new_course: float = 0.0
) -> Array:
	var meas: Array = []
	var t: float = 0.0
	while t <= duration_s + 0.01:
		meas.append(_gen_meas(own, target, t, sigma, rng))
		if t > 0.0 and absf(t - own_turn_at_s) < interval_s * 0.5:
			own.course_deg = own_new_course
		if t > 0.0 and absf(t - tgt_turn_at_s) < interval_s * 0.5:
			target.course_deg = tgt_new_course
		own.advance(interval_s)
		target.advance(interval_s)
		t += interval_s
	return meas


## 验收测试 1 + 5：无噪声、两腿、匀速目标、不规则间隔 → 精确恢复。
func _accept_test1() -> bool:
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 45.0, "speed_kn": 8.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{
			"position_east_m": 8000.0,
			"position_north_m": 6000.0,
			"course_deg": 200.0,
			"speed_kn": 10.0
		}
	)
	# 不规则间隔（60s 与 90s 交替），600s 附近本艇转向 → 第二腿
	var meas: Array = []
	var t: float = 0.0
	var i: int = 0
	while t <= 1200.0:
		meas.append(_gen_meas(own, target, t, 0.0, null))
		var step: float = 60.0 if i % 2 == 0 else 90.0
		if absf(t - 600.0) < 30.0:
			own.course_deg = 135.0
		own.advance(step)
		target.advance(step)
		t += step
		i += 1
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		print("TMA_ACCEPT FAIL t1: solve failed")
		return false
	if str(r["status"]) != "CONVERGED":
		print("TMA_ACCEPT FAIL t1: status=%s (want CONVERGED)" % str(r["status"]))
		return false
	var best: Dictionary = r["best"]
	# 真值距离按参考时刻（最后一条测量 t=1200s）计算：
	#   目标 (8000,6000) 航向200° 10kn 走1200s → (5888.6, 198.9)
	#   本艇 45°/8kn 走600s → (1746,1746)，再 135°/8kn 走600s → (3492,0)
	#   真值距离 ≈ 2404.7m
	var rng_err: float = absf(float(best["range_m"]) - 2404.7)
	var spd_err: float = absf(float(best["speed_kn"]) - 10.0)
	var crs_err: float = absf(NavUtils.angle_diff(float(best["course_deg"]), 200.0))
	if rng_err > 400.0 or spd_err > 0.8 or crs_err > 4.0:
		print(
			(
				"TMA_ACCEPT FAIL t1: rng_err=%.0fm spd_err=%.2fkn crs_err=%.1fdeg"
				% [rng_err, spd_err, crs_err]
			)
		)
		return false
	if float(r["angular_rmse"]) > 0.5:
		print("TMA_ACCEPT FAIL t1: angular_rmse=%.3f" % float(r["angular_rmse"]))
		return false
	if int(r["legs"]) < 2:
		print("TMA_ACCEPT FAIL t1: legs=%d (want >=2)" % int(r["legs"]))
		return false
	print(
		(
			"TMA_ACCEPT t1 ok: rng_err=%.0fm spd_err=%.2fkn crs_err=%.1fdeg rmse=%.3f"
			% [rng_err, spd_err, crs_err, float(r["angular_rmse"])]
		)
	)
	return true


## 验收测试 2：无噪声、单一直航腿 → INSUFFICIENT_GEOMETRY/MULTIMODAL，无虚假小椭圆。
func _accept_test2() -> bool:
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 90.0, "speed_kn": 8.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{
			"position_east_m": 6000.0,
			"position_north_m": 8000.0,
			"course_deg": 250.0,
			"speed_kn": 12.0
		}
	)
	var meas: Array = _collect(own, target, 1200.0, 60.0, 0.0, null)
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		print("TMA_ACCEPT FAIL t2: solve failed")
		return false
	var status: String = str(r["status"])
	if status != "INSUFFICIENT_GEOMETRY" and status != "MULTIMODAL":
		print("TMA_ACCEPT FAIL t2: status=%s" % status)
		return false
	if int(r["jacobian_rank"]) == 4 and float(r["condition_number"]) < 100.0:
		print(
			(
				"TMA_ACCEPT FAIL t2: single leg looks observable (rank=%d cond=%.0f)"
				% [int(r["jacobian_rank"]), float(r["condition_number"])]
			)
		)
		return false
	if float(r["position_uncertainty_m"]) > 0.0 and float(r["position_uncertainty_m"]) < 500.0:
		print(
			(
				"TMA_ACCEPT FAIL t2: suspicious small pos_unc=%.0fm"
				% float(r["position_uncertainty_m"])
			)
		)
		return false
	print(
		(
			"TMA_ACCEPT t2 ok: status=%s rank=%d hyps=%d"
			% [status, int(r["jacobian_rank"]), int(r["hypothesis_count"])]
		)
	)
	return true


## 验收测试 4：0°/360° 跨越 → 残差正确，无 358° 级错误。
func _accept_test4() -> bool:
	if absf(NavUtils.wrap180(1.0 - 359.0) - 2.0) > 1e-6:
		print("TMA_ACCEPT FAIL t4: wrap180(1-359) != 2")
		return false
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 0.0, "speed_kn": 0.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{"position_east_m": 200.0, "position_north_m": 5000.0, "course_deg": 330.0, "speed_kn": 8.0}
	)
	var meas: Array = _collect(own, target, 600.0, 60.0, 0.0, null)
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		print("TMA_ACCEPT FAIL t4: solve failed")
		return false
	for res in r["residuals"]:
		if absf(float(res["residual_deg"])) > 5.0:
			print(
				(
					"TMA_ACCEPT FAIL t4: wrap residual %.1fdeg at t=%.0f"
					% [float(res["residual_deg"]), float(res["time"])]
				)
			)
			return false
	print("TMA_ACCEPT t4 ok: no 358deg error across 0/360 crossing")
	return true


## 验收测试 6：本艇圆弧机动 + 历史位置各不相同 → 仍能正确恢复。
func _accept_test6() -> bool:
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 0.0, "speed_kn": 6.0}
	)
	own.turn_rate_deg_s = 1.0
	var target := TruthEntity.new()
	target.from_dict(
		{"position_east_m": 7000.0, "position_north_m": 3000.0, "course_deg": 90.0, "speed_kn": 5.0}
	)
	var meas: Array = _collect(own, target, 900.0, 45.0, 0.0, null)
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		print("TMA_ACCEPT FAIL t6: solve failed")
		return false
	var best: Dictionary = r["best"]
	# 真值距离按参考时刻（t=900s）计算：目标 (9315, 3000)；
	# 本艇圆弧机动 v/ω=147.4m，t=900s 时 ωt=900°≡180° → 本艇 (294.8, 0)
	# 真值距离 ≈ 9505m
	var rng_err: float = absf(float(best["range_m"]) - 9505.0)
	var spd_err: float = absf(float(best["speed_kn"]) - 5.0)
	if rng_err > 600.0 or spd_err > 1.5:
		print(
			(
				"TMA_ACCEPT FAIL t6: rng_err=%.0fm spd_err=%.2fkn status=%s"
				% [rng_err, spd_err, str(r["status"])]
			)
		)
		return false
	print(
		(
			"TMA_ACCEPT t6 ok: rng_err=%.0fm spd_err=%.2fkn status=%s"
			% [rng_err, spd_err, str(r["status"])]
		)
	)
	return true


## 验收测试 8：目标中途转向 → MANEUVER_SUSPECTED。
func _accept_test8() -> bool:
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 90.0, "speed_kn": 8.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{
			"position_east_m": 5000.0,
			"position_north_m": 8000.0,
			"course_deg": 180.0,
			"speed_kn": 10.0
		}
	)
	var meas: Array = _collect(own, target, 1200.0, 60.0, 0.3, null, -1.0, 0.0, 600.0, 300.0)
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		print("TMA_ACCEPT FAIL t8: solve failed")
		return false
	if not bool(r["maneuver_suspected"]):
		print(
			(
				"TMA_ACCEPT FAIL t8: maneuver not suspected (status=%s rmse=%.2f)"
				% [str(r["status"]), float(r["angular_rmse"])]
			)
		)
		return false
	print("TMA_ACCEPT t8 ok: maneuver suspected (status=%s)" % str(r["status"]))
	return true


## 验收测试 11：外推过期 → staleness 增长，超阈值状态 STALE。
func _accept_test11() -> bool:
	var own := TruthEntity.new()
	own.from_dict(
		{"position_east_m": 0.0, "position_north_m": 0.0, "course_deg": 45.0, "speed_kn": 8.0}
	)
	var target := TruthEntity.new()
	target.from_dict(
		{
			"position_east_m": 8000.0,
			"position_north_m": 6000.0,
			"course_deg": 200.0,
			"speed_kn": 10.0
		}
	)
	var meas: Array = _collect(own, target, 600.0, 60.0, 0.0, null, 300.0, 135.0)
	var r: Dictionary = TmaSolver.solve_auto(meas, {"now_time": 1500.0})
	if not bool(r.get("success", false)):
		print("TMA_ACCEPT FAIL t11: solve failed")
		return false
	if str(r["status"]) != "STALE":
		print("TMA_ACCEPT FAIL t11: status=%s (want STALE)" % str(r["status"]))
		return false
	if float(r["stale_seconds"]) < 890.0:
		print("TMA_ACCEPT FAIL t11: stale=%.0fs" % float(r["stale_seconds"]))
		return false
	var r2: Dictionary = TmaSolver.solve_auto(meas)
	if str(r2["status"]) == "STALE":
		print("TMA_ACCEPT FAIL t11: fresh fit wrongly STALE")
		return false
	print(
		(
			"TMA_ACCEPT t11 ok: stale=%.0fs -> STALE; fresh -> %s"
			% [float(r["stale_seconds"]), str(r2["status"])]
		)
	)
	return true


## 验收测试 12：Truth 隔离（结构性验证：solve_auto 输入接口仅测量字典）。
func _accept_test12() -> bool:
	var src: String = FileAccess.get_file_as_string("res://scripts/tma_solver.gd")
	for bad in ["TruthEntity", "truth_entity", "World.new", "world.world"]:
		if src.contains(bad):
			print("TMA_ACCEPT FAIL t12: solver references Truth (%s)" % bad)
			return false
	print("TMA_ACCEPT t12 ok: solver input interface free of Truth")
	return true


## 汇总入口。
func _stage_tma_auto() -> bool:
	var tests: Array = [
		["t1_two_legs", _accept_test1],
		["t2_single_leg", _accept_test2],
		["t4_wrap", _accept_test4],
		["t6_history_own", _accept_test6],
		["t8_maneuver", _accept_test8],
		["t11_stale", _accept_test11],
		["t12_truth_isolation", _accept_test12],
	]
	for t in tests:
		if not t[1].call():
			print("PLAY_TEST result=FAIL (tma_accept_%s)" % str(t[0]))
			return false
	print("sonar tma accept: 7/7 passed")
	return true
