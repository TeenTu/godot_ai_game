extends SceneTree
## active_echo_auto_test.gd — P1-A（PG-01/PG-03/PG-04）主动回波自动处理与粗定位验收。
##
##   T14 单次主动"方位+距离"回波 → 立即产出可见的 POSITION_ONLY 系统位置估计，
##       绝不被"4 条证据"门限拦截；单次观测不得凭空给出航速/航向。
##   T15 无有效回波 → 不创建虚假位置；监听结束明确"本次未获得有效回波"，
##       且不保留上一次的成功摘要/关联。
##   T20 本艇在回波往返期间机动 → 观测参考站位/参考时刻统一（发射瞬间冻结），
##       运动近似偏差显式记入位置协方差（不伪装高精度）。
##   T21 主动卡片模式与全局模式同源（切卡片 = 切全局；Take Control 一致），
##       自动系统估计不覆盖玩家正在编辑的手动草案。
##
## 运行：godot --headless --path games/sonar --script res://tools/active_echo_auto_test.gd

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

const DT: float = 0.5
const RANGE_M: float = 8000.0
const LISTEN_S: float = 15.0
const ECHO_T_S: float = 2.0 * RANGE_M / 1500.0  # ≈10.67 s
## 完整监听窗步数（无回波时必须等满窗口）+ 余量。
const NO_RETURN_STEPS: int = 40


