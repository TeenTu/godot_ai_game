extends SceneTree
## depth_layer_test.gd — S1-07A 双层伪三维深度层模型无头验收（Commit 2）。
##
## 覆盖（S1-07 §4.5 验收 + §4.1/§4.3）：
##   D1  层带分类（UPPER/LOWER/TRANSITION）+ hold 深度 + w_cross：同稳定层≈0、
##       稳定跨层≈1、转换带内 smoothstep 平滑（0<w<1）。
##   D2  TruthEntity 连续升降：70→180m @ Vz=2m/s 耗时 ≥55s，无瞬移（速率受限）。
##   D3  跨层损失连续：深度 1m 步扫温跃层，w/TL 附加无突跳（无单帧跳变）。
##   D4  跨层 SE/Pd 低于同层但非硬置零（无 hard hidden）；主动双程更甚。
##   D5  旧二维场景（无 depth_layers / disabled）零行为变化：额外 TL=0，
##       propagation_loss_layer == propagation_loss。
##   D6  鱼雷深度：ctx.depth_model 注入后升降按模型 hold 深度、surface/bottom
##       钳制生效，禁瞬移。
##
## 全部确定性，可无头运行：
##   godot --headless --path games/sonar --script res://tools/depth_layer_test.gd

const DT: float = 0.5


func _mk_model(enabled: bool = true) -> DepthLayerModel:
	var m := DepthLayerModel.new()
	(
		m
		. from_dict(
			{
				"enabled": enabled,
				"surface_depth_m": 0.0,
				"bottom_depth_m": 400.0,
				"thermocline_depth_m": 120.0,
				"thermocline_thickness_m": 20.0,
				"upper_hold_depth_m": 70.0,
				"lower_hold_depth_m": 180.0,
				"cross_layer_loss_db_by_frequency": {"500": 6.0, "3000": 10.0},
			}
		)
	)
	return m


func _mk_env(enabled: bool = true) -> EnvironmentModel:
	var env := EnvironmentModel.new()
	(
		env
		. from_dict(
			{
				"environment_type": "shallow",
				"ambient_noise_by_frequency": {"500": 55.0},
				"own_noise_base_db": 40.0,
				"own_noise_speed_coeff": 1.0,
				"tl_spreading_k": 20.0,
				"tl_absorption_alpha": 0.5,
				"tl_environment_loss": 0.0,
			}
		)
	)
	env.depth_model = _mk_model(enabled)
	return env


func _initialize() -> void:
	var fails: Array = []
	_d1_model(fails)
	_d2_truth_entity_vertical(fails)
	_d3_tl_continuity(fails)
	_d4_layer_se_pd(fails)
	_d5_legacy_compat(fails)
	_d6_torpedo_depth(fails)
	_finish(fails)


func _d1_model(fails: Array) -> void:
	var m := _mk_model()
	_assert_eq(fails, "D1a band upper", m.depth_band(50.0), "UPPER")
	_assert_eq(fails, "D1b band lower", m.depth_band(200.0), "LOWER")
	_assert_eq(fails, "D1c band transition", m.depth_band(120.0), "TRANSITION")
	_assert_float(fails, "D1d hold upper", m.hold_depth_for_band("UPPER"), 70.0, 1e-6)
	_assert_float(fails, "D1e hold lower", m.hold_depth_for_band("LOWER"), 180.0, 1e-6)
	# 同稳定层 w≈0；稳定跨层 w=1
	_assert_float(fails, "D1f same-layer w", m.cross_layer_weight(50.0, 70.0), 0.0, 1e-6)
	_assert_float(fails, "D1g cross w", m.cross_layer_weight(50.0, 200.0), 1.0, 1e-6)
	# 转换带内平滑：115m 与 125m 都在带内 → 0<w<1
	var w_mid: float = m.cross_layer_weight(115.0, 125.0)
	if w_mid <= 0.0 or w_mid >= 1.0:
		fails.append("D1h transition weight not in (0,1): %.3f" % w_mid)
	# 跨层损失 = w * L(f)，500Hz L=6
	_assert_float(fails, "D1i cross loss", m.cross_layer_loss_db(500.0, 1.0), 6.0, 1e-6)
	_assert_float(fails, "D1j same-layer loss", m.cross_layer_loss_db(500.0, 0.0), 0.0, 1e-6)


func _d2_truth_entity_vertical(fails: Array) -> void:
	var e := TruthEntity.new()
	e.from_dict(
		{
			"position_east_m": 0.0,
			"position_north_m": 0.0,
			"depth_m": 70.0,
			"max_vertical_speed_m_s": 2.0
		}
	)
	e.command_depth(180.0)
	var t0: float = 0.0
	var steps: int = 0
	while e.has_depth_command() and steps < 400:
		e.advance(DT)
		t0 += DT
		steps += 1
	if e.has_depth_command():
		fails.append("D2a never reached commanded depth")
	_assert_float(fails, "D2b final depth", e.depth_m, 180.0, 0.5)
	if t0 < 55.0 - 1e-6:
		fails.append("D2c vertical too fast: %.1fs (need >=55s)" % t0)
	# 无命令时深度保持（旧场景零行为变化）
	var e2 := TruthEntity.new()
	e2.from_dict({"depth_m": 90.0})
	for i in range(20):
		e2.advance(DT)
	_assert_float(fails, "D2d no-cmd holds depth", e2.depth_m, 90.0, 1e-6)


