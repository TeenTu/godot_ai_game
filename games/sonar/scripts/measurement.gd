class_name Measurement
extends RefCounted
## measurement.gd — 一次传感器观测记录（Measurement 层）。
## 注意：LOB 必须从"测量时刻本艇所在位置"发出，记录在该结构里，
## 不能从当前时刻本艇位置发出。

var measurement_id: int = 0
var timestamp: float = 0.0
var sensor_id: String = ""
var target_id: String = ""  # 对应 Truth 实体（仅供内部统计/测试钩子，不进玩家信息流）
var measurement_type: String = "PASSIVE_BEARING"  # PASSIVE_BEARING / ACTIVE_RANGE_BEARING
var ping_id: int = -1  # 主动回波所属 PingSession（被动为 -1）
var available_time: float = -1.0  # 对接收机"可用"时刻（主动回波=到达时刻；被动=timestamp）

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

# ---- 拖曳线阵左右舷镜像歧义（S1-03A）----
# 同一次声学到达产生 A/B 两个候选方位（共享证据），pair_id 相同：
#   ambiguity_branch: 0=无歧义；+1=A 支；-1=B 支（关于阵轴镜像）
#   array_heading_at_measurement_deg / array_center_* / actual_tow_length_m:
#   测量时刻的阵轴/阵列声学中心/实际缆长——TMA 不得用当前阵位回填历史。
var ambiguous_pair_id: String = ""
var ambiguity_branch: int = 0
var ambiguity_resolved: bool = false
var array_heading_at_measurement_deg: float = 0.0
var array_center_east_m: float = 0.0
var array_center_north_m: float = 0.0
var actual_tow_length_m: float = 0.0


## 是否属于拖曳阵镜像歧义组（A/B 共享证据）。
func has_ambiguity() -> bool:
	return ambiguous_pair_id != "" and ambiguity_branch != 0


## 是否带有测距信息（主动声呐或有源目标）。
## 统一判据（S1-04B-REQ-02）：距离与误差必须同时有效，禁止只给距离不给 σ。
func has_range() -> bool:
	return measured_range_m >= 0.0 and range_sigma_m > 0.0


func to_dict() -> Dictionary:
	# Truth 隔离（S1-04B-REQ-03）：玩家信息流不含 target_id；需要 Truth 对照的
	# 测试走独立 debug 钩子（Measurement.target_id 字段本身保留给内部/测试）。
	return {
		"id": measurement_id,
		"timestamp": timestamp,
		"sensor_id": sensor_id,
		"measurement_type": measurement_type,
		"ping_id": ping_id,
		"available_time": available_time,
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
		"ambiguous_pair_id": ambiguous_pair_id,
		"ambiguity_branch": ambiguity_branch,
		"ambiguity_resolved": ambiguity_resolved,
		"array_heading_deg": array_heading_at_measurement_deg,
		"array_center_e": array_center_east_m,
		"array_center_n": array_center_north_m,
		"tow_length_m": actual_tow_length_m,
	}
