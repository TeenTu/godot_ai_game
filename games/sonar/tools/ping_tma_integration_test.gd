extends SceneTree
## ping_tma_integration_test.gd — S1-04B 主动测距进 TMA 数据链验收（无头）。
##
## 覆盖（对应评审 TEST-S1-04B）：
##   R08  fit_meas_dict 透传 range/range_sigma（REQ-08）；纯方位零展开。
##   R08b 解算器把带 range 测量展开为 RANGE 残差行（kind=="range"），
##        residuals 行数与测量严格配对（pred_bearings/残差图不错位）。
##   R10  单腿纯方位 → INSUFFICIENT_GEOMETRY（不生成假运动）；同几何加
##        一条主动 range → 可锚定（used_range>0 放行，目标可解）。
##   R11  Tracker 方位+距离门控：错误距离不关联，正确距离关联。
##   R19  World 往返测距同源：measured_range ≈ 发射时刻登记的 range_ref
##        （不是到达时刻的当前 Truth 距离）；τ 内目标位移进 range_sigma。
##   R03  Truth 隔离：Measurement.to_dict() 不含 target_id。
##   E2E  控制器（operator 模式）：request_ping→回波→喂 Tracker 建 P 接触
##        → on_echo_hits 回调携带 Track → 摘要含 range → 主 UI REFIT 语义
##        （RANGE AIDED 文本出现在 TmaUiData.summary）。
##
## 运行：godot --headless --path games/sonar --script res://tools/ping_tma_integration_test.gd

const ENV: Dictionary = {
	"environment_type": "shallow",
	"sea_state": 2,
	"ambient_noise_by_frequency": {"500": 58.0, "1000": 52.0},
	"own_noise_base_db": 38.0,
	"own_noise_speed_coeff": 1.6,
	"tl_spreading_k": 20.0,
	"tl_absorption_alpha": 0.5,
	"tl_environment_loss": 2.0,
}
const OWN_AC: Dictionary = {
	"broadband_base_level_db": 45.0,
	"speed_noise_a": 15.0,
	"speed_noise_n": 2.0,
	"speed_noise_vref_kn": 5.0,
	"cavitation_speed_kn_at_surface": 12.0,
	"cavitation_depth_slope": 1.2,
	"cavitation_extra_db": 12.0,
}

const NEAR_RANGE_M: float = 8000.0
const ECHO_T_S: float = 2.0 * NEAR_RANGE_M / 1500.0  # ≈10.67s


func _initialize() -> void:
	var fails: Array = []
	_r08_fit_dict_passthrough(fails)
	_r08b_solver_range_rows(fails)
	_r10_single_leg_range_anchors(fails)
	_r11_tracker_range_gate(fails)
	_r19_roundtrip_same_source(fails)
	_r03_truth_isolation(fails)
	_r20_fixed_listen_window(fails)
	_r22_emission_event(fails)
	_e2e_controller_to_fit(fails)
	if fails.is_empty():
		print("PING_TMA_INTEGRATION result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("PING_TMA_INTEGRATION FAIL: %d problem(s)" % fails.size())
		quit(1)


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _assert_true(fails: Array, name: String, got: bool) -> void:
	_assert_bool(fails, name, got, true)


func _assert_eq(fails: Array, name: String, got: String, want: String) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, got, want])


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


# =====================================================================
#  造测量 / 场景
# =====================================================================


## 被动纯方位 Measurement（确定性，无噪声）。
func _mk_passive(
	own: TruthEntity, target: TruthEntity, ts: float, sigma_deg: float = 0.5
) -> Measurement:
	var m := Measurement.new()
	m.timestamp = ts
	m.measurement_type = "PASSIVE_BEARING"
	m.observer_east_m = own.position_east_m
	m.observer_north_m = own.position_north_m
	m.measured_bearing_deg = NavUtils.bearing_to_true(
		own.position_east_m, own.position_north_m, target.position_east_m, target.position_north_m
	)
	m.bearing_sigma_deg = sigma_deg
	m.detection_probability = 1.0
	return m


