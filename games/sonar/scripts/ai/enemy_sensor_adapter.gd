class_name EnemySensorAdapter
extends RefCounted
## enemy_sensor_adapter.gd — 敌方传感器采样适配器（S1-07 §9.5/§9.6，Commit 9）。
##
## 仿真内核边界（§2.2）：本类是敌方侧唯一允许接触 Truth 声源（玩家艇/玩家鱼雷/
## 诱饵）与声学事件的对象。向 DoctrineController 输出净化证据（Evidence 字典）：
##   - 只有 noisy bearing / 时间 / 频带 / 分类假设 / 置信度；
##   - 绝无真实 range、绝无目标位置、绝无 target_id/内部引用（§9.3/§9.8）。
##
## 证据来源（§9.6）：玩家持续航行噪声（被动采样）、玩家主动 Ping / 玩家鱼雷
## 发射瞬态 / 来袭鱼雷航行噪声与主动 Ping / 诱饵激活 / 爆炸（事件截获，单程）。
## 方程与玩家声呐同源（统一 AcousticService/DepthLayerModel）：
##   SE_intercept = SL - TL_layer_oneway - N_eff(receiver) + AG - DT
##   Pd = 1/(1+exp(-SE/k_d))（连续概率，未探测事件绝不产生证据 → AI 行为不变）
##
## 确定性：独立派生 RNG，不消耗世界主 RNG。

var env: RefCounted = null  # EnvironmentModel
var depth_model: RefCounted = null  # DepthLayerModel（可为 null）
var rng: RandomNumberGenerator = null
## Truth 声源（仿真内核持有，绝不下发玩法层）。
var contacts: Array = []
var contact_acs: Dictionary = {}  # id -> AcousticProfile

var receiver_ag_db: float = 18.0
var receiver_dt_db: float = 3.0
var receiver_k_d: float = 6.0
var sigma_min_deg: float = 1.0
var sigma_max_deg: float = 8.0
var sigma_se0_db: float = 12.0
var sigma_k_sigma_db: float = 6.0
var false_alarm_rate: float = 0.005
var max_intercept_range_m: float = 30000.0
## S109：与玩家侧同源的共享分类器（§6.1，只看可观测特征）。
var classifier := TorpedoClassifier.new()
var feature_noise_rel: float = 0.08

var _next_evidence_id: int = 1
var _last_event_id: int = 0  # 事件游标（只截获新事件，幂等）
## S109 §6.2：单程传播在途队列——事件按 t_emit + R/c 才可被截获；
## 传播时延与 doctrine 反应延迟是两段独立时间。
var _pending_delayed: Array = []


func bind(env_ref: RefCounted, depth_ref: RefCounted, contacts_arr: Array, acs: Dictionary) -> void:
	env = env_ref
	depth_model = depth_ref
	contacts = contacts_arr
	contact_acs = acs


func set_rng(r: RandomNumberGenerator) -> void:
	rng = r


func reset_cursor() -> void:
	_last_event_id = 0
	_pending_delayed.clear()


