class_name MeasurementGenerator
extends RefCounted
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
var _env: RefCounted = null  # EnvironmentModel
var _own_profile: RefCounted = null  # 本艇 AcousticProfile（用于自噪由传感器侧自理，这里无需）
var _measurement_counter: int = 0
var _evidence_counter: int = 0  # S1-00：每次物理到达发唯一 evidence_id


func setup(rng: RandomNumberGenerator, env: RefCounted) -> void:
	_rng = rng
	_env = env


## S1-00：为一次物理到达铸造唯一证据 id（A/B 镜像由调用方共享）。
func _next_evidence_id() -> String:
	_evidence_counter += 1
	return "ev_%05d" % _evidence_counter


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

	var true_bearing: float = NavUtils.bearing_to_true(
		observer.position_east_m,
		observer.position_north_m,
		target.position_east_m,
		target.position_north_m
	)
	var rng_range: float = NavUtils.distance(
		observer.position_east_m,
		observer.position_north_m,
		target.position_east_m,
		target.position_north_m
	)
	var freq_hz: float = (sensor.frequency_range.x + sensor.frequency_range.y) * 0.5

	# 目标当前宽带声源级
	var target_sl: float = target_ac.broadband_sl_db(target.speed_kn, target.depth_m)

	# 被动 SE（传感器内部会叠加本艇自噪）
	var se: float = sensor.passive_signal_excess(
		target_sl, rng_range, freq_hz, _env, observer.speed_kn
	)
	# S1-07A（Commit 2）：跨温跃层附加 TL（同层/旧场景 = 0，零行为变化）。
	se -= _env.cross_layer_extra_db(freq_hz, float(observer.depth_m), float(target.depth_m))

	# 概率探测
	var pd: float = sensor.detection_probability(se)
	# S1-03C-P1-03/REQ-08：coverage/baffle 真正参与自动链——覆盖扇区外或挡板
	# 盲区内的目标恒为 miss（detected=false）。旧实现 SensorArray.in_coverage()
	# 无任何调用方，场景 JSON 声明的覆盖角/盲区形同虚设（BOW/FLANK 全向）。
	# 覆盖判断放在 pd 采样之后，保持 RNG 消耗序列不变（全向覆盖场景零行为变化）。
	var in_cov: bool = sensor.in_coverage(
		NavUtils.wrap360(true_bearing - float(observer.course_deg))
	)
	var detected: bool = _rng.randf() < pd and in_cov

	# 生成观测（未探测到时 detected=false——这是"miss"，必须由 World/UI/
	# Tracker 三层过滤，绝不携带未加噪的真方位进入玩家链，GAP-DATA-01）。
	m.measurement_id = _measurement_counter
	_measurement_counter += 1
	m.timestamp = timestamp
	m.sensor_id = sensor.sensor_id
	m.target_id = target.id
	m.measurement_type = "PASSIVE_BEARING"
	m.available_time = timestamp
	m.detected = detected
	m.evidence_id = _next_evidence_id()
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


## 生成对某目标的主动观测（方位＋距离，ACTIVE_RANGE_BEARING）。
## S1-04B-REQ-19 往返测距同源：range_ref_m>0 时，measured_range_m 以发射时刻
## 登记距离（=c(t_return-t_emit)/2 的静态近似）为基准加噪声，绝不回填到达时刻
## 的当前 Truth 距离；目标在往返 τ 内的位移进入 range_sigma_m（移动近似误差）。
func generate_active(
	observer: RefCounted,
	target: RefCounted,
	target_ac: RefCounted,
	sensor: RefCounted,
	ping_sl_db: float,
	timestamp: float,
	ping_id: int = -1,
	range_ref_m: float = -1.0,
	range_ref_time_s: float = -1.0
) -> Measurement:
	var m := Measurement.new()

	var true_bearing: float = NavUtils.bearing_to_true(
		observer.position_east_m,
		observer.position_north_m,
		target.position_east_m,
		target.position_north_m
	)
	var rng_range: float = NavUtils.distance(
		observer.position_east_m,
		observer.position_north_m,
		target.position_east_m,
		target.position_north_m
	)
	var freq_hz: float = (sensor.frequency_range.x + sensor.frequency_range.y) * 0.5

	var se: float = sensor.active_signal_excess(
		ping_sl_db, target_ac.active_target_strength_db, rng_range, freq_hz, _env, observer.speed_kn
	)
	# S1-07A：主动双程跨层（去程+回程同源同深度对 → 2×单程附加；旧场景 = 0）。
	var xl: float = _env.cross_layer_extra_db(
		freq_hz, float(observer.depth_m), float(target.depth_m)
	)
	se -= 2.0 * xl
	var pd: float = sensor.detection_probability(se)
	var detected: bool = _rng.randf() < pd

	m.measurement_id = _measurement_counter
	_measurement_counter += 1
	m.timestamp = timestamp
	m.sensor_id = sensor.sensor_id
	m.target_id = target.id
	m.measurement_type = "ACTIVE_RANGE_BEARING"
	m.ping_id = ping_id
	m.available_time = timestamp
	m.detected = detected
	m.evidence_id = _next_evidence_id()
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
		if range_ref_m > 0.0:
			# 测距即测时：以发射时刻登记的几何距离为基准（往返测距同源）。
			# τ 内目标位移的保守径向项并入 σ（R=cτ/2 仅对静止目标严格成立）。
			var drift: float = 0.0
			if range_ref_time_s > 0.0:
				drift = (absf(timestamp - range_ref_time_s) * NavUtils.kn_to_ms(target.speed_kn))
			range_sigma = sqrt(range_sigma * range_sigma + drift * drift)
			m.measured_range_m = range_ref_m + _rng.randfn(0.0, range_sigma)
		else:
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
			(
				lines
				. append(
					{
						"freq_hz": float(t.get("freq_hz", 0.0)),
						"level_db": base_level,
						"snr_db": base_level + se_db,
					}
				)
			)
	return lines