## 主动 Measurement（确定性）：以调用方给的 range 为测量值。
func _mk_active(
	own: TruthEntity,
	target: TruthEntity,
	ts: float,
	range_m: float,
	range_sigma_m: float,
	ping_id: int = 7
) -> Measurement:
	var m := _mk_passive(own, target, ts, 1.0)
	m.measurement_type = "ACTIVE_RANGE_BEARING"
	m.ping_id = ping_id
	m.measured_range_m = range_m
	m.range_sigma_m = range_sigma_m
	m.signal_excess_db = 18.0
	m.detection_probability = 1.0
	return m


func _own_at(pos: Vector2, course_deg: float = 0.0, speed_kn: float = 0.0) -> TruthEntity:
	var own := TruthEntity.new()
	(
		own
		. from_dict(
			{
				"position_east_m": pos.x,
				"position_north_m": pos.y,
				"course_deg": course_deg,
				"speed_kn": speed_kn,
			}
		)
	)
	return own


func _tgt_at(pos: Vector2, course_deg: float = 90.0, speed_kn: float = 10.0) -> TruthEntity:
	var t := TruthEntity.new()
	(
		t
		. from_dict(
			{
				"position_east_m": pos.x,
				"position_north_m": pos.y,
				"course_deg": course_deg,
				"speed_kn": speed_kn,
			}
		)
	)
	return t


func _advance_entities(own: TruthEntity, target: TruthEntity, dt: float) -> void:
	own.advance(dt)
	target.advance(dt)


## 跑一条航迹，按 interval 采被动方位；可选在第 t_mark 时刻追加一条主动 range。
## 返回 Measurement 数组（已含主动测量，active_index 为其下标或 -1）。
func _collect_leg(
	own: TruthEntity,
	target: TruthEntity,
	duration_s: float,
	interval_s: float,
	active_at_s: float = -1.0,
	active_range_m: float = -1.0,
	active_sigma_m: float = 200.0,
	own_turn_at_s: float = -1.0,
	own_new_course: float = 0.0
) -> Array:
	var out: Array = []
	var active_index: int = -1
	var t: float = 0.0
	while t <= duration_s + 0.01:
		if t > 0.0 and own_turn_at_s > 0.0 and absf(t - own_turn_at_s) < interval_s * 0.5:
			own.course_deg = own_new_course
		if active_at_s >= 0.0 and absf(t - active_at_s) < interval_s * 0.51:
			var rng_m: float = (
				active_range_m
				if active_range_m > 0.0
				else (
					NavUtils
					. distance(
						own.position_east_m,
						own.position_north_m,
						target.position_east_m,
						target.position_north_m,
					)
				)
			)
			out.append(_mk_active(own, target, t, rng_m, active_sigma_m))
			active_index = out.size() - 1
		else:
			out.append(_mk_passive(own, target, t))
		_advance_entities(own, target, interval_s)
		t += interval_s
	out.append({"active_index": active_index})  # 哨兵放尾部，消费方 pop
	return out


# =====================================================================
#  R08 / R08b：透传 + 解算器 RANGE 残差行
# =====================================================================


func _r08_fit_dict_passthrough(fails: Array) -> void:
	var own := _own_at(Vector2.ZERO)
	var tgt := _tgt_at(Vector2(6000.0, 6000.0))
	var p := _mk_passive(own, tgt, 0.0)
	var a := _mk_active(own, tgt, 0.0, 8485.0, 150.0)
	var dp: Dictionary = TmaUiData.fit_meas_dict(p)
	var da: Dictionary = TmaUiData.fit_meas_dict(a)
	_assert_true(fails, "R08 passive dict has no range_m", not dp.has("range_m"))
	_assert_true(fails, "R08 passive dict has no range_sigma_m", not dp.has("range_sigma_m"))
	_assert_true(fails, "R08 active dict has range_m", da.has("range_m"))
	_assert_true(fails, "R08 active dict has range_sigma_m", da.has("range_sigma_m"))
	_assert_close(fails, "R08 range_m value", float(da["range_m"]), 8485.0, 0.01)
	_assert_close(fails, "R08 range_sigma_m value", float(da["range_sigma_m"]), 150.0, 0.01)


