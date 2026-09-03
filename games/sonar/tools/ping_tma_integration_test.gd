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
##   C5-C REQ-06：残差行单位分离（bearing=deg / range=m）+ summary 分列计数
##        （B/R used/rej + 物理证据）+ 残差图 deg/m/σ 三态视图过滤。
##   C5-D REQ-03/06 视觉联动：Contact 行徽章（R/P/B+置信）+ range ring 数据
##        （圆心=测距时刻观测位，半径=measured_range，>300s 过期抑制）。
##   C5-E REQ-02/03 验收：fit_mode MANUAL/ASSISTED/AUTO 路由（证据都进 Track、
##        任何模式不自动提交 System Solution，只发 on_fit_requested 拟合请求）；
##        多回波优先级（选中→置信→SE 降序）；测距门控细节（最后有效测距非最新
##        参照 + 错距绝不回退 + 预测测距门控 conf≤0.85 + 带测距候选优先）。
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
	_c5c_residual_kind_rows(fails)
	_c5d_visual_badges(fails)
	_e2e_controller_to_fit(fails)
	_c5e_fit_mode_routing(fails)
	_c5e_echo_priority(fails)
	_c5e_assoc_gating(fails)
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
#  C5-C（REQ-06）：残差行单位分离 + summary 分列计数 + 残差图三态
# =====================================================================


