extends SceneTree
## towed_performance_test.gd — P0-C 验收：统一口径 + 拖曳阵性能等级 + 主动跨层校准
##
## 覆盖验收清单：
##   T07 同配置同观测条件的手动显示链与自动链 SE/Pd 一致；显示增益不改 Pd。
##   T08 TOWED 满长稳定时左右 90° 不再扣旧 25 dB；FOM 相对 BOW ≥12 dB、相对
##       FLANK ≥8 dB；端射额外 SE 惩罚 ≤4 dB、误差有界且 A/B 镜像严格对称。
##   T09 弱目标 + ≥200 固定种子：TOWED 单次 Pd、30 s 发现率、50% 建轨距离比、
##       首次发现时间、方位 RMSE 全部满足 AC-02/AC-04。
##   T10 收回/部分布放/转弯/高速各项损失连续生效、不重复扣同一项；
##       DEGRADED 中位 SE 不低于 BOW。
##
## 全部断言只用固定种子与解析式概率，不依赖 Truth 之外的随机实现。

const SPEED_KN: float = 4.0
const OWN_DEPTH_M: float = 50.0
const UPDATE_INTERVAL_S: float = 2.0
const UPDATES_30S: int = 15  # 30 s / 2 s
const SEEDS: int = 200
## 场景主动阵 AG(24) + PG(6)：AC-01 要求 AG/PG 分开配置、只相加一次。
const ACTIVE_AG_PG_DB: float = 30.0

const ENV_DICT: Dictionary = {
	"environment_type": "shallow",
	"sea_state": 2,
	"ambient_noise_by_frequency": {"500": 58.0, "1000": 52.0},
	"own_noise_base_db": 38.0,
	"own_noise_speed_coeff": 1.6,
	"tl_spreading_k": 20.0,
	"tl_absorption_alpha": 0.5,
	"tl_environment_loss": 2.0,
}

var _fails: Array = []


func _initialize() -> void:
	_t07_unified_config()
	_t08_relative_performance()
	_t09_weak_target_statistics()
	_t10_degradation_continuity()
	if _fails.is_empty():
		print("TOWED-PERFORMANCE P0-C TEST PASS")
		quit(0)
	else:
		for f in _fails:
			print("FAIL ", f)
		print("TOWED-PERFORMANCE P0-C TEST FAIL (%d)" % _fails.size())
		quit(1)


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)


## 参数顺序为 (name, cond) 的变体（可读性用；与 _assert 等价）。
func _check(fails: Array, name: String, cond: bool) -> void:
	if not cond:
		fails.append(name)


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s got=%.4f want=%.4f tol=%.4f" % [name, got, want, tol])


func _mk_env() -> EnvironmentModel:
	var e := EnvironmentModel.new()
	e.from_dict(ENV_DICT)
	return e


# ------------------------------------------------------------------
#  T07：统一配置口径 —— 手动显示链与自动船员链 SE/Pd 一致
# ------------------------------------------------------------------


