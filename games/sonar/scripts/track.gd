class_name Track
extends RefCounted
## track.gd — 接触航迹（Track 层）。
##
## 玩家掌握的接触航迹：把来自一个或多个传感器的 Measurement 聚合成一条航迹。
## 这是"Measurement 之上的聚合"，不是 Truth。玩家通过 Mark / Tracker 创建。
##
## 接触编号（Track ID）方案：
##   S01  声呐接触（sonar）
##   E01  电子支援接触（ESM）
##   R01  雷达接触（radar）
##   V01  目视/潜望镜接触（visual）
##   M01  多传感器合并后的 Master Track
##
## 关键不变量：
##   - 保存每条 Measurement 的测量时间戳 + 当时本艇位置（LOB 起点），
##     绝不能从"当前时刻本艇位置"补算历史 LOB。
##   - 接触丢失后进入"失去接触"状态，不得凭空继续生成精确测量。

enum TrackState {
	ACTIVE,  # 正在持续跟踪
	LOST,  # 失去接触（不再产生新测量）
	MERGED,  # 已合并进 Master Track
}

## REQ-DEP-01：深度评估状态（独立估计/假设，绝不是精确水深）。仅当存在有噪
## 深度观测模型（俯仰测角/多路径/多深度观测）时才允许离开 UNKNOWN；BB/NB/
## 主动 Ping 距离均不能唯一解深度。默认 UNKNOWN，绝不编码成 0 m 或 UPPER。
const DEPTH_ASSESSMENT_UNKNOWN := "UNKNOWN"
const DEPTH_ASSESSMENT_SURFACE := "SURFACE_LIKELY"
const DEPTH_ASSESSMENT_UPPER := "UPPER_LIKELY"
const DEPTH_ASSESSMENT_LOWER := "LOWER_LIKELY"

var track_id: String = ""  # 如 "S01"、"M01"
var source_type: String = "S"  # S/E/R/V/M
var measurement_history: Array = []  # 按时间排序的 Measurement 数组
var source_sensors: Array = []  # 参与本航迹的 sensor_id 列表
var classification_probabilities: Dictionary = {}  # class_id -> 概率
var affiliation: String = "unknown"  # friend/foe/neutral/unknown
var kinematic_hypotheses: Array = []  # 各候选 TMA 假设（后续）
var last_update_time: float = -1.0
var staleness: float = 0.0  # 距上次更新的秒数
var merged_track_ids: Array = []  # 若为 Master Track，记录合并进来的子航迹
var state: int = TrackState.ACTIVE
var origin_time: float = 0.0  # 首次 Mark 的时间
## S1-04C-REQ-03/06：最近一次关联的置信度 0..1（由 Tracker 评分写入，
## 无 range 参考的方位退化关联会偏低；Contact 行显示用）。
var association_confidence: float = 0.0
## S1-04C-REQ-03：最近一次关联的评分模式（Tracker 写入）：
##   "range"        新测量带测距且 Track 有最后有效测距 → 双测距门控
##   "predicted"    Track 无测距历史但有有效 TMA 预测测距 → 预测门控
##   "bearing_only" 纯方位退化关联（无任何 range 参照）
var last_association_mode: String = "bearing_only"
## 最近一次关联的归一化评分 d²（越小越紧；无关联时保持大值）。
var last_association_score: float = 1.0e9

var depth_assessment: String = DEPTH_ASSESSMENT_UNKNOWN
var depth_assessment_source: String = ""  # 观测模型/来源标签（如 "PITCH_ANGLE"）
var depth_assessment_confidence: float = 0.0  # 0..1
var depth_assessment_updated_s: float = -1.0


## 更新深度评估。仅接受四个合法状态；来源/置信度必填，供 UI 展示假设依据。
func update_depth_assessment(
	state: String, source: String, confidence: float, now_s: float
) -> bool:
	if (
		state
		not in [
			DEPTH_ASSESSMENT_UNKNOWN,
			DEPTH_ASSESSMENT_SURFACE,
			DEPTH_ASSESSMENT_UPPER,
			DEPTH_ASSESSMENT_LOWER,
		]
	):
		return false
	depth_assessment = state
	depth_assessment_source = source
	depth_assessment_confidence = clampf(confidence, 0.0, 1.0)
	depth_assessment_updated_s = now_s
	return true


## UI/预填建议用摘要（假设 + 依据；不含任何精确深度数值）。
func depth_assessment_summary() -> Dictionary:
	return {
		"state": depth_assessment,
		"source": depth_assessment_source,
		"confidence": depth_assessment_confidence,
		"updated_s": depth_assessment_updated_s,
	}