func _c5c_residual_kind_rows(fails: Array) -> void:
	var own := _own_at(Vector2.ZERO, 45.0, 8.0)
	var tgt := _tgt_at(Vector2(8000.0, 6000.0), 200.0, 10.0)
	var ms: Array = _collect_leg(own, tgt, 420.0, 60.0, 420.0, 0.0, 200.0, 200.0, 135.0)
	ms.pop_back()
	# 合成测量不带 evidence_id/measurement_id → 手工赋唯一物理证据号，使
	# Track.evidence_count() 口径可断言（N 次物理到达，而非展开行数）。
	var ev: int = 0
	for m in ms:
		ev += 1
		m.evidence_id = "ev_%03d" % ev
		m.measurement_id = ev
	var track := Track.create("P", 1, ms[0])
	for i in range(1, ms.size()):
		track.add_measurement(ms[i])
	var n_phys: int = ms.size()  # 7 被动 + 1 主动 = 8
	_assert_eq(fails, "C5C evidence_count physical", str(track.evidence_count()), str(n_phys))
	# 主动测距微偏 +120m（仍在 σ=200 门内）：保证 range 残差非零，使 σ_ref
	# 的 |raw/normalized| 中位数口径可被实际求值（零残差会触发回退）。
	var last_m: Measurement = ms[ms.size() - 1]
	last_m.measured_range_m += 120.0
	var meas: Array = []
	for m in ms:
		meas.append(TmaUiData.fit_meas_dict(m))
	var r: Dictionary = TmaSolver.solve_auto(meas)
	if not bool(r.get("success", false)):
		fails.append("C5C solve failed: status=" + str(r.get("status", "?")))
		return
	var b_rows: int = 0
	var r_rows: int = 0
	for row in r["residuals"]:
		if str(row.get("kind", "bearing")) == "range":
			r_rows += 1
		else:
			b_rows += 1
	_assert_eq(fails, "C5C rows = 8 bearing + 1 range", str(b_rows + r_rows), "9")
	var txt: String = TmaUiData.summary(r, track)
	_assert_true(fails, "C5C summary Rows B", txt.contains("Rows B used"))
	_assert_true(fails, "C5C summary R used", txt.contains("R used"))
	_assert_true(fails, "C5C summary RANGE AIDED", txt.contains("RANGE AIDED"))
	_assert_true(
		fails, "C5C summary B used %d rej 0" % b_rows, txt.contains("B used %d rej 0" % b_rows)
	)
	_assert_true(
		fails, "C5C summary R used %d rej 0" % r_rows, txt.contains("R used %d rej 0" % r_rows)
	)
	_assert_true(fails, "C5C summary Ev %d phys" % n_phys, txt.contains("Ev %d phys" % n_phys))
	# 单位分离：bearing 行 deg、range 行 m（不得混单位）。
	for row in r["residuals"]:
		if str(row.get("kind", "bearing")) == "range":
			_assert_eq(fails, "C5C range row unit m", str(row.get("raw_unit", "?")), "m")
		else:
			_assert_eq(fails, "C5C bearing row unit deg", str(row.get("raw_unit", "?")), "deg")
	# kind 过滤 helper 各自只回本通道。
	var rrows: Array = TmaUiData.range_residuals(r["residuals"])
	var brows: Array = TmaUiData.bearing_residuals(r["residuals"])
	_assert_eq(fails, "C5C range_residuals size", str(rrows.size()), "1")
	_assert_eq(fails, "C5C bearing_residuals size", str(brows.size()), str(b_rows))
	# 测距参考 σ（m）≈ 合成 range_sigma=200；方位参考 σ 用 deg 通道。
	var sr_m: float = TmaUiData.mean_sigma_range(r["residuals"])
	_assert_close(fails, "C5C sigma_ref_m ~200m", sr_m, 200.0, 80.0)
	var sd_deg: float = TmaUiData.mean_sigma(r["residuals"])
	_assert_close(fails, "C5C sigma_ref_deg ~0.5deg", sd_deg, 0.5, 0.3)
	# 纯方位路径：无 range 行 → sigma_ref_m 回退 1.0。
	var meas_b: Array = []
	for m in ms.slice(0, n_phys - 1):
		meas_b.append(TmaUiData.fit_meas_dict(m))
	var rb: Dictionary = TmaSolver.solve_auto(meas_b)
	if bool(rb.get("success", false)):
		_assert_close(
			fails,
			"C5C sigma_ref_m fallback 1.0",
			TmaUiData.mean_sigma_range(rb["residuals"]),
			1.0,
			1e-6
		)
	# 残差图三态（deg→m→σ→deg）：每态只显示对应 kind / 全部。
	var plot := ResidualPlot.new()
	plot.residuals = r["residuals"]
	plot.sigma_ref_deg = TmaUiData.mean_sigma(r["residuals"])
	plot.sigma_ref_m = sr_m
	_assert_eq(fails, "C5C plot starts deg", plot.mode, "deg")
	_assert_eq(fails, "C5C deg view bearing only", str(plot._visible_rows().size()), str(b_rows))
	plot._cycle_mode()
	_assert_eq(fails, "C5C m view after cycle", plot.mode, "m")
	_assert_eq(fails, "C5C m view range only", str(plot._visible_rows().size()), "1")
	plot._cycle_mode()
	_assert_eq(fails, "C5C sigma view after cycle", plot.mode, "sigma")
	_assert_eq(
		fails, "C5C sigma view all rows", str(plot._visible_rows().size()), str(b_rows + r_rows)
	)
	plot._cycle_mode()
	_assert_eq(fails, "C5C cycles back to deg", plot.mode, "deg")
	plot.free()
	# 纯被动（无 range 行）时点击应跳过 m 直达 σ。
	if bool(rb.get("success", false)):
		var plot2 := ResidualPlot.new()
		plot2.residuals = rb["residuals"]
		plot2.sigma_ref_deg = TmaUiData.mean_sigma(rb["residuals"])
		plot2._cycle_mode()
		_assert_eq(fails, "C5C no-range skips m", plot2.mode, "sigma")
		plot2.free()


# =====================================================================
#  C5-D（REQ-03/06 视觉联动）：Contact 行徽章 + range ring 数据
# =====================================================================