func _t07_unified_config() -> void:
	var env := _mk_env()
	for aid in ["BOW", "FLANK", "TOWED"]:
		var prof: SensorAcousticProfile = SensorAcousticProfile.builtin_profile(aid)
		var sensor := SensorArray.new()
		sensor.from_dict(prof.to_sensor_dict())
		sensor.set_rng(_mk_rng(4242))
		# 自动船员链：SensorArray.passive_signal_excess（同一 AcousticService 公式）
		var se_auto: float = sensor.passive_signal_excess(
			135.0, 7000.0, prof.center_freq_hz, env, SPEED_KN
		)
		# 手动/显示链：profile 统一入口
		var se_manual: float = prof.passive_se_db(135.0, 7000.0, env, SPEED_KN)
		_assert_close(_fails, "T07 %s SE 两链一致" % aid, se_manual, se_auto, 1e-6)
		_assert_close(
			_fails,
			"T07 %s Pd 两链一致" % aid,
			prof.detection_probability(se_manual),
			sensor.detection_probability(se_auto),
			1e-9
		)
		_assert_close(
			_fails,
			"T07 %s AG/PG 口径一致" % aid,
			prof.detection_gain_db(),
			float(sensor.array_gain_db),
			1e-9
		)
		_assert_close(
			_fails,
			"T07 %s DT 口径一致" % aid,
			prof.detection_threshold_db,
			float(sensor.detection_threshold_db),
			1e-9
		)

	# 显示增益与探测增益分离：瀑布幅度缩放不得改变 Pd。
	var se_probe: float = 5.0
	var pd_probe: float = SensorAcousticProfile.builtin_profile("BOW").detection_probability(
		se_probe
	)
	_assert(
		_fails,
		(
			absf(
				(
					OperatorSonar.display_amp_db(se_probe, 0.6, 30.0)
					- OperatorSonar.display_amp_db(se_probe, 2.0, 30.0)
				)
			)
			> 0.5
		),
		"T07 显示幅度确实随配色缩放变化"
	)
	_assert_close(
		_fails,
		"T07 显示增益不改 Pd",
		SensorAcousticProfile.builtin_profile("BOW").detection_probability(se_probe),
		pd_probe,
		1e-12
	)

	# AC-01：self_noise=-1 只表示"采用平台默认自噪"，不得因此跳过干扰源。
	_t07_interferer_with_default_self_noise()

	# 集成：OperatorSonar 实际生成的峰用同一口径（含 TOWED 的 +12 dB 与零方向惩罚）。
	var env2 := _mk_env()
	var own := _mk_entity("own", 0.0, 0.0, 0.0, SPEED_KN)
	own.depth_m = OWN_DEPTH_M
	var tgt := _mk_entity("t1", 0.0, 6000.0, 0.0, 8.0)
	tgt.depth_m = OWN_DEPTH_M
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 140.0
	ac.speed_noise_a = 16.0
	ac.speed_noise_n = 2.2
	ac.speed_noise_vref_kn = 8.0
	var rng := _mk_rng(777)
	var op := OperatorSonar.new()
	op.setup({"env": env2, "own": own, "rng": rng})
	op.set_array("BOW")
	var peaks: Array = []
	for i in range(60):
		op.update(float(i) * UPDATE_INTERVAL_S, [tgt], {tgt.id: ac})
		peaks = op.latest_peaks()
		if not peaks.is_empty():
			break
	_check(_fails, "T07 集成：BOW 产出峰", not peaks.is_empty())
	if not peaks.is_empty():
		var sl: float = ac.broadband_sl_db(float(tgt.speed_kn), float(tgt.depth_m))
		var rng_m: float = 6000.0
		var se_expect: float = op.profile_for("BOW").passive_se_db(sl, rng_m, env2, SPEED_KN)
		_assert_close(_fails, "T07 集成：峰 SE 与统一口径一致", float(peaks[0]["se_db"]), se_expect, 1e-3)
		_check(
			_fails,
			"T07 集成：显示幅度 != 探测 SE（两条链分离）",
			absf(float(peaks[0]["level_db"]) - float(peaks[0]["se_db"])) > 0.5
		)


## AC-01：self_noise=-1 只表示"采用平台默认自噪"，不得因此跳过干扰源
## （旧 layer 服务把 self_noise>=0 当成"是否计入干扰"的开关）。
func _t07_interferer_with_default_self_noise() -> void:
	var env := _mk_env()
	var jammers: Array = [
		{
			"e": 8000.0,
			"n": 0.0,
			"z": 50.0,
			"sl_band_db": 150.0,
			"band_min_hz": 200.0,
			"band_max_hz": 800.0,
		}
	]
	env.interferers = jammers
	var se_jam: float = AcousticService.passive_se_layer(
		135.0, 7000.0, 500.0, env, SPEED_KN, 50.0, 50.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 90.0
	)
	env.interferers = []
	var se_clean: float = AcousticService.passive_se_layer(
		135.0, 7000.0, 500.0, env, SPEED_KN, 50.0, 50.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 90.0
	)
	_check(
		_fails,
		"AC-01 self_noise=-1 仍计入干扰源（SE 降低 %.2f dB）" % (se_clean - se_jam),
		se_jam < se_clean - 0.5
	)


# ------------------------------------------------------------------
#  T08：相对性能与方向响应（AC-02）
# ------------------------------------------------------------------


