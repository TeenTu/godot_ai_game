class_name Tracker
extends RefCounted
## tracker.gd — 接触关联管理器（Mark 一次性 + Tracker 持续跟踪）。
##
## 阶段二核心：把源源不断的 Measurement 流聚合成 Track。
## 两种玩家操作：
##   - Mark：一次性，从当前声呐接触创建一个接触（Contact ID），保存测量并画 LOB，
##     不自动后续更新。
##   - Tracker 分配：为某个接触分配持续跟踪，按可配置间隔自动产生测量。
##
## 设计要点（对应需求）：
##   - Mark 创建的 Track 只含最初的 Measurement；后续由 Tracker 周期追加。
##   - 每个 Measurement 都保存"测量时本艇位置"，LOB 从历史位置发出。
##   - Tracker 数量有限（capacity）。
##   - 接触丢失 → 对应 Track 进入 LOST 状态，不得凭空继续生成精确测量。
##   - 关联：按方位 + 本艇位置最近邻，把新测量归到最可能的已有 Track。

# 方位＋距离关联门控（S1-04B-REQ-11 / S1-04C-REQ-03 混合关联评分）：
#   d² = (Δθ/σθc)² + (ΔR/σRc)²；σRc² = σnew² + σold² + σmotion²(=(v·Δt)²)
# 门控语义（REQ-03）：
#   - 新测量带测距且 Track 有"最后有效测距"（可能不是最新测量）→ 双测距门控；
#   - Track 无测距历史但有有效 TMA 预测测距 → 预测测距门控（精度略降）；
#   - 两者皆无 → 纯方位退化关联（低置信，Contact 行徽标降级）。
# 多 Track 优先级：先看带 range 参照的候选（门内取 d² 最小），全部被门拒或
# 不存在时才允许纯方位回退——避免把一次明显错距的主动回波硬贴到无关被动接触。
const RANGE_GATE_D2: float = 6.0  # 归一化门限（χ² 2dof 95% ≈ 5.99）
const RANGE_GATE_VEL_MS: float = 8.0  # 门内目标机动速度估计（~15kn），随 Δt 累计
const PRED_RANGE_MAX_AGE_S: float = 300.0  # TMA 预测测距允许的最大外推年龄

## S1-04C-REQ-03：TMA 预测测距表 track_id -> {range_m, sigma_m, time}。
## 由持有拟合状态的调用方（main_ui / 测试）在每次拟合更新后写入；
## 仅当新测量带 range 且 Track 无测距历史时使用（预测门控）。
var predicted_ranges: Dictionary = {}

var _tracks: Array = []  # 全部 Track
var _next_number: Dictionary = {}  # source_type -> 下一个编号（S/E/R/V/M 各自计数）
var _rng: RandomNumberGenerator = null
var _tracker_capacity: int = 8  # 可分配的持续 Tracker 数
var _auto_update_interval_s: float = 120.0  # Tracker 默认自动测量间隔（需求指定）
var _sensor_intervals: Dictionary = {}  # sensor_id -> 上次测量时间（自动关联用）


func set_predicted_range(track_id: String, range_m: float, sigma_m: float, at_time: float) -> void:
	predicted_ranges[track_id] = {"range_m": range_m, "sigma_m": sigma_m, "time": at_time}


func clear_predicted_range(track_id: String) -> void:
	predicted_ranges.erase(track_id)


func set_rng(rng: RandomNumberGenerator) -> void:
	_rng = rng


func set_capacity(cap: int) -> void:
	_tracker_capacity = maxi(cap, 1)


func set_auto_interval(interval_s: float) -> void:
	_auto_update_interval_s = maxf(interval_s, 1.0)


## 用一条测量执行 Mark：创建新接触并返回 Track。
## source_type 取 "S"/"E"/"R"/"V"/"M"（默认 S=声呐）。
## REQ-B1-01：显式新建空 Mark 组（Track），不携带任何证据。
func create_empty_track() -> Track:
	var n: int = int(_next_number.get("M", 1))
	_next_number["M"] = n + 1
	var t := Track.new()
	t.source_type = "M"
	t.track_id = "M%02d" % n
	t.state = Track.TrackState.ACTIVE
	_tracks.append(t)
	return t


