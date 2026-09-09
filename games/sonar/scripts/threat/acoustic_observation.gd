class_name AcousticObservation
extends RefCounted
## acoustic_observation.gd — S109 §2.2 声学观测不可变 DTO。
##
## SensorAdapter 边界内允许读取 Truth 生成带误差观测；离开边界时必须构造成
## 本结构（或其 to_dict()）：只含接收端可观测量（加噪/量化后的估计值），
## 绝不含 §2.3 禁止字段（target_id / emission_kind / Truth 位置与运动参数 /
## 内部引用）。forbidden_keys() 供静态扫描与序列化断言（AT-02）共用。

const FORBIDDEN_KEYS := [
	"target_id",
	"internal_token",
	"emitter_internal_ref",
	"target_ref",
	"source_ref",
	"platform_kind",
	"emission_kind",
	"position_east_m",
	"position_north_m",
	"true_bearing_deg",
	"true_range_m",
	"true_course_deg",
	"true_speed_kn",
	"true_depth_m",
	"seeker_target_internal_ref",
	"source_position_internal",
	"source_depth_internal",
]

# 允许字段（§2.2）。带默认值 = 必备；null = 可选。
const ALLOWED_KEYS := [
	"evidence_id",
	"timestamp",
	"available_time",
	"sensor_id",
	"observer_e_m",
	"observer_n_m",
	"observer_course_deg",
	"measured_bearing_deg",
	"bearing_sigma_deg",
	"measured_range_m",
	"range_sigma_m",
	"signal_excess_db",
	"detection_probability",
	"received_level_db",
	"noise_level_db",
	"measured_band_min_hz",
	"measured_band_max_hz",
	"spectral_centroid_hz",
	"spectral_spread_hz",
	"tonal_peaks",
	"modulation_peaks_hz",
	"pulse_width_s",
	"pulse_interval_s",
	"transient_rise_s",
	"transient_duration_s",
	"doppler_hz",
	"source_path",
]

var evidence_id: int = 0
var timestamp: float = 0.0
var available_time: float = 0.0
var sensor_id: String = ""
var observer_e_m: float = 0.0
var observer_n_m: float = 0.0
var observer_course_deg: float = 0.0
var measured_bearing_deg: float = 0.0
var bearing_sigma_deg: float = 2.0
var measured_range_m: Variant = null
var range_sigma_m: Variant = null
var signal_excess_db: float = 0.0
var detection_probability: float = 0.0
var measured_band_min_hz: float = 0.0
var measured_band_max_hz: float = 0.0
var spectral_centroid_hz: Variant = null
var spectral_spread_hz: Variant = null
var tonal_peaks: Array = []
var pulse_width_s: Variant = null
var pulse_interval_s: Variant = null
var transient_duration_s: Variant = null
var source_path: String = "PASSIVE_SONAR"


## 事件特征 → 观测（仅 SensorAdapter 内部调用）：特征一律加噪/量化，
## 绝不复制发射端配置原值。est 为 {"center_frequency_hz","bandwidth_hz",
## "duration_s","tonal_count"}（接收端估计值，已含噪声）。
static func from_event_features(
	id: int,
	now: float,
	sensor: String,
	obs_e: float,
	obs_n: float,
	brg: float,
	sigma: float,
	se: float,
	pd: float,
	est: Dictionary,
	path: String
) -> AcousticObservation:
	var o := AcousticObservation.new()
	o.evidence_id = id
	o.timestamp = now
	o.available_time = now
	o.sensor_id = sensor
	o.observer_e_m = obs_e
	o.observer_n_m = obs_n
	o.measured_bearing_deg = brg
	o.bearing_sigma_deg = sigma
	o.signal_excess_db = se
	o.detection_probability = pd
	var f: float = float(est.get("center_frequency_hz", 0.0))
	var bw: float = float(est.get("bandwidth_hz", 0.0))
	# 宽带低频源的频带下限会被物理下界截断——分类用谱重心/谱展宽
	#（无截断失真），频带仅作显示/参考。
	o.spectral_centroid_hz = f
	o.spectral_spread_hz = bw
	o.measured_band_min_hz = maxf(f - 0.5 * bw, 1.0)
	o.measured_band_max_hz = f + 0.5 * bw
	o.tonal_peaks = est.get("tonal_peaks", [])
	var dur: Variant = est.get("duration_s", null)
	if dur != null:
		o.transient_duration_s = dur
		# 短脉冲（主动寻的脉冲）与连续机械噪声的区分特征。
		if float(dur) <= 0.5:
			o.pulse_width_s = dur
	o.source_path = path
	return o


func to_dict() -> Dictionary:
	var d := {
		"evidence_id": evidence_id,
		"timestamp": timestamp,
		"available_time": available_time,
		"sensor_id": sensor_id,
		"observer_e_m": observer_e_m,
		"observer_n_m": observer_n_m,
		"observer_course_deg": observer_course_deg,
		"measured_bearing_deg": measured_bearing_deg,
		"bearing_sigma_deg": bearing_sigma_deg,
		"signal_excess_db": signal_excess_db,
		"detection_probability": detection_probability,
		"measured_band_min_hz": measured_band_min_hz,
		"measured_band_max_hz": measured_band_max_hz,
		"tonal_peaks": (tonal_peaks as Array).duplicate(),
		"source_path": source_path,
	}
	if measured_range_m != null:
		d["measured_range_m"] = measured_range_m
	if range_sigma_m != null:
		d["range_sigma_m"] = range_sigma_m
	if spectral_centroid_hz != null:
		d["spectral_centroid_hz"] = spectral_centroid_hz
	if spectral_spread_hz != null:
		d["spectral_spread_hz"] = spectral_spread_hz
	if pulse_width_s != null:
		d["pulse_width_s"] = pulse_width_s
	if pulse_interval_s != null:
		d["pulse_interval_s"] = pulse_interval_s
	if transient_duration_s != null:
		d["transient_duration_s"] = transient_duration_s
	return d
