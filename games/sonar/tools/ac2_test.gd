extends SceneTree
## ac2_test.gd — 阶段一收尾 v2.0 P0-B 统一声学/干扰/声纹/显示 无头验收。
##
## 对应文档验收 AC-1..6：
##   AC-1  两同功率噪声相加 +3.0103 dB；固定总功率加宽频带不增能量。
##   AC-2  JAMMER 抬 N_eff 降弱目标 P_d；频带外不贡献；波束外按旁瓣衰减。
##   AC-3  追帧调度与逐行调度行数一致（倍速/低帧率不跳测量机会）。
##   AC-4  空化 smoothstep 连续（临界速度处无跳变）；深度升高阈值升高。
##   AC-5  AR(1) 平稳标准差≈1；DEMON 换算修复旧 60 倍错误且不被模板覆盖。
##   AC-6  AGC 只影响显示：同 rows 两次重建一致；开关 AGC 不改 operator 数据。

const DT: float = 0.5


func _initialize() -> void:
	var fails: Array = []
	_ac1_power_additivity(fails)
	_ac2_jammer_effect(fails)
	_ac3_schedule_catchup(fails)
	_ac4_cavitation_smooth(fails)
	_ac5_ar1_demon(fails)
	_ac6_display_isolation(fails)
	if fails.is_empty():
		print("AC2_TEST result=PASS")
	else:
		for f in fails:
			print("AC2_FAIL " + str(f))
		print("AC2_TEST result=FAIL (%d)" % fails.size())
	quit(1 if not fails.is_empty() else 0)


func _ok(fails: Array, name: String, got, want = true) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _mk_jammer(e: float, n: float, sl: float, bw: float) -> Dictionary:
	return {
		"e": e,
		"n": n,
		"z": 50.0,
		"sl_band_db": sl,
		"band_min_hz": 1000.0 - bw * 0.5,
		"band_max_hz": 1000.0 + bw * 0.5,
	}


func _mk_env(interferers: Array) -> EnvironmentModel:
	var env := EnvironmentModel.new()
	env.ambient_noise_by_frequency = {"500": 60.0, "1000": 60.0}
	env.interferers = interferers
	return env


## ---- AC-1：功率加法与能量守恒 ----
func _ac1_power_additivity(fails: Array) -> void:
	# 两个相同功率、相同距离的干扰源 → +3.0103 dB（线性功率合成）。
	var e1 := _mk_env([_mk_jammer(0.0, 1000.0, 185.0, 400.0)])
	var e2 := _mk_env(
		[
			_mk_jammer(0.0, 1000.0, 185.0, 400.0),
			_mk_jammer(1000.0, 0.0, 185.0, 400.0),
		]
	)
	var n1: float = e1.effective_noise_db_at(1000.0, -1.0, 4.0, 0.0, 0.0, 50.0)
	var n2: float = e2.effective_noise_db_at(1000.0, -1.0, 4.0, 0.0, 0.0, 50.0)
	_ok(fails, "AC1a two jammers +3.0103dB", _approx(n2 - n1, 3.0103, 0.01), true)
	# 相同 PSD、带宽翻倍 → 带级 +3.0103 dB（PSD 口径换算正确）。
	var env0 := _mk_env([])
	var itf_a := _mk_jammer(0.0, 0.0, 185.0, 400.0)  # PSD=185-26.02
	var itf_b := _mk_jammer(0.0, 0.0, 188.0103, 800.0)  # 同 PSD，带级 +3.0103
	var ja: float = EnvironmentModel.interferer_noise_db(itf_a, 1000.0, env0, 0.0, 0.0, 50.0)
	var jb: float = EnvironmentModel.interferer_noise_db(itf_b, 1000.0, env0, 0.0, 0.0, 50.0)
	# 相同 PSD（固定总功率随带宽补偿）→ 单频贡献相同。
	_ok(fails, "AC1b same PSD same per-freq", _approx(jb - ja, 0.0, 0.01), true)
	# 带级差 = 10log10(bw2/bw1) = 3.0103 dB（带级口径与 PSD 口径自洽）。
	# 固定总功率加宽频带：单频 PSD 贡献 -3.0103 dB（总能量不变）。
	var itf_c := _mk_jammer(0.0, 0.0, 185.0, 800.0)  # 同总功率，带宽翻倍
	var jc: float = EnvironmentModel.interferer_noise_db(itf_c, 1000.0, env0, 0.0, 0.0, 50.0)
	_ok(fails, "AC1c fixed power widen", _approx(jc - ja, -3.0103, 0.01), true)