func _c5d_visual_badges(fails: Array) -> void:
	var own := _own_at(Vector2.ZERO, 45.0, 8.0)
	var tgt := _tgt_at(Vector2(8000.0, 6000.0), 200.0, 10.0)
	var ms: Array = _collect_leg(own, tgt, 300.0, 60.0, 300.0, 0.0, 200.0, 150.0, 120.0)
	ms.pop_back()
	var ev: int = 0
	for m in ms:
		ev += 1
		m.evidence_id = "ev_%03d" % ev
		m.measurement_id = ev
	var track := Track.create("P", 1, ms[0])
	for i in range(1, ms.size()):
		track.add_measurement(ms[i])
	var n_phys: int = ms.size()  # 5 被动 + 1 主动 = 6
	var active_m: Measurement = ms[ms.size() - 1]
	_assert_true(fails, "C5D last meas has range", active_m.has_range())
	# 徽章分级：R（真实测距）/ P（预测测距）/ B（纯方位）；conf=0 → 空。
	track.association_confidence = 0.9
	track.last_association_mode = "range"
	_assert_eq(fails, "C5D badge R", TmaUiData.association_badge(track), "R.90")
	track.last_association_mode = "predicted"
	track.association_confidence = 0.8
	_assert_eq(fails, "C5D badge P", TmaUiData.association_badge(track), "P.80")
	track.last_association_mode = "bearing_only"
	track.association_confidence = 0.35
	_assert_eq(fails, "C5D badge B", TmaUiData.association_badge(track), "B.35")
	track.association_confidence = 0.0
	_assert_eq(fails, "C5D no badge on conf 0", TmaUiData.association_badge(track), "")
	# 行文本：编号 + Brg + Rng（最新带测距）+ 徽章 + 测量数。
	track.association_confidence = 0.9
	track.last_association_mode = "range"
	var lab: String = TmaUiData.contact_label(track)
	_assert_true(fails, "C5D label has track id", lab.contains(track.track_id))
	_assert_true(fails, "C5D label has Rng", lab.contains("Rng %.0fm" % active_m.measured_range_m))
	_assert_true(fails, "C5D label has R.90", lab.contains("R.90"))
	_assert_true(fails, "C5D label has meas count", lab.contains("(%d meas)" % n_phys))
	# range ring 数据：中心=测量时刻观测位，半径=measured_range，σ/方位随附。
	var ring: Dictionary = TmaUiData.range_ring_data(
		track, active_m.timestamp, Color(0.4, 1.0, 0.6)
	)
	if ring.is_empty():
		fails.append("C5D range_ring_data empty for fresh range")
		return
	_assert_close(
		fails,
		"C5D ring center east",
		float((ring["center"] as Vector2).x),
		active_m.observer_east_m,
		1e-3
	)
	_assert_close(
		fails,
		"C5D ring center north",
		float((ring["center"] as Vector2).y),
		active_m.observer_north_m,
		1e-3
	)
	_assert_close(
		fails, "C5D ring range_m", float(ring["range_m"]), active_m.measured_range_m, 1e-3
	)
	_assert_close(fails, "C5D ring sigma_m", float(ring["sigma_m"]), active_m.range_sigma_m, 1e-3)
	_assert_close(
		fails, "C5D ring bearing", float(ring["bearing_deg"]), active_m.measured_bearing_deg, 1e-3
	)
	# 过期证据（>300s）→ 空 dict（不画误导环）。
	_assert_true(
		fails,
		"C5D stale ring suppressed",
		TmaUiData.range_ring_data(track, active_m.timestamp + 400.0, Color.WHITE).is_empty()
	)
	# 纯被动 Track（无测距历史）→ 无 ring。
	var track_b := Track.create("S", 2, ms[0])
	for i in range(1, n_phys - 1):
		track_b.add_measurement(ms[i])
	_assert_true(
		fails,
		"C5D no-range track has no ring",
		TmaUiData.range_ring_data(track_b, ms[n_phys - 2].timestamp, Color.WHITE).is_empty()
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


# =====================================================================
#  C5-E（REQ-02/03 验收）：fit_mode 路由 + 多回波优先级 + 测距门控细节
# =====================================================================


## 完整跑一次 ping 周期（发射→等回波→排空结算），返回 controller 排出的
## hits（fed 命中数组）。op_panel 传 null（无头只走逻辑层）。
func _c5e_ping_cycle(w: World, ctrl: ActivePingController) -> Array:
	var hits: Array = []
	ctrl.on_echo_hits = func(fed: Array): hits.append_array(fed)
	ctrl.request_ping()
	w.run_steps(ceili(ECHO_T_S / 0.5) + 2)
	ctrl.refresh_panel(null)
	return hits


## REQ-02 fit_mode 路由验收。核心不变量：三种模式证据都已进 Track，但任何
## 模式都不自动提交 System Solution——控制器唯一副作用是 on_fit_requested
## 拟合请求（Trial 重拟合/提交由 main_ui 玩家 Accept 门控，本层无提交路径）。
##   MANUAL   证据入 Track、Trial 不动 → REFIT_REQUIRED（不请求拟合）
##   ASSISTED 挂起待 Apply；Apply → 请求拟合 → mark_range_applied → RANGE AIDED；
##            Undo/Reject → 测量移除 + REJECTED
##   AUTO     命中即请求拟合（不留 PENDING_APPLY）
func _c5e_fit_mode_routing(fails: Array) -> void:
	_c5e_routing_manual(fails)
	_c5e_routing_assisted_apply(fails)
	_c5e_routing_assisted_reject(fails)
	_c5e_routing_auto(fails)


func _c5e_routing_manual(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.fit_mode = ActivePingController.MODE_MANUAL
	var fit: Array = []
	c.on_fit_requested = func(tid: String): fit.append(tid)
	var hits: Array = _c5e_ping_cycle(w, c)
	_assert_true(fails, "C5E MANUAL echo hit", not hits.is_empty())
	if hits.is_empty():
		return
	var t: Track = hits[0].get("track")
	_assert_true(fails, "C5E MANUAL track present", t != null)
	if t == null:
		return
	_assert_eq(fails, "C5E MANUAL state REFIT_REQUIRED", c.evidence_state, "REFIT_REQUIRED")
	_assert_true(fails, "C5E MANUAL no pending apply", not c.has_pending_apply())
	_assert_eq(fails, "C5E MANUAL no fit requested", str(fit.size()), "0")
	_assert_true(fails, "C5E MANUAL evidence in track", _c5e_track_has_active(t))
	_assert_true(fails, "C5E MANUAL undo armed", c.has_undo())


func _c5e_routing_assisted_apply(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.fit_mode = ActivePingController.MODE_ASSISTED
	var fit: Array = []
	c.on_fit_requested = func(tid: String): fit.append(tid)
	var hits: Array = _c5e_ping_cycle(w, c)
	_assert_true(fails, "C5E ASSISTED echo hit", not hits.is_empty())
	if hits.is_empty():
		return
	var t: Track = hits[0].get("track")
	_assert_true(fails, "C5E ASSISTED track present", t != null)
	if t == null:
		return
	_assert_eq(fails, "C5E ASSISTED PENDING_APPLY", c.evidence_state, "PENDING_APPLY")
	_assert_true(fails, "C5E ASSISTED pending set", c.has_pending_apply())
	_assert_eq(fails, "C5E ASSISTED no auto fit", str(fit.size()), "0")
	_assert_true(fails, "C5E ASSISTED apply ok", c.apply_pending())
	_assert_eq(fails, "C5E ASSISTED fit requested once", str(fit.size()), "1")
	_assert_eq(fails, "C5E ASSISTED fit id", str(fit[0]), t.track_id)
	_assert_true(fails, "C5E ASSISTED pending cleared", not c.has_pending_apply())
	c.mark_range_applied(true)
	_assert_eq(fails, "C5E ASSISTED RANGE_AIDED", c.evidence_state, "RANGE_AIDED")
	_assert_true(fails, "C5E ASSISTED undo still armed", c.has_undo())


func _c5e_routing_assisted_reject(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.fit_mode = ActivePingController.MODE_ASSISTED
	var hits: Array = _c5e_ping_cycle(w, c)
	_assert_true(fails, "C5E REJECT echo hit", not hits.is_empty())
	if hits.is_empty():
		return
	var t: Track = hits[0].get("track")
	_assert_true(fails, "C5E REJECT track present", t != null)
	if t == null:
		return
	var n_before: int = t.measurement_history.size()
	_assert_eq(fails, "C5E REJECT PENDING_APPLY", c.evidence_state, "PENDING_APPLY")
	_assert_true(fails, "C5E REJECT undo ok", c.undo_last_association())
	_assert_eq(fails, "C5E REJECT state REJECTED", c.evidence_state, "REJECTED")
	_assert_true(
		fails, "C5E REJECT measurement removed", t.measurement_history.size() == n_before - 1
	)
	_assert_true(fails, "C5E REJECT no undo left", not c.has_undo())


func _c5e_routing_auto(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.fit_mode = ActivePingController.MODE_AUTO
	var fit: Array = []
	c.on_fit_requested = func(tid: String): fit.append(tid)
	var hits: Array = _c5e_ping_cycle(w, c)
	_assert_true(fails, "C5E AUTO echo hit", not hits.is_empty())
	if hits.is_empty():
		return
	var t: Track = hits[0].get("track")
	_assert_true(fails, "C5E AUTO track present", t != null)
	if t == null:
		return
	_assert_eq(fails, "C5E AUTO fit requested once", str(fit.size()), "1")
	_assert_eq(fails, "C5E AUTO fit id", str(fit[0]), t.track_id)
	_assert_eq(fails, "C5E AUTO no PENDING_APPLY", c.evidence_state, "")
	_assert_true(fails, "C5E AUTO no pending apply", not c.has_pending_apply())
	_assert_true(fails, "C5E AUTO evidence in track", _c5e_track_has_active(t))


func _c5e_track_has_active(t: Track) -> bool:
	for m in t.measurement_history:
		if m.measurement_type == "ACTIVE_RANGE_BEARING" and m.has_range():
			return true
	return false


## REQ-02 多回波优先级：选中 Track（preferred_track_id）最前 → 其余按
## association_confidence 降序 → SE 降序（controller 排序后主 UI 取 fed[0]）。
func _c5e_echo_priority(fails: Array) -> void:
	var own := _own_at(Vector2.ZERO)
	var tgt := _tgt_at(Vector2(6000.0, 0.0), 90.0, 0.0)
	var ta := Track.create("P", 1, _mk_passive(own, tgt, 0.0))
	var tb := Track.create("P", 2, _mk_passive(own, tgt, 0.0))
	var tc := Track.create("P", 3, _mk_passive(own, tgt, 0.0))
	ta.association_confidence = 0.5
	tb.association_confidence = 0.9
	tc.association_confidence = 0.4
	var ctrl := ActivePingController.new()
	ctrl.preferred_track_id = tc.track_id
	var fed: Array = [
		{"track": ta, "summary": {"se_db": 12.0}},
		{"track": tb, "summary": {"se_db": 18.0}},
		{"track": tc, "summary": {"se_db": 15.0}},
	]
	ctrl._sort_hits_by_priority(fed)
	_assert_eq(fails, "C5E priority preferred first", str(fed[0]["track"].track_id), tc.track_id)
	_assert_eq(fails, "C5E priority conf 2nd", str(fed[1]["track"].track_id), tb.track_id)
	_assert_eq(fails, "C5E priority conf 3rd", str(fed[2]["track"].track_id), ta.track_id)
	# 等置信 → SE 降序
	var fed2: Array = [
		{"track": ta, "summary": {"se_db": 12.0}},
		{"track": tb, "summary": {"se_db": 18.0}},
	]
	ta.association_confidence = 0.9
	tb.association_confidence = 0.9
	ctrl._sort_hits_by_priority(fed2)
	_assert_eq(fails, "C5E tiebreak SE first", str(fed2[0]["track"].track_id), tb.track_id)
	_assert_eq(fails, "C5E tiebreak SE second", str(fed2[1]["track"].track_id), ta.track_id)


## REQ-03 测距门控细节验收：
##   - 最后有效测距可非最新（后随纯方位）仍作参照（mode="range"）；
##   - 错距主动回波：测距门全拒 → 绝不回退纯方位（返回 null，不入 Track）；
##   - 预测测距门控：无测距历史 + 有效预测（≤300s）→ mode="predicted"，
##     confidence 上限 0.85；
##   - 带测距候选优先于纯方位候选（gated 非空先取，不回退 bearing_only）。
func _c5e_assoc_gating(fails: Array) -> void:
	var own := _own_at(Vector2.ZERO)
	var tgt := _tgt_at(Vector2(6000.0, 0.0), 90.0, 0.0)  # 静止目标 → 几何恒定
	# 主动测距后跟两条被动：最新测量无 range，但"最后有效测距"仍是 t=0 主动
	var trk := Tracker.new()
	var a0 := _mk_active(own, tgt, 0.0, 6000.0, 150.0, 1)
	var track: Track = trk.mark(a0, "P")
	track.add_measurement(_mk_passive(own, tgt, 60.0))
	track.add_measurement(_mk_passive(own, tgt, 120.0))
	_assert_true(
		fails, "C5E gate last-valid is non-latest", track.last_valid_range_measurement() == a0
	)
	_assert_eq(
		fails, "C5E gate latest is passive", str(track.latest_measurement().timestamp), "120.0"
	)
	# 正确测距（静止几何 6000m）→ range 档关联成功（参照=非最新也生效）
	var good := _mk_active(own, tgt, 180.0, 6000.0, 150.0, 2)
	var assoc: Track = trk.feed(good)
	_assert_bool(fails, "C5E gate non-latest ref associates", assoc == track, true)
	_assert_eq(fails, "C5E gate mode range", track.last_association_mode, "range")
	_assert_true(
		fails,
		"C5E gate conf in [0.25,0.98]",
		track.association_confidence >= 0.25 and track.association_confidence <= 0.98
	)
	# 错距（6000m off）→ 门拒；存在测距能力 Track 时绝不回退纯方位
	var bad := _mk_active(own, tgt, 240.0, 12000.0, 150.0, 3)
	var assoc_bad: Track = trk.feed(bad)
	_assert_bool(fails, "C5E gate wrong-range no fallback", assoc_bad == null, true)
	_assert_true(fails, "C5E gate rejected not added", not track.measurement_history.has(bad))
	# 预测测距门控：Track 无测距历史 + Tracker 有 ≤300s 预测 → predicted 档
	var trk2 := Tracker.new()
	var tb: Track = trk2.mark(_mk_passive(own, tgt, 0.0), "P")
	tb.add_measurement(_mk_passive(own, tgt, 60.0))
	tb.add_measurement(_mk_passive(own, tgt, 120.0))
	_assert_true(fails, "C5E gate no range history", tb.last_valid_range_measurement() == null)
	trk2.set_predicted_range(tb.track_id, 6000.0, 200.0, 120.0)
	var act_p := _mk_active(own, tgt, 180.0, 6000.0, 150.0, 4)
	var assoc_p: Track = trk2.feed(act_p)
	_assert_bool(fails, "C5E gate predicted associates", assoc_p == tb, true)
	_assert_eq(fails, "C5E gate mode predicted", tb.last_association_mode, "predicted")
	_assert_true(fails, "C5E gate predicted conf <=0.85", tb.association_confidence <= 0.85)
	_assert_true(fails, "C5E gate predicted conf >=0.2", tb.association_confidence >= 0.2)
	# 带测距候选优先：纯方位 Track 方位够近也不抢（gated 先于 bearing_only）
	var trk3 := Tracker.new()
	var t_bear: Track = trk3.mark(_mk_passive(own, tgt, 0.0), "P")
	var t_rng: Track = trk3.mark(_mk_active(own, tgt, 0.0, 6000.0, 150.0, 5), "P")
	var act3 := _mk_active(own, tgt, 60.0, 6000.0, 150.0, 6)
	var assoc3: Track = trk3.feed(act3)
	_assert_bool(fails, "C5E gate range-track preferred", assoc3 == t_rng, true)
	_assert_eq(fails, "C5E gate range mode preferred", t_rng.last_association_mode, "range")
	_assert_true(
		fails, "C5E gate bearing track untouched", not t_bear.measurement_history.has(act3)
	)