func _r08b_solver_range_rows(fails: Array) -> void:
	var own := _own_at(Vector2.ZERO, 45.0, 8.0)
	var tgt := _tgt_at(Vector2(8000.0, 6000.0), 200.0, 10.0)
	var ms: Array = _collect_leg(own, tgt, 480.0, 60.0, 480.0, 0.0, 200.0, 240.0, 135.0)
	var sentinel: Dictionary = ms.pop_back()
	var meas: Array = []
	for m in ms:
		meas.append(TmaUiData.fit_meas_dict(m))
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		fails.append("R08b solve failed: status=" + str(r.get("status", "?")))
		return
	_assert_true(fails, "R08b has_range_measurements", bool(r.get("has_range_measurements", false)))
	_assert_eq(
		fails, "R08b active_range_rows_used==1", str(r.get("active_range_rows_used", -1)), "1"
	)
	var range_rows: int = 0
	var bearing_rows: int = 0
	for rr in r["residuals"]:
		if str(rr.get("kind", "")) == "range":
			range_rows += 1
		else:
			bearing_rows += 1
	_assert_eq(fails, "R08b exactly 1 range row", str(range_rows), "1")
	# 输入 8 被动 + 1 主动 = 9 测量 → 展开后 10 行
	_assert_eq(fails, "R08b row total = 10", str(range_rows + bearing_rows), "10")
	# 残差图过滤函数只输出方位行（RANGE 行是米量纲，不得混轴）
	var br: Array = TmaUiData.bearing_residuals(r["residuals"])
	_assert_eq(fails, "R08b bearing_residuals excludes range", str(br.size()), str(bearing_rows))
	if int(sentinel["active_index"]) >= 0:
		_assert_true(fails, "R08b range_rmse_m >= 0", float(r.get("range_rmse_m", -1.0)) >= 0.0)


# =====================================================================
#  R10：单腿 + range 锚定 / 纯方位单腿不生成假运动
# =====================================================================


func _r10_single_leg_range_anchors(fails: Array) -> void:
	# 本艇静止、目标自北侧正横穿越（0°→~27° 方位变化显著；纯方位无距离尺度）。
	# 纯方位单腿 → INSUFFICIENT_GEOMETRY；同几何 + 尾部一条主动 range → 可解。
	var own := _own_at(Vector2.ZERO)
	var tgt := _tgt_at(Vector2(0.0, 6000.0), 90.0, 10.0)  # 自北向东正横穿越
	var ms: Array = _collect_leg(own, tgt, 600.0, 60.0)
	ms.pop_back()
	var meas: Array = []
	for m in ms:
		meas.append(TmaUiData.fit_meas_dict(m))
	var r0: Dictionary = TmaSolver.solve_auto(meas)
	_assert_eq(
		fails,
		"R10 bearing-only single-leg INSUFFICIENT_GEOMETRY",
		str(r0.get("status", "?")),
		"INSUFFICIENT_GEOMETRY"
	)

	# 同几何：最后加一条主动 range（600s 处）
	var own2 := _own_at(Vector2.ZERO)
	var tgt2 := _tgt_at(Vector2(0.0, 6000.0), 90.0, 10.0)
	var ms2: Array = _collect_leg(own2, tgt2, 600.0, 60.0, 600.0, 0.0, 150.0)
	ms2.pop_back()
	var meas2: Array = []
	for m in ms2:
		meas2.append(TmaUiData.fit_meas_dict(m))
	var r1: Dictionary = TmaSolver.solve_auto(meas2)
	if not bool(r1.get("success", false)):
		fails.append("R10 range-aided solve failed: status=" + str(r1.get("status", "?")))
		return
	_assert_true(fails, "R10 range-aided used range", int(r1.get("active_range_rows_used", 0)) >= 1)
	var st1: String = str(r1.get("status", "?"))
	if st1 == "INSUFFICIENT_GEOMETRY":
		(
			fails
			. append(
				(
					"R10 range-aided still INSUFFICIENT_GEOMETRY (rank=%d cond=%.0f range_rows=%d)"
					% [
						int(r1.get("jacobian_rank", -1)),
						float(r1.get("condition_number", -1.0)),
						int(r1.get("active_range_rows_used", 0)),
					]
				)
			)
		)
		return
	# 600s 末目标真实位置：0e + 10kn(5.144m/s)*600s=3086.7e, 6000n
	# 本艇静止在原点 → 真距 ≈ 6748m
	var best: Dictionary = r1["best"]
	var rng_err: float = absf(float(best["range_m"]) - 6748.3)
	if rng_err > 800.0:
		fails.append("R10 range-aided range err %.0fm (want < 800m)" % rng_err)