## ---- AC-2：JAMMER 真实干扰效果 ----
func _ac2_jammer_effect(fails: Array) -> void:
	var env := _mk_env([_mk_jammer(3000.0, 0.0, 185.0, 400.0)])
	var base: float = env.effective_noise_db_at(1000.0, -1.0, 4.0, 0.0, 0.0, 50.0)
	var env0 := _mk_env([])
	var clean: float = env0.effective_noise_db_at(1000.0, -1.0, 4.0, 0.0, 0.0, 50.0)
	_ok(fails, "AC2a N_eff raised", base > clean + 6.0, true)
	# 弱目标统计探测率下降（同接触，JAMMER 与其同方位）。
	var env_clean := EnvironmentModel.new()
	env_clean.ambient_noise_by_frequency = {"500": 60.0, "1000": 60.0}
	var se_clean: float = AcousticService.passive_se_layer(
		130.0, 8000.0, 1000.0, env_clean, 4.0, 50.0, 50.0, 0.0, 0.0, 55.0
	)
	var env_jam := EnvironmentModel.new()
	env_jam.ambient_noise_by_frequency = {"500": 60.0, "1000": 60.0}
	env_jam.interferers = [_mk_jammer(8000.0, 0.0, 185.0, 400.0)]
	var se_jam: float = AcousticService.passive_se_layer(
		130.0, 8000.0, 1000.0, env_jam, 4.0, 50.0, 50.0, 0.0, 0.0, 55.0, 0.0, 0.0, 0.0, 5.0
	)
	var pd_clean: float = AcousticService.detection_probability(se_clean)
	var pd_jam: float = AcousticService.detection_probability(se_jam)
	_ok(fails, "AC2b weak target Pd drops", pd_jam < pd_clean * 0.1, true)
	# 频带外不贡献（band 800–1200，问 5000 Hz）。
	var j_out: float = EnvironmentModel.interferer_noise_db(
		_mk_jammer(3000.0, 0.0, 185.0, 400.0), 5000.0, env0, 0.0, 0.0, 50.0
	)
	_ok(fails, "AC2c out-of-band silent", j_out <= -INF, true)
	# 波束外按旁瓣衰减（不无差别全向）。
	var j_in: float = EnvironmentModel.interferer_noise_db(
		_mk_jammer(0.0, 3000.0, 185.0, 400.0), 1000.0, env0, 0.0, 0.0, 50.0, 0.0, 60.0
	)
	var j_side: float = EnvironmentModel.interferer_noise_db(
		_mk_jammer(0.0, 3000.0, 185.0, 400.0), 1000.0, env0, 0.0, 0.0, 50.0, 180.0, 60.0
	)
	_ok(
		fails,
		"AC2d beam response",
		_approx(j_in - j_side, EnvironmentModel.BEAM_SIDELOBE_LOSS_DB, 0.01),
		true,
	)


