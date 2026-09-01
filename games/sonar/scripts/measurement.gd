class_name Measurement
extends RefCounted
## measurement.gd — 一次传感器观测记录（Measurement 层）。
## 注意：LOB 必须从"测量时刻本艇所在位置"发出，记录在该结构里，
## 不能从当前时刻本艇位置发出。

var measurement_id: int = 0
var timestamp: float = 0.0
var sensor_id: String = ""
var target_id: String = ""  # 对应 Truth 实体（仅供内部统计/测试）

var observer_east_m: float = 0.0  # 测量时刻本艇位置
var observer_north_m: float = 0.0

var measured_bearing_deg: float = 0.0
var bearing_sigma_deg: float = 0.0

var measured_range_m: float = -1.0  # -1 表示无测距（纯被动 LOB）
var range_sigma_m: float = -1.0

var signal_excess_db: float = 0.0
var snr_db: float = 0.0
var detection_probability: float = 0.0

var detected_frequencies: Array = []  # [{freq_hz, level_db, snr_db}]
var classification_features: Dictionary = {}
var ambiguous_pair_id: String = ""


## 是否带有测距信息（主动声呐或有源目标）。
func has_range() -> bool:
	return measured_range_m >= 0.0


func to_dict() -> Dictionary:
	return {
		"id": measurement_id,
		"timestamp": timestamp,
		"sensor_id": sensor_id,
		"target_id": target_id,
		"observer_east_m": observer_east_m,
		"observer_north_m": observer_north_m,
		"bearing_deg": measured_bearing_deg,
		"bearing_sigma_deg": bearing_sigma_deg,
		"range_m": measured_range_m,
		"range_sigma_m": range_sigma_m,
		"se_db": signal_excess_db,
		"snr_db": snr_db,
		"pd": detection_probability,
		"frequencies": detected_frequencies,
	}
