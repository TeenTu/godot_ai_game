extends SceneTree
## ping_test.gd — S1-04 主动声呐 Ping 交互无头验收（评审修正：声呐非光速）。
##
## 核心物理：ping 回波按往返传播延迟 τ=2R/c 到达（c≈1500m/s），到达时
## 才做检测/测距并进测量流；测距本质是测时 R=c·τ/2。
##
##   P1  冷却逻辑：连发被拒，冷却结束恢复。
##   P2  回波延迟到达：发射后 pending=1、next_echo_in≈2R/c≈10.7s；
##       半途 take 为空；到点 take 得 detected 回波，range≈真距、SE>0。
##   P3  极远目标无回波：到点结算 SE 极负 → 不产 Measurement。
##   P4  回波到时才进测量流：发射瞬间不 append，到达后 append 带 range。
##   P5  摘要字段完整：target_id/detected/se_db/pd/bearing_deg/range_m。
##   P6  场景配置覆盖：ping_sl_db/cooldown_s/sound_speed_m_s（改声速→改 τ）。
##   P7  无目标时 ping 发射成功但无在途回波；无硬件（无 active 传感器）也能 ping。
##   P8  摘要方位与几何真方位一致（±6°）。
##
## 运行：godot --headless --path games/sonar --script res://tools/ping_test.gd

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

const NEAR_RANGE_M: float = 8000.0  # 目标 (5656.85,5656.85) 到原点
const ECHO_T_S: float = 2.0 * NEAR_RANGE_M / 1500.0  # ≈10.67s