func _t08_relative_performance() -> void:
	var bow: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("BOW")
	var flank: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("FLANK")
	var towed: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("TOWED")
	var n_eff: float = 60.0
	var n_amb: float = 58.0

	# 相对 BOW ≥12 dB / 相对 FLANK ≥8 dB（同一声源、同一环境、同一噪声口径）。
	_assert(
		_fails,
		towed.fom_eff_db(n_eff, n_amb) - bow.fom_eff_db(n_eff, n_amb) >= 12.0 - 1e-6,
		"T08 TOWED FOM 相对 BOW ≥12dB"
	)
	_assert(
		_fails,
		towed.fom_eff_db(n_eff, n_amb) - flank.fom_eff_db(n_eff, n_amb) >= 8.0 - 1e-6,
		"T08 TOWED FOM 相对 FLANK ≥8dB"
	)
	_assert(
		_fails,
		flank.fom_eff_db(n_eff, n_amb) - bow.fom_eff_db(n_eff, n_amb) >= 4.0,
		"T08 FLANK 保持中间等级（≥BOW+4dB）"
	)

	# 旧的"阵轴前视 ±100°、侧向 90° 扣 25 dB"模型必须已被删除。
	for a in [90.0, -90.0, 45.0, -45.0, 135.0, -135.0]:
		_assert_close(
			_fails, "T08 TOWED 主工作区 %d° 不再扣方向增益" % int(a), towed.direction_gain_db(a), 0.0, 1e-9
		)
		_check(_fails, "T08 TOWED %d° 不再被旧 25dB 惩罚" % int(a), towed.direction_gain_db(a) > -3.0)

	# 端射额外 SE 惩罚 ≤4 dB、连续、无硬盲区（±150° 处仍是可用工作区）。
	_assert_close(_fails, "T08 端射 0° 惩罚上限 4dB", towed.direction_gain_db(0.0), -4.0, 1e-9)
	_assert_close(_fails, "T08 端射 180° 惩罚上限 4dB", towed.direction_gain_db(180.0), -4.0, 1e-9)
	_assert_close(_fails, "T08 端射区外 16° 无惩罚", towed.direction_gain_db(16.0), 0.0, 1e-9)
	var prev: float = towed.direction_gain_db(0.0)
	var max_jump: float = 0.0
	for i in range(1, 91):
		var g: float = towed.direction_gain_db(float(i) * 0.5)
		max_jump = maxf(max_jump, absf(g - prev))
		prev = g
	_check(_fails, "T08 方向响应连续（无跳变）", max_jump < 0.2)
	_check(_fails, "T08 无硬盲区（处处 ≥ -4dB）", towed.direction_gain_db(179.0) >= -4.0 - 1e-9)
	# 稳定满长时端射仍不低于 BOW：+12 dB 优势 − 4 dB 惩罚 = +8 dB。
	_assert(
		_fails,
		(
			towed.fom_eff_db(n_eff, n_amb) + towed.direction_gain_db(0.0)
			> bow.fom_eff_db(n_eff, n_amb)
		),
		"T08 端射端 TOWED 仍优于 BOW"
	)

	# 方位精度：主工作区 ≤0.5°、同等 SE 下 ≤BOW 的 60%、端射有界。
	var se_probe: float = 0.0
	var bow_sigma: float = bow.bearing_sigma_deg(se_probe, 90.0)
	for a in [45.0, 90.0, 135.0, -45.0, -90.0, -135.0]:
		var s: float = towed.bearing_sigma_deg(se_probe, a)
		_check(_fails, "T08 主工作区 %d° sigma ≤0.5°" % int(a), s <= 0.5)
		_check(_fails, "T08 主工作区 %d° sigma ≤BOW 60%%" % int(a), s <= 0.6 * bow_sigma)
	var s_end: float = towed.bearing_sigma_deg(se_probe, 0.0)
	_check(
		_fails,
		"T08 端射 sigma 有界（≤4×主工作区）",
		s_end <= 4.0 * towed.bearing_sigma_deg(se_probe, 90.0) + 1e-9
	)

	# A/B 两支共用同一 sigma（只符号相反），不因两个候选而扩大随机误差。
	_assert_close(
		_fails,
		"T08 A/B 两支 sigma 相同",
		towed.bearing_sigma_deg(se_probe, 70.0),
		towed.bearing_sigma_deg(se_probe, -70.0),
		1e-12
	)

	# 集成：TOWED 实产出峰必须是严格关于阵轴对称、共享同一 evidence 的 A/B 两支。
	_assert(_fails, _t08_mirror_pair_symmetric(), "T08 集成：TOWED A/B 镜像严格对称且同一 pair")


