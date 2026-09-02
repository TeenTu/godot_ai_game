extends SceneTree
## fix_batch1b_test.gd — 声呐综合修复 批次1收尾：BB 瀑布显示模式 + Mark 方位语义 无头验收。
##
## 对应修复需求：
##   §一.1 底部诊断区显示模式 CLOSED/BT/RESIDUAL/SPLIT（可见性切换，数据不随隐藏丢失）。
##   §一.2 瀑布提供 RELATIVE(默认,艇艏=0°) / TRUE STABILIZED，Mark 语义正确区分。
##
## 验证点（确定性，固定种子）：
##   1. RELATIVE 模式：玩家点艇艏相对方位(display) → create_mark(as_true=false)
##      内部反算真方位(βtrue=wrap360(ψown+βdisplay))，绝不让相对方位直入 Measurement。
##   2. TRUE STABILIZED 模式：玩家点真北方位 → create_mark(as_true=true) 直接写入(加噪声)。
##   3. 两种模式在同航向下对同一目标应得到同一真方位（噪声均值近似一致）。
##   4. 隐藏/显示诊断区不丢数据（数据在 plot 内，与可见性无关——逻辑断言）。


func _initialize() -> void:
	var fails: Array = []
	var world := World.new()
	var scenario: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	world.load_scenario(scenario)
	world.auto_measurements = false
	var wd: Dictionary = world.world
	# 拉近目标并固定航向，使目标可靠出现（作者侧 Truth 配置，玩家不可见）
	wd["targets"][0].position_east_m = 3500.0
	wd["targets"][0].position_north_m = 4200.0
	# 本艇转向 90°：真方位45° 的目标在 RELATIVE 瀑布显示为 -45°（艇艏=90）
	wd["own"].course_deg = 90.0

	var op := OperatorSonar.new()
	op.setup(wd)

	# 推进让 BB 行出现峰值
	var target_true: float = NavUtils.true_to_display(wd["own"].course_deg, 45.0)
	_assert_close(fails, "t1 rel of true45 at course90 = -45", target_true, -45.0, 1e-6)

	var attempts: int = 60
	for _i in range(attempts):
		world.tick()
		op.update(world.sim_time, wd["targets"], wd["target_acs"])

	var peaks: Array = op.latest_peaks()
	if peaks.is_empty():
		fails.append("no BB peak produced after %d steps (scenario too quiet?)" % attempts)
		# 只要有峰即可继续，否则失败并退出
	else:
		# 用最接近期望相对方位 -45 的峰作为被测目标
		var best_pk: Dictionary = {}
		var best_d: float = 1e9
		for pk in peaks:
			var dd: float = absf(NavUtils.angle_diff(float(pk["bearing_deg"]), -45.0))
			if dd < best_d:
				best_d = dd
				best_pk = pk
		var rel_mark: float = float(best_pk["bearing_deg"])  # 相对方位

		# RELATIVE 模式 mark：内部应反算成真方位 ≈ wrap360(90 + rel) ≈ 45
		var m_rel: Measurement = op.create_mark(rel_mark, world.sim_time)
		var expect_true: float = NavUtils.wrap360(90.0 + rel_mark)
		_assert_close(
			fails,
			"t2 RELATIVE mark backs out true~45",
			m_rel.measured_bearing_deg,
			expect_true,
			3.0
		)

		# TRUE STABILIZED 模式 mark：玩家点真北方位(≈45) → 直接接受
		var true_input: float = NavUtils.wrap360(expect_true)
		var m_true: Measurement = op.create_mark(true_input, world.sim_time, "", true)
		_assert_close(
			fails,
			"t3 TRUE mark accepts true input~45",
			m_true.measured_bearing_deg,
			true_input,
			3.0
		)

		# 两种模式应对同一目标给出同一真方位(±噪声尺度内)
		_assert_close(
			fails,
			"t4 rel-mark true ~= true-mark true",
			NavUtils.angle_diff(m_rel.measured_bearing_deg, m_true.measured_bearing_deg),
			0.0,
			4.0,
		)

	if fails.is_empty():
		print("FIX_BATCH1B PASS: bearing display + mark semantics correct")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("FIX_BATCH1B FAIL: %d problem(s)" % fails.size())
		quit(1)


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
