class_name TrackClassification
extends RefCounted
## track_classification.gd — S1-11 §3.7 概率分类与渐进标签（D-15）。
##
## 渐进标签：未知接触 → 疑似潜艇/疑似鱼雷/疑似诱饵 → 高可信分类。
## 只消费可测特征：实测频带/窄带谱线稳定性、宽带特征、主动脉冲、Doppler/方位率、
## 发射瞬态、航行噪声事件。绝不读取真值实体或目标内部 ID。
##
## 纪律：
##   - 单次回波（<2 条独立证据）最多给出"疑似"，不得直接揭示真实实体名称；
##   - 同一 physical evidence_id 只计一次（拖曳阵 A/B 镜像共享）；
##   - 概率随新证据升级或降级，界面同时显示置信度与依据；
##   - 低置信度一律回落"未知接触"。

const SUBMARINE := "SUBMARINE"
const TORPEDO := "TORPEDO"
const DECOY := "DECOY"
const SURFACE := "SURFACE"
const UNKNOWN := "UNKNOWN"

const CLASSES: Array = [SUBMARINE, TORPEDO, DECOY, SURFACE]

const STATE_UNKNOWN := "UNKNOWN"
const STATE_SUSPECT := "SUSPECT"
const STATE_CLASSIFIED := "CLASSIFIED"

## 置信度分档（§7.4 同风格）：<0.55 未知；0.55–0.75 疑似；>0.75 高可信。
const SUSPECT_THRESHOLD := 0.55
const CLASSIFIED_THRESHOLD := 0.75
## 最少独立证据数：低于此值强制不高于"疑似"（AT-60）。
const MIN_EVIDENCE_FOR_CLASSIFIED := 2

const CLASS_NAMES := {
	SUBMARINE: "潜艇",
	TORPEDO: "鱼雷",
	DECOY: "诱饵",
	SURFACE: "水面舰",
	UNKNOWN: "未知",
}

## 净化证据层的线索类型（EmissionSanitizer / TorpedoClassifier 输出；不使用内核事件枚举）。
const TORPEDO_KINDS: Array = ["LAUNCH_TRANSIENT", "RUNNING_NOISE", "ACTIVE_PING"]
const DECOY_KINDS: Array = ["DECOY"]


## 主入口：对一条 Track 生成 ClassificationAssessment。
## threat_evidence 为可选净化声学证据 DTO 列表（不含内部身份或真值位置）。
static func assess(track: Track, now_s: float, threat_evidence: Array = []) -> Dictionary:
	var acc := {"seen": {}, "scores": {}, "tonal": 0, "active": 0, "events": {}, "ids": []}
	for c in CLASSES:
		acc["scores"][c] = 0.0
	if track != null:
		_accum_measurements(track, acc)
	for e in threat_evidence:
		_accum_threat_evidence(e, acc)
	return _finalize(acc, now_s)


static func _key_of(m: Measurement) -> String:
	return m.evidence_id if m.evidence_id != "" else "obj_%d" % m.measurement_id


static func _accum_measurements(track: Track, acc: Dictionary) -> void:
	var seen: Dictionary = acc["seen"]
	var scores: Dictionary = acc["scores"]
	for m in track.measurement_history:
		if not (m is Measurement) or not m.detected:
			continue
		var key: String = _key_of(m)
		if seen.has(key):
			continue
		seen[key] = true
		acc["ids"].append(key)
		# 窄带谱线：稳定 tonals 指向潜艇机械噪声（一次性被动/主动都算）。
		if m.detected_frequencies.size() > 0:
			acc["tonal"] = int(acc["tonal"]) + 1
			scores[SUBMARINE] = float(scores[SUBMARINE]) + 1.0
		# 主动回波：给水面/潜艇都在，但配合 tonals 才加强潜艇。
		if m.has_range():
			acc["active"] = int(acc["active"]) + 1
		# 分类特征显式标记（含净化后的 decoy 标记），只在存在时使用。
		var f: Dictionary = m.classification_features
		if bool(f.get("decoy_like", false)):
			scores[DECOY] = float(scores[DECOY]) + 2.0
		if bool(f.get("surface_like", false)):
			scores[SURFACE] = float(scores[SURFACE]) + 2.0


static func _accum_threat_evidence(e: Dictionary, acc: Dictionary) -> void:
	if not (e is Dictionary):
		return
	var seen: Dictionary = acc["seen"]
	var scores: Dictionary = acc["scores"]
	var eid: String = str(e.get("evidence_id", e.get("event_id", "")))
	if eid != "":
		if seen.has(eid):
			return
		seen[eid] = true
		acc["ids"].append(eid)
	var kind: String = str(e.get("evidence_kind", ""))
	if TORPEDO_KINDS.has(kind):
		scores[TORPEDO] = float(scores[TORPEDO]) + 2.0
		acc["events"]["TORPEDO"] = int(acc["events"].get("TORPEDO", 0)) + 1
	elif DECOY_KINDS.has(kind):
		scores[DECOY] = float(scores[DECOY]) + 2.0
		acc["events"]["DECOY"] = int(acc["events"].get("DECOY", 0)) + 1


static func _finalize(acc: Dictionary, now_s: float) -> Dictionary:
	var scores: Dictionary = acc["scores"]
	var total: float = 0.0
	for c in CLASSES:
		total += float(scores[c])
	# 未知质量：证据越多 → 未知越低（每单位信号压掉一部分）。
	var unknown_mass: float = clampf(1.0 / (1.0 + total), 0.05, 1.0)
	var probs: Dictionary = {}
	var best: String = UNKNOWN
	var best_p: float = 0.0
	for c in CLASSES:
		var p: float = 0.0
		if total > 0.0:
			p = float(scores[c]) / total * (1.0 - unknown_mass)
		probs[c] = p
		if p > best_p:
			best_p = p
			best = c
	probs[UNKNOWN] = unknown_mass
	var n_ev: int = acc["ids"].size()
	var state: String = STATE_UNKNOWN
	if n_ev > 0 and best_p >= SUSPECT_THRESHOLD:
		state = STATE_SUSPECT
	if n_ev >= MIN_EVIDENCE_FOR_CLASSIFIED and best_p >= CLASSIFIED_THRESHOLD:
		state = STATE_CLASSIFIED
	return {
		"probabilities": probs,
		"best": best,
		"confidence": best_p,
		"state": state,
		"label": label_for(state, best),
		"evidence_summary": summary(acc),
		"source_evidence_ids": acc["ids"],
		"evidence_count": n_ev,
		"updated_time": now_s,
	}


## 渐进中文标签（D-15 / AT-60）。
static func label_for(state: String, best: String) -> String:
	var nm: String = str(CLASS_NAMES.get(best, "未知"))
	if state == STATE_CLASSIFIED:
		return "高可信%s" % nm
	if state == STATE_SUSPECT:
		return "疑似%s" % nm
	return "未知接触"


## 依据摘要（可测特征，不含真实身份）。
static func summary(acc: Dictionary) -> String:
	var parts: Array = []
	var tonal: int = int(acc["tonal"])
	var active: int = int(acc["active"])
	var events: Dictionary = acc["events"]
	if tonal > 0:
		parts.append("窄带谱线×%d" % tonal)
	if active > 0:
		parts.append("主动回波×%d" % active)
	if int(events.get("TORPEDO", 0)) > 0:
		parts.append("鱼雷航行事件×%d" % int(events["TORPEDO"]))
	if int(events.get("DECOY", 0)) > 0:
		parts.append("诱饵激活×%d" % int(events["DECOY"]))
	if parts.is_empty():
		return "证据不足"
	return " · ".join(parts)
