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

# S109 §3.5 生命周期：无新证据 → COASTING（置信度随增量仿真时间衰减）
# → 超过门限 LOST（UI 保留最后估计一段时间后移出主要视图）。
const COAST_AFTER_S: float = 20.0
const LOST_AFTER_S: float = 60.0
const CONFIDENCE_DECAY_PER_S: float = 0.01
## §4.4 多目标歧义：最优/次优候选 χ² 代价差小于该值 → 关联不确定，
## 不融合、不缩小任何航迹误差。
const AMBIGUOUS_COST: float = 1.0
## 距离门 σ 地板：防止过度收敛的航迹用几十米伪 σ 拒掉真实回波（AT-14）；
## 离谱距离（9 km 级）仍被拒（AT-15 成立）。
const GATE_MIN_RANGE_SIGMA_M: float = 900.0

# 证据种类升级链（rank 小 → 大；只有升级方向改写主类，绝不降级）。
const KIND_RANK := {
	"LAUNCH_TRANSIENT": 1,
	"RUNNING_NOISE": 2,
	"ACTIVE_PING": 3,
}

var _tracks: Array = []  # [{track_id, kind, state, bearing_deg, bearing_rate_deg_s,
#   sigma_deg, confidence, first_time, last_time, evidence_count, evidence_ids,
#   p_torpedo, class_state}]
var _next_track_id: int = 1
## §3.4 一对一分配：同一仿真时刻一条航迹最多承受一份证据（防近方位
## 双雷被贪心合并；AT-18）。
var _batch_now: float = -1.0
var _batch_taken: Dictionary = {}


func reset() -> void:
	_tracks.clear()
	_next_track_id = 1
	_batch_now = -1.0
	_batch_taken = {}


## §4.4 门面：构造净化回波 DTO + 距离—方位融合；返回净化证据（World 用）。
func fuse_active_measurement(m: Measurement, obs_e: float, obs_n: float, now: float) -> Dictionary:
	var dto := active_return_dto(m, obs_e, obs_n)
	fuse_active_return(dto, now)
	return dto


## S109 §4.4/§2.2：把真实 ACTIVE_RANGE_BEARING 测量构造为净化回波 DTO
## （可观测量+观测时刻本艇快照；结构上无 target_id/内核身份，AT-16）。
static func active_return_dto(m: Measurement, obs_e: float, obs_n: float) -> Dictionary:
	return {
		"evidence_id": m.measurement_id,
		"evidence_kind": "ACTIVE_RETURN",
		"source_mode": "ACTIVE_RETURN",
		"timestamp": m.timestamp,
		"available_time": m.timestamp,
		"sensor_id": m.sensor_id,
		"observer_e_m": obs_e,
		"observer_n_m": obs_n,
		"bearing_deg": m.measured_bearing_deg,
		"bearing_sigma_deg": m.bearing_sigma_deg,
		"measured_range_m": m.measured_range_m,
		"range_sigma_m": m.range_sigma_m,
		"signal_excess_db": m.signal_excess_db,
		"detection_probability": m.detection_probability,
	}


## 生命周期推进（每仿真tick）：无新证据 → COASTING → LOST；COASTING 期
## 置信度按增量仿真时间衰减（§3.5）。确定性（纯时间驱动）。
## 同时推进位置估计器：协方差随过程噪声扩大（AT-12，绝不缩小）。
func advance(now: float) -> void:
	for tr in _tracks:
		var age: float = now - float(tr["last_time"])
		if age > LOST_AFTER_S:
			tr["state"] = "LOST"
		elif age > COAST_AFTER_S:
			tr["state"] = "COASTING"
			tr["confidence"] = clampf(
				float(tr["confidence"]) - CONFIDENCE_DECAY_PER_S * age, 0.0, 1.0
			)
		var est: TorpedoThreatEstimator = tr.get("est")
		if est != null:
			est.predict(now)


