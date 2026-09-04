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

var env: RefCounted = null
var depth_model: RefCounted = null
var rng: RandomNumberGenerator = null

var receiver_ag_db: float = 20.0
var receiver_dt_db: float = 3.0
var receiver_k_d: float = 6.0
var sigma_min_deg: float = 1.0
var sigma_max_deg: float = 8.0

var _next_evidence_id: int = 1
var _last_event_id: int = 0


func bind(env_ref: RefCounted, depth_ref: RefCounted, r: RandomNumberGenerator) -> void:
	env = env_ref
	depth_model = depth_ref
	rng = r


func reset_cursor() -> void:
	_last_event_id = 0


## 消费新事件，产出净化证据（DETONATION_HEARD / 告警 / 本艇武器事实）。
## own_emitter_refs：己方 emitter 内部引用集合（本艇 id、己方鱼雷/诱饵 id）。
func consume_events(
	events: Array, own: RefCounted, now: float, own_emitter_refs: Dictionary
) -> Array:
	var out: Array = []
	if env == null:
		return out
	for ev in events:
		var eid: int = int(ev.get("event_id", 0))
		if eid <= _last_event_id:
			continue
		_last_event_id = maxi(_last_event_id, eid)
		var emitter: String = str(ev.get("emitter_internal_ref", ""))
		var kind: String = str(ev.get("emission_kind", ""))
		var own_side: bool = own_emitter_refs.has(emitter)
		if own_side:
			# 本艇事实：自己的武器/诱饵事件直接转录（无 Truth 目标信息）。
			# 方位与接收 SE 由本艇位置对事件源计算（己方武器状态合法信息，
			# 确定性计算、不消耗 RNG、不做探测门限判定）。
			out.append(_make_fact(ev, kind, emitter, own))
			continue
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
			continue  # 未探测 → 无证据 → UI/告警绝不变（§9.8 同纪律）
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
		(
			out
			. append(
				{
					"evidence_id": _next_evidence_id,
					"timestamp": now,
					"side_hint": "INTERCEPT",
					"alert": _alert_for(kind),
					"emission_kind": kind,
					"bearing_deg": NavUtils.wrap360(true_brg + rng.randfn(0.0, sigma)),
					"bearing_sigma_deg": sigma,
					"se_db": se,
					"pd": pd,
					"confidence": clampf(pd, 0.0, 1.0),
					"freq_hz": freq,
				}
			)
		)
		_next_evidence_id += 1
	return out


## 战果反馈层级（§10.4，纯函数）：输入爆炸证据（含方位）与玩家航迹方位集合
## （均为玩家合法数据）。绝不读 target_id / damage_state。
static func classify_detonation(
	evidence: Dictionary, track_bearings_deg: Array, own_detonated: bool
) -> String:
	if str(evidence.get("emission_kind", "")) != AcousticEmissionEvent.EXPLOSION:
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


## 本艇事实转录（无探测判定、无 Truth）。bearing_deg/se_db 为本艇声学
## 接收端的确定性计算值，供 classify_detonation() 做战果层级判定（§10.4）。
func _make_fact(ev: Dictionary, kind: String, emitter: String, own: RefCounted) -> Dictionary:
	var fact := {
		"evidence_id": _next_evidence_id,
		"timestamp": float(ev.get("emit_time", 0.0)),
		"side_hint": "OWN_FACT",
		"alert": _alert_for(kind),
		"emission_kind": kind,
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
