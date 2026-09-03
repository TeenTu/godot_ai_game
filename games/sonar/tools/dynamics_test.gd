extends SceneTree
## dynamics_test.gd — S1-02 本艇动力学 + S1-04 统一声学模型 无头验收。
##
## 覆盖：
##   D1  G-05/S1-02 转向速率限制：命令艏向不瞬移，实际按最大转向率逼近，
##       完成后命令清除。
##   D2  S1-02 加/减速度限制：命令航速渐变逼近。
##   D3  旧路径兼容：无命令时直接写 actual（AI 目标/旧测试）不受命令干扰。
##   D4  A1 声学等价：SensorArray 与 AcousticService 公式逐位一致（G-03 单一实现）。
##   D5  S1-04 环境噪声表：JSON 字符串键正确匹配 + 频率间线性插值（不得恒回退 60dB）。
##   D6  S1-04/G-03：OperatorSonar 用 EnvironmentModel TL（含吸收项）计算 BB SE，
##       峰 se_db 与解析公式一致。
##   D7  S1-04 概率探测：弱目标不再被 SE<=0 硬门限切掉，间歇出现（非全有/全无）。
##   D8  S1-04.4/G-04：谱图背景为时间相关随机噪声，非固定纯色。
##
## 运行：godot --headless --path games/sonar --script res://tools/dynamics_test.gd


func _initialize() -> void:
	var fails: Array = []

	_d1_rate_limited_turn(fails)
	_d2_accel_limited_speed(fails)
	_d3_legacy_direct_write(fails)
	_d4_acoustic_equivalence(fails)
	_d5_ambient_noise_keys(fails)
	_d6_operator_uses_env_tl(fails)
	_d7_probabilistic_detection(fails)
	_d8_noise_texture(fails)

	if fails.is_empty():
		print("DYNAMICS_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("DYNAMICS_TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ------------------------------------------------------------------
#  D1：转向速率限制
# ------------------------------------------------------------------


func _d1_rate_limited_turn(fails: Array) -> void:
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 4.0
	own.turn_rate_deg_s = 2.0  # 最大 2°/s
	own.command_course(90.0)
	# 1s 后实际艏向最多转 2°：绝不瞬移
	own.advance(1.0)
	_assert_close(fails, "D1 turn <= 2 deg/s", own.course_deg, 2.0, 0.01)
	_assert_bool(fails, "D1 command active", own.has_course_command(), true)
	# 45s 后应恰好到达 90° 并清除命令
	for _i in range(45):
		own.advance(1.0)
	_assert_close(fails, "D1 converges to 90", own.course_deg, 90.0, 0.1)
	_assert_bool(fails, "D1 command cleared", own.has_course_command(), false)
	# 命令完成后保持直航（不再继续转）
	for _i in range(10):
		own.advance(1.0)
	_assert_close(fails, "D1 holds ordered course", own.course_deg, 90.0, 0.1)
	# 反向命令跨 0/360 稳定
	own.command_course(270.0)
	for _i in range(200):
		own.advance(1.0)
	_assert_close(fails, "D1 wrap-safe to 270", own.course_deg, 270.0, 0.1)


# ------------------------------------------------------------------
#  D2：加/减速度限制
# ------------------------------------------------------------------


func _d2_accel_limited_speed(fails: Array) -> void:
	var own := TruthEntity.new()
	own.speed_kn = 0.0
	own.acceleration_kn_s = 0.5
	own.command_speed(10.0)
	own.advance(1.0)
	_assert_close(fails, "D2 accel <= 0.5 kn/s", own.speed_kn, 0.5, 0.01)
	for _i in range(25):
		own.advance(1.0)
	_assert_close(fails, "D2 converges to 10kn", own.speed_kn, 10.0, 0.05)
	# 减速同样受限
	own.command_speed(2.0)
	for _i in range(5):
		own.advance(1.0)
	_assert_close(fails, "D2 decel limited", own.speed_kn, 7.5, 0.05)


# ------------------------------------------------------------------
#  D3：无命令时直接写 actual 不被干扰（AI 目标/旧测试兼容）
# ------------------------------------------------------------------


func _d3_legacy_direct_write(fails: Array) -> void:
	var t := TruthEntity.new()
	t.course_deg = 45.0
	t.speed_kn = 8.0
	for _i in range(30):
		t.advance(1.0)
	_assert_close(fails, "D3 direct course stays", t.course_deg, 45.0, 0.01)
	# 常率转向（AI 巡航路径）仍然有效
	t.turn_rate_deg_s = 1.0
	for _i in range(10):
		t.advance(1.0)
	_assert_close(fails, "D3 legacy constant-rate turn", t.course_deg, 55.0, 0.1)


# ------------------------------------------------------------------
#  D4：SensorArray ↔ AcousticService 公式等价（G-03 单一声学模型）
# ------------------------------------------------------------------


func _d4_acoustic_equivalence(fails: Array) -> void:
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
	var s := SensorArray.new()
	s.array_gain_db = 5.0
	s.detection_threshold_db = 1.0
	s.detection_k_d = 3.0
	# 被动/主动 SE 逐位一致
	var se_p_s: float = s.passive_signal_excess(150.0, 3000.0, 500.0, env, 6.0)
	var se_p_a: float = AcousticService.passive_se(150.0, 3000.0, 500.0, env, 6.0, 5.0, 1.0)
	_assert_close(fails, "D4 passive SE identical", se_p_s, se_p_a, 1e-9)
	var se_a_s: float = s.active_signal_excess(210.0, 10.0, 3000.0, 500.0, env, 6.0)
	var se_a_a: float = AcousticService.active_se(210.0, 10.0, 3000.0, 500.0, env, 6.0, 5.0, 1.0)
	_assert_close(fails, "D4 active SE identical", se_a_s, se_a_a, 1e-9)
	# P_d / sigma 一致
	_assert_close(
		fails,
		"D4 P_d identical",
		s.detection_probability(3.7),
		AcousticService.detection_probability(3.7, 3.0),
		1e-12
	)
	_assert_close(
		fails,
		"D4 sigma identical",
		s.bearing_sigma_deg(4.2),
		AcousticService.bearing_sigma_deg(4.2, 0.5, 5.0, 6.0, 4.0),
		1e-12
	)
	# P_d 连续（无 SE>0 硬门限）：SE 略负也有非零概率
	_assert_bool(fails, "D4 P_d(-1) > 0", AcousticService.detection_probability(-1.0) > 0.3, true)


# ------------------------------------------------------------------
#  D5：环境噪声表 JSON 字符串键 + 插值（S1-04）
# ------------------------------------------------------------------


func _d5_ambient_noise_keys(fails: Array) -> void:
	var env := EnvironmentModel.new()
	env.from_dict({"ambient_noise_by_frequency": {"500": 55.0, "1000": 65.0}})
	_assert_close(fails, "D5 string key 500Hz", env.ambient_noise_db(500.0), 55.0, 1e-9)
	_assert_close(fails, "D5 interp 750Hz", env.ambient_noise_db(750.0), 60.0, 1e-9)
	_assert_close(fails, "D5 string key 1000Hz", env.ambient_noise_db(1000.0), 65.0, 1e-9)
	_assert_close(fails, "D5 clamp below table", env.ambient_noise_db(200.0), 55.0, 1e-9)
	_assert_close(fails, "D5 clamp above table", env.ambient_noise_db(2000.0), 65.0, 1e-9)


# ------------------------------------------------------------------
#  D6：OperatorSonar 用环境 TL 计算宽带 SE（解析对照）
# ------------------------------------------------------------------


func _d6_operator_uses_env_tl(fails: Array) -> void:
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
	own.speed_kn = 0.0  # 降自噪便于解析对照
	var tgt := TruthEntity.new()
	tgt.id = "TD"
	tgt.position_east_m = 0.0
	tgt.position_north_m = 2000.0  # 艏向 0 的正前方：array_rel=0 → 方向增益 0
	tgt.speed_kn = 10.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 180.0})
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 555
	op.setup({"env": env, "own": own, "rng": rng})
	op.set_array("BOW")
	op.update(0.0, [tgt], {"TD": ac})
	var peaks: Array = op.bb_rows[-1]["peaks"]
	_assert_bool(fails, "D6 peak produced", not peaks.is_empty(), true)
	if peaks.is_empty():
		return
	# 解析期望：SL(10kn) - TL(2000m,500Hz) - N_eff(500Hz,0kn) + 0(AG) + 0(dir)
	var sl: float = ac.broadband_sl_db(10.0, 0.0)
	var tl: float = env.propagation_loss(2000.0, 500.0)
	var n_eff: float = env.effective_noise_db(500.0, 0.0)
	var expect: float = sl - tl - n_eff
	_assert_close(fails, "D6 SE matches unified formula", float(peaks[0]["se_db"]), expect, 0.1)
	# TL 必须含吸收项（旧的 20log10*1.2 简式给不出这个值）
	_assert_bool(fails, "D6 TL includes absorption", absf(tl - (68.5206)) < 0.01, true)


