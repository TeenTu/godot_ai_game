class_name EnemyTrackManager
extends RefCounted
## enemy_track_manager.gd — 敌方航迹管理（S1-07 §9.5，Commit 9）。
##
## 只消费净化证据（无 target_id / 无 range / 无位置）：按方位门限关联、
## 平滑方位/方位率、质量随命中涨随时间衰减（不确定区随证据陈旧扩大）。
## 简化 TMA/不确定区滤波（§9.5）：本版以方位航迹质量 + 证据陈旧度刻画
## 不确定度；方位-only 反击走宽扇区（§9.7 ATTACKING）。
##
## 纯逻辑、无 RNG（关联确定性），固定 seed 可复现。

var tracks: Array = []  # 航迹字典数组（见 _new_track）

var bearing_gate_deg: float = 12.0
var alpha_hit: float = 0.18  # 每次命中质量增量（× pd）
var decay_per_s: float = 0.01  # 每秒无证据质量衰减
var min_quality: float = 0.05  # 低于此删除航迹
var ema_gain: float = 0.3  # 方位 EMA 增益

var _next_id: int = 1


func clear() -> void:
	tracks.clear()
	_next_id = 1


func _new_track(ev: Dictionary, now: float) -> Dictionary:
	var t := {
		"track_id": _next_id,
		"bearing_est_deg": float(ev.get("bearing_deg", 0.0)),
		"bearing_rate_deg_s": 0.0,
		"prev_bearing_deg": float(ev.get("bearing_deg", 0.0)),
		"prev_t": now,
		"quality": clampf(float(ev.get("pd", 0.5)), 0.0, 1.0),
		"mean_se_db": float(ev.get("se_db", 0.0)),
		"hits": 1,
		"first_t": now,
		"last_t": now,
		"source_class": str(ev.get("source_class", "PLATFORM")),
	}
	_next_id += 1
	return t


## 喂一条证据：方位门限内关联最近航迹，否则新建。返回航迹 id（-1=丢弃）。
func feed(ev: Dictionary, now: float) -> int:
	if ev.is_empty():
		return -1
	var brg: float = float(ev.get("bearing_deg", 0.0))
	var best: Dictionary = {}
	var best_err: float = bearing_gate_deg + 1.0
	for t in tracks:
		var err: float = absf(NavUtils.wrap180(brg - float(t["bearing_est_deg"])))
		if err <= bearing_gate_deg and err < best_err:
			best = t
			best_err = err
	if best.is_empty():
		tracks.append(_new_track(ev, now))
		return _next_id - 1
	# 关联更新：方位 EMA + 方位率有限差分 + 质量按 pd 增长。
	var dt: float = maxf(now - float(best["prev_t"]), 1e-3)
	var raw_rate: float = NavUtils.wrap180(brg - float(best["prev_bearing_deg"])) / dt
	best["bearing_rate_deg_s"] = lerpf(float(best["bearing_rate_deg_s"]), raw_rate, 0.3)
	best["prev_bearing_deg"] = brg
	best["prev_t"] = now
	best["bearing_est_deg"] = NavUtils.wrap360(
		(
			lerpf(float(best["bearing_est_deg"]), brg, ema_gain)
			+ float(best["bearing_rate_deg_s"]) * 0.0
		)
	)
	best["mean_se_db"] = lerpf(float(best["mean_se_db"]), float(ev.get("se_db", 0.0)), 0.3)
	best["quality"] = clampf(
		float(best["quality"]) + alpha_hit * float(ev.get("pd", 0.5)), 0.0, 1.0
	)
	best["hits"] = int(best["hits"]) + 1
	best["last_t"] = now
	# 分类假设取更"警报"的一方（TORPEDO 优先保留，警示语义不可降级）。
	if str(ev.get("source_class", "")) == "TORPEDO":
		best["source_class"] = "TORPEDO"
	return int(best["track_id"])


## 周期推进：质量随无证据时间衰减，低于 min_quality 删除（不确定区扩大）。
func update(now: float) -> void:
	var keep: Array = []
	for t in tracks:
		var dt: float = maxf(now - float(t["last_t"]), 0.0)
		t["quality"] = clampf(float(t["quality"]) - decay_per_s * dt, 0.0, 1.0)
		if float(t["quality"]) >= min_quality:
			keep.append(t)
	tracks = keep


func track_by_id(tid: int) -> Dictionary:
	for t in tracks:
		if int(t["track_id"]) == tid:
			return t
	return {}


## 最高质量航迹（空 = {}）。
func best_track() -> Dictionary:
	var best: Dictionary = {}
	for t in tracks:
		if best.is_empty() or float(t["quality"]) > float(best["quality"]):
			best = t
	return best


## 最近 TORPEDO 分类航迹（鱼雷告警，§9.7 EVADING 触发源）。
func torpedo_track(now: float, max_age_s: float = 30.0) -> Dictionary:
	var best: Dictionary = {}
	for t in tracks:
		if str(t["source_class"]) != "TORPEDO":
			continue
		if now - float(t["last_t"]) > max_age_s:
			continue
		if best.is_empty() or float(t["quality"]) > float(best["quality"]):
			best = t
	return best


func has_torpedo_alert(now: float, max_age_s: float = 30.0) -> bool:
	return not torpedo_track(now, max_age_s).is_empty()
