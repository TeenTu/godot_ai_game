class_name EnemyTrackManager
extends RefCounted
## enemy_track_manager.gd — 敌方航迹管理（S1-07 §9.5，Commit 9）。
##
## 只消费净化证据（无 target_id / 无 range / 无位置）：按方位门限关联、
## 平滑方位/方位率、质量随命中涨随时间衰减（不确定区随证据陈旧扩大）。
## 简化 TMA/不确定区滤波（§9.5）：本版以方位航迹质量 + 证据陈旧度刻画
## 不确定度；方位-only 反击走宽扇区（§9.7 ATTACKING）。
##
## AI-01（P0-B）：**把几个本来被混为一谈的量拆开**——
##   detection_reliability  探测可靠度（Pd 的滑动平均）：这一次报告有多可信
##   classification_confidence 分类置信：它像什么
##   quality                航迹质量：**持续跟踪**的证据充分度（从 0 攒起）
##   motion_quality         运动解质量：需要跨时刻几何才谈得上航向/航速
##   evidence_count / span_s / last_t 证据数、观察跨度、新鲜度
## 旧实现把首次观测 Pd 直接当 quality，于是一条强 Ping 截获就能一次性满足
## 发射门槛；现在攻击资格由 attack_authorized() 独立判定，见该函数。
##
## 纯逻辑、无 RNG（关联确定性），固定 seed 可复现。

var tracks: Array = []  # 航迹字典数组（见 _new_track）

var bearing_gate_deg: float = 12.0
## 每次命中质量增量（× pd）。quality 从 0 攒起，绝不用首次 Pd 直接当质量。
var alpha_hit: float = 0.18
## 首次截获的"怀疑权重"：够进 SUSPICIOUS（要机动、要观察），远不够攻击。
var alpha_first: float = 0.3
var decay_per_s: float = 0.01  # 每秒无证据质量衰减
var min_quality: float = 0.05  # 低于此删除航迹
var ema_gain: float = 0.3  # 方位 EMA 增益
## 运动解质量增长：需要一定跨度与方位变化才谈得上"有解"。
var motion_min_span_s: float = 30.0
var motion_min_evidence: int = 4

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
		# AI-01：quality 从"首次截获的怀疑权重"起步——足以开始观察，
		# 绝不足以直接把一次强 Ping 变成发射资格。
		"quality": clampf(alpha_first * float(ev.get("pd", 0.5)), 0.0, 1.0),
		"detection_reliability": clampf(float(ev.get("pd", 0.5)), 0.0, 1.0),
		"classification_confidence": clampf(float(ev.get("class_confidence", 0.0)), 0.0, 1.0),
		"motion_quality": 0.0,
		"evidence_count": 1,
		"span_s": 0.0,
		"_evidence_ids":
		{str(ev.get("evidence_id", "")): true} if str(ev.get("evidence_id", "")) != "" else {},
		"mean_se_db": float(ev.get("se_db", 0.0)),
		"hits": 1,
		"first_t": now,
		"last_t": now,
		# S109 P0-03：衰减时钟独立于 last_t（证据龄期）——按增量时间衰减，
		# 更新频率不再影响结果（AT-22）。
		"last_decay_t": now,
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
	# AI-01：同一物理证据（同 evidence_id）不得重复抬高质量/证据数。
	var ev_id: String = str(ev.get("evidence_id", ""))
	var known: Dictionary = best.get("_evidence_ids", {})
	var fresh: bool = ev_id == "" or not known.has(ev_id)
	if fresh and ev_id != "":
		known[ev_id] = true
		best["_evidence_ids"] = known
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
	best["detection_reliability"] = lerpf(
		float(best["detection_reliability"]), clampf(float(ev.get("pd", 0.5)), 0.0, 1.0), 0.4
	)
	best["classification_confidence"] = maxf(
		float(best["classification_confidence"]),
		clampf(float(ev.get("class_confidence", 0.0)), 0.0, 1.0)
	)
	if fresh:
		best["evidence_count"] = int(best["evidence_count"]) + 1
		best["quality"] = clampf(
			float(best["quality"]) + alpha_hit * float(ev.get("pd", 0.5)), 0.0, 1.0
		)
	# AI-01：运动解质量需要"证据数 + 观察跨度"共同成立，且随几何缓慢建立；
	# 一次截获永远拿不到运动解，方位-only 反击只能走宽扇区。
	var span: float = maxf(now - float(best["first_t"]), 0.0)
	best["span_s"] = span
	var span_frac: float = clampf(span / maxf(motion_min_span_s, 1.0), 0.0, 1.0)
	var cnt_frac: float = clampf(
		float(best["evidence_count"]) / float(maxi(motion_min_evidence, 1)), 0.0, 1.0
	)
	best["motion_quality"] = clampf(minf(span_frac, cnt_frac), 0.0, 1.0)
	best["hits"] = int(best["hits"]) + 1
	best["last_t"] = now
	best["last_decay_t"] = now  # 新证据重置衰减时钟（S109 P0-03）
	# 分类假设取更"警报"的一方（TORPEDO 优先保留，警示语义不可降级）。
	if str(ev.get("source_class", "")) == "TORPEDO":
		best["source_class"] = "TORPEDO"
	return int(best["track_id"])


## 周期推进：质量按增量时间衰减（delta = now − last_decay_t），低于
## min_quality 删除（不确定区扩大）。S109 P0-03/AT-22：同一证据序列与
## 总时长下，0.1s/0.5s/2s 更新步长得到近似相同结果。
func update(now: float) -> void:
	var keep: Array = []
	for t in tracks:
		var delta: float = maxf(now - float(t["last_decay_t"]), 0.0)
		t["last_decay_t"] = now
		t["quality"] = clampf(float(t["quality"]) - decay_per_s * delta, 0.0, 1.0)
		if float(t["quality"]) >= min_quality:
			keep.append(t)
	tracks = keep


func track_by_id(tid: int) -> Dictionary:
	for t in tracks:
		if int(t["track_id"]) == tid:
			return t
	return {}


## AI-01：攻击资格判据——与"质量"分开，四项条件必须同时成立：
##   ① 独立证据数足够（默认 ≥3，可配置）
##   ② 观察跨度足够（默认 ≥15 仿真秒，可配置）
##   ③ 证据仍然新鲜（默认 30 秒内有更新）
##   ④ 航迹质量达发射门槛（默认 0.7）
## 单条强 Ping 截获只能给出较可靠的**方位**，拿不到这里任何一项的豁免。
func attack_authorized(t: Dictionary, now: float, cfg: Dictionary = {}) -> bool:
	if t.is_empty():
		return false
	var min_ev: int = int(cfg.get("attack_min_evidence", 3))
	var min_span: float = float(cfg.get("attack_min_span_s", 15.0))
	var max_age: float = float(cfg.get("attack_max_evidence_age_s", 30.0))
	var min_q: float = float(cfg.get("fire_quality_threshold", 0.7))
	if now - float(t.get("last_t", now)) > max_age:
		return false
	if int(t.get("evidence_count", 0)) < min_ev:
		return false
	if float(t.get("span_s", 0.0)) < min_span:
		return false
	if float(t.get("quality", 0.0)) < min_q:
		return false
	return true


## AI-01：运动解是否足以支撑 SOLUTION 类发射（本版敌方无主动声呐，
## 该判据供接口/测试使用；不满足时只能 BEARING_ONLY 宽扇区）。
func has_motion_solution(t: Dictionary, min_motion_quality: float = 0.6) -> bool:
	return not t.is_empty() and float(t.get("motion_quality", 0.0)) >= min_motion_quality


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