# =====================================================================
#  R11：Tracker 方位+距离门控
# =====================================================================


func _r11_tracker_range_gate(fails: Array) -> void:
	var tracker := Tracker.new()
	var own := _own_at(Vector2.ZERO)
	var tgt := _tgt_at(Vector2(6000.0, 0.0), 90.0, 10.0)
	var a0 := _mk_active(own, tgt, 0.0, 6000.0, 150.0)
	var track: Track = tracker.mark(a0, "P")
	_assert_true(fails, "R11 mark created track", track != null)
	# 正确距离（同一目标继续横穿）→ 关联
	_advance_entities(own, tgt, 60.0)
	var good_rng: float = NavUtils.distance(
		own.position_east_m, own.position_north_m, tgt.position_east_m, tgt.position_north_m
	)
	var a1 := _mk_active(own, tgt, 60.0, good_rng, 150.0)
	var assoc: Track = tracker.feed(a1)
	_assert_bool(fails, "R11 correct-range associates", assoc == track, true)
	# 错误距离（差 3000m，远超门控）→ 不关联
	_advance_entities(own, tgt, 60.0)
	var a2 := _mk_active(own, tgt, 120.0, good_rng + 3000.0, 150.0)
	var assoc2: Track = tracker.feed(a2)
	_assert_bool(fails, "R11 wrong-range rejected", assoc2 == null, true)


# =====================================================================
#  R19 / R03：World 往返测距同源 + Truth 隔离
# =====================================================================