func _initialize() -> void:
	var fails: Array = []
	_t14_single_echo_position_only(fails)
	_t15_no_return_no_fake_position(fails)
	_t20_mixed_reference_epoch(fails)
	_t21_single_mode_source_and_draft(fails)
	if fails.is_empty():
		print("ACTIVE_ECHO_AUTO TEST PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("ACTIVE_ECHO_AUTO TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ---------------- T14：单次回波 → POSITION_ONLY ----------------
func _t14_single_echo_position_only(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.automation = AutomationController.new()
	_ping_cycle(w, c, 24)
	_assert_true(fails, "T14 echoed track exists", c.tracker.count() == 1)
	if c.tracker.count() != 1:
		return
	var t: Track = c.tracker.all_tracks()[0]
	var obs: Dictionary = c.position_estimate_for(t.track_id)
	# 单条证据（远少于 4 条）也必须已输出位置——T14 的核心。
	_assert_eq(fails, "T14 evidence count", str(t.evidence_count()), "1")
	_assert_true(
		fails, "T14 has_position without 4 evidences", bool(obs.get("has_position", false))
	)
	_assert_eq(fails, "T14 kind", str(obs.get("kind_name", "")), "POSITION_ONLY")
	_assert_true(fails, "T14 no motion from one echo", not bool(obs.get("has_motion", false)))
	_assert_true(fails, "T14 no speed field", not obs.has("speed_kn"))
	_assert_eq(fails, "T14 epochs", str(obs.get("epochs", -1)), "1")
	# 位置 = 参考站位 + 距离·方位；误差区是完整 2×2 协方差（非单标量）。
	var cov: Array = obs.get("cov", [])
	_assert_true(
		fails, "T14 full 2x2 covariance", cov.size() == 2 and (cov[0] as Array).size() == 2
	)
	_assert_true(
		fails, "T14 covariance positive diagonal", float(cov[0][0]) > 0.0 and float(cov[1][1]) > 0.0
	)
	var e: float = float(obs.get("east_m", 0.0))
	var n: float = float(obs.get("north_m", 0.0))
	var rr: float = sqrt(e * e + n * n)
	_assert_true(
		fails, "T14 position near measured range (%.0f m)" % rr, absf(rr - RANGE_M) < 0.1 * RANGE_M
	)
	# 卡片说明行同源可见。
	var note: String = c.note_text()
	_assert_true(
		fails, "T14 card note mentions POSITION_ONLY (%s)" % note, note.contains("POSITION_ONLY")
	)
	# PG-03：到达即生成的临时点已在监听窗关闭后被最终航迹 id 替换，
	# 且没有新增重复证据（仍是一条 evidence）。
	var temp: Array = c.temp_contacts_snapshot()
	_assert_true(fails, "T14 temp contact registered", not temp.is_empty())
	if not temp.is_empty():
		_assert_true(
			fails,
			"T14 temp label replaced by track id",
			str(temp[0]["resolved_track_id"]) == t.track_id and not bool(temp[0]["awaiting"])
		)
	_assert_eq(fails, "T14 no duplicate evidence", str(t.evidence_count()), "1")


# ---------------- T15：无回波 → 不造虚假位置 + 明确文案 ----------------
func _t15_no_return_no_fake_position(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0))
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.automation = AutomationController.new()
	# 第一次：正常回波（建立"上次成功摘要"）。
	_ping_cycle(w, c, 24)
	_assert_true(fails, "T15 first ping produced returns", not c.return_rows.is_empty())
	if c.return_rows.is_empty():
		return
	# 先等第一次会话冷却结束（单在途门），再让下一次 Ping 有资格发射。
	w.run_steps(40)
	w.world["targets"][0].position_east_m = 30000.0
	w.world["targets"][0].position_north_m = 30000.0
	_ping_cycle(w, c, NO_RETURN_STEPS)
	_assert_eq(fails, "T15 outcome", c.last_outcome, "NO_RETURN")
	_assert_true(
		fails,
		"T15 explicit no-return text (%s)" % c.last_summary,
		c.last_summary.contains("未获得有效回波")
	)
	_assert_true(fails, "T15 previous return rows cleared", c.return_rows.is_empty())
	_assert_eq(fails, "T15 no stale association shown", c.linked_track_id(), "-")
	# 不创建虚假位置：临时点清空，且没有新增航迹/位置估计。
	_assert_true(fails, "T15 no fake temp contact", c.temp_contacts_snapshot().is_empty())
	_assert_true(fails, "T15 no fake position estimate", c.position_estimates.size() <= 1)
	_assert_true(fails, "T15 explanation non-empty", c.note_text() != "")
	# 第二次 Ping 不得新增航迹（上次成功的那条仍在，且没有任何 range 证据新增）。
	_assert_eq(fails, "T15 track count unchanged", str(c.tracker.count()), "1")
	var t: Track = c.tracker.all_tracks()[0]
	_assert_eq(fails, "T15 evidence count unchanged", str(t.evidence_count()), "1")


# ---------------- T20：往返期间机动 → 参考基准统一 ----------------
func _t20_mixed_reference_epoch(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario(0.0, 12.0))
	w.auto_measurements = false
	var own: TruthEntity = w.world["own"]
	var emit_e: float = float(own.position_east_m)
	var emit_n: float = float(own.position_north_m)
	_assert_true(fails, "T20 ping ok", w.issue_ping())
	_assert_true(fails, "T20 emit time frozen", w.ping_emit_time() >= 0.0)
	var t_emit: float = w.ping_emit_time()
	w.run_steps(ceili(ECHO_T_S / DT) + 1)
	var arrive_e: float = float(own.position_east_m)
	var arrive_n: float = float(own.position_north_m)
	var moved: float = sqrt(
		(arrive_e - emit_e) * (arrive_e - emit_e) + (arrive_n - emit_n) * (arrive_n - emit_n)
	)
	_assert_true(fails, "T20 own moved during τ (%.0f m)" % moved, moved > 30.0)
	var echoes: Array = w.take_arrived_echoes()
	_assert_true(fails, "T20 echo arrived", not echoes.is_empty())
	if echoes.is_empty():
		return
	var m: Measurement = echoes[0]["measurement"]
	# 参考站位/参考时刻 = 发射瞬间冻结值（消除"发射时距离 + 接收时站位"混用）。
	_assert_true(
		fails,
		"T20 reference east is emit station (%.1f vs %.1f)" % [m.reference_east_m, emit_e],
		absf(m.reference_east_m - emit_e) < 1.0
	)
	_assert_true(
		fails,
		"T20 reference north is emit station (%.1f vs %.1f)" % [m.reference_north_m, emit_n],
		absf(m.reference_north_m - emit_n) < 1.0
	)
	_assert_true(
		fails,
		"T20 reference time is emit time (%.2f vs %.2f)" % [m.reference_time_s, t_emit],
		absf(m.reference_time_s - t_emit) < 1e-6
	)
	_assert_true(
		fails, "T20 observer fields = reference station", m.observer_east_m == m.reference_east_m
	)
	_assert_true(
		fails, "T20 motion bias recorded (%.1f m)" % m.motion_bias_m, m.motion_bias_m > 5.0
	)
	# 偏差显式进协方差：带偏差的 σ 必须 ≥ 无偏差的 σ（不许靠隐藏基准得到假精度）。
	var with_bias: Dictionary = ActivePositionObs.ellipse_of_cov(
		ActivePositionObs.position_covariance(m)
	)
	var m2 := Measurement.new()
	m2.measured_bearing_deg = m.measured_bearing_deg
	m2.bearing_sigma_deg = m.bearing_sigma_deg
	m2.measured_range_m = m.measured_range_m
	m2.range_sigma_m = m.range_sigma_m
	m2.observer_pos_sigma_m = m.observer_pos_sigma_m
	m2.motion_bias_m = 0.0
	var no_bias: Dictionary = ActivePositionObs.ellipse_of_cov(
		ActivePositionObs.position_covariance(m2)
	)
	# 协方差按"方差"比较：σ_bias² 必须真的进了位置误差（不是把偏差藏起来）。
	var var_with: float = pow(float(with_bias["minor_m"]), 2.0)
	var var_without: float = pow(float(no_bias["minor_m"]), 2.0)
	_assert_true(
		fails,
		(
			"T20 bias inflates covariance (var %.0f vs %.0f, bias² %.0f)"
			% [var_with, var_without, m.motion_bias_m * m.motion_bias_m]
		),
		var_with - var_without >= 0.9 * m.motion_bias_m * m.motion_bias_m
	)
	_assert_true(fails, "T20 no false precision", float(with_bias["major_m"]) > 0.0)


# ---------------- T21：唯一模式源 + 手动草案保护 ----------------
func _t21_single_mode_source_and_draft(fails: Array) -> void:
	var auto_ctrl := AutomationController.new()
	var c := ActivePingController.new()
	c.automation = auto_ctrl
	# 卡片切模式 = 切全局模式（同一份状态）。
	c.set_fit_mode("AUTO")
	_assert_eq(fails, "T21 card AUTO", c.fit_mode, "AUTO")
	_assert_true(
		fails, "T21 global mode follows card", auto_ctrl.mode == AutomationController.Mode.FULL_AUTO
	)
	c.set_fit_mode("ASSIST")
	_assert_eq(fails, "T21 canon ASSIST", c.fit_mode, "ASSISTED")
	_assert_true(fails, "T21 global ASSIST", auto_ctrl.mode == AutomationController.Mode.ASSISTED)
	c.take_control()
	_assert_eq(fails, "T21 take control = MANUAL", c.fit_mode, "MANUAL")
	_assert_true(fails, "T21 global MANUAL", auto_ctrl.mode == AutomationController.Mode.MANUAL)
	# 全局改模式 → 卡片视图同步（反向一致）。
	auto_ctrl.set_mode(AutomationController.Mode.FULL_AUTO, 1.0)
	_assert_eq(fails, "T21 card follows global", c.fit_mode, "AUTO")
	# 规范词表映射（旧名兼容）。
	_assert_eq(
		fails,
		"T21 legacy FULL_AUTO maps to AUTO",
		AutomationController.canon_name_of(AutomationController.Mode.FULL_AUTO),
		"AUTO"
	)
	_assert_true(
		fails,
		"T21 ASSIST and AUTO are both automatic",
		(
			AutomationController.is_automatic(AutomationController.Mode.ASSISTED)
			and AutomationController.is_automatic(AutomationController.Mode.FULL_AUTO)
			and not AutomationController.is_automatic(AutomationController.Mode.MANUAL)
		)
	)
	_t21_draft_not_overwritten(fails)


## 自动系统估计独立更新，绝不覆盖玩家正在编辑的手动草案（也不吞掉草案）。
func _t21_draft_not_overwritten(fails: Array) -> void:
	var fcc := FireControlContext.new()
	var m := Measurement.new()
	m.measured_bearing_deg = 20.0
	m.bearing_sigma_deg = 1.5
	m.timestamp = 0.0
	var t: Track = Track.create("S", 1, m)
	var draft := TrialSolution.new()
	draft.range_m = 1234.0
	draft.source_track_id = t.track_id
	fcc.trial_by_track_id[t.track_id] = draft
	fcc.mark_manual_draft(t.track_id)
	_assert_true(fails, "T21 draft flag set", fcc.has_manual_draft(t.track_id))
	fcc.store_fit(t, _mk_fit(4000.0), 20.0)
	_assert_true(
		fails, "T21 auto fit keeps player draft object", fcc.trial_by_track_id[t.track_id] == draft
	)
	var sys: TrialSolution = fcc.system_estimate(t.track_id)
	_assert_true(fails, "T21 system estimate stored separately", sys != null)
	if sys != null:
		_assert_true(
			fails,
			"T21 system estimate has auto range (%.0f)" % sys.range_m,
			absf(sys.range_m - 4000.0) < 1.0
		)
		_assert_true(fails, "T21 system estimate is not the draft", sys != draft)
	# 草案释放后（采纳/显式重拟合）自动解才回到前台。
	fcc.clear_manual_draft(t.track_id)
	fcc.store_fit(t, _mk_fit(5500.0), 30.0)
	_assert_true(
		fails,
		"T21 after draft release auto fit takes over",
		fcc.trial_by_track_id[t.track_id] != draft
	)


# ---------------- helpers ----------------
func _ping_cycle(w: World, c: ActivePingController, steps: int) -> void:
	c.request_ping()
	w.run_steps(steps)
	c.refresh_panel(null)


func _mk_scenario(target_speed_kn: float = 0.0, own_speed_kn: float = 0.0) -> Dictionary:
	var off: float = 0.5 * sqrt(2.0) * RANGE_M
	return {
		"name": "active_echo_auto",
		"seed": 20260911,
		"dt": DT,
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
			"speed_kn": own_speed_kn,
			"turn_rate_deg_s": 0.0,
			"acceleration_kn_s": 0.0,
			"active_sonar":
			{
				"ping_sl_db": 210.0,
				"cooldown_s": 15.0,
				"freq_min_hz": 2000.0,
				"freq_max_hz": 4000.0,
				"array_gain_db": 24.0,
				"sound_speed_m_s": 1500.0,
				"listen_window_s": LISTEN_S,
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
					"active_target_strength_db": 25.0,
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


func _mk_fit(range_m: float) -> Dictionary:
	return {
		"success": true,
		"status": "CONVERGED",
		"best":
		{
			"bearing_deg": 45.0,
			"range_m": range_m,
			"course_deg": 90.0,
			"speed_kn": 8.0,
			"t_ref": 0.0,
			"v_ms": Vector2.ZERO,
			"p_ref": Vector2.ZERO,
		},
	}


func _assert_true(fails: Array, name: String, cond: bool) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _assert_eq(fails: Array, name: String, got: String, want: String) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, got, want])
		print("FAIL %s: got=%s want=%s" % [name, got, want])
	else:
		print("ok   ", name)