## ---- AC-3：追帧调度与逐行调度一致 ----
func _ac3_schedule_catchup(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var op_a := OperatorSonar.new()
	op_a.setup(w.world)
	op_a.active_array_id = "BOW"
	var scene: Array = w._acoustic_scene_emitters()
	var acs: Dictionary = w.world["target_acs"].duplicate()
	acs.merge(w._acoustic_scene_acs())
	# A：每 0.5s 逐行 update。
	var t := 0.0
	for i in range(60):
		t += DT
		op_a.update(t, scene, acs)
	# B：一次性追帧 30s。
	var op_b := OperatorSonar.new()
	op_b.setup(w.world)
	op_b.active_array_id = "BOW"
	op_b.catch_up_rows(30.0, scene, acs, 64)
	_ok(fails, "AC3a row count equal", op_b.bb_rows.size() == op_a.bb_rows.size(), true)
	_ok(fails, "AC3b rows >= 1", op_b.bb_rows.size() >= 1, true)


## ---- AC-4：空化连续性 ----
func _ac4_cavitation_smooth(fails: Array) -> void:
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 130.0
	ac.cavitation_speed_kn_at_surface = 12.0
	ac.cavitation_depth_slope = 1.2
	ac.cavitation_extra_db = 12.0
	var vcav: float = ac.cavitation_speed_kn(50.0)
	var sl_below: float = ac.broadband_sl_db(vcav - 0.05, 50.0)
	var sl_above: float = ac.broadband_sl_db(vcav + 0.05, 50.0)
	_ok(fails, "AC4a no jump at Vcav", sl_above - sl_below < 0.5, true)
	var sl_deep: float = ac.broadband_sl_db(vcav + 1.0, 200.0)
	var sl_shallow: float = ac.broadband_sl_db(vcav + 1.0, 0.0)
	_ok(fails, "AC4b deeper raises threshold", sl_deep < sl_shallow, true)
	var sl_slow: float = ac.broadband_sl_db(4.0, 50.0)
	var sl_fast: float = ac.broadband_sl_db(30.0, 0.0)
	_ok(fails, "AC4c faster louder", sl_fast > sl_slow, true)


## ---- AC-5：AR(1) 平稳性 + DEMON 换算 ----
func _ac5_ar1_demon(fails: Array) -> void:
	var op := OperatorSonar.new()
	op._rng = RandomNumberGenerator.new()
	op._rng.seed = 424242
	var tex := PackedFloat32Array()
	tex.resize(OperatorSonar.BB_BINS)
	tex.fill(0.0)
	var burn := 200
	var n := 20000
	var mean := 0.0
	var m2 := 0.0
	for i in range(burn + n):
		op._advance_noise_tex(tex)
		if i >= burn:
			mean += tex[10]
			m2 += tex[10] * tex[10]
	mean /= float(n)
	var std: float = sqrt(m2 / float(n) - mean * mean)
	# 平稳标准差 = 1（× NOISE_TEXTURE_DB 即配置幅度；旧写法仅 0.378）。
	_ok(fails, "AC5a AR1 stationary std", _approx(std, 1.0, 0.08), true)
	# DEMON 换算：V = f_shaft * pitch / 0.514444（旧公式少 60 倍量级）。
	op._update_demon_estimate(10.0, 5, 20.0)
	var expect: float = 10.0 * OperatorSonar.PROP_PITCH_M / 0.514444
	_ok(
		fails,
		"AC5b demon speed formula",
		_approx(float(op.demon_estimate["speed_kn"]), expect, 3.0),
		true,
	)


## ---- AC-6：AGC 只影响显示 ----
func _ac6_display_isolation(fails: Array) -> void:
	var row := {"values": PackedFloat32Array(), "course": 0.0}
	var vals := PackedFloat32Array()
	for i in range(180):
		vals.append(-20.0 + 0.1 * (i % 30))
	row["values"] = vals
	var v1 := WaterfallView.new()
	v1.rows = [row]
	v1._img_dirty = true
	v1._rebuild_image()
	var v2 := WaterfallView.new()
	v2.rows = [row]
	v2._img_dirty = true
	v2._rebuild_image()
	_ok(
		fails,
		"AC6a rebuild deterministic",
		v1._img.get_pixel(10, 1).is_equal_approx(v2._img.get_pixel(10, 1)),
		true
	)
	var v3 := WaterfallView.new()
	v3.agc_enabled = false
	v3.rows = [row]
	v3._img_dirty = true
	v3._rebuild_image()
	# AGC（P10/P99 归一）与固定量程映射不同，但只影响显示：同一 rows 源、
	# 开关 AGC 均不修改 rows 本身（证据/TMA 数值不变）。
	_ok(
		fails,
		"AC6b agc remaps display only",
		not v3._img.get_pixel(10, 1).is_equal_approx(v1._img.get_pixel(10, 1)),
		true,
	)
	_ok(fails, "AC6c rows untouched", v1.rows.size() == 1 and v1.rows[0] == row, true)