## S109 §4.4：主动距离—方位融合。真实 Ping 回波（净化后无 target_id）
## 按方位+距离统计门控关联到已有威胁航迹；成功 → RANGE_AIDED + 距离
## 更新 + 刷新估计；失败 → 返回 ""，绝不人为缩小任何航迹误差（AT-15）。
## 关联绝不使用内核身份（AT-16）。
func fuse_active_return(e: Dictionary, now: float) -> String:
	if not e.has("measured_range_m"):
		return ""
	var z_r: float = float(e["measured_range_m"])
	var s_r: float = maxf(float(e.get("range_sigma_m", 100.0)), 1.0)
	var z_b: float = float(e.get("bearing_deg", 0.0))
	var s_b: float = maxf(float(e.get("bearing_sigma_deg", 2.0)), 0.5)
	if not (e.has("observer_e_m") and e.has("observer_n_m")):
		return ""
	var obs_e: float = float(e["observer_e_m"])
	var obs_n: float = float(e["observer_n_m"])
	# S1-11 §3.5：同一 Ping 批次内每条 TT 航迹最多吸收一条回波（AT-52）。
	var batch_key: String = str(e.get("batch_key", ""))
	# S1-11 §3.5/AT-51..54：批次分配器（ActiveReturnBatch）已完成一对一分配时，
	# 融合必须尊重其决定——只对指定的 preferred 航迹做门控，不再二次做"次优接近"
	# 歧义裁决（否则同一证据会被批次放行却被融合层误拒，真实 RANGE_AIDED 丢失）。
	var preferred: String = str(e.get("preferred_track_id", ""))
	var best: Dictionary = {}
	var best_cost: float = INF
	var second_cost: float = INF
	for tr in _tracks:
		if str(tr.get("state", "TRACKING")) == "LOST":
			continue
		if preferred != "" and str(tr.get("track_id", "")) != preferred:
			continue
		if batch_key != "" and _batch_taken.has("%s:%s" % [batch_key, str(tr["track_id"])]):
			continue
		var est: TorpedoThreatEstimator = tr.get("est")
		if est == null:
			continue
		est.predict(now)
		var pos: Vector2 = est.position()
		var de: float = pos.x - obs_e
		var dn: float = pos.y - obs_n
		var exp_r: float = maxf(sqrt(de * de + dn * dn), 1.0)
		var exp_b: float = NavUtils.wrap360(rad_to_deg(atan2(de, dn)))
		var innov_r: float = absf(z_r - exp_r)
		var innov_b_rad: float = deg_to_rad(absf(NavUtils.wrap180(z_b - exp_b)))
		# 统计门控：马氏距离 3σ（距离/方位各自，含航迹当前协方差——LOB
		# 先验沿航向的大不确定自动放宽门；AT-15：门控失败分支零写入）。
		var hr: Array = [de / exp_r, dn / exp_r]
		var s_r_tot: float = (
			est.quad_pos(hr) + s_r * s_r + GATE_MIN_RANGE_SIGMA_M * GATE_MIN_RANGE_SIGMA_M
		)
		var hb: Array = est.bearing_h_row(obs_e, obs_n)
		var s_b_tot: float = maxf(est.quad_pos(hb) + pow(deg_to_rad(s_b), 2.0), 1e-12)
		if innov_r > 3.0 * sqrt(s_r_tot):
			continue
		if innov_b_rad > maxf(3.0 * sqrt(s_b_tot), deg_to_rad(8.0)):
			continue
		var cost: float = innov_r * innov_r / s_r_tot + innov_b_rad * innov_b_rad / s_b_tot
		if cost < best_cost:
			second_cost = best_cost
			best_cost = cost
			best = tr
		elif cost < second_cost:
			second_cost = cost
	if best.is_empty():
		return ""
	# §4.4：多目标关联仍有歧义 → 不融合（绝不凭先写先赢错绑雷）。
	if second_cost < INF and second_cost - best_cost < AMBIGUOUS_COST:
		return ""
	var est_b: TorpedoThreatEstimator = best["est"]
	est_b.predict(now)
	est_b.bearing_update(z_b, s_b, obs_e, obs_n)
	est_b.range_update(z_r, s_r, obs_e, obs_n)
	best["state"] = "RANGE_AIDED"
	best["range_est_m"] = z_r
	best["range_sigma_m"] = s_r
	best["confidence"] = clampf(maxf(float(best["confidence"]), 0.9), 0.0, 1.0)
	best["last_time"] = now
	best["evidence_count"] = int(best["evidence_count"]) + 1
	(best["evidence_ids"] as Array).append(int(str(e.get("evidence_id", "0")).to_int()))
	# 距离辅助后：估计方位/距离快照供 UI 使用。
	var pos2: Vector2 = est_b.position()
	best["bearing_deg"] = NavUtils.wrap360(rad_to_deg(atan2(pos2.x - obs_e, pos2.y - obs_n)))
	best["source_modes"] = "RANGE_AIDED"
	if batch_key != "":
		_batch_taken["%s:%s" % [batch_key, str(best["track_id"])]] = true
	return str(best["track_id"])