func _mk_scenario(
	target_speed_kn: float = 0.0,
	ts_db: float = 25.0,
	target_range_m: float = 8000.0,
	cooldown_s: float = 15.0
) -> Dictionary:
	# 45° 斜距 → 每轴偏移；默认 8000m ↔ 5656.85m（历史用例几何不变）
	var off: float = 0.5 * sqrt(2.0) * target_range_m
	return {
		"name": "ping_tma_int",
		"seed": 20260903,
		"dt": 0.5,
		"duration": 400.0,
		"environment": ENV,
		"own_ship":
		{
			"id": "own",
			"class_id": "attack_sub",
			"side": "blue",
			"platform_type": "submarine",
			"position_east_m": 0.0,
			"position_north_m": 0.0,
			"depth_m": 50.0,
			"course_deg": 0.0,
			"speed_kn": 0.0,
			"turn_rate_deg_s": 0.0,
			"acceleration_kn_s": 0.0,
			"active_sonar":
			{
				"ping_sl_db": 210.0,
				"cooldown_s": cooldown_s,
				"freq_min_hz": 2000.0,
				"freq_max_hz": 4000.0,
				"array_gain_db": 24.0,
				"sound_speed_m_s": 1500.0,
				"listen_window_s": 15.0,
			},
		},
		"own_acoustic": OWN_AC,
		"targets":
		[
			{
				"id": "tgt",
				"class_id": "frigate",
				"side": "red",
				"platform_type": "surface",
				"position_east_m": off,
				"position_north_m": off,
				"depth_m": 0.0,
				"course_deg": 90.0,
				"speed_kn": target_speed_kn,
				"turn_rate_deg_s": 0.0,
				"acceleration_kn_s": 0.0,
				"acoustic":
				{
					"broadband_base_level_db": 150.0,
					"speed_noise_a": 18.0,
					"speed_noise_n": 2.5,
					"speed_noise_vref_kn": 8.0,
					"active_target_strength_db": ts_db,
				},
			}
		],
		"sensors":
		[
			{
				"sensor_id": "hull_broadband",
				"array_type": "passive_broadband",
				"owner_id": "own",
				"freq_min_hz": 100.0,
				"freq_max_hz": 1000.0,
				"array_gain_db": 20.0,
				"detection_threshold_db": 3.0,
				"update_interval_s": 2.0,
				"deployed": true,
			}
		],
	}


func _r19_roundtrip_same_source(fails: Array) -> void:
	# 慢目标（4kn）：τ≈10.7s 内位移 ~22m，drift 进 range_sigma_m。
	var w := World.new()
	w.load_scenario(_mk_scenario(4.0))
	_assert_true(fails, "R19 ping ok", w.issue_ping())
	w.run_steps(ceili(ECHO_T_S / 0.5))
	var echoes: Array = w.take_arrived_echoes()
	_assert_true(fails, "R19 echo arrived", not echoes.is_empty())
	if echoes.is_empty():
		return
	var e: Dictionary = echoes[0]
	_assert_true(fails, "R19 detected", bool(e["detected"]))
	if not bool(e["detected"]):
		return
	var m: Measurement = e["measurement"]
	# 测距以发射时刻登记的 range_ref 为基准（同源），不读到达时刻 Truth 回填
	_assert_true(fails, "R19 measurement has range", m.has_range())
	var ref: float = float(e.get("range_m", -1.0))
	var sig: float = float(e.get("range_sigma_m", -1.0))
	# 静态基准 8000m；允许 3σ
	if absf(m.measured_range_m - ref) > 3.0 * sig and sig > 0.0:
		fails.append(
			"R19 measured %.0fm far from ref %.0fm (sig %.0fm)" % [m.measured_range_m, ref, sig]
		)
	_assert_true(fails, "R19 range_sigma > 0", sig > 0.0)