func mark(m: Measurement, source_type: String = "S") -> Track:
	var n: int = _next_number.get(source_type, 1)
	_next_number[source_type] = n + 1
	var track := Track.create(source_type, n, m)
	_tracks.append(track)
	return track


## 把所有测量按最近邻关联到已有 Track（或返回 null 表示无匹配）。
## 用于 Tracker 持续跟踪时把新测量归到正确接触。
## S1-04C-REQ-03 混合关联评分：新测量带测距时按「最后有效测距 / TMA 预测
## 测距 / 纯方位回退」三档处理；成功关联会把 association_confidence /
## last_association_mode / last_association_score 写到 Track（Contact 行徽章）。
func associate(m: Measurement, max_angle_deg: float = 6.0) -> Track:
	var gated: Array = []  # [{score, track, mode}]（测距/预测门内候选）
	var bearing_only: Track = null
	var bearing_d2: float = 1.0e18
	var saw_range_track: bool = false  # 是否存在可做测距门控的 Track
	for track in _tracks:
		if track.state != Track.TrackState.ACTIVE:
			continue
		var prev: Measurement = track.latest_measurement()
		if prev == null:
			continue
		# 方位差：从 prev 的测量方位到当前测量的方位变化应很小（连续接触）
		var dangle: float = absf(
			NavUtils.angle_diff(m.measured_bearing_deg, prev.measured_bearing_deg)
		)
		if dangle > max_angle_deg:
			continue
		var s_theta: float = sqrt(
			(
				m.bearing_sigma_deg * m.bearing_sigma_deg
				+ prev.bearing_sigma_deg * prev.bearing_sigma_deg
			)
		)
		var b_d2: float = (dangle / maxf(s_theta, 0.1)) * (dangle / maxf(s_theta, 0.1))
		if not m.has_range():
			# 被动测量：纯方位评分（与旧行为一致），只记最低者。
			if b_d2 < bearing_d2:
				bearing_d2 = b_d2
				bearing_only = track
			continue
		# ---- 新测量带测距：REQ-03 测距门控档位 ----
		var r_ref: Dictionary = {}
		var mode: String = "bearing_only"
		var lr: Measurement = track.last_valid_range_measurement()
		if lr != null:
			saw_range_track = true
			r_ref = {
				"range_m": lr.measured_range_m, "sigma_m": lr.range_sigma_m, "time": lr.timestamp
			}
			mode = "range"
		elif predicted_ranges.has(track.track_id):
			saw_range_track = true
			var pr: Dictionary = predicted_ranges[track.track_id]
			if absf(m.timestamp - float(pr.get("time", -1.0e9))) <= PRED_RANGE_MAX_AGE_S:
				r_ref = pr
				mode = "predicted"
		if r_ref.is_empty():
			# 无测距历史也无有效预测测距 → 纯方位回退候选（低置信）
			if b_d2 < bearing_d2:
				bearing_d2 = b_d2
				bearing_only = track
			continue
		var dt: float = maxf(m.timestamp - float(r_ref["time"]), 0.0)
		var s_rng: float = sqrt(
			(
				m.range_sigma_m * m.range_sigma_m
				+ float(r_ref["sigma_m"]) * float(r_ref["sigma_m"])
				+ pow(RANGE_GATE_VEL_MS * dt, 2.0)
			)
		)
		var d_rng: float = m.measured_range_m - float(r_ref["range_m"])
		var r_d2: float = (d_rng / maxf(s_rng, 1.0)) * (d_rng / maxf(s_rng, 1.0))
		var total: float = b_d2 + r_d2
		if total >= RANGE_GATE_D2:
			continue  # 测距门拒（明显错距/错位），不参与关联
		gated.append({"score": total, "track": track, "mode": mode})
	if not gated.is_empty():
		gated.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) < float(b["score"])
		)
		var pick: Dictionary = gated[0]
		var tr: Track = pick["track"]
		var score: float = float(pick["score"])
		var gm: String = str(pick["mode"])
		tr.association_confidence = _gated_confidence(score, gm)
		tr.last_association_mode = gm
		tr.last_association_score = score
		return tr
	# 测距档全部被门拒：若本可测距（有测距历史/预测）则不得回退纯方位，
	# 避免把一次明显错距的主动回波硬贴到无关被动接触（R11 语义）。
	if m.has_range() and saw_range_track:
		return null
	if bearing_only != null:
		bearing_only.association_confidence = _bearing_confidence(bearing_d2)
		bearing_only.last_association_mode = "bearing_only"
		bearing_only.last_association_score = bearing_d2
	return bearing_only