## 航迹估计快照（§4.1，只读副本；UI/威胁卡用）。
func estimate_snapshot(tr: Dictionary) -> Dictionary:
	var out := {
		"track_id": str(tr.get("track_id", "")),
		"state": str(tr.get("state", "")),
		"p_torpedo": float(tr.get("p_torpedo", 0.0)),
		"confidence": float(tr.get("confidence", 0.0)),
		"evidence_count": int(tr.get("evidence_count", 0)),
		"last_update_time": float(tr.get("last_time", 0.0)),
		# PG-06：true = 自动探测/分类链建立（海图标注"自动"）。
		"auto_created": bool(tr.get("auto_created", true)),
		"bearing_est_deg": float(tr.get("bearing_deg", 0.0)),
		"bearing_sigma_deg": float(tr.get("sigma_deg", 2.0)),
		"range_est_m": tr.get("range_est_m"),
		"range_sigma_m": tr.get("range_sigma_m"),
		"position_mean_e_m": null,
		"position_mean_n_m": null,
		"ellipse_a_m": null,
		"ellipse_b_m": null,
		"converged": false,
		"course_est_deg": null,
		"speed_est_kn": null,
		# §4.3/§4.5 绘制专用：95% 椭圆长轴朝向 + 概率中心（走廊渲染锦点）。
		# 与 position_mean_* 区分：未收敛时卡片仍不得展示"精确坐标"（AT-10），
		# 但海图允许画大不确定走廊 + 其中心（非伪精确点声明）。
		"ellipse_angle_deg": null,
		"draw_center_e_m": null,
		"draw_center_n_m": null,
	}
	var est: TorpedoThreatEstimator = tr.get("est")
	if est != null:
		var el: Dictionary = est.ellipse_95()
		out["ellipse_a_m"] = float(el["axis_a_m"])
		out["ellipse_b_m"] = float(el["axis_b_m"])
		out["ellipse_angle_deg"] = 0.5 * rad_to_deg(atan2(2.0 * est.p12, est.p11 - est.p22))
		var cen: Vector2 = est.position()
		out["draw_center_e_m"] = cen.x
		out["draw_center_n_m"] = cen.y
		out["converged"] = est.converged()
		if bool(out["converged"]):
			var pos: Vector2 = est.position()
			out["position_mean_e_m"] = pos.x
			out["position_mean_n_m"] = pos.y
			var vel: Vector2 = est.velocity()
			var spd: float = vel.length()
			out["speed_est_kn"] = spd * 1.94384
			if spd > 0.5:
				out["course_est_deg"] = NavUtils.wrap360(rad_to_deg(atan2(vel.x, vel.y)))
	return out


## 当前威胁航迹（只读数组引用；调用方不得修改）。
func tracks() -> Array:
	return _tracks


## S109 §4.5：UI 快照集合（海图/威胁条/列表消费；无 RNG、零写入）。
func ui_snapshots() -> Array:
	var out: Array = []
	for tr in _tracks:
		out.append(estimate_snapshot(tr))
	return out


