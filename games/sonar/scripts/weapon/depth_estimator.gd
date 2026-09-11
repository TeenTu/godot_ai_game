class_name DepthEstimator
extends RefCounted
## depth_estimator.gd — S1-11 §7.3：敌方可能深度概率估计器（层带 + 可选区间）。
##
## 默认 UNKNOWN（绝不用 0m 代表未知、绝不默认上层）。只消费合法的
## DepthEvidence（§7.2 带误差模型垂向观测），逐条按
##   P(layer | e) ∝ P(e | layer) × P(layer)
## 更新；陈旧证据按半衰期衰减（AT-31），同 evidence_id 只计一次（AT-30）。
##
## 输出（§7.1）：
##   probabilities   {SURFACE_LIKELY, UPPER_LIKELY, LOWER_LIKELY, UNKNOWN}
##   confidence      主导层概率（<0.55 → 视为未知）
##   depth_interval_m / interval_confidence  仅在存在明确垂向测量时给出
##   evidence_count / source_summary / updated_time / dominant / probability
##
## 信息边界：本类不接受 TruthEntity / target_id / 场景 depth_band。

const SURFACE := "SURFACE_LIKELY"
const UPPER := "UPPER_LIKELY"
const LOWER := "LOWER_LIKELY"
const UNKNOWN := "UNKNOWN"
## 证据半衰期（秒；陈旧证据概率回落，绝不永久保持高置信度）。
const HALF_LIFE_S: float = 150.0
## UNKNOWN 先验权重（防止少量证据即塌缩为确定层）。
const UNKNOWN_PRIOR: float = 1.2

var _w: Dictionary = {}  # layer -> 权重（未衰减的"最后更新时刻"权重）
var _last_contrib_t: Dictionary = {}  # layer -> 最近一次贡献时刻
var _last_t: float = -1.0
var _seen: Dictionary = {}  # evidence_id -> true（去重）
var _sources: Dictionary = {}  # source_kind -> count
var _evidence_count: int = 0
var _obs_depth: float = -1.0
var _obs_sigma: float = -1.0
var _obs_t: float = -1.0


func _init() -> void:
	_w[SURFACE] = 0.0
	_w[UPPER] = 0.0
	_w[LOWER] = 0.0


## 喂入一条证据。返回是否被接受（重复 evidence_id / 不可用证据 → false）。
func update(e: DepthEvidence, now: float) -> bool:
	if e == null or not e.is_usable():
		return false
	if e.evidence_id != "" and _seen.has(e.evidence_id):
		return false  # AT-30：同一物理证据只计一次
	if e.evidence_id != "":
		_seen[e.evidence_id] = true
	_decay_to(now)
	var like_sum: float = 0.0
	var w: float = maxf(e.weight, 0.0)
	for k in [SURFACE, UPPER, LOWER]:
		var like: float = float(e.layer_likelihoods.get(k, 0.0))
		like_sum += like
		if like > 0.0:
			_w[k] = float(_w[k]) + like * w
			_last_contrib_t[k] = now
	if like_sum <= 0.0:
		return false
	# 明确垂向测量（带 sigma）才记录区间；否则不伪造精确水深（AT-28）。
	if e.depth_observed_m >= 0.0 and e.depth_sigma_m > 0.0:
		_obs_depth = e.depth_observed_m
		_obs_sigma = e.depth_sigma_m
		_obs_t = now
	_sources[e.source_kind] = int(_sources.get(e.source_kind, 0)) + 1
	_evidence_count += 1
	_last_t = now
	return true


## 时间推进（每 tick 调用；使陈旧证据衰减）。
func decay(now: float) -> void:
	_decay_to(now)
	_last_t = now


func _decay_to(now: float) -> void:
	for k in [SURFACE, UPPER, LOWER]:
		if not _last_contrib_t.has(k):
			continue
		var age: float = maxf(now - float(_last_contrib_t[k]), 0.0)
		var f: float = pow(0.5, age / HALF_LIFE_S)
		_w[k] = float(_w[k]) * f
		_last_contrib_t[k] = now


## 估计结果（now 为当前时刻；用于衰减）。
func result(now: float = -1.0) -> Dictionary:
	var t: float = now if now >= 0.0 else maxf(_last_t, 0.0)
	var w: Dictionary = {}
	var total: float = 0.0
	for k in [SURFACE, UPPER, LOWER]:
		var v: float = float(_w[k])
		if _last_contrib_t.has(k):
			var age: float = maxf(t - float(_last_contrib_t[k]), 0.0)
			v *= pow(0.5, age / HALF_LIFE_S)
		w[k] = maxf(v, 0.0)
		total += w[k]
	var unk: float = UNKNOWN_PRIOR
	w[UNKNOWN] = unk
	total += unk
	var probs: Dictionary = {}
	var dom: String = UNKNOWN
	var best: float = -1.0
	for k in [SURFACE, UPPER, LOWER, UNKNOWN]:
		var p: float = float(w[k]) / maxf(total, 1e-9)
		probs[k] = p
		if k != UNKNOWN and p > best:
			best = p
			dom = k
	# 未离开 UNKNOWN 或主导层概率低于门限一律视为未知。
	if _evidence_count == 0 or best < 0.55:
		dom = UNKNOWN
		best = float(probs[UNKNOWN])
	var conf: float = best if dom != UNKNOWN else 0.0
	var out: Dictionary = {
		"probabilities": probs,
		"confidence": conf,
		"dominant": dom,
		"probability": best if dom != UNKNOWN else 0.0,
		"evidence_count": _evidence_count,
		"source_summary": _source_summary(),
		"updated_time": _last_t,
		"depth_interval_m": [],
		"interval_confidence": 0.0,
	}
	# 只有存在真实垂向测量时才给区间（95% ≈ ±2σ）。
	if _obs_depth >= 0.0 and _obs_sigma > 0.0:
		var lo: float = maxf(_obs_depth - 2.0 * _obs_sigma, 0.0)
		var hi: float = _obs_depth + 2.0 * _obs_sigma
		out["depth_interval_m"] = [lo, hi]
		out["interval_confidence"] = 0.95
	return out


func _source_summary() -> String:
	if _sources.is_empty():
		return ""
	var parts: Array = []
	for k in _sources:
		parts.append("%s×%d" % [str(k), int(_sources[k])])
	return " ".join(parts)


func evidence_count() -> int:
	return _evidence_count


func dominant() -> String:
	return str(result().get("dominant", UNKNOWN))