func _d3_tl_continuity(fails: Array) -> void:
	var m := _mk_model()
	# 从 80m 扫到 160m，1m 步：w(z, 200) = 1-u(z) 单调下降、单步增量小（无突跳）
	var prev_w: float = -1.0
	var max_dw: float = 0.0
	for z in range(80, 161):
		var w: float = m.cross_layer_weight(z, 200.0)
		if prev_w >= 0.0:
			max_dw = maxf(max_dw, absf(w - prev_w))
			if w > prev_w + 1e-9:
				fails.append("D3a w not monotonic at z=%d" % z)
		prev_w = w
	if max_dw > 0.08:
		fails.append("D3b w jump too large across transition: %.3f" % max_dw)
	# 层损失随深度连续变化（TL 附加无单帧突跳）
	var env := _mk_env()
	var prev_loss: float = -1.0
	var max_dl: float = 0.0
	for z in range(80, 161):
		var loss: float = env.cross_layer_extra_db(500.0, float(z), 200.0)
		if prev_loss >= 0.0:
			max_dl = maxf(max_dl, absf(loss - prev_loss))
		prev_loss = loss
	if max_dl > 0.5:
		fails.append("D3c TL extra jump too large: %.3f dB" % max_dl)


func _d4_layer_se_pd(fails: Array) -> void:
	var env := _mk_env()
	var sl: float = 150.0
	var rng_m: float = 3000.0
	var freq: float = 500.0
	var own_speed: float = 5.0
	# 同层（都在 UPPER 50m） vs 跨层（50m→200m）
	var se_same: float = AcousticService.passive_se_layer(
		sl, rng_m, freq, env, own_speed, 50.0, 50.0
	)
	var se_cross: float = AcousticService.passive_se_layer(
		sl, rng_m, freq, env, own_speed, 50.0, 200.0
	)
	if se_cross >= se_same:
		fails.append("D4a cross SE not lower: same=%.1f cross=%.1f" % [se_same, se_cross])
	var pd_same: float = AcousticService.detection_probability(se_same)
	var pd_cross: float = AcousticService.detection_probability(se_cross)
	if pd_cross > pd_same:
		fails.append("D4b cross Pd not lower")
	if pd_cross <= 0.0:
		fails.append("D4c cross Pd hard-zero (must not be invisible)")
	# 主动双程：跨层额外损失 ×2
	var se_a_same: float = AcousticService.active_se_layer(
		210.0, 14.0, rng_m, freq, env, own_speed, 50.0, 50.0, 50.0
	)
	var se_a_cross: float = AcousticService.active_se_layer(
		210.0, 14.0, rng_m, freq, env, own_speed, 50.0, 50.0, 200.0
	)
	if se_a_cross >= se_a_same:
		fails.append("D4d active cross SE not lower")
	if AcousticService.detection_probability(se_a_cross) <= 0.0:
		fails.append("D4e active cross Pd hard-zero")


func _d5_legacy_compat(fails: Array) -> void:
	# 无 depth_layers 的旧场景：DepthLayerModel disabled
	var m_off := _mk_model(false)
	if m_off.depth_band(300.0) != "UPPER":
		fails.append("D5a disabled band not UPPER")
	var env := _mk_env(false)
	_assert_float(
		fails, "D5b disabled extra 0", env.cross_layer_extra_db(500.0, 50.0, 300.0), 0.0, 1e-9
	)
	var tl_base: float = env.propagation_loss(5000.0, 500.0)
	var tl_layer: float = env.propagation_loss_layer(5000.0, 500.0, 50.0, 300.0)
	_assert_float(fails, "D5c layer==base when disabled", tl_layer, tl_base, 1e-9)
	# env.depth_model == null 同样 0
	var env0 := EnvironmentModel.new()
	_assert_float(
		fails, "D5d null model extra 0", env0.cross_layer_extra_db(500.0, 50.0, 300.0), 0.0, 1e-9
	)


func _d6_torpedo_depth(fails: Array) -> void:
	# ctx 注入 depth_model：鱼雷 depth 钳制与 hold 来自模型
	var p := WeaponProgram.new()
	p.initial_course_deg = 0.0
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.speed_mode = WeaponProgram.SpeedMode.CRUISE
	p.warhead_arm_distance_m = 300.0
	p.fallback_program = p.make_default_fallback()
	var ctx := TorpedoContext.new()
	ctx.depth_model = _mk_model()
	var tp := Torpedo.new()
	tp.launch("T_D", p, 0.0, 0.0, 50.0, 0.0)
	for i in range(3):
		tp.step(DT, 1.0 + DT * i, ctx)
	_assert_bool(
		fails, "D6a depth cmd accepted", tp.command_depth_band(WeaponProgram.DEPTH_BAND_LOWER), true
	)
	_assert_float(fails, "D6b cmd hold depth", tp.commanded_depth_m, 180.0, 1e-6)
	tp.step(DT, 3.0, ctx)
	if tp.actual_depth_m >= 180.0:
		fails.append("D6c torpedo teleported to lower layer")
	var arrived: bool = false
	for i in range(200):
		tp.step(DT, 4.0 + DT * i, ctx)
		if tp.commanded_depth_m < 0.0 and absf(tp.actual_depth_m - 180.0) < 1.0:
			arrived = true
			break
	if not arrived:
		fails.append("D6d torpedo never reached lower hold depth")
	if tp.depth_state != Torpedo.DepthState.HOLDING_LOWER:
		fails.append("D6e depth_state not HOLDING_LOWER after arrival")


func _assert_eq(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _assert_float(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	for f in fails:
		print("DEPTH_FAIL ", f)
	if fails.is_empty():
		print("DEPTH_LAYER_TEST result=PASS")
	else:
		print("DEPTH_LAYER_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
