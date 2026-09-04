class_name TorpedoSeeker
extends RefCounted

## TorpedoSeeker（S1-07 §7，Commit 7）：鱼雷 Seeker 的航迹管理 + 相位状态机。
## 只消费净化 SeekerReturn（§6.5），绝不接触 TruthEntity——验收 WPN-SEEK-12
## 的"Guidance API 不接受 TruthEntity"由此保证：本类与 SeekerTrack/Guidance
## 的全部入参只有 return/track/配置数值。
##
## 相位（§7.3 滞回；映射到 Torpedo.SeekerState 呈现）：
##   SEARCH → (best.lock>=acquire) → ACQUIRING
##   ACQUIRING → (lock>=stable) → TRACKING
##   TRACKING → (lock<drop) → LOST
##   LOST/REACQUIRE → (任一 track 重新达到 acquire) → REACQUIRE → TRACKING
##   LOST 超时 reacquire_timeout_s → SEARCH（§7.6 第 6 步）

enum Phase { SEARCH, ACQUIRING, TRACKING, LOST, REACQUIRE }

const MAX_TRACKS: int = 8

var phase: int = Phase.SEARCH
var tracks: Array = []  # SeekerTrack
var selected_track_id: int = -1

var _cfg: Dictionary = {}
var _phase_since: float = 0.0
var _lost_bearing_deg: float = 0.0


## cfg（全部可配置；缺省为文档示例量级）：
##   acquire_threshold(0.65) stable_track_threshold(0.80) drop_threshold(0.25)
##   beta_miss(0.10) bearing_gate_deg(12.0) miss_after_s(1.2)
##   reacquire_timeout_s(120.0) max_tracks(8) + SeekerTrack.update/score 的全部键
func configure(cfg: Dictionary) -> void:
	_cfg = cfg.duplicate(true)


func _c(key: String, def: float) -> float:
	return float(_cfg.get(key, def))


## 喂入一批新 return（§7.2 关联：预测方位差/方位率/主动测距/时间连续性；
## 绝不用 target_id）。返回 {new_track_ids: [..]}。
func process_returns(returns: Array, now: float) -> Dictionary:
	var new_ids: Array = []
	for r in returns:
		if not (r is SeekerReturn) or not r.detected:
			continue
		var best: SeekerTrack = null
		var best_cost: float = INF
		var gate: float = _c("bearing_gate_deg", 12.0)
		for t in tracks:
			# §7.2 关联：未钳位的预测方位差过绝对门限（防止不同源误并入）。
			var innov_deg: float = absf(
				NavUtils.wrap180(r.bearing_deg - t.predicted_bearing_deg(now))
			)
			var cost: float = innov_deg
			# 主动测距同时作为关联证据（§7.2）。
			cost += 2.0 * t.normalized_range_innovation(r) * gate
			# 深度层突变提高关联代价（§7.2 深度层关系）。
			if t.depth_relation != "" and str(r.depth_relation) != t.depth_relation:
				cost += gate * 0.5
			if cost <= gate and cost < best_cost:
				best_cost = cost
				best = t
		if best == null:
			if tracks.size() >= MAX_TRACKS:
				_evict_weakest()
			best = SeekerTrack.create()
			tracks.append(best)
			new_ids.append(best.seeker_track_id)
		best.update_with_return(r, now, _cfg)
	return {"new_track_ids": new_ids}


