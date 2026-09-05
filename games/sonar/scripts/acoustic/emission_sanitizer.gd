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

# P0-07：事件种类 → 威胁证据种类（地图图层颜色/线型语义）。
const _EVIDENCE_KINDS := {
	AcousticEmissionEvent.TORPEDO_TUBE_TRANSIENT: "LAUNCH_TRANSIENT",
	AcousticEmissionEvent.TORPEDO_MOTOR_START: "LAUNCH_TRANSIENT",
	AcousticEmissionEvent.TORPEDO_RUNNING_NOISE: "RUNNING_NOISE",
	AcousticEmissionEvent.TORPEDO_ACTIVE_PING: "ACTIVE_PING",
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
func _consume_single(ev: Dictionary, own: RefCounted, now: float) -> Dictionary:
	var out: Array = []
	var kind: String = str(ev.get("emission_kind", ""))
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
	(
		out
		. append(
			{
				"evidence_id": _next_evidence_id,
				"timestamp": now,
				"available_time": now,
				"side_hint": "INTERCEPT",
				"alert": _alert_for(kind),
				"emission_kind": kind,
				"evidence_kind": _evidence_kind_for(kind),
				"sensor_id": "own_passive",
				"observer_e_m": float(own.position_east_m),
				"observer_n_m": float(own.position_north_m),
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
	return {"evidence": out}


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


func _evidence_kind_for(kind: String) -> String:
	return str(_EVIDENCE_KINDS.get(kind, "ACOUSTIC_EVENT"))


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