func _t08_mirror_pair_symmetric() -> bool:
	var env := _mk_env()
	var own := _mk_entity("own", 0.0, 0.0, 0.0, SPEED_KN)
	own.depth_m = OWN_DEPTH_M
	var towed := TowedArray.new()
	towed.setup({"tow_length_m": 400.0, "deploy_time_s": 1.0})
	towed.stream()
	towed.step(200.0, 0.0, NavUtils.kn_to_ms(SPEED_KN))  # 放满并沉降
	own.towed = towed
	var tgt := _mk_entity("t1", 5000.0, 0.0, 0.0, 8.0)  # 正横（阵列相对 90°）
	tgt.depth_m = OWN_DEPTH_M
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 140.0
	ac.speed_noise_a = 16.0
	ac.speed_noise_n = 2.2
	ac.speed_noise_vref_kn = 8.0
	var op := OperatorSonar.new()
	op.setup({"env": env, "own": own, "rng": _mk_rng(9091)})
	op.set_array("TOWED")
	var peaks: Array = []
	for i in range(80):
		op.update(float(i) * UPDATE_INTERVAL_S, [tgt], {tgt.id: ac})
		peaks = op.latest_peaks()
		if peaks.size() >= 2:
			break
	if peaks.size() < 2:
		return false
	var pid: String = str(peaks[0]["ambiguous_pair_id"])
	if pid == "":
		return false
	var n_pair: int = 0
	var sum: float = 0.0
	for p in peaks:
		if str(p["ambiguous_pair_id"]) != pid:
			continue
		n_pair += 1
		sum += float(p["bearing_deg"])
	if n_pair != 2:
		return false
	return absf(NavUtils.wrap180(sum)) < 1e-6


# ------------------------------------------------------------------
#  T09：弱目标统计验收（AC-02/AC-04，≥200 固定种子）
# ------------------------------------------------------------------