## 每 tick 计龄与相位推进。返回 {changed, phase, selected_track_id, lost_bearing_deg}。
func update(now: float) -> Dictionary:
	var miss_after: float = _c("miss_after_s", 1.2)
	var beta: float = _c("beta_miss", 0.10)
	for t in tracks:
		if t.last_update_time >= 0.0 and now - t.last_update_time > miss_after:
			# 每 miss 窗口只计一次。
			if t.last_miss_time < 0.0 or now - t.last_miss_time >= miss_after:
				t.age_miss(now, beta)
	# 超龄航迹清理（久无更新且质量耗尽）。
	tracks = tracks.filter(
		func(t: SeekerTrack) -> bool:
			return not (
				t.total_misses > 0 and t.lock_quality <= 0.001 and now - t.last_miss_time > 30.0
			)
	)

	var changed: bool = false
	var reacquire_bearing: float = -1.0
	match phase:
		Phase.SEARCH:
			var best: SeekerTrack = _best_track()
			if best != null and best.lock_quality >= _c("acquire_threshold", 0.65):
				selected_track_id = best.seeker_track_id
				phase = Phase.ACQUIRING
				_phase_since = now
				changed = true
		Phase.ACQUIRING:
			var sel: SeekerTrack = _track(selected_track_id)
			if sel == null or sel.lock_quality < _c("drop_threshold", 0.25):
				phase = Phase.SEARCH
				_phase_since = now
				changed = true
			elif sel.lock_quality >= _c("stable_track_threshold", 0.80):
				phase = Phase.TRACKING
				_phase_since = now
				changed = true
		Phase.TRACKING:
			var sel: SeekerTrack = _track(selected_track_id)
			if sel == null or sel.lock_quality < _c("drop_threshold", 0.25):
				if sel != null:
					_lost_bearing_deg = sel.bearing_estimate_deg
				else:
					_lost_bearing_deg = -1.0
				phase = Phase.LOST
				_phase_since = now
				selected_track_id = -1
				changed = true
		Phase.LOST, Phase.REACQUIRE:
			# §7.6：围绕最后预测方位扩大扇区重搜；任一航迹重新达到捕获阈值
			# → REACQUIRE（过渡相位）→ 稳定后 TRACKING。
			var best: SeekerTrack = _best_track()
			if best != null and best.lock_quality >= _c("acquire_threshold", 0.65):
				selected_track_id = best.seeker_track_id
				if phase == Phase.LOST:
					phase = Phase.REACQUIRE
					_phase_since = now
					changed = true
			elif phase == Phase.LOST and now - _phase_since > _c("reacquire_timeout_s", 120.0):
				phase = Phase.SEARCH
				_phase_since = now
				changed = true
	# REACQUIRE 过渡：再更新一轮仍达标 → TRACKING。
	if phase == Phase.REACQUIRE and now - _phase_since > 2.0 * _c("miss_after_s", 1.2):
		var sel: SeekerTrack = _track(selected_track_id)
		if sel != null and sel.lock_quality >= _c("acquire_threshold", 0.65):
			phase = Phase.TRACKING
			_phase_since = now
			changed = true
		else:
			phase = Phase.LOST
			_phase_since = now
			selected_track_id = -1
			changed = true
	return {
		"changed": changed,
		"phase": phase,
		"selected_track_id": selected_track_id,
		"lost_bearing_deg": _lost_bearing_deg,
	}


## 多目标竞争（§7.4）：score 最高且达到捕获阈值的航迹；已锁对象有 continuity
## bonus 但绝不"永不脱锁"（lock_quality 独立衰减）。
func _best_track() -> SeekerTrack:
	var best: SeekerTrack = null
	var best_score: float = -INF
	for t in tracks:
		var s: float = t.score(_cfg, t.seeker_track_id == selected_track_id)
		if s > best_score:
			best_score = s
			best = t
	return best


func _track(id: int) -> SeekerTrack:
	if id < 0:
		return null
	for t in tracks:
		if t.seeker_track_id == id:
			return t
	return null


## 公开查询（ASSISTED 接受/摘要回传用）；无此航迹返回 null。
func track_by_id(id: int) -> SeekerTrack:
	return _track(id)


func selected_track() -> SeekerTrack:
	return _track(selected_track_id)


## ASSISTED 接受指定航迹（§7.7）：候选由 UI/玩家从 to_summary 列表中挑选。
func track_summaries() -> Array:
	var out: Array = []
	for t in tracks:
		out.append(t.to_summary())
	return out


## 满编时淘汰质量最低航迹。
func _evict_weakest() -> void:
	var worst: SeekerTrack = null
	var worst_score: float = INF
	for t in tracks:
		var s: float = t.lock_quality + 0.1 * t.track_quality
		if s < worst_score:
			worst_score = s
			worst = t
	if worst != null:
		tracks.erase(worst)


## LOST/REACQUIRE 重搜扇区（§7.6 第 3 步）：最后预测方位 ± 扩大半角。
func reacquire_sector(half_angle_deg: float) -> Dictionary:
	var center: float = _lost_bearing_deg
	var half: float = minf(half_angle_deg * 2.0, 150.0)
	if center < 0.0:
		center = 0.0
		half = 180.0
	return {"center_deg": NavUtils.wrap360(center), "half_angle_deg": half}
