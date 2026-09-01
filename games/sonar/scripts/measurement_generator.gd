extends RefCounted
class_name MeasurementGenerator
## measurement_generator.gd — Truth → Measurement 的唯一通道。
##
## 把"真实目标(Truth)"经声学辐射→传播→传感器变成"观测(Measurement)"。
## 这是数据链上隔离 Truth 与玩家可见世界的核心关卡：
##   1) 计算目标当前声源级 SL
##   2) 用被动/主动声呐方程算 SE
##   3) 概率探测决定是否报出接触
##   4) 加方位噪声（含间歇/误报）生成 Measurement
##
## 所有随机走注入的 RNG，固定种子 → 固定测量流。

var _rng: RandomNumberGenerator = null
var _env: RefCounted = null          # EnvironmentModel
var _own_profile: RefCounted = null  # 本艇 AcousticProfile（用于自噪由传感器侧自理，这里无需）
var _measurement_counter: int = 0


func setup(rng: RandomNumberGenerator, env: RefCounted) -> void:
	_rng = rng
	_env = env


## 生成对某目标的被动观测（无测距，纯 LOB）。
## - observer: TruthEntity（本艇，提供位置）
## - observer_speed_kn: 本艇当前航速（自噪用，传感器侧已含，此处只算 SE 参考）
## - target: TruthEntity（目标）
## - target_ac: AcousticProfile（目标声学特征）
## - sensor: SensorArray
## - timestamp: 内部秒
func generate_passive(
	observer: RefCounted,
	target: RefCounted,
	target_ac: RefCounted,
	sensor: RefCounted,
	timestamp: float
) -> Measurement:
	var m := Measurement.new()

	var true_bearing: float = nav_utils.bearing_to_true(
		observer.position_east_m, observer.position_north_m,
		target.position_east_m, target.position_north_m
	)
	var rng_range: float = nav_utils.distance(
		observer.position_east_m, observer.position_north_m,
		target.position_east_m, target.position_north_m
	)
	var freq_hz: float = (sensor.frequency_range.x + sensor.frequency_range.y) * 0.5

	# 目标当前宽带声源级
	var target_sl: float = target_ac.broadband_sl_db(target.speed_kn, target.depth_m)

	# 被动 SE（传感器内部会叠加本艇自噪）
	var se: float = sensor.passive_signal_excess(
		target_sl, rng_range, freq_hz, _env, observer.speed_kn
	)

	# 概率探测
	var pd: float = sensor.detection_probability(se)
	var detected: bool = _rng.randf() < pd

	# 生成观测（即使未探测到，也生成一条空测量供 UI 做"间歇"表现）
	m.measurement_id = _measurement_counter
	_measurement_counter += 1
	m.timestamp = timestamp
	m.sensor_id = sensor.sensor_id
	m.target_id = target.id
	m.observer_east_m = observer.position_east_m
	m.observer_north_m = observer.position_north_m
	m.measured_bearing_deg = true_bearing
	m.bearing_sigma_deg = sensor.bearing_sigma_deg(se)
	m.signal_excess_db = se
	m.detection_probability = pd

	if detected:
		var nb: Dictionary = sensor.noisy_bearing(true_bearing, se)
		m.measured_bearing_deg = nb["bearing"]
		m.bearing_sigma_deg = nb["sigma"]
		m.detected_frequencies = _build_lofar(target_ac, se)
		m.snr_db = se  # 简化：SNR ≈ SE（基准化）

	return m


## 生成对某目标的主动观测（带测距）。
func generate_active(
	observer: RefCounted,
	target: RefCounted,
	target_ac: RefCounted,
	sensor: RefCounted,
	ping_sl_db: float,
	timestamp: float
) -> Measurement:
	var m := Measurement.new()

	var true_bearing: float = nav_utils.bearing_to_true(
		observer.position_east_m, observer.position_north_m,
		target.position_east_m, target.position_north_m
	)
	var rng_range: float = nav_utils.distance(
		observer.position_east_m, observer.position_north_m,
		target.position_east_m, target.position_north_m
	)
	var freq_hz: float = (sensor.frequency_range.x + sensor.frequency_range.y) * 0.5

	var se: float = sensor.active_signal_excess(
		ping_sl_db, target_ac.active_target_strength_db, rng_range, freq_hz, _env, observer.speed_kn
	)
	var pd: float = sensor.detection_probability(se)
	var detected: bool = _rng.randf() < pd

	m.measurement_id = _measurement_counter
	_measurement_counter += 1
	m.timestamp = timestamp
	m.sensor_id = sensor.sensor_id
	m.target_id = target.id
	m.observer_east_m = observer.position_east_m
	m.observer_north_m = observer.position_north_m
	m.measured_bearing_deg = true_bearing
	m.bearing_sigma_deg = sensor.bearing_sigma_deg(se)
	m.signal_excess_db = se
	m.detection_probability = pd

	if detected:
		var nb: Dictionary = sensor.noisy_bearing(true_bearing, se)
		m.measured_bearing_deg = nb["bearing"]
		m.bearing_sigma_deg = nb["sigma"]
		# 主动声呐带测距，误差随 SE 变化
		var range_sigma: float = rng_range * 0.02 + (1.0 / maxf(se, 0.1)) * 30.0
		m.measured_range_m = rng_range + _rng.randfn(0.0, range_sigma)
		m.range_sigma_m = range_sigma
		m.detected_frequencies = _build_lofar(target_ac, se)
		m.snr_db = se

	return m


## 构建窄带 Lofar 谱线。SE 越高，谱线越完整。
func _build_lofar(target_ac: RefCounted, se_db: float) -> Array:
	var lines: Array = []
	for t in target_ac.tonal_lines:
		var base_level: float = float(t.get("level_db", 0.0))
		# 探测到的概率随 SE 提高（谱线完整度）
		var detect_p: float = 1.0 / (1.0 + exp(-(se_db - 3.0) / 3.0))
		if _rng.randf() < detect_p:
			lines.append({
				"freq_hz": float(t.get("freq_hz", 0.0)),
				"level_db": base_level,
				"snr_db": base_level + se_db,
			})
	return lines