## 测距/预测门控候选的置信度：d² 越小越紧；预测门控整体压低一档（上限 0.85）。
func _gated_confidence(total_d2: float, mode: String) -> float:
	var base: float = clampf(1.0 - total_d2 / (2.0 * RANGE_GATE_D2), 0.25, 0.98)
	if mode == "predicted":
		return clampf(base * 0.9, 0.2, 0.85)
	return base


## 纯方位退化关联的置信度：无 range 参照恒为低置信（上限 0.5），随方位离群降。
func _bearing_confidence(bearing_d2: float) -> float:
	return clampf(0.5 - bearing_d2 / 18.0, 0.05, 0.5)


## 为某 Track 分配持续 Tracker（若数量已达上限返回 false）。
func assign_tracker(track: Track) -> bool:
	if track.state != Track.TrackState.ACTIVE:
		return false
	var assigned: int = 0
	for t in _tracks:
		if t.state == Track.TrackState.ACTIVE:
			assigned += 1
	if assigned > _tracker_capacity:
		return false
	return true


## 自动把测量追加到对应 Track（associate 后 add_measurement）。
## 若没有匹配 Track 则不自动建（避免凭空建接触）。
func feed(m: Measurement, max_angle_deg: float = 6.0) -> Track:
	var track: Track = associate(m, max_angle_deg)
	if track != null:
		track.add_measurement(m)
	return track


# ------------------------------------------------------------------
#  S1-03C-P0-01：ambiguity-aware 证据组关联
# ------------------------------------------------------------------
# 拖曳阵一次物理到达 = 一个 A/B 镜像组（共享 evidence_id）。修复前把组内两条
# 当普通测量逐条 feed：Track.latest_measurement() 常是 sibling，玩家下次点同一
# 可见支时方位差超门限 → 静默新建 M02/M03……。本 API 把整组当作一个证据原子：
#   - 关联判定用「候选集合最小角差」：组内任一支（A 或 B）与 Track 最近测量的
#     角差 <= 门限即视为同一连续接触（latest 是 sibling 也不分裂）；
#   - 同一组原子追加：全部成员进同一个 Track，绝不拆开；
#   - preferred_track_id（选中接触）非空时只对该 Track 门控：通过则追加，
#     不通过返回 null（调用方提示，绝不静默新建 Contact）。


func _find_track(track_id: String) -> Track:
	for tr in _tracks:
		if tr.track_id == track_id:
			return tr
	return null


## 组与某 Track 的关联评分：组内每个候选与 Track 在**该测量时刻**的预测
## 方位（REQ-09：历史行按该时刻预测/证据关联，不只比较最新方位）取最小
## 角差，归一化 d²（纯方位风格，与 associate 被动分支一致）；最小角差超
## 门限返回 -1。
func _group_track_d2(cands: Array, track: Track, max_angle_deg: float) -> float:
	var prev: Measurement = track.latest_measurement()
	if prev == null:
		return -1.0
	var best_dang: float = 1.0e18
	var best_sigma: float = 0.1
	for m in cands:
		# REQ-09：以该测量自己的时间戳向 Track 外推预测方位。
		var ref_brg: float = track.predicted_bearing_at(m.timestamp)
		if ref_brg < 0.0:
			ref_brg = prev.measured_bearing_deg
		var dang: float = absf(NavUtils.angle_diff(m.measured_bearing_deg, ref_brg))
		if dang < best_dang:
			best_dang = dang
			var s_theta: float = sqrt(
				(
					m.bearing_sigma_deg * m.bearing_sigma_deg
					+ prev.bearing_sigma_deg * prev.bearing_sigma_deg
				)
			)
			best_sigma = maxf(s_theta, 0.1)
	if best_dang > max_angle_deg:
		return -1.0
	return (best_dang / best_sigma) * (best_dang / best_sigma)


