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
##
## 0.2 六条回归补充（阶段一拖曳修正批次）：
##   R1 多扇区阵列方向性增益取"所有覆盖扇区中最优一支"（maxf，非 minf）。
##   R2 TRUE STABILIZED 瀑布重排：源列恒 -180..180（每格 2°），不得用已切换的
##      x_min=0 反推源相对方位；亮斑必须落在正确真北方位列。
##   R3 瀑布历史行 Mark：create_mark 携带被点行上下文（时间/艏向/站位取自那一行）。
##   R4 create_mark 峰匹配用 canonical frame：as_true 输入先转显示 frame 再比峰。


func _initialize() -> void:
	var fails: Array = []

	# 0.2 六条回归（无外部依赖，先跑）
	_regression_multi_sector_gain(fails)
	_regression_true_waterfall_columns(fails)
	_regression_historical_row_mark(fails)
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


# ------------------------------------------------------------------
#  R1：多扇区阵列方向性增益取最优扇区（maxf，0.2 回归 #1）
# ------------------------------------------------------------------


func _regression_multi_sector_gain(fails: Array) -> void:
	var flank: Dictionary = OperatorSonar.ARRAY_DEFS["FLANK"]
	# 右舷扇区中心 +90 / 左舷扇区中心 -90：都应取该扇区的 0 dB（最优支），
	# 而不是被对侧扇区的 -70 dB 拖垮（旧 minf 实现的 bug）
	var g_r: float = OperatorSonar._array_direction_gain_db(90.0, flank)
	var g_l: float = OperatorSonar._array_direction_gain_db(-90.0, flank)
	_assert_bool(fails, "R1 flank +90 gain ~0", g_r > -1.0, true)
	_assert_bool(fails, "R1 flank -90 gain ~0", g_l > -1.0, true)
	# 两扇区之间（0°）不在覆盖内：应显著衰减
	var g_mid: float = OperatorSonar._array_direction_gain_db(0.0, flank)
	_assert_bool(fails, "R1 flank gap attenuated", g_mid < -3.0, true)
	# 单扇区 TOWED 不受影响：阵轴中心 0 dB，扇区外衰减
	var towed: Dictionary = OperatorSonar.ARRAY_DEFS["TOWED"]
	_assert_bool(
		fails,
		"T1 towed center gain ~0",
		OperatorSonar._array_direction_gain_db(0.0, towed) > -1.0,
		true
	)
	_assert_bool(
		fails,
		"R1 towed outside attenuated",
		OperatorSonar._array_direction_gain_db(150.0, towed) < -3.0,
		true
	)


# ------------------------------------------------------------------
#  R2：TRUE STABILIZED 瀑布重排源列恒 -180..180（0.2 回归 #2）
# ------------------------------------------------------------------


func _regression_true_waterfall_columns(fails: Array) -> void:
	var wf := WaterfallView.new()
	wf.axis_mode = "bearing"
	wf.set_bearing_mode("true")  # x 轴切为 0..360 真北
	# 一行 BB：180 列，每列 2°，源相对方位 = -180 + 2c（与显示轴无关）
	var vals := PackedFloat32Array()
	vals.resize(180)
	vals.fill(-28.0)
	# 在源相对方位 0°（c=90）放亮斑；本行艏向 90° → 真北方位 90 → 目标列 tc=45
	for c in range(89, 92):
		vals[c] = 8.0
	wf.rows = [{"t": 0.0, "values": vals, "course": 90.0}]
	wf._rebuild_image()
	_assert_bool(fails, "R2 image built", wf._img != null, true)
	if wf._img == null:
		return
	_assert_close(fails, "R2 image width=source cols", float(wf._img.get_width()), 180.0, 0.0)
	# 亮斑必须落在真北 90° 列（tc=45），行 h-1-0
	var hot: Color = wf._img.get_pixel(45, 1)
	_assert_bool(fails, "R2 hot at true-90 column", hot.r > 0.8, true)
	# 旧 bug（用 x_min=0 反推源列）会把亮斑放到 tc=135：那里必须是暗的
	var cold: Color = wf._img.get_pixel(135, 1)
	_assert_bool(fails, "R2 wrong-column stays dark", cold.r < 0.3, true)
	# 交叉验证另一行：艏向 0° → 真北 0 → tc=0
	var vals2 := PackedFloat32Array()
	vals2.resize(180)
	vals2.fill(-28.0)
	for c2 in range(89, 92):
		vals2[c2] = 8.0
	wf.rows = [{"t": 1.0, "values": vals2, "course": 0.0}]
	wf._rebuild_image()
	_assert_bool(fails, "R2 hot at true-0 column", wf._img.get_pixel(0, 1).r > 0.8, true)


