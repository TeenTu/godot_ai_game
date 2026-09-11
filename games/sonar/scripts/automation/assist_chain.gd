class_name AssistChain
extends RefCounted
## assist_chain.gd — S1-11 §3.1/§3.2 ASSIST 统一自动链（D-11）。
##
## 把"候选→证据→航迹→分类→TMA"连成一条可解释的数据链：
##   - 只对 detected 样本生成自动 Mark（Pd 数值不算已探测）；
##   - 自动 Mark 标注来源：自动·被动 / 自动·主动 / 自动·鱼雷威胁；
##   - 同一 physical evidence_id 只计一次（拖曳阵 A/B 镜像共享一个证据）；
##   - 跨帧关联复用 Tracker.feed_evidence_group（以证据组为单位，不按单条镜像）；
##   - 关联失败新建候选，不丢证据；
##   - Fit 按 track_id + evidence_revision 缓存（见 FireControlContext.needs_refit），
##     切换目标不清空、不重新抽样。
##
## 本类只消费净化 Measurement / 净化声学证据 DTO，绝不含真值实体或目标内部 ID。

const SRC_PASSIVE := "自动·被动"
const SRC_ACTIVE := "自动·主动"
const SRC_THREAT := "自动·鱼雷威胁"

const ASSOC_GATE_DEG: float = 8.0

var tracker: Tracker = null
## 自动 Mark 台账（审计/UI 来源标签）：[{evidence_id, track_id, source, time, bearing_deg}]
var auto_marks: Array = []
## 已消费的物理证据 id（去重；A/B 镜像共享同一 id）。
var _seen_evidence: Dictionary = {}
var _next_mark_seq: int = 1


func _init(tr: Tracker = null) -> void:
	tracker = tr


func reset() -> void:
	_seen_evidence.clear()
	auto_marks.clear()
	_next_mark_seq = 1


func seen_count() -> int:
	return _seen_evidence.size()


## 摄取一批 Measurement（一次声呐处理的实际 detected 样本）。
## 按 evidence_id 分组成证据组，逐组跨帧关联；返回 {created, appended, marks}。
func ingest_measurements(ms: Array, now_s: float) -> Dictionary:
	var groups: Dictionary = {}
	var order: Array = []
	for m in ms:
		if not (m is Measurement) or not m.detected:
			continue
		var key: String = _key_of(m)
		if _seen_evidence.has(key):
			continue
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		groups[key].append(m)
	var created: int = 0
	var appended: int = 0
	for key in order:
		var grp: Array = groups[key]
		var is_active: bool = _group_is_active(grp)
		var src: String = SRC_ACTIVE if is_active else SRC_PASSIVE
		var t: Track = _ingest_group(grp, src, now_s)
		if t == null:
			continue
		if _was_new(t, key):
			created += 1
		else:
			appended += 1
	return {
		"created": created,
		"appended": appended,
		"marks": auto_marks.slice(auto_marks.size() - order.size())
	}


## 摄取一份净化鱼雷威胁证据（发射瞬态/航行噪声/主动寻的）。
## 只登记来源标签与证据，不在此处改动 Track 结构（TT 由 ThreatTrackManager 建）。
func ingest_threat_evidence(ev: Dictionary, now_s: float) -> bool:
	var eid: String = str(ev.get("evidence_id", ev.get("event_id", "")))
	if eid != "" and _seen_evidence.has(eid):
		return false
	if eid != "":
		_seen_evidence[eid] = true
	var tid: String = str(ev.get("threat_track_id", ""))
	(
		auto_marks
		. append(
			{
				"mark_id": _next_mark_seq,
				"evidence_id": eid,
				"track_id": tid,
				"source": SRC_THREAT,
				"time": now_s,
				"bearing_deg": float(ev.get("bearing_deg", -1.0)),
			}
		)
	)
	_next_mark_seq += 1
	return true


func _ingest_group(grp: Array, src: String, now_s: float) -> Track:
	var key: String = _key_of(grp[0])
	var before: int = tracker.count()
	var t: Track = tracker.feed_evidence_group(grp, "", ASSOC_GATE_DEG)
	if t == null:
		t = tracker.mark(grp[0] as Measurement, "S")
		for j in range(1, grp.size()):
			t.add_measurement(grp[j] as Measurement)
		t.last_association_mode = "auto_new"
	_seen_evidence[key] = true
	if t != null:
		t.auto_mark_sources[src] = int(t.auto_mark_sources.get(src, 0)) + 1
		(
			auto_marks
			. append(
				{
					"mark_id": _next_mark_seq,
					"evidence_id": key,
					"track_id": t.track_id,
					"source": src,
					"time": now_s,
					"bearing_deg": float((grp[0] as Measurement).measured_bearing_deg),
					"new_track": tracker.count() > before,
				}
			)
		)
		_next_mark_seq += 1
	return t


func _was_new(_t: Track, _key: String) -> bool:
	var last: Dictionary = auto_marks[auto_marks.size() - 1]
	return bool(last.get("new_track", false))


func _group_is_active(grp: Array) -> bool:
	for m in grp:
		if m is Measurement and (m as Measurement).has_range():
			return true
	return false


func _key_of(m: Measurement) -> String:
	return m.evidence_id if m.evidence_id != "" else "obj_%d" % m.measurement_id