func _initialize() -> void:
	var fails: Array = []
	_p1_cooldown(fails)
	_p2_delayed_echo(fails)
	_p3_far_no_echo(fails)
	_p4_echo_in_stream_on_arrival(fails)
	_p5_summary_fields(fails)
	_p6_config_override(fails)
	_p7_no_targets_no_hardware(fails)
	_p8_bearing_close(fails)
	if fails.is_empty():
		print("PING_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("PING_TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


func _mk_scenario(extra_own: Dictionary = {}, target_override: Array = []) -> Dictionary:
	var own: Dictionary = {
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
	}
	for k in extra_own:
		own[k] = extra_own[k]
	var tgts: Array = (
		target_override
		if not target_override.is_empty()
		else [
			{
				"id": "tgt",
				"class_id": "frigate",
				"side": "red",
				"platform_type": "surface",
				"position_east_m": 5656.85,
				"position_north_m": 5656.85,
				"depth_m": 0.0,
				"course_deg": 180.0,
				"speed_kn": 0.0,
				"turn_rate_deg_s": 0.0,
				"acceleration_kn_s": 0.0,
				"acoustic":
				{
					"broadband_base_level_db": 150.0,
					"speed_noise_a": 18.0,
					"speed_noise_n": 2.5,
					"speed_noise_vref_kn": 8.0,
					"active_target_strength_db": 14.0,
				},
			}
		]
	)
	return {
		"name": "ping_test",
		"seed": 20260903,
		"dt": 0.5,
		"duration": 400.0,
		"environment": ENV,
		"own_ship": own,
		"own_acoustic": OWN_AC,
		"targets": tgts,
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


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _steps_until(t_s: float) -> int:
	# dt=0.5s，取首个 ≥t_s 的步数
	return ceili(t_s / 0.5)


func _p1_cooldown(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	_assert_bool(fails, "P1 initial can_ping", w.can_ping(), true)
	_assert_bool(fails, "P1 first ping ok", w.issue_ping(), true)
	_assert_bool(fails, "P1 cannot re-ping immediately", w.can_ping(), false)
	_assert_close(fails, "P1 cd remaining ~15s", w.ping_cooldown_remaining(), 15.0, 0.01)
	_assert_bool(fails, "P1 second ping blocked", w.issue_ping(), false)
	w.run_steps(30)  # 30 × 0.5s = 15s
	_assert_bool(fails, "P1 can_ping after cooldown", w.can_ping(), true)


func _p2_delayed_echo(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	_assert_bool(fails, "P2 ping transmitted", w.issue_ping(), true)
	_assert_bool(fails, "P2 one echo in flight", w.pending_echo_count() == 1, true)
	# 声速 1500m/s → 8km 往返 τ≈10.67s（声呐不是光速！）
	_assert_close(fails, "P2 next_echo_in ~2R/c", w.next_echo_in(), ECHO_T_S, 0.05)
	# 半途（5s）回波尚未到达
	w.run_steps(_steps_until(5.0))
	_assert_bool(fails, "P2 no echo at 5s", w.take_arrived_echoes().is_empty(), true)
	# 到点（11s > 10.67s）回波到达
	w.run_steps(_steps_until(ECHO_T_S) - _steps_until(5.0))
	var echoes: Array = w.take_arrived_echoes()
	_assert_bool(fails, "P2 echo arrived", echoes.size() == 1, true)
	if echoes.is_empty():
		return
	var e: Dictionary = echoes[0]
	_assert_bool(fails, "P2 near target detected", bool(e["detected"]), true)
	_assert_close(fails, "P2 range ~8km", float(e["range_m"]), NEAR_RANGE_M, 600.0)
	_assert_bool(fails, "P2 SE > 0", float(e["se_db"]) > 0.0, true)
	_assert_bool(fails, "P2 pd high", float(e["pd"]) > 0.9, true)


func _p3_far_no_echo(fails: Array) -> void:
	var tgt: Dictionary = {
		"id": "far",
		"class_id": "frigate",
		"side": "red",
		"platform_type": "surface",
		"position_east_m": 200000.0,
		"position_north_m": 0.0,
		"depth_m": 0.0,
		"course_deg": 180.0,
		"speed_kn": 0.0,
		"turn_rate_deg_s": 0.0,
		"acceleration_kn_s": 0.0,
		"acoustic": {"active_target_strength_db": 14.0},
	}
	var w := World.new()
	w.load_scenario(_mk_scenario({}, [tgt]))
	_assert_bool(fails, "P3 ping transmitted", w.issue_ping(), true)
	w.run_steps(_steps_until(2.0 * 200000.0 / 1500.0) + 1)  # 到 τ 之后
	var echoes: Array = w.take_arrived_echoes()
	_assert_bool(fails, "P3 far got echo entry", echoes.size() == 1, true)
	if echoes.is_empty():
		return
	var e: Dictionary = echoes[0]
	_assert_bool(fails, "P3 far SE very low", float(e["se_db"]) < -20.0, true)
	_assert_bool(fails, "P3 far not detected", bool(e["detected"]), false)


func _p4_echo_in_stream_on_arrival(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	w.auto_measurements = false  # 关闭被动自动测量，纯验回波进流
	var n0: int = w.measurements.size()
	w.issue_ping()
	# 发射瞬间绝不进测量流（回波还在路上）
	_assert_bool(fails, "P4 no append at transmit", w.measurements.size() == n0, true)
	_assert_bool(fails, "P4 nothing arrived yet", w.take_arrived_echoes().is_empty(), true)
	w.run_steps(_steps_until(ECHO_T_S))
	var after: Array = w.take_arrived_echoes()  # 结算到点回波（lazy）
	var added: int = w.measurements.size() - n0
	_assert_bool(fails, "P4 echo appended on arrival", added == 1, true)
	_assert_bool(fails, "P4 one echo arrived", after.size() == 1, true)
	if added == 1:
		var m: Measurement = w.measurements[n0]
		_assert_bool(fails, "P4 appended has range", m.has_range(), true)
		_assert_bool(fails, "P4 appended target_id", str(m.target_id) == "tgt", true)


func _p5_summary_fields(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	w.issue_ping()
	w.run_steps(_steps_until(ECHO_T_S))
	var echoes: Array = w.take_arrived_echoes()
	if echoes.is_empty():
		fails.append("P5 no echoes")
		return
	var e: Dictionary = echoes[0]
	for key in ["target_id", "detected", "se_db", "pd", "bearing_deg", "range_m"]:
		if not e.has(key):
			fails.append("P5 missing field: " + key)


func _p6_config_override(fails: Array) -> void:
	var w := World.new()
	var sc: Dictionary = _mk_scenario(
		{"active_sonar": {"ping_sl_db": 200.0, "cooldown_s": 8.0, "sound_speed_m_s": 1200.0}}
	)
	w.load_scenario(sc)
	_assert_close(fails, "P6 ping_sl_db override", w.ping_sl_db, 200.0, 1e-6)
	_assert_close(fails, "P6 cooldown override", w.ping_cooldown_s, 8.0, 1e-6)
	_assert_close(fails, "P6 sound_speed override", w.ping_sound_speed_m_s, 1200.0, 1e-6)
	w.issue_ping()
	_assert_close(fails, "P6 cd remaining ~8s", w.ping_cooldown_remaining(), 8.0, 0.01)
	# 声速 1200 → τ=2*8000/1200≈13.33s（测距即测时，声速变则 τ 变）
	_assert_close(
		fails, "P6 tau scales with sound speed", w.next_echo_in(), 2.0 * NEAR_RANGE_M / 1200.0, 0.05
	)


func _p7_no_targets_no_hardware(fails: Array) -> void:
	var w := World.new()
	var sc: Dictionary = _mk_scenario()
	sc["targets"] = []  # 显式空目标列表
	w.load_scenario(sc)
	_assert_bool(fails, "P7 ping transmitted", w.issue_ping(), true)
	_assert_bool(fails, "P7 no echo in flight", w.pending_echo_count() == 0, true)
	_assert_bool(fails, "P7 ping still consumed", w.can_ping(), false)
	# 主场景只有 passive_broadband 传感器：P2 已隐式验证缺省主动阵可用


func _p8_bearing_close(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	w.issue_ping()
	w.run_steps(_steps_until(ECHO_T_S))
	var echoes: Array = w.take_arrived_echoes()
	if echoes.is_empty():
		fails.append("P8 no echoes")
		return
	var e: Dictionary = echoes[0]
	# 目标在 (5656.85, 5656.85)，本艇原点 → 真方位 45°
	_assert_close(fails, "P8 bearing ~45deg", float(e["bearing_deg"]), 45.0, 6.0)