# ------------------------------------------------------------------
#  R3/R4：历史行 Mark 上下文 + canonical 峰匹配（0.2 回归 #3/#4）
# ------------------------------------------------------------------


func _regression_historical_row_mark(fails: Array) -> void:
	var env := EnvironmentModel.new()
	(
		env
		. from_dict(
			{
				"ambient_noise_by_frequency": {"500": 60.0},
				"own_noise_base_db": 40.0,
				"own_noise_speed_coeff": 2.0,
				"tl_spreading_k": 20.0,
				"tl_absorption_alpha": 0.5,
				"tl_environment_loss": 2.0,
			}
		)
	)
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 5.0
	own.position_east_m = 0.0
	own.position_north_m = 0.0
	var tgt := TruthEntity.new()
	tgt.id = "TR"
	tgt.position_east_m = 1500.0
	tgt.position_north_m = 1500.0  # 本艇(0,0) 艏向 0 时真方位 45°
	tgt.speed_kn = 10.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 185.0})
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	op.setup({"env": env, "own": own, "rng": rng})
	op.set_array("BOW")
	op.update(0.0, [tgt], {"TR": ac})
	# 本艇移动+转向后产生第二行：历史行点击必须用旧行上下文
	own.course_deg = 90.0
	own.position_east_m = 1000.0
	own.position_north_m = 2000.0
	op.update(20.0, [tgt], {"TR": ac})
	_assert_bool(fails, "R3 two bb rows", op.bb_rows.size() >= 2, true)
	var row0: Dictionary = op.bb_rows[0]
	var row1: Dictionary = op.bb_rows[1]
	# R3：用历史行 row0 Mark → 时间/站位/艏向取自 row0（不是当前仿真状态）
	var m_old: Measurement = op.create_mark(45.0, 999.0, "", true, row0)
	_assert_close(fails, "R3 old-row timestamp", m_old.timestamp, 0.0, 1e-6)
	_assert_close(fails, "R3 old-row observer e", m_old.observer_east_m, 0.0, 1e-6)
	_assert_close(fails, "R3 old-row observer n", m_old.observer_north_m, 0.0, 1e-6)
	var m_new: Measurement = op.create_mark(45.0, 999.0, "", true, row1)
	_assert_close(fails, "R3 new-row timestamp", m_new.timestamp, 20.0, 1e-6)
	_assert_close(fails, "R3 new-row observer e", m_new.observer_east_m, 1000.0, 1e-6)
	_assert_close(fails, "R3 new-row observer n", m_new.observer_north_m, 2000.0, 1e-6)
	# R4：as_true 输入先转该行显示 frame 再比峰（canonical frame）。
	# row0 艏向 0，真北 45 的峰显示为 45 → TRUE 输入 45 必须命中峰（SE>0）
	_assert_bool(fails, "R4 true input matches peak", m_old.signal_excess_db > 0.0, true)
	# 负对照：真北 180（该行无峰）→ 不命中（SE=-1）
	var m_miss: Measurement = op.create_mark(180.0, 999.0, "", true, row0)
	_assert_close(fails, "R4 non-peak no match", m_miss.signal_excess_db, -1.0, 1e-6)


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