## 创建一个新接触。source_type 取 "S"/"E"/"R"/"V"/"M"。
## counter 用于生成编号（外部传入，保证全局递增）。
static func create(source_type: String, counter: int, initial_m: Measurement) -> Track:
	var t := Track.new()
	t.source_type = source_type
	t.track_id = "%s%02d" % [source_type, counter]
	t.origin_time = initial_m.timestamp
	t.add_measurement(initial_m)
	return t


## 追加一条测量。维护时间排序、传感器来源、更新时间。
func add_measurement(m: Measurement) -> void:
	measurement_history.append(m)
	# 按时间排序（通常已有序，但保险起见）
	measurement_history.sort_custom(
		func(a: Measurement, b: Measurement) -> bool: return a.timestamp < b.timestamp
	)
	if not source_sensors.has(m.sensor_id):
		source_sensors.append(m.sensor_id)
	last_update_time = m.timestamp
	staleness = 0.0
	state = TrackState.ACTIVE


## 最近一次测量。
func latest_measurement() -> Measurement:
	if measurement_history.is_empty():
		return null
	return measurement_history[measurement_history.size() - 1]


## REQ-09：时刻 t 的预测方位（历史行关联用）。以最近两条测量的方位率线性
## 外推到 t（测量时间与点击行时间一致——不能只比较最新方位）；只有一条
## 测量时直接返回其方位；无测量返回 -1。
func predicted_bearing_at(t: float) -> float:
	var n: int = measurement_history.size()
	if n == 0:
		return -1.0
	if n == 1:
		return measurement_history[0].measured_bearing_deg
	var m1: Measurement = measurement_history[n - 1]
	var m0: Measurement = measurement_history[n - 2]
	var dt: float = m1.timestamp - m0.timestamp
	var rate: float = 0.0
	if dt > 0.01:
		rate = NavUtils.wrap180(m1.measured_bearing_deg - m0.measured_bearing_deg) / dt
	return NavUtils.wrap360(m1.measured_bearing_deg + rate * (t - m1.timestamp))


## 移除一条测量（S1-04C 撤销自动关联/改绑）。维护时间排序与更新时间。
## 找不到时返回 false；移除后空历史保留（由调用方决定是否弃用 Track）。
func remove_measurement(m: Measurement) -> bool:
	var idx: int = measurement_history.find(m)
	if idx < 0:
		return false
	measurement_history.remove_at(idx)
	# 重算 last_update_time（可能已非 ACTIVE 语义由调用方处理）
	if measurement_history.is_empty():
		last_update_time = -1.0
	else:
		var last: Measurement = measurement_history[measurement_history.size() - 1]
		last_update_time = last.timestamp
	return true


## 最早一次测量（Mark 点）。
func first_measurement() -> Measurement:
	if measurement_history.is_empty():
		return null
	return measurement_history[0]


## S1-04C-REQ-03：最后一次"有效测距"的测量。
## 最新测量可能只是纯方位被动（无 range），但 Track 此前曾收到过主动测距；
## 关联测距门控做协方差比较（σRc² = σR_new² + σR_last_valid² + σmotion²）时
## 必须用它而不是 latest_measurement()。无测距历史时返回 null。
func last_valid_range_measurement() -> Measurement:
	for i in range(measurement_history.size() - 1, -1, -1):
		var m: Measurement = measurement_history[i]
		if m.has_range():
			return m
	return null


## 有效物理证据数（S1-00-REQ-02）：按去重 evidence_id 统计，A/B 镜像共享
## 一次物理到达只计一次；主动 bearing+range 单条 Measurement 也是一个证据。
## 旧数据/手工测量无 evidence_id 时按 measurement_id 兜底（各计一次）。
func evidence_count() -> int:
	var ids: Dictionary = {}
	for m in measurement_history:
		if not m.detected:
			continue  # miss 样本不得计入（GAP-DATA-01）
		var key: String = m.evidence_id if m.evidence_id != "" else "obj_%d" % m.measurement_id
		ids[key] = true
	return ids.size()


## 有效探测数（= 去重物理证据数；GAP-DATA-03：不再用 Pd>0 近似，也不再
## 把 A/B 镜像当两次独立探测）。
func detection_count() -> int:
	return evidence_count()


## 标记失去接触。
func mark_lost() -> void:
	state = TrackState.LOST


## 标记已合并进某个 Master Track。
func mark_merged(master_id: String) -> void:
	state = TrackState.MERGED
	merged_track_ids.append(master_id)


## 推进陈旧度（每秒调用）。若已失去接触则增加 staleness。
func update_staleness(dt: float) -> void:
	if state == TrackState.ACTIVE:
		staleness = 0.0
	else:
		staleness += dt


## 是否"有效可用"（未合并，且未长时间失去接触）。
func is_usable(max_stale_s: float = 30.0) -> bool:
	if state == TrackState.MERGED:
		return false
	if state == TrackState.LOST:
		return staleness <= max_stale_s
	return true
