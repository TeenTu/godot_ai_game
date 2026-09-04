## AT-16 声学标定包线测试（评审 Patch F / P1-05.4）：
## 固定环境（stage1_basic_passive）、同层/跨层、QUIET/CRUISE/HIGH，
## Monte Carlo 输出被动与主动 P_d(R) 曲线；断言 R50/R90 位于设计区间、
## 次序关系正确、固定 seed 可复现。曲线同时打印存档（Debrief/标定基准）。
extends SceneTree

const SEED := 20260905
const MC_TRIALS := 120
const RANGE_STEP := 200.0
const RANGE_MAX := 20000.0

# 设计包线（标定基准，冻结回归；改标定须显式更新此区间与 DESIGN.md）：
# 被动 R50（己方声呐 AG20/DT3、4kn）：QUIET 近距隐蔽雷 1.5-6km；
# CRUISE 6-18km；HIGH 必须 > CRUISE（不做上限，趋势正确即可）。
# 跨层（雷在下层 180m / 声呐在上层 50m）R50 必须显著小于同层。
# 主动（seeker 12kHz SL195 TS14 self-noise@40kn）：R50 150-1200m、
# R90 50-900m（默认标定的真实设计射程：近距强信号确认用）。
const PASSIVE_QUIET_R50_MIN := 1500.0
const PASSIVE_QUIET_R50_MAX := 6000.0
const PASSIVE_CRUISE_R50_MIN := 6000.0
const PASSIVE_CRUISE_R50_MAX := 18000.0
const ACTIVE_R50_MIN := 150.0
const ACTIVE_R50_MAX := 1200.0
const ACTIVE_R90_MIN := 50.0
const ACTIVE_R90_MAX := 900.0

var _pass: int = 0


func _init() -> void:
	var fails: Array = []
	var env = EnvironmentModel.new()
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	env.from_dict(sc["environment"])
	var dm = DepthLayerModel.new()
	dm.from_dict(sc["depth_layers"])
	env.depth_model = dm
	var prof := TorpedoAcousticProfile.new()

	var curve_a := _mc_passive(env, prof, "CRUISE", 50.0)
	var curve_b := _mc_passive(env, prof, "CRUISE", 50.0)
	_assert_bool(fails, "CAL-1 fixed seed reproducible", curve_a["r50"] == curve_b["r50"], true)
	var r50_q := _mc_passive(env, prof, "QUIET", 50.0)
	var r50_c := curve_a
	var r50_h := _mc_passive(env, prof, "HIGH", 50.0)
	var r50_cx := _mc_passive(env, prof, "CRUISE", 180.0)
	print(
		(
			"R50 passive  QUIET/same=%.0f CRUISE/same=%.0f HIGH/same=%.0f CRUISE/cross=%.0f"
			% [r50_q["r50"], r50_c["r50"], r50_h["r50"], r50_cx["r50"]]
		)
	)
	print(
		(
			"R90 passive  QUIET/same=%.0f CRUISE/same=%.0f HIGH/same=%.0f CRUISE/cross=%.0f"
			% [r50_q["r90"], r50_c["r90"], r50_h["r90"], r50_cx["r90"]]
		)
	)
	_assert_near(fails, "CAL-2 QUIET R50 band", r50_q["r50"], 3750.0, 2250.0)
	_assert_near(fails, "CAL-3 CRUISE R50 band", r50_c["r50"], 12000.0, 6000.0)
	_assert_bool(
		fails,
		"CAL-4 speed ordering QUIET<CRUISE<HIGH",
		r50_q["r50"] < r50_c["r50"] and r50_c["r50"] < r50_h["r50"],
		true
	)
	_assert_bool(fails, "CAL-5 cross-layer < same-layer", r50_cx["r50"] < r50_c["r50"] * 0.8, true)
	_assert_bool(fails, "CAL-6 R50 >= R90 (CRUISE)", r50_c["r50"] >= r50_c["r90"], true)

	var act := _mc_active(env, prof)
	print(
		(
			"active R50=%.0f R90=%.0f (12kHz SL%.0f TS14 self-noise%.1f)"
			% [
				act["r50"],
				act["r90"],
				prof.active_source_level_db,
				prof.receiver_self_noise_db(40.0)
			]
		)
	)
	_assert_bool(
		fails,
		"CAL-7 active R50 band",
		act["r50"] >= ACTIVE_R50_MIN and act["r50"] <= ACTIVE_R50_MAX,
		true
	)
	_assert_bool(
		fails,
		"CAL-8 active R90 band",
		act["r90"] >= ACTIVE_R90_MIN and act["r90"] <= ACTIVE_R90_MAX,
		true
	)
	_assert_bool(fails, "CAL-9 active R50 > R90", act["r50"] > act["r90"], true)

	for f in fails:
		print("[FAIL] " + f)
	print("passed=%d failed=%d" % [_pass, _pass + fails.size()])
	if fails.is_empty():
		print("result=PASS")
	else:
		print("result=FAIL")
	quit(0 if fails.is_empty() else 1)


