class_name Measurement
extends RefCounted
## measurement.gd — 一次传感器观测记录（Measurement 层）。
## 注意：LOB 必须从"测量时刻本艇所在位置"发出，记录在该结构里，
## 不能从当前时刻本艇位置发出。

var measurement_id: int = 0
var timestamp: float = 0.0
var sensor_id: String = ""
# S109 P0-06：玩法层 Measurement 结构性不含 target_id / 内部身份。Truth 对照
# 需求走测量发生器的 identity_by_evidence 调试台账（Debrief/测试专用）。
var measurement_type: String = "PASSIVE_BEARING"  # PASSIVE_BEARING / ACTIVE_RANGE_BEARING
var ping_id: int = -1  # 主动回波所属 PingSession（被动为 -1）
var available_time: float = -1.0  # 对接收机"可用"时刻（主动回波=到达时刻；被动=timestamp）

# ---- S1-00 证据契约（GAP-DATA-01/03）----
# detected：本次概率抽样是否真的探测到。false = miss（未探测样本），禁止
#   append 进 World.measurements / 喂 Tracker / 进 TMA（Truth 泄漏源头）。
# evidence_id：一次物理到达的唯一证据 id。拖曳阵 A/B 镜像（同一 physical
#   到达的两个候选）共享同一 evidence_id；主动 bearing+range 单条 Measurement
#   也是一个 evidence（TMA 内部展开成两行 residual component）。计数/统计
#   一律按去重 evidence_id，绝不用"测量对象数"或 Pd>0 近似。
var detected: bool = true
var evidence_id: String = ""

var observer_east_m: float = 0.0  # 测量时刻本艇位置
var observer_north_m: float = 0.0

var measured_bearing_deg: float = 0.0
var bearing_sigma_deg: float = 0.0

var measured_range_m: float = -1.0  # -1 表示无测距（纯被动 LOB）
var range_sigma_m: float = -1.0

var signal_excess_db: float = 0.0
var snr_db: float = 0.0
var detection_probability: float = 0.0

# PG-02 统一谱线 DTO：规范形式是 [{freq_hz, level_db?, snr_db?}]（SpectralFeature）。
# 被动操作员 Mark 的谱线历史上是纯数值数组（峰上的 freqs_hz），两种形式都会
# 出现在 detected_frequencies 里——消费方一律走 spectral_freqs()/spectral_features()
# 归一化，禁止直接 float(元素)（字典会运行时报错）。
var detected_frequencies: Array = []
var classification_features: Dictionary = {}

# MK-03：本次记录是"纯人工假设"（玩家在瀑布数据区自由落点，未命中任何实测峰）。
# 它仍是一条合法方位证据（进 TMA、可发射），但不得被当成自动探测成功：
# 不给它虚构高 SE/Pd，也不让它单独推动目标分类升级。
var manual_hypothesis: bool = false

## 是否属于拖曳阵镜像歧义组（A/B 共享证据）。
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
		"detected": detected,
		"evidence_id": evidence_id,
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
		"manual_hypothesis": manual_hypothesis,
		"ambiguous_pair_id": ambiguous_pair_id,
		"ambiguity_branch": ambiguity_branch,
		"ambiguity_resolved": ambiguity_resolved,
		"array_heading_deg": array_heading_at_measurement_deg,
		"array_center_e": array_center_east_m,
		"array_center_n": array_center_north_m,
		"tow_length_m": actual_tow_length_m,
	}


## PG-02：把一个谱线数组归一化成 SpectralFeature DTO 列表。
## 输入允许规范字典、纯数值（旧式）或混合；无有效 freq_hz 的条目直接丢弃，
## 而不是塞 NAN/0 进后续评分。空输入 → 空数组（"无谱线"≠"确定不匹配"）。
static func spectral_features(list: Array) -> Array:
	var out: Array = []
	for f in list:
		var hz: float = NAN
		var lvl: float = NAN
		var snr: float = NAN
		if f is Dictionary:
			hz = float(f.get("freq_hz", NAN))
			lvl = float(f.get("level_db", NAN))
			snr = float(f.get("snr_db", NAN))
		elif f is float or f is int:
			hz = float(f)
		if not is_finite(hz):
			continue
		var dto: Dictionary = {"freq_hz": hz}
		if is_finite(lvl):
			dto["level_db"] = lvl
		if is_finite(snr):
			dto["snr_db"] = snr
		out.append(dto)
	return out


## PG-02：评分前提取有限数值 freq_hz（关联器只比较频率，不比较电平）。
static func spectral_freqs(list: Array) -> Array:
	var out: Array = []
	for dto in spectral_features(list):
		out.append(float((dto as Dictionary)["freq_hz"]))
	return out