func _r03_truth_isolation(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.issue_ping()
	w.run_steps(ceili(ECHO_T_S / 0.5))
	var echoes: Array = w.take_arrived_echoes()
	if echoes.is_empty():
		fails.append("R03 no echo")
		return
	var found: Measurement = null
	for e in echoes:
		if bool(e["detected"]):
			found = e["measurement"]
			break
	if found == null:
		fails.append("R03 no detected echo")
		return
	_assert_true(fails, "R03 measurement appended to world stream", w.measurements.has(found))
	_assert_eq(
		fails,
		"R03 measurement_type ACTIVE_RANGE_BEARING",
		found.measurement_type,
		"ACTIVE_RANGE_BEARING",
	)
	var d: Dictionary = found.to_dict()
	_assert_true(fails, "R03 to_dict() has no target_id", not d.has("target_id"))


# =====================================================================
#  R20 / R22（S1-04C）：固定监听窗 + ActiveEmissionEvent
# =====================================================================


## R20（S1-04C-REQ-04）固定监听窗：监听窗只由本艇配置决定，绝不因最远
## 目标 τ 拉长；arrive_t 超出窗口的回波在窗口到期即被丢弃（不可接收），
## 不进结算结果、不进 returned_count，也不让状态机继续 LISTENING 干等。
func _r20_fixed_listen_window(fails: Array) -> void:
	# 目标 20km（τ=2R/c≈26.7s）远超配置监听窗 15s（最大可测距 11.25km）；
	# 冷却 40s > 窗口 15s，保证窗口到期后 NO_RETURN 停留可观测（不被冷却清空）。
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0, 25.0, 20000.0, 40.0))
	_assert_true(fails, "R20 ping ok", w.issue_ping())
	# 窗口内（t=5s）仍在监听：远目标不得让窗口立即判死
	w.run_steps(10)  # t=5.0
	_assert_eq(fails, "R20 still LISTENING inside window", w.ping_state_name(), "LISTENING")
	_assert_eq(fails, "R20 1 echo pending inside window", str(w.pending_echo_count()), "1")
	# 窗口到期（t=15.0）：远回波（26.7s 才到）被丢弃 → NO_RETURN。
	# 旧缺陷会把 listen_end 拉到 max(窗, 最远τ+0.1)≈26.8s → 此刻仍 LISTENING。
	w.run_steps(22)  # t=16.0
	_assert_eq(fails, "R20 window expiry -> NO_RETURN", w.ping_state_name(), "NO_RETURN")
	_assert_eq(fails, "R20 no echo pending after drop", str(w.pending_echo_count()), "0")
	# 越过远回波原定到达时刻（t=30s）：超窗回波不得补结算/产出任何结果摘要
	w.run_steps(28)  # t=30.0
	var results: Array = w.take_arrived_echoes()
	_assert_eq(fails, "R20 over-window echo never settles", str(results.size()), "0")
	_assert_eq(fails, "R20 stays NO_RETURN past far arrival", w.ping_state_name(), "NO_RETURN")


