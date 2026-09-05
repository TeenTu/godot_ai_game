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
##   TRACKING → (目标离开 FOV) → COAST（按最后方位+率短时预测）
##   TRACKING/COAST → (lock<drop / COAST 超时) → LOST
##   LOST/REACQUIRE → (任一 track 重新达到 acquire) → REACQUIRE → TRACKING
##   LOST 超时 reacquire_timeout_s → SEARCH（§7.6 第 6 步）

enum Phase { SEARCH, ACQUIRING, TRACKING, COAST, LOST, REACQUIRE }

const MAX_TRACKS: int = 8

var phase: int = Phase.SEARCH
var tracks: Array = []  # SeekerTrack
var selected_track_id: int = -1
## REQ-02：保留字段兼容（历史签名）；滤波方位率已是真方位惯性率，
## 不再消费自身转率。
var own_turn_rate_deg_s: float = 0.0
## REQ-06：载体实际艏向 + 接收半角（机会判定：航迹预测方位是否在 FOV 内。
## FOV 外无有效测量机会，不计 miss；离开 FOV → COAST）。
var own_course_deg: float = 0.0
var fov_half_deg: float = 60.0

var _cfg: Dictionary = {}
var _phase_since: float = 0.0
var _lost_bearing_deg: float = 0.0
var _last_now: float = 0.0


## cfg（全部可配置；缺省为文档示例量级）：
##   acquire_threshold(0.65) stable_track_threshold(0.80) drop_threshold(0.25)
##   beta_miss(0.10) bearing_gate_deg(12.0) miss_after_s(1.2)
##   reacquire_timeout_s(120.0) max_tracks(8) + SeekerTrack.update/score 的全部键
func configure(cfg: Dictionary) -> void:
	_cfg = cfg.duplicate(true)


func _c(key: String, def: float) -> float:
	return float(_cfg.get(key, def))


## 喂入一批新 return（§7.2 关联：预测方位差/主动测距/深度层连续性；
## 绝不用 target_id）。P0-04：先构造 Return×Track 代价矩阵再做一对一分配
## （贪心按代价升序、各用一次）——旧实现逐条贪心允许同一 scan 双 return
## 重复更新同一航迹（dt 夹到 0.001 制造方位率尖峰）。返回 {new_track_ids: [..]}。
func process_returns(returns: Array, now: float) -> Dictionary:
	var new_ids: Array = []
	var gate: float = _c("bearing_gate_deg", 12.0)
	var w_theta: float = _c("assoc_w_theta", 1.0)
	var w_r: float = _c("assoc_w_range", 0.5)
	# ---- 代价矩阵（无量纲创新）：d_theta² / d_r²；纯被动无虚构距离项。
	var pairs: Array = []
	for ri in range(returns.size()):
		var r = returns[ri]
		if not (r is SeekerReturn) or not r.detected:
			continue
		for t in tracks:
			var innov_deg: float = absf(
				NavUtils.wrap180(r.bearing_deg - t.predicted_bearing_deg(now))
			)
			if innov_deg > gate:
				continue
			var d_theta: float = innov_deg / maxf(r.bearing_sigma_deg, 0.5)
			var cost: float = w_theta * d_theta * d_theta
			# 主动测距同时作为关联证据（§7.2）；双方都有距离才计（P0-04.3）。
			if t.range_estimate_m >= 0.0 and r.range_m >= 0.0:
				var d_r: float = absf(r.range_m - t.range_estimate_m) / maxf(r.range_sigma_m, 10.0)
				cost += w_r * d_r * d_r
			# 深度层突变提高关联代价（§7.2 深度层关系）。
			if t.depth_relation != "" and str(r.depth_relation) != t.depth_relation:
				cost += 0.5
			pairs.append({"ri": ri, "track": t, "cost": cost})
	# ---- 一对一分配：代价升序贪心，return 与 track 各最多用一次。
	pairs.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return float(a["cost"]) < float(b["cost"])
	)
	var used_returns: Dictionary = {}
	var used_tracks: Dictionary = {}
	for p in pairs:
		var ri: int = int(p["ri"])
		var t: SeekerTrack = p["track"]
		if used_returns.has(ri) or used_tracks.has(t.seeker_track_id):
			continue
		used_returns[ri] = true
		used_tracks[t.seeker_track_id] = true
		t.update_with_return(returns[ri], now, _cfg)
	# ---- 未分配 return 才创建新航迹（满编先淘汰最弱）。
	for ri in range(returns.size()):
		var r2 = returns[ri]
		if not (r2 is SeekerReturn) or not r2.detected:
			continue
		if used_returns.has(ri):
			continue
		if tracks.size() >= MAX_TRACKS:
			_evict_weakest()
		var nt := SeekerTrack.create()
		tracks.append(nt)
		nt.update_with_return(r2, now, _cfg)
		new_ids.append(nt.seeker_track_id)
	return {"new_track_ids": new_ids}


