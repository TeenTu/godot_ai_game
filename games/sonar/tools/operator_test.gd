extends SceneTree
## operator_test.gd — Sonar Operator Layer 无头验收。
##
## 验收目标（需求 10）：玩家在不知道 Truth 的情况下，从噪声瀑布中发现目标，
## 经宽带标记、窄带识别、DEMON 测速和本艇机动完成 TMA，
## 最后提交可信的 System Solution。
##
## 测试中的「玩家」只读 OperatorSonar 输出（瀑布行/分类/DEMON 估计），
## 绝不读 Truth 位置决策；Truth 仅在断言阶段用于统计误差。

const OP_INTERVAL: float = 2.0
const MARK_INTERVAL: float = 15.0
const TURN_DELAY_S: float = 120.0
const SIM_END: float = 900.0
const DT: float = 0.5


func _initialize() -> void:
	var fails: Array = []
	var world := World.new()
	var scenario: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	world.load_scenario(scenario)
	world.auto_measurements = false  # Operator 模式：测量只来自 Mark/Tracker/Autocrew
	var wd: Dictionary = world.world
	# 测试场景设置（作者侧 Truth 配置，玩家不可见）：拉近目标使发现节奏合理
	wd["targets"][0].position_east_m = 3500.0
	wd["targets"][0].position_north_m = 4200.0

	var op := OperatorSonar.new()
	op.setup(wd)

	var tracker := Tracker.new()
	var rng: RandomNumberGenerator = wd.get("rng", null)
	if rng != null:
		tracker.set_rng(rng)
	tracker.set_capacity(8)
	tracker.set_auto_interval(5.0)

	# o1: 默认无自动测量、无 Track
	world.run_steps(40)
	if not world.measurements.is_empty() or not tracker.all_tracks().is_empty():
		fails.append("o1 auto-measure/track must be OFF in operator mode")

	# 模拟玩家操作循环
	var track: Track = null
	var next_mark_t: float = -1.0
	var discovered: bool = false
	var discovered_at: float = -1.0
	var marks: int = 0
	var turn_done: bool = false
	var t: float = 0.0
	while t < SIM_END:
		world.tick()
		t = world.sim_time
		if discovered and not turn_done and t >= discovered_at + TURN_DELAY_S:
			wd["own"].course_deg = fposmod(float(wd["own"].course_deg) + 70.0, 360.0)
			turn_done = true
		op.update(t, wd["targets"], wd["target_acs"])

		# 1) 发现：BB 峰高出噪底 ≥ 8 dB 才算玩家看到
		if not discovered:
			for pk in op.latest_peaks():
				if float(pk["level_db"]) >= 8.0:
					discovered = true
					discovered_at = t
					break
		# 2) 宽带标记（带跟踪，全部沿峰方位）
		if discovered and t >= next_mark_t:
			var peaks: Array = op.latest_peaks()
			if not peaks.is_empty():
				var m: Measurement = op.create_mark(float(peaks[0]["bearing_deg"]), t)
				world.measurements.append(m)
				marks += 1
				if track == null:
					track = tracker.mark(m, "M")
				else:
					var fed: Track = tracker.feed(m, 15.0)
					if fed == null:
						track = tracker.mark(m, "M")
					else:
						track = fed
			next_mark_t = t + MARK_INTERVAL

	# 3) 窄带识别 + DEMON 测速（只读操作员估计）
	var has_class: bool = (
		not op.classification.is_empty() and op.classification.get("best", "") != ""
	)
	var de: Dictionary = op.demon_estimate
	var has_demon: bool = not de.is_empty() and float(de.get("speed_sigma_kn", 99.0)) < 6.0

	# 4) TMA：两腿测量 + DEMON 软约束
	#    测量集合 = 全部玩家 Mark（OP_ 传感器），即 TMA 的合法输入
	var op_marks: Array = []
	for m in world.measurements:
		if str(m.sensor_id).begins_with("OP_"):
			op_marks.append(m)
	var ok_track: bool = op_marks.size() >= 10
	var fit: Dictionary = {}
	var converged: bool = false
	if ok_track:
		var meas: Array = []
		for m in op_marks:
			var d: Dictionary = {
				"time": m.timestamp,
				"observer_e": m.observer_east_m,
				"observer_n": m.observer_north_m,
				"bearing_deg": m.measured_bearing_deg,
				"sigma_deg": m.bearing_sigma_deg,
				"bearing": m.measured_bearing_deg,
				"sigma": m.bearing_sigma_deg,
			}
			meas.append(d)
		var opts: Dictionary = {"now_time": t}
		if has_demon:
			opts["demon_speed_kn"] = float(de["speed_kn"])
			opts["demon_sigma_kn"] = float(de["speed_sigma_kn"])
		fit = TmaSolver.solve_auto(meas, opts)
		converged = str(fit.get("status", "")) in ["CONVERGED", "PROVISIONAL"]

	# 5) 提交 System Solution（仅当 fit 可信）
	var submitted: bool = false
	if converged and fit.has("best"):
		var sys := SystemSolution.new()
		var best: Dictionary = fit["best"]
		sys.bearing_deg = float(best.get("bearing_deg", 0.0))
		sys.range_m = float(best.get("range_m", 0.0))
		sys.course_deg = float(best.get("course_deg", 0.0))
		sys.speed_kn = float(best.get("speed_kn", 0.0))
		submitted = sys.range_m > 0.0

	# ---- 断言（Truth 仅在此处出现，用于统计误差）----
	if not discovered:
		fails.append("o2 player never discovered target in broadband noise")
	elif discovered_at < 0.0:
		fails.append("o3 discovery time not recorded")
	if marks < 10:
		fails.append("o4 too few marks: %d" % marks)
	if not ok_track:
		fails.append("o5 track has too few measurements")
	if not has_class:
		fails.append("o6 no classification result")
	if not has_demon:
		fails.append("o7 no usable DEMON speed estimate")
	if not converged:
		var n_meas: int = track.measurement_history.size() if track != null else 0
		var diag: String = (
			"o8 TMA not converged: %s legs=%s rank=%s n_meas=%d"
			% [
				str(fit.get("status", "?")),
				str(fit.get("legs", "?")),
				str(fit.get("rank", "?")),
				n_meas
			]
		)
		fails.append(diag)
	if not submitted:
		fails.append("o9 system solution not submitted")
	if converged:
		var best: Dictionary = fit["best"]
		var tg: RefCounted = wd["targets"][0]
		var dp: Vector2 = (
			(best["p_ref"] as Vector2)
			- Vector2(float(tg.position_east_m), float(tg.position_north_m))
		)
		if dp.length() > 3500.0:
			fails.append(
				(
					"o10 range error too large: %.0f m (true %.0f)"
					% [
						dp.length(),
						Vector2(float(tg.position_east_m), float(tg.position_north_m)).length()
					]
				)
			)
	# o11 信息隔离：OperatorSonar 输出不含位置字段
	for out_key in ["bb_rows", "nb_rows", "demon_rows", "demon_estimate", "classification"]:
		var blob: String = str(op.get(out_key))
		if blob.contains("east_m") or blob.contains("north_m"):
			fails.append("o11 truth position leaked in " + out_key)

	for f in fails:
		print("OPERATOR_FAIL ", f)
	if fails.is_empty():
		print(
			(
				"OPERATOR_TEST result=PASS discovered_at=%.0fs marks=%d legs>=%s status=%s"
				% [discovered_at, marks, "2", str(fit.get("status", ""))]
			)
		)
	else:
		print("OPERATOR_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
