class_name EmissionSanitizer
extends RefCounted
## emission_sanitizer.gd — 事件净化器（S1-07 §10.4/§12.3，Commit 10）。
##
## 内核事件（含 internal_emitter_ref / 源位置）出玩法层前必须经过本类：
##   - 只输出净化证据字典（noisy bearing / 时间 / 告警种类 / 置信度）；
##   - 绝不携带 target_id、真实位置、range（被动单程探测无距离）、内部引用；
##   - 敌方声学事件（来袭鱼雷瞬态/噪声/主动 Ping/诱饵/爆炸）按单程
##     SE_intercept = SL − TL_layer − N_eff + AG − DT 概率截获（§9.3 同源）；
##     未探测绝不产证据（UI/告警不变）；
##   - 己方武器事件（own_emitter_refs 集合内）作为本艇事实（OWN_FACT）直接
##     转录（不消耗 RNG、不做探测判定——自己的武器状态是合法信息）。
##
## 战果反馈层级（§10.4）：DETONATION_HEARD → PROBABLE_HIT → PROBABLE_KILL
## 由 classify_detonation() 纯函数给出（基于证据 + 玩家航迹方位，均为合法
## 数据）；CONFIRMED_KILL 只能由 Debrief（调试通道）或任务脚本给出。
##
## P0-07：证据携带地图威胁图层所需字段——接收时刻本艇位置快照
## (observer_e_m/observer_n_m)、available_time、evidence_kind（
## LAUNCH_TRANSIENT / RUNNING_NOISE / ACTIVE_PING / DETONATION / DECOY）与
## sensor_id。地图 LOB 起点用接收时刻快照，本艇机动后不漂移（AT-09）；
## 绝不包含 Truth 位置 / range / target_id。

# P0-07/S109：本类不再把内核事件枚举映射为鱼雷类别（P0-01 修复）。己方事件
# （own_emitter_refs 集合内）是本艇合法已知事实，仍按事件种类转录；敌方事件
# 一律经 TorpedoClassifier（只看可观测特征）得到分类结果。
const _FACT_EVIDENCE_KINDS := {
	AcousticEmissionEvent.EXPLOSION: "DETONATION",
	AcousticEmissionEvent.DECOY_ACTIVATION: "DECOY",
}

var env: RefCounted = null
var depth_model: RefCounted = null
var rng: RandomNumberGenerator = null

var receiver_ag_db: float = 20.0
var receiver_dt_db: float = 3.0
var receiver_k_d: float = 6.0
var sigma_min_deg: float = 1.0
var sigma_max_deg: float = 8.0
## S109：特征估计噪声（加噪/量化，绝不复制发射端配置原值）。
var feature_noise_rel: float = 0.08
var classifier := TorpedoClassifier.new()

var _next_evidence_id: int = 1
var _last_event_id: int = 0
## 验收12：单程传播时延在途台账——事件按 t_emit + R/c 才可被发现
##（出管/电机启动/主动 Ping/爆炸等敌方瞬态不是光速）。到点后再结算。
var _pending_delayed: Array = []  # [ev, ...]（ emit_time + R/c > now 的敌方事件）


func bind(env_ref: RefCounted, depth_ref: RefCounted, r: RandomNumberGenerator) -> void:
	env = env_ref
	depth_model = depth_ref
	rng = r


func reset_cursor() -> void:
	_last_event_id = 0
	_pending_delayed.clear()


## 消费新事件，产出净化证据（DETONATION_HEARD / 告警 / 本艇武器事实）。
## own_emitter_refs：己方 emitter 内部引用集合（本艇 id、己方鱼雷/诱饵 id）。
func consume_events(
	events: Array, own: RefCounted, now: float, own_emitter_refs: Dictionary
) -> Array:
	var out: Array = []
	if env == null:
		return out
	# 先结算到点的在途事件（t_emit + R/c <= now），再消费新事件（保持 event_id
	# 顺序）。到点判定用接收时刻距离——接收端只掌握几何事实（非 Truth 泄露：
	# 这是声学到达时间的物理事实，与玩家主动测距同源）。
	var still_pending: Array = []
	for ev in _pending_delayed:
		if _event_available_time(ev, own) <= now:
			var res: Dictionary = _consume_single(ev, own, now)
			out.append_array(res["evidence"])
		else:
			still_pending.append(ev)
	_pending_delayed = still_pending
	for ev in events:
		var eid: int = int(ev.get("event_id", 0))
		if eid <= _last_event_id:
			continue
		_last_event_id = maxi(_last_event_id, eid)
		var emitter: String = str(ev.get("emitter_internal_ref", ""))
		if own_emitter_refs.has(emitter):
			# 己方事件无传播延迟（本艇事实，接收即合法信息）。
			out.append(_make_fact(ev, str(ev.get("emission_kind", "")), emitter, own))
			continue
		var avail: float = _event_available_time(ev, own)
		if avail > now:
			_pending_delayed.append(ev)  # 在途：到点后结算
			continue
		var res2: Dictionary = _consume_single(ev, own, now)
		out.append_array(res2["evidence"])
	return out