## ---- 被动接触采样（玩家持续航行噪声等，§9.6）----
## observer 为敌方实体状态快照（内核内）；输出净化证据（无 range/位置）。
func sample_passive(observer: RefCounted, now: float) -> Array:
	var out: Array = []
	if rng == null or env == null:
		return out
	var freq: float = 1000.0
	for c in contacts:
		var cid: String = str(c.id)
		if not contact_acs.has(cid):
			continue
		var ac: RefCounted = contact_acs[cid]
		var range_m: float = (
			NavUtils
			. distance(
				float(observer.position_east_m),
				float(observer.position_north_m),
				float(c.position_east_m),
				float(c.position_north_m),
			)
		)
		var sl: float = float(ac.broadband_sl_db(float(c.speed_kn), float(c.depth_m)))
		var se: float = (
			AcousticService
			. passive_se_layer(
				sl,
				range_m,
				freq,
				env,
				float(observer.speed_kn),
				float(c.depth_m),
				float(observer.depth_m),
				receiver_ag_db,
				receiver_dt_db,
				-1.0,
				float(observer.position_east_m),
				float(observer.position_north_m),
			)
		)
		var pd: float = AcousticService.detection_probability(se, receiver_k_d)
		if rng.randf() >= pd:
			continue
		# P0-01：真方位来自几何 bearing_to_true，绝不把目标深度当方位。
		var true_brg: float = (
			NavUtils
			. bearing_to_true(
				float(observer.position_east_m),
				float(observer.position_north_m),
				float(c.position_east_m),
				float(c.position_north_m),
			)
		)
		out.append(_passive_evidence("PASSIVE_CONTACT", now, true_brg, se, pd, freq))
	# 误报（独立生成器，不绑定任何真实源）。
	if false_alarm_rate > 0.0 and rng.randf() < false_alarm_rate:
		var ev := _passive_evidence("FALSE_ALARM", now, float(observer.depth_m), 0.0, 0.5, freq)
		ev["bearing_deg"] = NavUtils.wrap360(rng.randf() * 360.0)
		out.append(ev)
	return out


## 被动接触/误报净化证据构造（无 range、无位置、无内部引用、无事件枚举）。
func _passive_evidence(
	kind: String, now: float, true_bearing_deg: float, se: float, pd: float, freq: float
) -> Dictionary:
	var sigma: float = (
		sigma_min_deg
		+ (sigma_max_deg - sigma_min_deg) / (1.0 + exp((se - sigma_se0_db) / sigma_k_sigma_db))
	)
	var ev := {
		"evidence_id": _next_evidence_id,
		"timestamp": now,
		"kind": kind,
		"source_class": "PLATFORM",
		"bearing_deg": NavUtils.wrap360(true_bearing_deg + rng.randfn(0.0, sigma)),
		"bearing_sigma_deg": sigma,
		"se_db": se,
		"pd": pd,
		"confidence": clampf(pd, 0.0, 1.0),
		"freq_hz": freq,
	}
	_next_evidence_id += 1
	return ev


## ---- 事件截获（单程，§9.2/§9.3；S109 §6.2 传播队列）----
## events 为 AcousticEmissionBus 的事件字典数组（内核内允许读源位置/源级）；
## 事件在 t_emit + R/c 之前不可截获；截获成功只产出 noisy bearing + 分类假设，
## 绝不产出 range/位置/事件枚举（§9.3、S109 §2.3）。
func intercept_events(events: Array, observer: RefCounted, now: float) -> Array:
	var out: Array = []
	if rng == null or env == null:
		return out
	# 先结算到点的在途事件，再消费新事件。
	var still_pending: Array = []
	for ev in _pending_delayed:
		if _event_available_time(ev, observer) <= now:
			var res: Dictionary = _intercept_single(ev, observer, now)
			if not res.is_empty():
				out.append(res)
		else:
			still_pending.append(ev)
	_pending_delayed = still_pending
	for ev in events:
		var eid: int = int(ev.get("event_id", 0))
		if eid <= _last_event_id:
			continue
		_last_event_id = maxi(_last_event_id, eid)
		if _event_available_time(ev, observer) > now:
			_pending_delayed.append(ev)  # 在途：到点后结算
			continue
		var res2: Dictionary = _intercept_single(ev, observer, now)
		if not res2.is_empty():
			out.append(res2)
	return out


## 事件可用时刻 = t_emit + R/c（单程传播；S109 §6.2）。
func _event_available_time(ev: Dictionary, observer: RefCounted) -> float:
	var src: Dictionary = ev.get("source_position_internal", {})
	var range_m: float = (
		NavUtils
		. distance(
			float(observer.position_east_m),
			float(observer.position_north_m),
			float(src.get("e", 0.0)),
			float(src.get("n", 0.0)),
		)
	)
	return float(ev.get("emit_time", 0.0)) + range_m / AcousticService.SOUND_SPEED_M_S


