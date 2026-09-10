class_name WireDepthRelay
extends RefCounted
## wire_depth_relay.gd — S1-11 §7.2/§7.5：鱼雷导线回传 → 母艇接触深度概率中继。
##
## 语义（AT-32）：
##   - 只有「导线 CONNECTED」的己方在水鱼雷才允许新增回传；BROKEN/CUT 立即停止
##     （已有估计继续按半衰期衰减，不清零、不伪造）；
##   - 回传内容只有 Seeker 的**带噪层带提示**（UPPER/LOWER → 层似然），来源标
##     `DepthEvidence.SRC_TORPEDO_WIRE`，UI 显示「鱼雷回传」；
##   - 关联「所关联接触」只用玩家可见几何：主动回波同时给出带噪方位 + 距离，
##     即鱼雷自己的目标**位置观测**；把它与母艇各 Track 的最新 LOB 做角残差门，
##     命中者即所关联接触（绝不用 target_id / Truth 位置裁决）；
##   - 已被关联的接触具粘滞性（避免相邻两 Track 之间来回跳），Track 消失即解除。
##
## 信息边界：只消费 SeekerReturn（净化）+ Measurement（玩家可见），绝不读 Truth。

## 位置观测与 Track 最新 LOB 的角残差门（度）。
const ASSOC_TOL_DEG: float = 12.0
## 合法的测距范围（m）——太小 = 本艇/友军回声，太大 = 不可信。
const MIN_FIX_RANGE_M: float = 40.0
const MAX_FIX_RANGE_M: float = 40000.0

var relayed_count: int = 0
## torpedo_id -> track_id（粘滞关联；Track 消失自动解除）。
var _assoc: Dictionary = {}


func reset() -> void:
	relayed_count = 0
	_assoc.clear()


## 每帧调用一次。返回本帧新增的深度证据条数（去重由 DepthEstimator 保证）。
func advance(world: World, tracker: Tracker, sim_time: float) -> int:
	# AT-31：无论是否有回传，陈旧证据都要随时间衰减。
	_decay_all(tracker, sim_time)
	if world == null or world.weapons == null or tracker == null:
		return 0
	var added: int = 0
	for tp in world.weapons.torpedoes:
		if tp == null or tp.is_dead():
			continue
		var tid: String = str(tp.torpedo_id)
		if _assoc.has(tid) and tracker.track_by_id(str(_assoc[tid])) == null:
			_assoc.erase(tid)
		# AT-32：断线后不再新增回传。
		if not tp.wire_link.accepts_commands():
			continue
		var r: SeekerReturn = _newest_fix(tp)
		if r == null:
			continue
		var like: Dictionary = _likelihoods(str(r.depth_band_hint))
		var ev := (
			DepthEvidence
			. make(
				"WIRE:%s:%d" % [tid, int(r.return_id)],
				sim_time,
				DepthEvidence.SRC_TORPEDO_WIRE,
				tid,
				like,
				str(r.depth_band_hint),
			)
		)
		if not ev.is_usable():
			continue
		var owner: Track = _associate(tp, r, tracker)
		if owner == null:
			continue
		if owner.ingest_depth_evidence(ev, sim_time):
			_assoc[tid] = str(owner.track_id)
			relayed_count += 1
			added += 1
	return added


## 关联接触的 track_id（UI/测试可读；空 = 未关联）。
func associated_track(torpedo_id: String) -> String:
	return str(_assoc.get(torpedo_id, ""))


func _decay_all(tracker: Tracker, sim_time: float) -> void:
	if tracker == null:
		return
	for t in tracker.all_tracks():
		if t != null:
			t.depth_estimate_decay(sim_time)


## 最新一条可用于定位的 Seeker 回波：ACTIVE + 有效测距 + 有层带提示。
func _newest_fix(tp: Torpedo) -> SeekerReturn:
	var i: int = tp.seeker_returns.size() - 1
	while i >= 0:
		var r = tp.seeker_returns[i]
		i -= 1
		if not (r is SeekerReturn) or not r.detected:
			continue
		if str(r.sensor_mode) != "ACTIVE":
			continue
		if r.range_m < MIN_FIX_RANGE_M or r.range_m > MAX_FIX_RANGE_M:
			continue
		if r.range_sigma_m <= 0.0 or str(r.depth_band_hint) == "":
			continue
		return r
	return null


## 回波位置观测（鱼雷自身位置 + 带噪方位/距离）→ 与玩家 Track LOB 做角残差门。
func _associate(tp: Torpedo, r: SeekerReturn, tracker: Tracker) -> Track:
	var fix := Vector2(
		float(tp.pos_east_m) + r.range_m * sin(deg_to_rad(r.bearing_deg)),
		float(tp.pos_north_m) + r.range_m * cos(deg_to_rad(r.bearing_deg))
	)
	if _assoc.has(str(tp.torpedo_id)):
		var sticky: Track = tracker.track_by_id(str(_assoc[str(tp.torpedo_id)]))
		if sticky != null and residual_deg(sticky, fix) <= ASSOC_TOL_DEG:
			return sticky
	var best: Track = null
	var best_res: float = ASSOC_TOL_DEG
	for t in tracker.all_tracks():
		if t == null:
			continue
		var res: float = residual_deg(t, fix)
		if res < best_res:
			best_res = res
			best = t
	return best


## 位置观测相对 Track 最新 LOB 的角残差（度）。
## 观测必须落在 LOB 正方向（投影 > 0）；无测量 / 反向 / 超出量程 → 大值（不可关联）。
static func residual_deg(track: Track, fix: Vector2) -> float:
	if track == null:
		return 9.9e9
	var lm = track.latest_measurement()
	if lm == null or not lm.detected:
		return 9.9e9
	var obs := Vector2(float(lm.observer_east_m), float(lm.observer_north_m))
	var rel := fix - obs
	var dist: float = rel.length()
	if dist < MIN_FIX_RANGE_M or dist > MAX_FIX_RANGE_M:
		return 9.9e9
	var brg: float = rad_to_deg(atan2(rel.x, rel.y))
	var along: float = (
		dist * cos(deg_to_rad(NavUtils.wrap180(brg - float(lm.measured_bearing_deg))))
	)
	if along <= 0.0:
		return 9.9e9  # 落在 LOB 反方向
	return absf(NavUtils.wrap180(brg - float(lm.measured_bearing_deg)))


## §7.2：只有层带提示（带噪垂向粗分类）才是合法深度证据，映射为层似然。
static func _likelihoods(band: String) -> Dictionary:
	match band:
		"UPPER":
			return {DepthEstimator.UPPER: 1.0}
		"LOWER":
			return {DepthEstimator.LOWER: 1.0}
	return {}
