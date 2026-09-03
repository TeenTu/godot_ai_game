extends SceneTree
## ping_test.gd — S1-04 主动声呐 Ping 交互无头验收。
##
##   P1  冷却逻辑：连发被拒，冷却结束后恢复。
##   P2  近目标回波：detected=true，带 range≈真距、bearing≈真方位，SE>0。
##   P3  极远目标无回波：SE 极负 → 不产 Measurement。
##   P4  回波进测量流：detected 回波 append world.measurements。
##   P5  摘要字段完整：target_id/detected/se_db/pd/bearing_deg/range_m。
##   P6  场景配置覆盖：own_ship.active_sonar.ping_sl_db/cooldown_s 生效。
##   P7  无目标时 ping 返回空数组、无硬件（无 active 传感器）也能 ping。
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


func _initialize() -> void:
	var fails: Array = []
	_p1_cooldown(fails)
	_p2_near_echo(fails)
	_p3_far_no_echo(fails)
	_p4_echo_in_stream(fails)
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
		"speed_kn": 4.0,
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
				"speed_kn": 10.0,
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
		"duration": 120.0,
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


func _p1_cooldown(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	_assert_bool(fails, "P1 initial can_ping", w.can_ping(), true)
	var e1: Array = w.issue_ping()
	_assert_bool(fails, "P1 first ping ok", not e1.is_empty(), true)
	_assert_bool(fails, "P1 cannot re-ping immediately", w.can_ping(), false)
	_assert_close(fails, "P1 cd remaining ~15s", w.ping_cooldown_remaining(), 15.0, 0.01)
	var e2: Array = w.issue_ping()
	_assert_bool(fails, "P1 second ping blocked", e2.is_empty(), true)
	w.run_steps(30)  # 30 × 0.5s = 15s
	_assert_bool(fails, "P1 can_ping after cooldown", w.can_ping(), true)


func _p2_near_echo(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	var echoes: Array = w.issue_ping()
	_assert_bool(fails, "P2 got echoes", echoes.size() == 1, true)
	if echoes.is_empty():
		return
	var e: Dictionary = echoes[0]
	_assert_bool(fails, "P2 near target detected", bool(e["detected"]), true)
	_assert_close(fails, "P2 range ~8km", float(e["range_m"]), 8000.0, 600.0)
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
		"speed_kn": 10.0,
		"turn_rate_deg_s": 0.0,
		"acceleration_kn_s": 0.0,
		"acoustic": {"active_target_strength_db": 14.0},
	}
	var w := World.new()
	w.load_scenario(_mk_scenario({}, [tgt]))
	var echoes: Array = w.issue_ping()
	_assert_bool(fails, "P3 far got echo entry", echoes.size() == 1, true)
	if echoes.is_empty():
		return
	var e: Dictionary = echoes[0]
	_assert_bool(fails, "P3 far SE very low", float(e["se_db"]) < -20.0, true)
	_assert_bool(fails, "P3 far not detected", bool(e["detected"]), false)


func _p4_echo_in_stream(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	var n0: int = w.measurements.size()
	w.issue_ping()
	var added: int = w.measurements.size() - n0
	_assert_bool(fails, "P4 one echo measurement appended", added == 1, true)
	if added == 1:
		var m: Measurement = w.measurements[n0]
		_assert_bool(fails, "P4 appended has range", m.has_range(), true)
		_assert_bool(fails, "P4 appended target_id", str(m.target_id) == "tgt", true)


func _p5_summary_fields(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	var echoes: Array = w.issue_ping()
	if echoes.is_empty():
		fails.append("P5 no echoes")
		return
	var e: Dictionary = echoes[0]
	for key in ["target_id", "detected", "se_db", "pd", "bearing_deg", "range_m"]:
		if not e.has(key):
			fails.append("P5 missing field: " + key)


func _p6_config_override(fails: Array) -> void:
	var w := World.new()
	var sc: Dictionary = _mk_scenario({"active_sonar": {"ping_sl_db": 200.0, "cooldown_s": 8.0}})
	w.load_scenario(sc)
	_assert_close(fails, "P6 ping_sl_db override", w.ping_sl_db, 200.0, 1e-6)
	_assert_close(fails, "P6 cooldown override", w.ping_cooldown_s, 8.0, 1e-6)
	w.issue_ping()
	_assert_close(fails, "P6 cd remaining ~8s", w.ping_cooldown_remaining(), 8.0, 0.01)


func _p7_no_targets_no_hardware(fails: Array) -> void:
	var w := World.new()
	var sc: Dictionary = _mk_scenario()
	sc["targets"] = []  # 显式空目标列表
	w.load_scenario(sc)
	var echoes: Array = w.issue_ping()
	_assert_bool(fails, "P7 no targets -> empty echoes", echoes.is_empty(), true)
	_assert_bool(fails, "P7 ping still consumed", w.can_ping(), false)
	# 主场景只有 passive_broadband 传感器：P2 已隐式验证缺省主动阵可用


func _p8_bearing_close(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	var echoes: Array = w.issue_ping()
	if echoes.is_empty():
		fails.append("P8 no echoes")
		return
	var e: Dictionary = echoes[0]
	# 目标在 (5656.85, 5656.85)，本艇原点 → 真方位 45°
	_assert_close(fails, "P8 bearing ~45deg", float(e["bearing_deg"]), 45.0, 6.0)