## 事件可用时刻 = t_emit + R/c（单程传播；验收12）。
func _event_available_time(ev: Dictionary, own: RefCounted) -> float:
	var src: Dictionary = ev.get("source_position_internal", {})
	var range_m: float = (
		NavUtils
		. distance(
			float(own.position_east_m),
			float(own.position_north_m),
			float(src.get("e", 0.0)),
			float(src.get("n", 0.0)),
		)
	)
	return float(ev.get("emit_time", 0.0)) + range_m / AcousticService.SOUND_SPEED_M_S


## 单事件结算（敌方瞬态概率截获）。返回 {"evidence": [...]}。
## S109 P0-01：类别只由 TorpedoClassifier 从可观测特征得出；输出证据
## 绝不含 emission_kind / target_id / Truth 位置（§2.3）。
func _consume_single(ev: Dictionary, own: RefCounted, now: float) -> Dictionary:
	var out: Array = []
	# 敌方事件：单程概率截获（§9.3）。
	var src: Dictionary = ev.get("source_position_internal", {})
	var range_m: float = (
		NavUtils
		. distance(
			float(own.position_east_m),
			float(own.position_north_m),
			float(src.get("e", 0.0)),
			float(src.get("n", 0.0)),
		)
	)
	var freq: float = float(ev.get("center_frequency_hz", 1000.0))
	var sl: float = float(ev.get("source_level_db", 0.0))
	var se: float = (
		AcousticService
		. passive_se_layer(
			sl,
			range_m,
			freq,
			env,
			float(own.speed_kn),
			float(ev.get("source_depth_internal", 0.0)),
			float(own.depth_m),
			receiver_ag_db,
			receiver_dt_db,
		)
	)
	var pd: float = AcousticService.detection_probability(se, receiver_k_d)
	if rng == null or rng.randf() >= pd:
		return {"evidence": out}  # 未探测 → 无证据 → UI/告警绝不变（§9.8 同纪律）
	var sigma: float = (
		sigma_min_deg + (sigma_max_deg - sigma_min_deg) / (1.0 + exp((se - 12.0) / 6.0))
	)
	var true_brg: float = (
		NavUtils
		. bearing_to_true(
			float(own.position_east_m),
			float(own.position_north_m),
			float(src.get("e", 0.0)),
			float(src.get("n", 0.0)),
		)
	)
	var brg: float = NavUtils.wrap360(true_brg + rng.randfn(0.0, sigma))
	# 接收端特征估计（加噪+量化）：中心频率/带宽/持续时间/谱线数。
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
		"own_passive",
		float(own.position_east_m),
		float(own.position_north_m),
		brg,
		sigma,
		se,
		pd,
		est,
		"EMISSION_INTERCEPT"
	)
	var res: Dictionary = classifier.classify(obs.to_dict())
	var kind: String = TorpedoClassifier.evidence_kind_for(res)
	var alert: String = TorpedoClassifier.alert_for(res)
	var e: Dictionary = obs.to_dict()
	# UI/航迹层兼容键（视图别名；DTO 纪律见 §2.2/§2.3）。
	e["bearing_deg"] = brg
	e["side_hint"] = "INTERCEPT"
	e["alert"] = alert
	e["evidence_kind"] = kind
	e["se_db"] = se
	e["pd"] = pd
	e["confidence"] = clampf(pd, 0.0, 1.0)
	e["p_torpedo"] = float(res.get("p_torpedo", 0.0))
	e["class_state"] = str(res.get("classification_state", "UNCLASSIFIED"))
	e["class_cues"] = res.get("cues", [])
	e["model_version"] = str(res.get("model_version", ""))
	out.append(e)
	_next_evidence_id += 1
	return {"evidence": out}


