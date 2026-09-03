extends SceneTree
## s100_integrity_test.gd — S1-00 信息链完整性热修验收（GAP-DATA-01/03）。
##
##   D1  探测失败（detected=false）的样本不进入 World.measurements ——
##       "miss 携带未加噪真方位"的数据泄漏被三层过滤堵死（GAP-DATA-01）。
##   D2  一万个固定种子 miss 直接生成也全部 detected=false（无一条精确
##       Truth bearing 可被 append 进玩家链）。
##   D3  Track 按去重 evidence_id 计数：A/B 镜像共享证据只计一次（哪怕
##       measurement_history 有 2 条）；detected=false 样本不计入。
##   D4  主动 bearing+range 单条 Measurement 是一个物理证据（evidence_count=1）。
##   D5  to_dict() 携带 detected/evidence_id，且不含 target_id（Truth 隔离）。
##
## 运行：godot --headless --path games/sonar --script res://tools/s100_integrity_test.gd

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


func _base_own() -> Dictionary:
	return {
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


func _target(id: String, pos_e_m: float, pos_n_m: float, sl_db: float) -> Dictionary:
	return {
		"id": id,
		"class_id": "frigate",
		"side": "red",
		"platform_type": "surface",
		"position_east_m": pos_e_m,
		"position_north_m": pos_n_m,
		"depth_m": 0.0,
		"course_deg": 180.0,
		"speed_kn": 0.0,
		"turn_rate_deg_s": 0.0,
		"acceleration_kn_s": 0.0,
		"acoustic":
		{
			"broadband_base_level_db": sl_db,
			"speed_noise_a": 18.0,
			"speed_noise_n": 2.5,
			"speed_noise_vref_kn": 8.0,
			"active_target_strength_db": 14.0,
		},
	}


func _mk_scenario() -> Dictionary:
	# near：2km、SL 170 → pd≈1（几乎必探测）；far：150km、SL 105 → SE 极负
	# （pd 趋近 0，绝大多数样本为 miss）。
	return {
		"name": "s100_integrity_test",
		"seed": 20260903,
		"dt": 1.0,
		"duration": 400.0,
		"environment": ENV,
		"own_ship": _base_own(),
		"own_acoustic": OWN_AC,
		"targets": [_target("near", 2000.0, 0.0, 170.0), _target("far", 0.0, 150000.0, 105.0)],
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
				"update_interval_s": 1.0,
				"deployed": true,
			}
		],
	}