func _append_group(track: Track, group: Array) -> void:
	for m in group:
		if m is Measurement:
			track.add_measurement(m)


## S1-11 §3.3 / D-13：显式 Mark 命令的直接追加通道。
## 玩家明确选组（或 Shift＋点击指定接触）时，点击是"记录命令"而非"探测判决"：
## 不检查声强/Pd/分类门限，也不再受 8° 自动关联门否决；空组首点同样成立。
## 自动关联（feed_evidence_group）仍按候选门评分，两条路径互不污染。
func append_group_direct(track: Track, group: Array) -> Track:
	if track == null:
		return null
	if track.state == Track.TrackState.MERGED:
		return null
	var first: Measurement = null
	for m in group:
		if m is Measurement:
			if first == null:
				first = m
			track.add_measurement(m)
	if first != null:
		track.association_confidence = 1.0
		track.last_association_mode = "manual"
		track.last_association_score = 0.0
	return track


## MK-06：纯计算候选——只评分，不改动任何 Track。
## SUGGEST 模式必须在玩家接受前保持零副作用（旧实现先 feed 再提示，等于
## 未获同意就改了航迹，且让同一观测有可能被算两遍）。返回按代价升序的
## [{track, d2}]，调用方自行决定提示/改绑。
func score_group_candidates(group: Array, max_angle_deg: float = 8.0) -> Array:
	var cands: Array = []
	for m in group:
		if m is Measurement and m.detected:
			cands.append(m)
	var out: Array = []
	if cands.is_empty():
		return out
	for track in _tracks:
		var t := track as Track
		if t.state != Track.TrackState.ACTIVE:
			continue
		var d2: float = _group_track_d2(cands, t, max_angle_deg)
		if d2 >= 0.0:
			out.append({"track": t, "d2": d2})
	out.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return float(a["d2"]) < float(b["d2"])
	)
	return out


## MK-03/MK-06：把一条物理证据（A/B 镜像组整体）原子地从一个 Track 移到另一个。
##   - 组内每个成员要么全部迁移成功，要么整体回滚（不允许只搬走 A 支，
##     留下 B 支在原组形成"同一观测两处计数"的裂缝）；
##   - 保持同一 evidence_id / pair_id（改绑不是新探测）；
##   - 返回成功迁移的成员数组（空数组 = 未做任何改动，可原样撤销）。
## source_track 为 null 时自动按当前归属推断。
func move_evidence_group(group: Array, to_track: Track, source_track: Track = null) -> Array:
	var empty: Array = []
	if to_track == null or to_track.state == Track.TrackState.MERGED:
		return empty
	var members: Array = []
	for m in group:
		if m is Measurement:
			members.append(m as Measurement)
	if members.is_empty():
		return empty
	var from_t: Track = source_track
	if from_t == null:
		from_t = track_of_measurement(members[0])
	if from_t == null or from_t == to_track:
		return empty
	var moved: Array = []
	for m in members:
		if not from_t.measurement_history.has(m):
			# 组内成员分散在不同 Track（历史上不该出现）：整体放弃，保持原状。
			_rollback_group(from_t, moved)
			return empty
		if from_t.remove_measurement(m):
			moved.append(m)
		else:
			_rollback_group(from_t, moved)
			return empty
	for m in members:
		to_track.add_measurement(m)
	to_track.association_confidence = 1.0
	to_track.last_association_mode = "manual"
	to_track.last_association_score = 0.0
	return moved