## 单事件截获结算（概率）。返回净化证据 dict（空=未探测/超程）。
func _intercept_single(ev: Dictionary, observer: RefCounted, now: float) -> Dictionary:
	var src: Dictionary = ev.get("source_position_internal", {})
	var src_depth: float = float(ev.get("source_depth_internal", 0.0))
	var range_m: float = (
		NavUtils
		. distance(
			float(observer.position_east_m),
			float(observer.position_north_m),
			float(src.get("e", 0.0)),
			float(src.get("n", 0.0)),
		)
	)
	if range_m > max_intercept_range_m:
		return {}
	var freq: float = float(ev.get("center_frequency_hz", 1000.0))
	var sl: float = float(ev.get("source_level_db", 0.0))
	var se: float = (
		AcousticService
		. passive_se_layer(
			sl,
			range_m,
			freq,
			env,
			float(observer.speed_kn),
			src_depth,
			float(observer.depth_m),
			receiver_ag_db,
			receiver_dt_db,
			-1.0,
			float(observer.position_east_m),
			float(observer.position_north_m),
		)
	)
	var pd: float = AcousticService.detection_probability(se, receiver_k_d)
	if rng.randf() >= pd:
		return {}  # 未探测 → 无证据 → AI 行为绝不变（§9.8）
	# P0-01/S109：真方位来自源位置几何（几何事实）；src_depth 只用于跨层
	# 传播损失。类别绝不来自事件枚举（§6.1 共享分类器）。
	var src_brg: float = (
		NavUtils
		. bearing_to_true(
			float(observer.position_east_m),
			float(observer.position_north_m),
			float(src.get("e", 0.0)),
			float(src.get("n", 0.0)),
		)
	)
	var sigma: float = (
		sigma_min_deg
		+ (sigma_max_deg - sigma_min_deg) / (1.0 + exp((se - sigma_se0_db) / sigma_k_sigma_db))
	)
	var brg: float = NavUtils.wrap360(src_brg + rng.randfn(0.0, sigma))
	var tonals: Array = ev.get("tonal_lines", [])
	var est := {
		"center_frequency_hz": _noisy(freq),
		"bandwidth_hz": _noisy(float(ev.get("bandwidth_hz", 0.0))),
		"duration_s": _noisy(float(ev.get("duration_s", 0.0))),
		"tonal_peaks": tonals,
	}
	var obs := AcousticObservation.from_event_features(
		_next_evidence_id,
		now,
		"enemy_intercept",
		float(observer.position_east_m),
		float(observer.position_north_m),
		brg,
		sigma,
		se,
		pd,
		est,
		"EMISSION_INTERCEPT"
	)
	var res: Dictionary = classifier.classify(obs.to_dict())
	var e: Dictionary = obs.to_dict()
	e["kind"] = "EMISSION_INTERCEPT"
	e["bearing_deg"] = brg
	e["bearing_sigma_deg"] = sigma
	e["se_db"] = se
	e["pd"] = pd
	e["confidence"] = clampf(pd, 0.0, 1.0)
	e["freq_hz"] = freq
	# source_class 来自分类器概率结果（§6.1）；PROBABLE → TORPEDO 告警语义。
	e["source_class"] = (
		"TORPEDO"
		if float(res.get("p_torpedo", 0.0)) >= TorpedoClassifier.PROBABLE_TH
		else "UNKNOWN"
	)
	e["p_torpedo"] = float(res.get("p_torpedo", 0.0))
	e["class_state"] = str(res.get("classification_state", "UNCLASSIFIED"))
	_next_evidence_id += 1
	return e


## 特征估计加噪（乘性）：接收端只有估计值。
func _noisy(v: float) -> float:
	if v <= 0.0:
		return v
	return maxf(v * (1.0 + rng.randfn(0.0, feature_noise_rel)), 0.01)

## 净化证据构造已并入 _intercept_single（S109：分类器概率来源，无事件枚举）。
