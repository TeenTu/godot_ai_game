class_name ThreatTrackManager
extends RefCounted
## threat_track_manager.gd — 威胁证据关联与洪泛抑制（评审 P1-11 / P0-07.3）。
##
## 鱼雷运行噪声约每秒一条事件；若每条都成为独立告警，会挤满证据队列并让
## 地图方位线每秒闪烁。本类把 INTERCEPT 证据按时间、方位（含方位率预测）、
## 与证据种类升级链关联到同一 ThreatTrack：
##   LAUNCH_TRANSIENT → RUNNING_NOISE → ACTIVE_PING 是同一威胁卡的证据升级，
##   不是三条互不相关的"确定目标"。
##
## 关联纪律：
##   - 时间间隔超过 ASSOC_GAP_S 不关联（威胁消失/新威胁）；
##   - 方位创新（按 track 方位率外推后）超过门限不关联；
##   - 只净化数据：输入是 EmissionSanitizer 证据（无 target_id/Truth 位置），
##     输出 track 也绝无 Truth。track_id 写回证据字典（threat_track_id）。
##   - 无 RNG：纯几何/时间关联，确定性。

const ASSOC_GAP_S: float = 45.0
const ASSOC_GATE_DEG: float = 12.0
const MAX_TRACKS: int = 64

# 证据种类升级链（rank 小 → 大；只有升级方向改写主类，绝不降级）。
const KIND_RANK := {
	"LAUNCH_TRANSIENT": 1,
	"RUNNING_NOISE": 2,
	"ACTIVE_PING": 3,
}

var _tracks: Array = []  # [{track_id, kind, bearing_deg, bearing_rate_deg_s,
#   sigma_deg, confidence, first_time, last_time, evidence_count, evidence_ids}]
var _next_track_id: int = 1


func reset() -> void:
	_tracks.clear()
	_next_track_id = 1


## 当前威胁航迹（只读数组引用；调用方不得修改）。
func tracks() -> Array:
	return _tracks


## 摄入一条净化证据：关联成功 → 写回 threat_track_id 并更新 track；
## 无法关联 → 新建 track。非威胁类证据（爆炸/诱饵/本艇事实）原样返回 ""。
func ingest(e: Dictionary, now: float) -> String:
	var kind: String = str(e.get("evidence_kind", ""))
	if not KIND_RANK.has(kind):
		return ""
	var brg: float = float(e.get("bearing_deg", 0.0))
	var sigma: float = maxf(float(e.get("bearing_sigma_deg", 2.0)), 0.5)
	var conf: float = clampf(float(e.get("confidence", 0.0)), 0.0, 1.0)
	var best: Dictionary = {}
	var best_cost: float = INF
	for tr in _tracks:
		var dt: float = now - float(tr["last_time"])
		if dt < -1e-6 or dt > ASSOC_GAP_S:
			continue
		var pred: float = NavUtils.wrap360(
			float(tr["bearing_deg"]) + float(tr["bearing_rate_deg_s"]) * dt
		)
		var innov: float = absf(NavUtils.wrap180(brg - pred))
		var gate: float = maxf(3.0 * maxf(float(tr["sigma_deg"]), sigma), ASSOC_GATE_DEG)
		if innov > gate:
			continue
		var cost: float = innov / gate
		if cost < best_cost:
			best_cost = cost
			best = tr
	if best.is_empty():
		if _tracks.size() >= MAX_TRACKS:
			_tracks.pop_front()
		var tid: String = "TT%03d" % _next_track_id
		_next_track_id += 1
		best = {
			"track_id": tid,
			"kind": kind,
			"bearing_deg": brg,
			"bearing_rate_deg_s": 0.0,
			"sigma_deg": sigma,
			"confidence": conf,
			"first_time": now,
			"last_time": now,
			"evidence_count": 1,
			"evidence_ids": [int(e.get("evidence_id", 0))],
		}
		_tracks.append(best)
	else:
		var dt2: float = maxf(now - float(best["last_time"]), 1e-3)
		var pred2: float = NavUtils.wrap360(
			float(best["bearing_deg"]) + float(best["bearing_rate_deg_s"]) * dt2
		)
		var innov2: float = NavUtils.wrap180(brg - pred2)
		# 方位 EMA + 方位率更新（同 SeekerTrack 风格的轻量滤波）。
		var alpha: float = clampf(0.4 + 0.3 * conf, 0.3, 0.8)
		best["bearing_deg"] = NavUtils.wrap360(pred2 + alpha * innov2)
		best["bearing_rate_deg_s"] = clampf(innov2 / dt2, -10.0, 10.0)
		best["sigma_deg"] = maxf(float(best["sigma_deg"]) * 0.95, sigma)
		best["confidence"] = maxf(float(best["confidence"]), conf)
		best["last_time"] = now
		best["evidence_count"] = int(best["evidence_count"]) + 1
		(best["evidence_ids"] as Array).append(int(e.get("evidence_id", 0)))
		# 升级链：只升不降（TRANSIENT → NOISE → PING 同一张威胁卡）。
		var old_rank: int = int(KIND_RANK.get(str(best["kind"]), 0))
		if int(KIND_RANK[kind]) > old_rank:
			best["kind"] = kind
	e["threat_track_id"] = str(best["track_id"])
	e["source_class_hypothesis"] = "TORPEDO"
	return str(best["track_id"])