## 战果反馈层级（§10.4，纯函数）：输入爆炸证据（含方位）与玩家航迹方位集合
## （均为玩家合法数据）。绝不读 target_id / damage_state。识别爆炸证据用
## 净化后的 evidence_kind（DETONATION，分类器线索）/ 己方事实的 emission_kind。
static func classify_detonation(
	evidence: Dictionary, track_bearings_deg: Array, own_detonated: bool
) -> String:
	var is_blast: bool = (
		str(evidence.get("evidence_kind", "")) == "DETONATION"
		or str(evidence.get("emission_kind", "")) == AcousticEmissionEvent.EXPLOSION
	)
	if not is_blast:
		return ""
	if not own_detonated:
		return "DETONATION_HEARD"
	# 己方武器爆炸：与任一在跟航迹方位一致 → PROBABLE_HIT；SE 高（近炸强
	# 回声）且一致 → PROBABLE_KILL。
	var brg: float = float(evidence.get("bearing_deg", 0.0))
	var matched: bool = false
	for tb in track_bearings_deg:
		if absf(NavUtils.wrap180(brg - float(tb))) <= 8.0:
			matched = true
			break
	if not matched:
		return "DETONATION_HEARD"
	if float(evidence.get("se_db", 0.0)) >= 20.0:
		return "PROBABLE_KILL"
	return "PROBABLE_HIT"


func _alert_for(kind: String) -> String:
	match kind:
		AcousticEmissionEvent.TORPEDO_TUBE_TRANSIENT:
			return "POSSIBLE_LAUNCH_TRANSIENT"
		AcousticEmissionEvent.TORPEDO_RUNNING_NOISE:
			return "POSSIBLE_TORPEDO"
		AcousticEmissionEvent.TORPEDO_ACTIVE_PING:
			return "TORPEDO_ACTIVE_PING"
		AcousticEmissionEvent.DECOY_ACTIVATION:
			return "DECOY_DEPLOYED"
		AcousticEmissionEvent.EXPLOSION:
			return "DETONATION_HEARD"
	return "ACOUSTIC_EVENT"


## 己方事件种类 → 本艇事实证据种类（合法已知事实；非敌方识别）。
func _fact_evidence_kind_for(kind: String) -> String:
	return str(_FACT_EVIDENCE_KINDS.get(kind, "ACOUSTIC_EVENT"))


## 特征估计加噪（乘性）：接收端只有估计值，不是发射配置原值。
func _noisy(v: float) -> float:
	if v <= 0.0 or rng == null:
		return v
	return maxf(v * (1.0 + rng.randfn(0.0, feature_noise_rel)), 0.01)


## 本艇事实转录（无探测判定、无 Truth）。bearing_deg/se_db 为本艇声学
## 接收端的确定性计算值，供 classify_detonation() 做战果层级判定（§10.4）。
func _make_fact(ev: Dictionary, kind: String, emitter: String, own: RefCounted) -> Dictionary:
	var fact := {
		"evidence_id": _next_evidence_id,
		"timestamp": float(ev.get("emit_time", 0.0)),
		"side_hint": "OWN_FACT",
		"alert": _alert_for(kind),
		"emission_kind": kind,
		"evidence_kind": _fact_evidence_kind_for(kind),
		"own_emitter_ref": emitter,  # 己方武器 id（非敌方身份，合法）
		"confidence": 1.0,
	}
	if env != null:
		var src: Dictionary = ev.get("source_position_internal", {})
		var brg: float = (
			NavUtils
			. bearing_to_true(
				float(own.position_east_m),
				float(own.position_north_m),
				float(src.get("e", 0.0)),
				float(src.get("n", 0.0)),
			)
		)
		var range_m: float = (
			NavUtils
			. distance(
				float(own.position_east_m),
				float(own.position_north_m),
				float(src.get("e", 0.0)),
				float(src.get("n", 0.0)),
			)
		)
		var freq: float = float(ev.get("center_frequency_hz", 1000.0))
		fact["bearing_deg"] = NavUtils.wrap360(brg)
		fact["bearing_sigma_deg"] = 0.0  # 本艇事实无方位误差
		fact["se_db"] = (
			AcousticService
			. passive_se_layer(
				float(ev.get("source_level_db", 0.0)),
				range_m,
				freq,
				env,
				float(own.speed_kn),
				float(ev.get("source_depth_internal", 0.0)),
				float(own.depth_m),
				receiver_ag_db,
				receiver_dt_db,
			)
		)
		fact["freq_hz"] = freq
	_next_evidence_id += 1
	return fact