## 摄入一条净化证据：关联成功 → 写回 threat_track_id 并更新 track；
## 无法关联 → 新建 track。非威胁类证据（爆炸/诱饵/本艇事实）原样返回 ""。
## S109：类别只来自分类器（class_state / p_torpedo 字段；手工构造的旧式
## 证据无 class_state 时按原有语义接受，保持测试脚手架兼容）。
func ingest(e: Dictionary, now: float) -> String:
	var kind: String = str(e.get("evidence_kind", ""))
	if not KIND_RANK.has(kind):
		return ""
	var state: String = str(e.get("class_state", "PROBABLE_TORPEDO"))
	if state != "" and state == "UNCLASSIFIED":
		return ""
	var p_torp: float = float(e.get("p_torpedo", 1.0))
	var brg: float = float(e.get("bearing_deg", 0.0))
	var sigma: float = maxf(float(e.get("bearing_sigma_deg", 2.0)), 0.5)
	var conf: float = clampf(float(e.get("confidence", 0.0)), 0.0, 1.0)
	var best: Dictionary = {}
	var best_cost: float = INF
	# §3.4：同帧证据批次重置一对一分配台账。
	if now != _batch_now:
		_batch_now = now
		_batch_taken = {}
	for tr in _tracks:
		if _batch_taken.has(str(tr["track_id"])):
			continue  # 同帧已被更高优先证据占用
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
	var obs_ok: bool = e.has("observer_e_m") and e.has("observer_n_m")
	if best.is_empty():
		if _tracks.size() >= MAX_TRACKS:
			_tracks.pop_front()
		var tid: String = "TT%03d" % _next_track_id
		_next_track_id += 1
		best = {
			"track_id": tid,
			"kind": kind,
			"state": "TENTATIVE",
			"bearing_deg": brg,
			"bearing_rate_deg_s": 0.0,
			"sigma_deg": sigma,
			"confidence": conf,
			"first_time": now,
			"last_time": now,
			"evidence_count": 1,
			"evidence_ids": [int(str(e.get("evidence_id", "0")).to_int())],
			"p_torpedo": p_torp,
			"class_state": state,
			"range_est_m": null,
			"range_sigma_m": null,
			"est": null,
			# PG-06：威胁航迹由自动探测/分类链建立（玩家手工标绘走普通接触航迹），
			# 海图据此标注"TTxxx 自动"，与玩家确认过的目标区分。
			"auto_created": true,
		}
		_tracks.append(best)
		if obs_ok:
			var est := TorpedoThreatEstimator.new()
			est.init_from_bearing(
				brg, sigma, float(e["observer_e_m"]), float(e["observer_n_m"]), now
			)
			best["est"] = est
	else:
		var dt2: float = maxf(now - float(best["last_time"]), 1e-3)
		var pred2: float = NavUtils.wrap360(
			float(best["bearing_deg"]) + float(best["bearing_rate_deg_s"]) * dt2
		)
		var innov2: float = NavUtils.wrap180(brg - pred2)
		# 方位 EMA + 方位率更新（同 SeekerTrack 风格的轻量滤波）。
		# 方位 EMA + 方位率。Batch 3：率估计对单点创新噪声平滑（lerp 0.15 +
		# 紧 clamp），防近距鱼雷抖动把预测方位打飞 → 证据分裂新 TT。
		var alpha: float = 0.35
		best["bearing_deg"] = NavUtils.wrap360(pred2 + alpha * innov2)
		best["bearing_rate_deg_s"] = clampf(
			lerpf(float(best["bearing_rate_deg_s"]), innov2 / dt2, 0.15), -4.0, 4.0
		)
		best["sigma_deg"] = maxf(float(best["sigma_deg"]) * 0.95, sigma)
		best["confidence"] = maxf(float(best["confidence"]), conf)
		best["last_time"] = now
		best["evidence_count"] = int(best["evidence_count"]) + 1
		(best["evidence_ids"] as Array).append(int(str(e.get("evidence_id", "0")).to_int()))
		best["p_torpedo"] = maxf(float(best.get("p_torpedo", 0.0)), p_torp)
		# S109 §4.2：被动方位估计更新（测量时刻本艇位置快照）。
		if obs_ok:
			var est2: TorpedoThreatEstimator = best.get("est")
			if est2 == null:
				est2 = TorpedoThreatEstimator.new()
				est2.init_from_bearing(
					brg, sigma, float(e["observer_e_m"]), float(e["observer_n_m"]), now
				)
				best["est"] = est2
			else:
				est2.predict(now)
				est2.bearing_update(brg, sigma, float(e["observer_e_m"]), float(e["observer_n_m"]))
		if state != "":
			best["class_state"] = state
		# §3.5：TENTATIVE → TRACKING（≥2 份证据或高概率）；COASTING/LOST →
		# 重获。RANGE_AIDED 不被被动证据降级（测距结果不丢，AT-14 可观测）。
		var st_now: String = str(best.get("state", "TENTATIVE"))
		if (
			st_now in ["TENTATIVE", "COASTING", "LOST"]
			and (
				int(best["evidence_count"]) >= 2
				or float(best.get("p_torpedo", 0.0)) >= TorpedoClassifier.PROBABLE_TH
			)
		):
			best["state"] = "TRACKING"
		# 升级链：只升不降（TRANSIENT → NOISE → PING 同一张威胁卡）。
		var old_rank: int = int(KIND_RANK.get(str(best["kind"]), 0))
		if int(KIND_RANK[kind]) > old_rank:
			best["kind"] = kind
	e["threat_track_id"] = str(best["track_id"])
	_batch_taken[str(best["track_id"])] = true  # 同帧一对一（AT-18）
	# S109：分类假设来自分类器状态，不再无条件写死 TORPEDO。
	e["source_class_hypothesis"] = (
		"TORPEDO" if p_torp >= TorpedoClassifier.SUSPECTED_TH else "UNKNOWN"
	)
	return str(best["track_id"])