# ------------------------------------------------------------------
#  D7：弱目标概率探测（无 SE<=0 硬门限，间歇出现）
# ------------------------------------------------------------------


func _d7_probabilistic_detection(fails: Array) -> void:
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
	own.speed_kn = 0.0
	# 远距离弱源：SE ≈ -0.5 dB → P_d ≈ 0.46 → 间歇出现
	var tgt := TruthEntity.new()
	tgt.id = "TW"
	tgt.position_east_m = 0.0
	tgt.position_north_m = 20000.0
	tgt.speed_kn = 10.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 142.0})
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	op.setup({"env": env, "own": own, "rng": rng})
	op.set_array("BOW")
	var rows_with_peak: int = 0
	var rows_total: int = 50
	for i in range(rows_total):
		op.update(float(i) * 2.0, [tgt], {"TW": ac})
		if not op.bb_rows[-1]["peaks"].is_empty():
			rows_with_peak += 1
	# 间歇：既不是全无（硬门限旧象限）也不是全有
	_assert_bool(fails, "D7 intermittent: some rows have peaks", rows_with_peak > 3, true)
	_assert_bool(fails, "D7 intermittent: not all rows", rows_with_peak < rows_total - 3, true)


# ------------------------------------------------------------------
#  D8：谱图背景时间相关噪声（非固定纯色）
# ------------------------------------------------------------------


func _d8_noise_texture(fails: Array) -> void:
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 0.0
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 999
	op.setup({"env": EnvironmentModel.new(), "own": own, "rng": rng})
	op.set_array("BOW")
	op.update(0.0, [], {})
	var v1: PackedFloat32Array = op.bb_rows[-1]["values"]
	var min_v: float = INF
	var max_v: float = -INF
	for v in v1:
		min_v = minf(min_v, v)
		max_v = maxf(max_v, v)
	_assert_bool(fails, "D8 background not flat", max_v - min_v > 0.5, true)
	op.update(2.0, [], {})
	var v2: PackedFloat32Array = op.bb_rows[-1]["values"]
	var sum_diff: float = 0.0
	for i in range(v1.size()):
		sum_diff += absf(v2[i] - v1[i])
	# rho=0.75：相邻行变化幅度有限（时间相关，非每帧独立重抽）
	_assert_bool(fails, "D8 temporally correlated", sum_diff / v1.size() < 2.0, true)


# ------------------------------------------------------------------
#  断言工具
# ------------------------------------------------------------------


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