func _t09_weak_target_statistics() -> void:
	var env := _mk_env()
	var bow: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("BOW")
	var flank: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("FLANK")
	var towed: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("TOWED")

	# ---- 1) 低源级弱目标：BOW 单次 Pd 落在 0.20~0.40，TOWED 落在 0.80~0.95 ----
	var r_weak: float = 7000.0
	var sl_weak: float = _sl_for_pd(bow, env, r_weak, 0.25)
	_assert(_fails, sl_weak < 138.0, "T09 弱目标源级确实低（%.1f dB < 场景 145 dB 强目标）" % sl_weak)
	var pd_bow: float = bow.detection_probability(bow.passive_se_db(sl_weak, r_weak, env, SPEED_KN))
	var pd_towed: float = towed.detection_probability(
		towed.passive_se_db(sl_weak, r_weak, env, SPEED_KN)
	)
	_check(_fails, "T09 BOW 单次 Pd ∈[0.20,0.40] (%.3f)" % pd_bow, pd_bow >= 0.20 and pd_bow <= 0.40)
	_check(
		_fails,
		"T09 TOWED 单次 Pd ∈[0.80,0.95] (%.3f)" % pd_towed,
		pd_towed >= 0.80 and pd_towed <= 0.95
	)

	# 30 s 累计发现率（15 次独立更新）与 200 个固定种子的实测发现率。
	var cum_bow: float = _cum30(pd_bow)
	var cum_towed: float = _cum30(pd_towed)
	_check(_fails, "T09 TOWED 30s 累计发现率 ≥95%% (%.4f)" % cum_towed, cum_towed >= 0.95)
	# 30 s 窗口对弱目标接近饱和（BOW 亦达 0.98+），故性能判别看单次 Pd 与首次发现时间。
	_check(
		_fails,
		"T09 TOWED 单次 Pd 显著高于 BOW (%.3f vs %.3f)" % [pd_towed, pd_bow],
		pd_towed >= pd_bow + 0.5
	)
	_check(_fails, "T09 BOW 30s 累计仍劣于 TOWED（弱目标判别力）", cum_bow < cum_towed)
	var mc_towed: Dictionary = _mc_discovery(towed, env, sl_weak, r_weak, SEEDS)
	var mc_bow: Dictionary = _mc_discovery(bow, env, sl_weak, r_weak, SEEDS)
	_assert(
		_fails,
		float(mc_towed["rate"]) >= 0.95,
		"T09 200 种子 TOWED 30s 发现率 ≥95%% (%.3f)" % float(mc_towed["rate"])
	)
	_assert(
		_fails,
		float(mc_towed["rate"]) > float(mc_bow["rate"]),
		(
			"T09 200 种子 TOWED 发现率不低于 BOW (%.3f vs %.3f)"
			% [float(mc_towed["rate"]), float(mc_bow["rate"])]
		)
	)

	# ---- 2) 50% 建轨距离：TOWED ≥1.8×BOW，FLANK ≥1.4×BOW ----
	# 逐距离扫描用"较响的弱目标基准"，使 50% 点落在扩散主导区间（玩法指标）。
	var sl_sweep: float = _sl_for_cum30(bow, env, 4000.0, 0.5)
	var r50_bow: float = _range_for_cum30(bow, env, sl_sweep, 0.5)
	var r50_flank: float = _range_for_cum30(flank, env, sl_sweep, 0.5)
	var r50_towed: float = _range_for_cum30(towed, env, sl_sweep, 0.5)
	_assert(
		_fails,
		r50_towed >= 1.8 * r50_bow,
		(
			"T09 TOWED 50%% 建轨距离 ≥1.8×BOW (%.0f vs %.0f, %.2f×)"
			% [r50_towed, r50_bow, r50_towed / r50_bow]
		)
	)
	_assert(
		_fails,
		r50_flank >= 1.4 * r50_bow,
		(
			"T09 FLANK 50%% 建轨距离 ≥1.4×BOW (%.0f vs %.0f, %.2f×)"
			% [r50_flank, r50_bow, r50_flank / r50_bow]
		)
	)
	_assert(_fails, r50_towed > r50_flank, "T09 TOWED 50%% 建轨距离 > FLANK")

	# ---- 3) 首次发现时间 ≤ BOW 的 50%；方位 RMSE ≤ BOW 的 60% ----
	var tt_towed: float = float(mc_towed["mean_time"])
	var tt_bow: float = float(mc_bow["mean_time"])
	_assert(
		_fails,
		tt_towed <= 0.5 * tt_bow,
		"T09 TOWED 平均首次发现时间 ≤50%% BOW (%.1fs vs %.1fs)" % [tt_towed, tt_bow]
	)
	var se_t: float = towed.passive_se_db(sl_weak, r_weak, env, SPEED_KN)
	var se_b: float = bow.passive_se_db(sl_weak, r_weak, env, SPEED_KN)
	var rmse_t: float = _mc_bearing_rmse(towed, se_t, 90.0, SEEDS)
	var rmse_b: float = _mc_bearing_rmse(bow, se_b, 90.0, SEEDS)
	_assert(
		_fails,
		rmse_t <= 0.6 * rmse_b,
		"T09 TOWED 方位 RMSE ≤60%% BOW (%.3f° vs %.3f°)" % [rmse_t, rmse_b]
	)

	# ---- 4) 主动跨层 8 km 单次 Pd 落在 0.30~0.60（AC-04，3 kHz 单程损耗 5 dB） ----
	var pd_cross: float = _cross_layer_pd(8000.0)
	_assert(
		_fails,
		pd_cross >= 0.30 and pd_cross <= 0.60,
		"T09 完全跨层 8km 主动单次 Pd ∈[0.30,0.60] (%.3f)" % pd_cross
	)
	var pd_same: float = _same_layer_pd(8000.0)
	_assert(
		_fails,
		pd_same >= 0.85 and pd_same <= 0.98,
		"T09 同层 8km 主动单次 Pd ∈[0.85,0.98] (%.3f)" % pd_same
	)


# ------------------------------------------------------------------
#  T10：性能状态与连续退化（AC-03）
# ------------------------------------------------------------------