## 被动 MC：BB 声呐方程 + 每谱线独立 P_d 采样（固定 seed），任一命中即检出。
func _mc_passive(env, prof, mode: String, z_r: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + mode.hash()
	var sl_bb: float = prof.own_noise_sl_db(mode)
	var lines: Array = prof.tonal_lines_by_mode.get(mode, [])
	var r50: float = -1.0
	var r90: float = -1.0
	var r: float = 200.0
	while r <= RANGE_MAX:
		var hits: int = 0
		for t in range(MC_TRIALS):
			var detected: bool = false
			var se_bb: float = AcousticService.passive_se_layer(
				sl_bb, r, 500.0, env, 4.0, 50.0, z_r, 20.0, 3.0
			)
			if rng.randf() < AcousticService.detection_probability(se_bb, 4.0):
				detected = true
			for ln in lines:
				var se_l: float = AcousticService.passive_se_layer(
					float(ln["level_db"]), r, float(ln["freq_hz"]), env, 4.0, 50.0, z_r, 20.0, 3.0
				)
				if rng.randf() < AcousticService.detection_probability(se_l, 4.0):
					detected = true
			if detected:
				hits += 1
		var frac: float = float(hits) / float(MC_TRIALS)
		# R50/R90 = 满足 P_d 阈值的最大距离（探测率随距离单调衰减）。
		if frac >= 0.5:
			r50 = r
		if frac >= 0.9:
			r90 = r
		if r50 > 0.0 and frac < 0.5:
			break
		r += RANGE_STEP
	return {"r50": r50, "r90": r90}


## 主动 MC：seeker 方程（self-noise @40kn、同层 50m、TS14），单发 ping 命中。
func _mc_active(env, prof) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 777
	var sn: float = prof.receiver_self_noise_db(40.0)
	var r50: float = -1.0
	var r90: float = -1.0
	var r: float = 50.0
	while r <= 5000.0:
		var hits: int = 0
		for t in range(MC_TRIALS):
			var se: float = AcousticService.active_se_layer(
				prof.active_source_level_db,
				14.0,
				r,
				12000.0,
				env,
				0.0,
				50.0,
				50.0,
				0.0,
				0.0,
				0.0,
				sn
			)
			if rng.randf() < AcousticService.detection_probability(se, 4.0):
				hits += 1
		var frac: float = float(hits) / float(MC_TRIALS)
		if frac >= 0.5:
			r50 = r
		if frac >= 0.9:
			r90 = r
		if r50 > 0.0 and frac < 0.5:
			break
		r += 50.0
	return {"r50": r50, "r90": r90}


func _assert_bool(fails: Array, name: String, cond: bool, want: bool) -> void:
	if cond == want:
		_pass += 1
		print("[ok] %s" % name)
	else:
		fails.append("%s (got %s want %s)" % [name, str(cond), str(want)])


func _assert_near(fails: Array, name: String, v: float, center: float, tol: float) -> void:
	if absf(v - center) <= tol:
		_pass += 1
		print("[ok] %s" % name)
	else:
		fails.append("%s (got %.0f want %.0f±%.0f)" % [name, v, center, tol])
