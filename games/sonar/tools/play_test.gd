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
	ui.queue_free()
	await process_frame
	print("sonar stage3 smoke: sim_time=%.1fs tracks=%d" % [sim_time, track_count])
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