## R22（S1-04C-REQ-05）ActiveEmissionEvent：每次成功发射记录一条本艇
## 发射事实事件（时刻/位置/中心频率/带宽/声源级/脉冲时长）；被拒的发射
## （无硬件/在途/冷却）绝不产生事件。
func _r22_emission_event(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	_assert_eq(fails, "R22 no emission before ping", str(w.active_emissions.size()), "0")
	_assert_true(fails, "R22 ping ok", w.issue_ping())
	_assert_eq(fails, "R22 one emission after ping", str(w.active_emissions.size()), "1")
	var ev: Dictionary = w.active_emissions[0]
	_assert_eq(
		fails, "R22 emitter_internal_ref own", str(ev.get("emitter_internal_ref", "")), "own"
	)
	_assert_close(fails, "R22 emit_time at launch", float(ev.get("emit_time", -1.0)), 0.0, 1e-6)
	var pos: Dictionary = ev.get("source_position_internal", {})
	_assert_close(fails, "R22 source east 0", float(pos.get("e", 1e9)), 0.0, 1e-6)
	_assert_close(fails, "R22 source north 0", float(pos.get("n", 1e9)), 0.0, 1e-6)
	# 场景 2–4kHz → 中心 3kHz / 带宽 2kHz；SL 210dB；缺省脉冲 0.25s
	_assert_close(
		fails, "R22 center_frequency_hz", float(ev.get("center_frequency_hz", -1.0)), 3000.0, 1.0
	)
	_assert_close(fails, "R22 bandwidth_hz", float(ev.get("bandwidth_hz", -1.0)), 2000.0, 1.0)
	_assert_close(fails, "R22 source_level_db", float(ev.get("source_level_db", -1.0)), 210.0, 0.01)
	_assert_close(
		fails, "R22 pulse_duration_s", float(ev.get("pulse_duration_s", -1.0)), 0.25, 0.001
	)
	# 在途二次发射被拒 → 不新增事件
	_assert_true(fails, "R22 in-flight ping rejected", not w.issue_ping())
	_assert_eq(fails, "R22 no event for rejected ping", str(w.active_emissions.size()), "1")
	# 冷却回 READY 后再发 → 第二条事件，emit_time 前进到当前 sim_time
	w.run_steps(32)  # t=16.0，冷却 15s 已过 → READY
	_assert_eq(fails, "R22 READY after cooldown", w.ping_state_name(), "READY")
	_assert_true(fails, "R22 second ping ok", w.issue_ping())
	_assert_eq(fails, "R22 two emissions", str(w.active_emissions.size()), "2")
	_assert_close(
		fails, "R22 second emit_time", float(w.active_emissions[1]["emit_time"]), 16.0, 1e-6
	)


# =====================================================================
#  E2E：控制器（operator 模式）→ Tracker → on_echo_hits → RANGE AIDED
# =====================================================================


func _e2e_controller_to_fit(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false  # operator 模式：主动回波由控制器喂 Tracker
	var tracker := Tracker.new()
	var ctrl := ActivePingController.new()
	ctrl.world = w
	ctrl.tracker = tracker
	var statuses: Array = []
	ctrl.on_status = func(t: String): statuses.append(t)
	var hits: Array = []
	ctrl.on_echo_hits = func(fed: Array): hits.append_array(fed)

	# 无硬件时（对照）：UNAVAILABLE 提示，不发脉冲（REQ-20）
	var w0 := World.new()
	w0.load_scenario(_mk_scenario(0.0))
	w0.ping_hardware = false
	var ctrl0 := ActivePingController.new()
	ctrl0.world = w0
	ctrl0.tracker = tracker
	var st0: Array = []
	ctrl0.on_status = func(t: String): st0.append(t)
	ctrl0.request_ping()
	_assert_true(fails, "E2E no-hardware ping rejected", not w0.issue_ping())

	# 正常发射 → 等待回波 → 排空结算
	ctrl.request_ping()
	_assert_true(fails, "E2E in-flight (LISTENING)", w.ping_state_name() == "LISTENING")
	w.run_steps(ceili(ECHO_T_S / 0.5) + 2)
	ctrl.refresh_panel(null)  # op_panel 可空：只排空回波/喂 Tracker
	_assert_true(fails, "E2E echo hits fired", not hits.is_empty())
	if hits.is_empty():
		return
	_assert_true(fails, "E2E hit carries Measurement", hits[0].has("measurement"))
	var tr: Track = hits[0].get("track")
	_assert_true(fails, "E2E hit carries Track", tr != null)
	if tr == null:
		return
	_assert_eq(fails, "E2E P contact id prefix", tr.track_id.substr(0, 1), "P")
	var has_active: bool = false
	for m in tr.measurement_history:
		if m.measurement_type == "ACTIVE_RANGE_BEARING" and m.has_range():
			has_active = true
	_assert_true(fails, "E2E P track history has ACTIVE range", has_active)
	_assert_true(fails, "E2E summary mentions range", ctrl.last_summary.contains("rng"))

	# 主 UI REFIT 语义：4 被动 + 1 主动 range 的 Track → solve → RANGE AIDED 文本
	var own := _own_at(Vector2.ZERO, 45.0, 8.0)
	var tgt := _tgt_at(Vector2(8000.0, 6000.0), 200.0, 10.0)
	var ms: Array = _collect_leg(own, tgt, 420.0, 60.0, 420.0, 0.0, 200.0, 200.0, 135.0)
	ms.pop_back()
	var meas: Array = []
	for m in ms:
		meas.append(TmaUiData.fit_meas_dict(m))
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		fails.append("E2E fit failed: status=" + str(r.get("status", "?")))
		return
	var txt: String = TmaUiData.summary(r)
	_assert_true(fails, "E2E summary shows RANGE AIDED", txt.contains("RANGE AIDED"))
	_assert_true(fails, "E2E summary has no Truth id", not txt.contains("tgt"))