func _initialize() -> void:
	var fails: Array = []
	_d1_no_miss_in_world(fails)
	_d2_miss_detected_flag(fails)
	_d3_ab_shared_evidence(fails)
	_d4_active_single_evidence(fails)
	_d5_to_dict_truth_isolation(fails)
	if fails.is_empty():
		print("S100_INTEGRITY result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("S100_INTEGRITY FAIL: %d problem(s)" % fails.size())
		quit(1)


func _assert_eq(fails: Array, name: String, got: String, want: String) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


## D1：固定种子跑 120s 自动被动采样——World.measurements 里不许出现任何
## detected=false 样本；极远弱目标（miss 主导）不许贡献任何 Measurement。
func _d1_no_miss_in_world(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	w.auto_measurements = true
	w.run_steps(120)
	_assert_bool(fails, "D1 world produced some measurements", w.measurements.size() > 0, true)
	for m in w.measurements:
		if not m.detected:
			fails.append("D1 miss leaked into world.measurements (id=%d)" % m.measurement_id)
			break
	var far_count: int = 0
	for m in w.measurements:
		if m.target_id == "far":
			far_count += 1
	_assert_eq(
		fails, "D1 far(miss-dominated) target contributed 0 measurements", str(far_count), "0"
	)


## D2：固定种子直接对极远目标生成 10000 次被动——全部 detected=false，
## 即不存在"可被 append 的精确 Truth bearing"样本（GAP-DATA-01 DoD）。
func _d2_miss_detected_flag(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_scenario())
	var gen: MeasurementGenerator = w.world["generator"]
	var own: RefCounted = w.world["own"]
	var sensor: RefCounted = w.world["sensors"][0]
	var far: RefCounted = null
	for t in w.world["targets"]:
		if t.id == "far":
			far = t
			break
	if far == null:
		fails.append("D2 scenario missing far target")
		return
	var ac: RefCounted = w.world["target_acs"][far.id]
	var leaked: int = 0
	var t0: float = w.sim_time
	for i in range(10000):
		var m: Measurement = gen.generate_passive(own, far, ac, sensor, t0 + float(i) * 0.1)
		if m.detected:
			leaked += 1
	_assert_eq(fails, "D2 10000 fixed-seed misses all detected=false", str(leaked), "0")


## D3：A/B 镜像共享 evidence_id → measurement_history=2 但 evidence_count=1、
## detection_count=1；detected=false 的样本不计入。
func _d3_ab_shared_evidence(fails: Array) -> void:
	var a := Measurement.new()
	a.timestamp = 10.0
	a.sensor_id = "OP_TOWED"
	a.measurement_type = "PASSIVE_BEARING"
	a.detected = true
	a.evidence_id = "ev_AB01"
	a.ambiguous_pair_id = "ab_7"
	a.ambiguity_branch = 1
	a.measured_bearing_deg = 45.0
	a.bearing_sigma_deg = 1.0
	a.detection_probability = 0.6
	var b := Measurement.new()
	b.timestamp = 10.0
	b.sensor_id = "OP_TOWED"
	b.measurement_type = "PASSIVE_BEARING"
	b.detected = true
	b.evidence_id = "ev_AB01"
	b.ambiguous_pair_id = "ab_7"
	b.ambiguity_branch = -1
	b.measured_bearing_deg = 315.0
	b.bearing_sigma_deg = 1.0
	b.detection_probability = 0.6
	var miss := Measurement.new()
	miss.timestamp = 11.0
	miss.detected = false
	miss.evidence_id = "ev_miss9"
	miss.measured_bearing_deg = 12.0
	var tr: Track = Track.create("S", 1, a)
	tr.add_measurement(b)
	tr.add_measurement(miss)
	_assert_eq(fails, "D3 history holds 3 raw objects", str(tr.measurement_history.size()), "3")
	_assert_eq(
		fails, "D3 evidence_count=1 (A/B shared, miss excluded)", str(tr.evidence_count()), "1"
	)
	_assert_eq(fails, "D3 detection_count=1", str(tr.detection_count()), "1")


## D4：主动 bearing+range 单条 Measurement = 一个物理证据（即便 TMA 展开成
## bearing/range 两残差行，物理证据仍计一次）。
func _d4_active_single_evidence(fails: Array) -> void:
	var m := Measurement.new()
	m.timestamp = 20.0
	m.sensor_id = "hull_active"
	m.measurement_type = "ACTIVE_RANGE_BEARING"
	m.detected = true
	m.evidence_id = "ev_AC01"
	m.measured_bearing_deg = 90.0
	m.bearing_sigma_deg = 1.0
	m.measured_range_m = 5000.0
	m.range_sigma_m = 150.0
	var tr: Track = Track.create("P", 1, m)
	_assert_eq(fails, "D4 active evidence_count=1", str(tr.evidence_count()), "1")
	_assert_eq(fails, "D4 active detection_count=1", str(tr.detection_count()), "1")


## D5：to_dict 携带 detected/evidence_id，且不含 target_id（Truth 隔离）。
func _d5_to_dict_truth_isolation(fails: Array) -> void:
	var m := Measurement.new()
	m.measurement_id = 42
	m.timestamp = 5.0
	m.target_id = "secret_target"
	m.evidence_id = "ev_D501"
	m.detected = false
	var d: Dictionary = m.to_dict()
	_assert_eq(fails, "D5 to_dict.evidence_id", str(d.get("evidence_id", "?")), "ev_D501")
	_assert_eq(fails, "D5 to_dict.detected", str(d.get("detected", "?")), "false")
	_assert_bool(fails, "D5 to_dict hides target_id", d.has("target_id"), false)