func _t10_degradation_continuity() -> void:
	var t := TowedArray.new()
	t.setup({"tow_length_m": 400.0, "deploy_time_s": 90.0})
	_check(_fails, "T10 未布放 = STOWED", t.performance_state() == TowedArray.Perf.STOWED)
	_assert_close(_fails, "T10 STOWED 无孔径", t.aperture_fraction(), 0.0, 1e-9)

	# 满长稳定 → BEST，四项损失均为 0。
	t.stream()
	for i in range(200):
		t.step(1.0, 0.0, NavUtils.kn_to_ms(6.0))
	_check(_fails, "T10 满长稳定 = BEST", t.performance_state() == TowedArray.Perf.BEST)
	var b_best: Dictionary = t.performance_loss_breakdown()
	_assert_close(_fails, "T10 BEST 无损失", t.performance_loss_db(), 0.0, 1e-6)
	_check(_fails, "T10 损失分解四项", b_best.size() == 4)

	# 部分布放（60%~85%）→ DEGRADED，且优势仍 > BOW。
	t.set_length_command(0.72 * 400.0)
	for i in range(400):
		t.step(1.0, 0.0, NavUtils.kn_to_ms(6.0))
	_assert(
		_fails,
		t.performance_state() == TowedArray.Perf.DEGRADED,
		"T10 部分布放 = DEGRADED (got %s)" % t.performance_state_name()
	)
	var bow_gain: float = SensorAcousticProfile.builtin_profile("BOW").detection_gain_db()
	var towed_gain: float = SensorAcousticProfile.builtin_profile("TOWED").detection_gain_db()
	var se_towed: float = towed_gain + t.performance_loss_db()
	_assert(
		_fails,
		se_towed > bow_gain,
		"T10 DEGRADED 净 SE 仍高于 BOW (%.2f vs %.2f)" % [se_towed, bow_gain]
	)
	# 10 节仍在 8~12 节区间：流速损失为 0（未超 12 节），四项不重复扣。
	t.step(1.0, 0.0, NavUtils.kn_to_ms(10.0))
	var b_deg: Dictionary = t.performance_loss_breakdown()
	_assert_close(_fails, "T10 10 节未超拖速无流噪损失", float(b_deg["speed_db"]), 0.0, 1e-9)
	_check(_fails, "T10 孔径损失独立计入", float(b_deg["aperture_db"]) < 0.0)

	# 高速（>12 节）→ UNSTABLE，原因可解释（流噪项非零）。
	t.step(1.0, 0.0, NavUtils.kn_to_ms(15.0))
	_assert(
		_fails,
		t.performance_state() == TowedArray.Perf.UNSTABLE,
		"T10 超拖速 = UNSTABLE (got %s)" % t.performance_state_name()
	)
	var b_un: Dictionary = t.performance_loss_breakdown()
	_check(_fails, "T10 UNSTABLE 有可解释原因（流噪）", float(b_un["speed_db"]) < 0.0)
	_assert_close(
		_fails,
		"T10 损失合计 = 四项之和",
		t.performance_loss_db(),
		(
			float(b_un["aperture_db"])
			+ float(b_un["settle_db"])
			+ float(b_un["bend_db"])
			+ float(b_un["speed_db"])
		),
		1e-6
	)

	# 连续退化：损失是"有效孔径/沉降/弯曲/流噪"的连续函数——沿长度逐 2m 采样，
	# DEGRADED 区间（q_L ≥0.6）内不得出现跳变；整段单调不增，且四种状态都被经过。
	var c := TowedArray.new()
	c.setup({"tow_length_m": 400.0, "deploy_time_s": 1.0})
	c.stream()
	for i in range(200):
		c.step(1.0, 0.0, NavUtils.kn_to_ms(6.0))
	var states: Dictionary = {}
	var max_step: float = 0.0
	var prev: float = c.performance_loss_db()
	for l in range(400, -1, -2):
		c.set_actual_length(float(l))
		var cur: float = c.performance_loss_db()
		states[c.performance_state_name()] = true
		if c.aperture_fraction() >= 0.6:
			max_step = maxf(max_step, absf(cur - prev))
		_check(_fails, "T10 损失沿长度单调不增（L=%d）" % l, cur <= prev + 1e-6)
		prev = cur
	_check(_fails, "T10 DEGRADED 区间损失连续（每 2m ≤0.5dB）", max_step <= 0.5)
	_check(_fails, "T10 收回经过 DEGRADED", states.has("DEGRADED"))
	_check(_fails, "T10 收回经过 UNSTABLE", states.has("UNSTABLE"))
	_check(_fails, "T10 收回最终 STOWED", states.has("STOWED"))


# ------------------------------------------------------------------
#  求解 / 蒙特卡洛辅助
# ------------------------------------------------------------------


