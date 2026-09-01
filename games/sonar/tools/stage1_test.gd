extends SceneTree
## stage1_test.gd — 阶段一纯逻辑无头单元测试。
##
## 运行：godot --headless --path games/sonar --script res://tools/stage1_test.gd
## 不依赖场景/UI。固定种子断言，可复现。
## 通过则输出 "STAGE1 TEST PASS"，非零退出码则失败。

var _failures: int = 0


func _init() -> void:
	print("=== STAGE1 TEST ===")
	_test_nav_utils()
	_test_motion()
	_test_acoustic_and_propagation()
	_test_detection_behavior()
	_test_reproducibility()
	_test_full_scenario_run()

	if _failures == 0:
		print("STAGE1 TEST PASS")
		quit(0)
	else:
		print("STAGE1 TEST FAILED: %d failures" % _failures)
		quit(1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  [ok] " + msg)
	else:
		_failures += 1
		print("  [FAIL] " + msg)


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _test_nav_utils() -> void:
	print("[nav_utils]")
	# wrap360
	_check(_approx(NavUtils.wrap360(361.0), 1.0, 0.001), "wrap360(361)=1")
	_check(_approx(NavUtils.wrap360(-10.0), 350.0, 0.001), "wrap360(-10)=350")
	_check(_approx(NavUtils.wrap360(720.0), 0.0, 0.001), "wrap360(720)=0")
	# wrap180
	_check(_approx(NavUtils.wrap180(190.0), -170.0, 0.001), "wrap180(190)=-170")
	_check(_approx(NavUtils.wrap180(-10.0), -10.0, 0.001), "wrap180(-10)=-10")
	_check(_approx(NavUtils.wrap180(170.0), 170.0, 0.001), "wrap180(170)=170")
	# angle_diff
	_check(_approx(NavUtils.angle_diff(10.0, 350.0), 20.0, 0.001), "angle_diff(10,350)=20")
	_check(_approx(NavUtils.angle_diff(350.0, 10.0), -20.0, 0.001), "angle_diff(350,10)=-20")
	# kn<->ms
	_check(_approx(NavUtils.kn_to_ms(1.0), 0.514444, 0.001), "1kn=0.514444m/s")
	_check(_approx(NavUtils.ms_to_kn(0.514444), 1.0, 0.001), "0.514444m/s=1kn")
	# bearing_to_true：目标在正北(0,+1000) → 方位 0
	var b_north: float = NavUtils.bearing_to_true(0, 0, 0, 1000)
	_check(_approx(b_north, 0.0, 0.5), "target due north -> bearing 0, got %.2f" % b_north)
	# 目标在正东(+1000, 0) → 方位 90（从北顺时针）
	var b_east: float = NavUtils.bearing_to_true(0, 0, 1000, 0)
	_check(_approx(b_east, 90.0, 0.5), "target due east -> bearing 90, got %.2f" % b_east)
	# 目标在正南(0,-1000) → 方位 180
	var b_south: float = NavUtils.bearing_to_true(0, 0, 0, -1000)
	_check(_approx(b_south, 180.0, 0.5), "target due south -> bearing 180, got %.2f" % b_south)


func _test_motion() -> void:
	print("[motion]")
	var t := TruthEntity.new()
	(
		t
		. from_dict(
			{
				"position_east_m": 0.0,
				"position_north_m": 0.0,
				"course_deg": 90.0,
				"speed_kn": 10.0,
			}
		)
	)
	# 航向 90° = 正东。10kn = 5.14444 m/s。跑 1 秒 → x 增加 5.144，y 不变
	t.advance(1.0)
	_check(
		_approx(t.position_east_m, 5.14444, 0.01),
		"course 90 -> x+=5.144, got %.3f" % t.position_east_m
	)
	_check(_approx(t.position_north_m, 0.0, 0.01), "course 90 -> y=0")
	# 航向 0° = 正北
	var t2 := TruthEntity.new()
	t2.from_dict({"position_north_m": 0.0, "course_deg": 0.0, "speed_kn": 10.0})
	t2.advance(1.0)
	_check(_approx(t2.position_north_m, 5.14444, 0.01), "course 0 -> north += 5.144")


func _test_acoustic_and_propagation() -> void:
	print("[acoustic & propagation]")
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
	# TL at 1000m: 20*log10(1000) + 0.5*(500/1000)*1km + 2 = 60 + 0.25 + 2 = 62.25
	var tl: float = env.propagation_loss(1000.0, 500.0)
	_check(_approx(tl, 62.25, 0.1), "TL(1000m,500Hz)=62.25, got %.2f" % tl)
	# N_eff：60dB 和 (40+2*5=50dB) 合成
	var neff: float = env.effective_noise_db(500.0, 5.0)
	var expect_neff: float = 10.0 * log(pow(10, 6.0) + pow(10, 5.0)) / log(10.0)
	_check(_approx(neff, expect_neff, 0.1), "N_eff multi-source ~60.4, got %.2f" % neff)
	# 声源级
	var ac := AcousticProfile.new()
	ac.from_dict(
		{
			"broadband_base_level_db": 150.0,
			"speed_noise_a": 18.0,
			"speed_noise_n": 2.5,
			"speed_noise_vref_kn": 8.0
		}
	)
	var sl: float = ac.broadband_sl_db(12.0, 0.0)
	# ratio=1.5, 1+(1.5)^2.5 ≈ 1+2.756=3.756, log10=0.5747, *18=10.34, +150=160.34
	_check(sl > 150.0 and sl < 180.0, "SL broadband in range, got %.2f" % sl)
	# 空化：深度越深，临界速度越高 → 同航速在浅水空化、深水不空化
	_check(ac.is_cavitating(20.0, 0.0), "cavitate at surface when Vcav_surf=20? (edge)")
	var ac2 := AcousticProfile.new()
	ac2.from_dict({"cavitation_speed_kn_at_surface": 12.0, "cavitation_depth_slope": 1.2})
	_check(ac2.is_cavitating(15.0, 0.0), "15kn at surface cavitates (Vcav=12)")
	_check(not ac2.is_cavitating(15.0, 10.0), "15kn at depth10 no cavitate (Vcav=24)")


func _test_detection_behavior() -> void:
	print("[detection & bearing sigma]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var sensor := SensorArray.new()
	sensor.set_rng(rng)
	(
		sensor
		. from_dict(
			{
				"bearing_sigma_min_deg": 0.5,
				"bearing_sigma_max_deg": 5.0,
				"bearing_se0_db": 6.0,
				"bearing_k_sigma_db": 4.0,
				"detection_k_d": 3.0,
			}
		)
	)
	# P_d 单调：SE 越高概率越高
	var p_low: float = sensor.detection_probability(-10.0)
	var p_mid: float = sensor.detection_probability(0.0)
	var p_high: float = sensor.detection_probability(10.0)
	_check(p_low < p_mid and p_mid < p_high, "P_d monotonic increasing with SE")
	_check(p_low > 0.0 and p_low < 0.1, "low SE -> small but nonzero P_d, got %.3f" % p_low)
	_check(p_high > 0.9, "high SE -> near 1, got %.3f" % p_high)
	# sigma 随 SE 下降
	var s_low: float = sensor.bearing_sigma_deg(-10.0)
	var s_high: float = sensor.bearing_sigma_deg(40.0)
	_check(s_low > s_high, "bearing sigma decreases with SE")
	_check(_approx(s_high, sensor.bearing_sigma_min_deg, 0.1), "high SE -> near sigma_min")
	_check(_approx(s_low, sensor.bearing_sigma_max_deg, 0.1), "low SE -> near sigma_max")
	# 噪声方位：多次采样围绕真实方位，且强 SE 误差小
	var true_b: float = 45.0
	var se_strong: float = 15.0
	var se_weak: float = -5.0
	var strong_err_sum: float = 0.0
	var weak_err_sum: float = 0.0
	for i in range(200):
		strong_err_sum += absf(
			NavUtils.angle_diff(sensor.noisy_bearing(true_b, se_strong)["bearing"], true_b)
		)
		weak_err_sum += absf(
			NavUtils.angle_diff(sensor.noisy_bearing(true_b, se_weak)["bearing"], true_b)
		)
	strong_err_sum /= 200.0
	weak_err_sum /= 200.0
	_check(
		strong_err_sum < weak_err_sum,
		"avg bearing error smaller for strong SE (%.2f < %.2f)" % [strong_err_sum, weak_err_sum]
	)


func _test_reproducibility() -> void:
	print("[reproducibility]")
	var scenario: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	_check(not scenario.is_empty(), "scenario loaded")

	var w1 := World.new()
	w1.load_scenario(scenario)
	w1.run_steps(10)

	var w2 := World.new()
	# 重新加载同一场景（种子相同）
	var scenario2: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	w2.load_scenario(scenario2)
	w2.run_steps(10)

	_check(
		w1.measurement_count() == w2.measurement_count(),
		"same measurement count: %d" % w1.measurement_count()
	)
	if w1.measurement_count() > 0 and w1.measurement_count() == w2.measurement_count():
		var same: bool = true
		for i in range(w1.measurement_count()):
			var a: Measurement = w1.measurements[i]
			var b: Measurement = w2.measurements[i]
			if not _approx(a.measured_bearing_deg, b.measured_bearing_deg, 0.0001):
				same = false
				break
		_check(same, "identical measurement stream for same seed")


func _test_full_scenario_run() -> void:
	print("[full scenario run]")
	var scenario: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	var w := World.new()
	w.load_scenario(scenario)
	w.run_steps(int(scenario.get("duration", 30.0) / scenario.get("dt", 0.5)))
	print(
		(
			"  produced %d measurements over %.0fs"
			% [w.measurement_count(), scenario.get("duration", 30.0)]
		)
	)
	_check(w.measurement_count() > 0, "measurements produced")
	# 验证测量方位落在合理范围（目标在东北方，本艇原地 → 方位 45° 附近）
	var detected_bearings: Array = []
	for m in w.measurements:
		if m.detection_probability > 0.3:
			detected_bearings.append(m.measured_bearing_deg)
	if detected_bearings.size() > 0:
		var avg: float = 0.0
		for b in detected_bearings:
			avg += b
		avg /= float(detected_bearings.size())
		_check(
			absf(NavUtils.angle_diff(avg, 45.0)) < 8.0,
			"avg bearing ~45deg (target NE), got %.2f (n=%d)" % [avg, detected_bearings.size()]
		)
	else:
		_check(false, "no detections in scenario")
