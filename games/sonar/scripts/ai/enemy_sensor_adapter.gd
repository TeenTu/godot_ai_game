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

var _next_evidence_id: int = 1
var _last_event_id: int = 0  # 事件游标（只截获新事件，幂等）


func bind(env_ref: RefCounted, depth_ref: RefCounted, contacts_arr: Array, acs: Dictionary) -> void:
	env = env_ref
	depth_model = depth_ref
	contacts = contacts_arr
	contact_acs = acs


func set_rng(r: RandomNumberGenerator) -> void:
	rng = r


func reset_cursor() -> void:
	_last_event_id = 0


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
			)
		)
		var pd: float = AcousticService.detection_probability(se, receiver_k_d)
		if rng.randf() >= pd:
			continue
		out.append(_make_evidence("PASSIVE_CONTACT", now, float(c.depth_m), se, pd, freq, ""))
	# 误报（独立生成器，不绑定任何真实源）。
	if false_alarm_rate > 0.0 and rng.randf() < false_alarm_rate:
		var ev := _make_evidence("FALSE_ALARM", now, float(observer.depth_m), 0.0, 0.5, freq, "")
		ev["bearing_deg"] = NavUtils.wrap360(rng.randf() * 360.0)
		out.append(ev)
	return out


## ---- 事件截获（单程，§9.2/§9.3）----
## events 为 AcousticEmissionBus 的事件字典数组（内核内允许读源位置/源级）；
## 截获成功只产出 noisy bearing + 分类假设，绝不产出 range/位置（§9.3）。
func intercept_events(events: Array, observer: RefCounted, now: float) -> Array:
	var out: Array = []
	if rng == null or env == null:
		return out
	for ev in events:
		var eid: int = int(ev.get("event_id", 0))
		if eid <= _last_event_id:
			continue
		_last_event_id = maxi(_last_event_id, eid)
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
			continue
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
			)
		)
		var pd: float = AcousticService.detection_probability(se, receiver_k_d)
		if rng.randf() >= pd:
			continue  # 未探测 → 无证据 → AI 行为绝不变（§9.8）
		out.append(
			_make_evidence(
				"EMISSION_INTERCEPT", now, src_depth, se, pd, freq, str(ev.get("emission_kind", ""))
			)
		)
	return out


## 净化证据构造：无 range、无位置、无内部引用。source_class 只是从声学特征
## 得到的分类假设（§9.3 emission kind hypothesis），不是身份。
func _make_evidence(
	kind: String,
	now: float,
	true_bearing_deg: float,
	se: float,
	pd: float,
	freq: float,
	emission_kind: String
) -> Dictionary:
	var sigma: float = (
		sigma_min_deg
		+ (sigma_max_deg - sigma_min_deg) / (1.0 + exp((se - sigma_se0_db) / sigma_k_sigma_db))
	)
	var ev := {
		"evidence_id": _next_evidence_id,
		"timestamp": now,
		"kind": kind,
		"source_class": _classify(emission_kind),
		"emission_kind": emission_kind,
		"bearing_deg": NavUtils.wrap360(true_bearing_deg + rng.randfn(0.0, sigma)),
		"bearing_sigma_deg": sigma,
		"se_db": se,
		"pd": pd,
		"confidence": clampf(pd, 0.0, 1.0),
		"freq_hz": freq,
	}
	_next_evidence_id += 1
	return ev


## 分类假设（§9.3）：从事件类型/声学特征得到，绝不读内部身份字段。
func _classify(emission_kind: String) -> String:
	if emission_kind.begins_with("TORPEDO"):
		return "TORPEDO"
	if emission_kind == AcousticEmissionEvent.PLATFORM_ACTIVE_PING:
		return "PING"
	if emission_kind == AcousticEmissionEvent.EXPLOSION:
		return "EXPLOSION"
	if emission_kind == AcousticEmissionEvent.DECOY_ACTIVATION:
		return "DECOY"
	return "PLATFORM"