func _rollback_group(from_t: Track, moved: Array) -> void:
	for m in moved:
		if not from_t.measurement_history.has(m):
			from_t.add_measurement(m)


## 公开按 id 查找（UI/控制器用；REQ-B1-03 后台 REFIT 不改选中时需要）。
func track_by_id(track_id: String) -> Track:
	return _find_track(track_id)


## 找到持有该 Measurement 的 Track（重复点击选中既有 Mark 用）。
func track_of_measurement(m: Measurement) -> Track:
	for track in _tracks:
		if (track as Track).measurement_history.has(m):
			return track
	return null


## REQ-B1-05：改绑单条 Measurement 到另一 Track，保持同一物理 evidence_id。
func reassign_measurement(m: Measurement, to_track: Track) -> bool:
	var from_t: Track = track_of_measurement(m)
	if from_t == null or to_track == null or from_t == to_track:
		return false
	if not from_t.remove_measurement(m):
		return false
	to_track.add_measurement(m)
	return true


## REQ-B1-05：从指定 Track 删除一条 Measurement（可撤销由调用方负责）。
func remove_measurement_from(track: Track, m: Measurement) -> bool:
	if track == null or not track.measurement_history.has(m):
		return false
	return track.remove_measurement(m)


## 证据组关联（见上）。group 为同一物理证据的 Measurement 列表（单条亦可）。
## 返回关联/新建到的 Track；无法关联到 preferred Track 时返回 null。
func feed_evidence_group(
	group: Array, preferred_track_id: String = "", max_angle_deg: float = 8.0
) -> Track:
	var cands: Array = []
	for m in group:
		if m is Measurement and m.detected:
			cands.append(m)
	if cands.is_empty():
		return null
	if preferred_track_id != "":
		var pt: Track = _find_track(preferred_track_id)
		if pt == null or pt.state != Track.TrackState.ACTIVE:
			return null
		var d2: float = _group_track_d2(cands, pt, max_angle_deg)
		if d2 < 0.0:
			return null
		_append_group(pt, group)
		pt.association_confidence = _bearing_confidence(d2)
		pt.last_association_mode = "bearing_only"
		pt.last_association_score = d2
		return pt
	var best: Track = null
	var best_d2: float = 1.0e18
	for track in _tracks:
		if track.state != Track.TrackState.ACTIVE:
			continue
		var d2: float = _group_track_d2(cands, track, max_angle_deg)
		if d2 >= 0.0 and d2 < best_d2:
			best_d2 = d2
			best = track
	if best != null:
		_append_group(best, group)
		best.association_confidence = _bearing_confidence(best_d2)
		best.last_association_mode = "bearing_only"
		best.last_association_score = best_d2
	return best


## 推进所有 Track 的陈旧度。
func update_staleness(dt: float) -> void:
	for track in _tracks:
		track.update_staleness(dt)


## 标记某 Track 失去接触（手动/接触消失）。
func mark_lost(track: Track) -> void:
	track.mark_lost()


## 合并多条 Track 成一条 Master Track（M 类）。
func merge_tracks(tracks: Array) -> Track:
	if tracks.is_empty():
		return null
	var first: Track = tracks[0]
	var master := Track.create("M", _next_number.get("M", 1), first.first_measurement())
	_next_number["M"] = _next_number.get("M", 1) + 1
	# 收集全部测量
	var all_m: Array = []
	for tr in tracks:
		for m in tr.measurement_history:
			all_m.append(m)
	all_m.sort_custom(
		func(a: Measurement, b: Measurement) -> bool: return a.timestamp < b.timestamp
	)
	for m in all_m:
		master.add_measurement(m)
	# 标记原 Track 已合并
	for tr in tracks:
		tr.mark_merged(master.track_id)
		master.merged_track_ids.append(tr.track_id)
	_tracks.append(master)
	return master


func all_tracks() -> Array:
	return _tracks


func count() -> int:
	return _tracks.size()