## 每 tick 推进相位。REQ-03：miss 不再按仿真 tick/壁钟时间统一扣分——
## 只按"有效测量机会"计龄（notify_passive_scan / notify_active_miss 由
## Torpedo 在被动扫描完成 / 主动监听窗结束时调用）。本函数只做相位机与
## 超龄航迹清理。返回 {changed, phase, selected_track_id, lost_bearing_deg}。
func update(now: float) -> Dictionary:
	_last_now = now
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
					_set_loss_kind(sel, "QUALITY_DROP")
				else:
					_lost_bearing_deg = -1.0
				phase = Phase.LOST
				_phase_since = now
				selected_track_id = -1
				changed = true
			elif not _track_in_fov(sel):
				# REQ-06：目标暂时离开 FOV → COAST（保持最后方位+率预测，
				# 不立刻 LOST）。COAST 超时由 COAST 分支判。
				phase = Phase.COAST
				_phase_since = now
				changed = true
		Phase.COAST:
			var sel2: SeekerTrack = _track(selected_track_id)
			if sel2 == null or sel2.lock_quality < _c("drop_threshold", 0.25):
				if sel2 != null:
					_lost_bearing_deg = sel2.bearing_estimate_deg
					_set_loss_kind(sel2, "QUALITY_DROP")
				phase = Phase.LOST
				_phase_since = now
				selected_track_id = -1
				changed = true
			elif _track_in_fov(sel2):
				# 重新进入覆盖范围 → REACQUIRE（过渡）→ 稳定后 TRACKING。
				phase = Phase.REACQUIRE
				_phase_since = now
				changed = true
			elif now - _phase_since > _c("coast_timeout_s", 32.0):
				# COAST 超时（覆盖 Ping 间隔+最大回波延迟+余量）→ LOST。
				_lost_bearing_deg = sel2.bearing_estimate_deg
				_set_loss_kind(sel2, "OUT_OF_FOV")
				phase = Phase.LOST
				_phase_since = now
				selected_track_id = -1
				changed = true
		Phase.LOST, Phase.REACQUIRE:
			# §7.6：围绕最后预测方位扩大扇区重搜；任一航迹重新达到捕获阈值
			# 且**在脱锁后有新测量**（REQ-06：禁止对陈旧航迹幽灵重锁——目标
			# 永久消失时必须能走到 SEARCH 重搜，不得 COAST→LOST→REACQUIRE 死循环）
			# → REACQUIRE（过渡相位）→ 稳定后 TRACKING。
			var best: SeekerTrack = _best_track()
			if (
				best != null
				and best.lock_quality >= _c("acquire_threshold", 0.65)
				and best.last_update_time > _phase_since
			):
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


## 航迹预测方位是否在当前接收 FOV 内（REQ-06：机会判定与 COAST 判定同一门）。
func _track_in_fov(t: SeekerTrack) -> bool:
	if fov_half_deg >= 180.0:
		return true
	var pred: float = t.predicted_bearing_deg(_last_now)
	return absf(NavUtils.wrap180(pred - own_course_deg)) <= fov_half_deg


## REQ-03/06：被动扫描完成——仅对“被动通道有支持历史”的航迹按机会计 miss。
## REQ-06：主动回波近期待的航迹（active-only 支持）不因空被动扫描被抽干
## 质量——没有被动支持不代表被动通道探测失败（目标安静属预期）。
## 每个 passive_miss_window_s 最多一次；FOV 外航迹无机会，不计 miss。
func notify_passive_scan(now: float) -> void:
	_last_now = now
	var window: float = _c("passive_miss_window_s", 1.2)
	var beta: float = _c("beta_miss", 0.10)
	var active_support: float = _c("active_support_window_s", 16.0)
	for t in tracks:
		if t.last_update_time < 0.0:
			continue
		if not _track_in_fov(t):
			continue
		# REQ-06：有近期主动回波支持的航迹跳过被动 miss（不因无被动支持
		# 而清空有效主动航迹）。
		if t.last_range_update_time >= 0.0 and now - t.last_range_update_time <= active_support:
			continue
		if (
			now - t.last_passive_update_time > window
			and (t.last_miss_time < 0.0 or now - t.last_miss_time >= window * 0.5)
		):
			t.age_miss(now, beta, "PASSIVE")


## REQ-03/06：主动 Ping 监听窗结束且无回波——只对“该 Ping 发射前已存在、
## FOV 内、且未因该 Ping 得到回波更新”的航迹记一次 active miss（每次 Ping
## 恰好一次；收到回波的航迹绝不扣分；Ping 发射后新建的航迹无此机会）。
func notify_active_miss(now: float, ping_emit_t: float = -1.0) -> void:
	var beta: float = _c("beta_miss", 0.10)
	var emit_t: float = ping_emit_t if ping_emit_t >= 0.0 else now
	for t in tracks:
		if t.last_update_time < 0.0:
			continue
		if t.last_update_time > emit_t:
			continue  # Ping 发射后有过测量（含该 Ping 回波）→ 有机会已兑现
		if not _track_in_fov(t):
			continue
		t.age_miss(now, beta, "ACTIVE")


func _set_loss_kind(t: SeekerTrack, kind: String) -> void:
	if t.last_miss_channel == "ACTIVE":
		t.loss_kind = "AGED_OUT_ACTIVE"
	else:
		t.loss_kind = kind


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