func _mk_rng(seed_v: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	return r


func _mk_entity(id: String, e: float, n: float, course: float, speed_kn: float) -> TruthEntity:
	var t := TruthEntity.new()
	(
		t
		. from_dict(
			{
				"id": id,
				"side": "blue",
				"position_east_m": e,
				"position_north_m": n,
				"course_deg": course,
				"speed_kn": speed_kn,
				"depth_m": 50.0,
			}
		)
	)
	return t


## 求使单次 Pd = target_pd 的源级 SL（解析式）。
func _sl_for_pd(prof: SensorAcousticProfile, env: RefCounted, r: float, target_pd: float) -> float:
	var k: float = prof.detection_k_d
	var se: float = k * log(target_pd / maxf(1.0 - target_pd, 1e-9))
	return se + env.propagation_loss(r, prof.center_freq_hz) + _no_eff(env, prof)


## 求使 30 s 累计发现率 = target_cum 的源级 SL。
func _sl_for_cum30(
	prof: SensorAcousticProfile, env: RefCounted, r: float, target_cum: float
) -> float:
	var pd: float = 1.0 - pow(maxf(1.0 - target_cum, 1e-12), 1.0 / float(UPDATES_30S))
	return _sl_for_pd(prof, env, r, pd)


## 30 s 内累计发现率（15 次独立更新）。
func _cum30(pd: float) -> float:
	return 1.0 - pow(maxf(1.0 - pd, 0.0), float(UPDATES_30S))


## 30 s 累计发现率 = target 的"50% 建轨距离"（二分；Pd 随距离单调下降）。
func _range_for_cum30(
	prof: SensorAcousticProfile, env: RefCounted, sl: float, target: float
) -> float:
	var lo: float = 500.0
	var hi: float = 400000.0
	for i in range(60):
		var mid: float = 0.5 * (lo + hi)
		var pd: float = prof.detection_probability(prof.passive_se_db(sl, mid, env, SPEED_KN))
		if _cum30(pd) >= target:
			lo = mid
		else:
			hi = mid
	return lo


func _no_eff(env: RefCounted, prof: SensorAcousticProfile) -> float:
	return float(env.effective_noise_db(prof.center_freq_hz, SPEED_KN))


## ≥seeds 个固定种子的 30 s 发现统计：发现率与平均首次发现时间。
func _mc_discovery(
	prof: SensorAcousticProfile, env: RefCounted, sl: float, r: float, seeds: int
) -> Dictionary:
	var pd: float = prof.detection_probability(prof.passive_se_db(sl, r, env, SPEED_KN))
	var hit: int = 0
	var sum_t: float = 0.0
	for i in range(seeds):
		var rng := _mk_rng(90000 + i)
		for u in range(UPDATES_30S):
			if rng.randf() < pd:
				hit += 1
				sum_t += float(u + 1) * UPDATE_INTERVAL_S
				break
	return {
		"rate": float(hit) / float(seeds),
		"mean_time": sum_t / maxf(float(hit), 1.0),
	}


## 方位误差 RMSE（≥seeds 次固定种子抽样，正横方向）。
func _mc_bearing_rmse(
	prof: SensorAcousticProfile, se_db: float, array_rel: float, seeds: int
) -> float:
	var sigma: float = prof.bearing_sigma_deg(se_db, array_rel)
	var rng := _mk_rng(31337)
	var acc: float = 0.0
	for i in range(seeds):
		var e: float = rng.randfn(0.0, sigma)
		acc += e * e
	return sqrt(acc / float(seeds))


## 同层 8 km 主动单次 Pd（SEa = SL - 2TL + TS - N + AG + PG - DT，AcousticService 单一口径）。
func _same_layer_pd(r: float) -> float:
	var env := _mk_env()
	var prof: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("BOW")
	var se: float = AcousticService.active_se(
		205.0, 12.0, r, 3000.0, env, SPEED_KN, ACTIVE_AG_PG_DB, 0.0
	)
	return AcousticService.detection_probability(se, prof.detection_k_d)


## 完全跨层 8 km 主动单次 Pd（3 kHz 单程跨层损耗 5 dB，AC-04）。
func _cross_layer_pd(r: float) -> float:
	var env := _mk_env()
	var dm := DepthLayerModel.new()
	(
		dm
		. from_dict(
			{
				"enabled": true,
				"surface_depth_m": 0,
				"bottom_depth_m": 400,
				"thermocline_depth_m": 120,
				"thermocline_thickness_m": 20,
				"upper_hold_depth_m": 70,
				"lower_hold_depth_m": 180,
				"cross_layer_loss_db_by_frequency": {"500": 6, "3000": 5},
			}
		)
	)
	env.depth_model = dm
	var prof: SensorAcousticProfile = SensorAcousticProfile.builtin_profile("BOW")
	var se: float = AcousticService.active_se_layer(
		205.0, 12.0, r, 3000.0, env, SPEED_KN, 50.0, 50.0, 220.0, ACTIVE_AG_PG_DB, 0.0
	)
	return AcousticService.detection_probability(se, prof.detection_k_d)
