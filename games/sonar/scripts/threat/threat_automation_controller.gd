class_name ThreatAutomationController
extends RefCounted
## threat_automation_controller.gd — S109 §3.1 来袭鱼雷强制安全自动化。
##
## 这是安全系统，不是一般 Autocrew：
##   always_enabled = true / user_can_disable = false
##   auto_ping = auto_fire = auto_decoy = false（绝不发射任何战术动作）
## 在全局三态（MANUAL/ASSISTED/FULL_AUTO）下都执行：
##   探测证据去重 → 鱼雷类别概率确认 → 自动建立/关联 TTxxx 威胁航迹。
## 与普通三态自动化和普通 MarkGroup 完全解耦：本类只读净化证据、只写
## ThreatTrackStore，不触碰 selected_track_id / MarkGroup / 武器 / Ping。
##
## 纯逻辑、无 Truth：输入是 EmissionSanitizer 净化证据（无 target_id /
## emission_kind / 位置），输出航迹 id 数组。

const EVIDENCE_KINDS := ["LAUNCH_TRANSIENT", "RUNNING_NOISE", "ACTIVE_PING"]

var always_enabled: bool = true
var user_can_disable: bool = false
var auto_ping: bool = false
var auto_fire: bool = false
var auto_decoy: bool = false
## 最小分类门槛：低于 SUSPECTED 的证据不建卡/不关联（§3.2 状态纪律）。
var min_state: String = "SUSPECTED_TORPEDO"

var _seen_evidence: Dictionary = {}  # evidence_id -> true（AT-08 去重）
var _store: ThreatTrackManager = null


func bind_store(store: ThreatTrackManager) -> void:
	_store = store


func reset() -> void:
	_seen_evidence.clear()


## 消费一批净化证据：去重 + 分类门槛 + 喂 ThreatTrackStore。
## 返回本轮新建/更新的威胁航迹 id（去重后无新证据则空数组）。
func process_evidence(evs: Array, now: float) -> Array:
	var touched: Array = []
	if _store == null:
		return touched
	for e in evs:
		if str(e.get("side_hint", "")) != "INTERCEPT":
			continue
		var eid: Variant = e.get("evidence_id", null)
		if eid == null or _seen_evidence.has(str(eid)):
			continue  # AT-08：同一 evidence_id 重复到达只计一次
		var kind: String = str(e.get("evidence_kind", ""))
		if not EVIDENCE_KINDS.has(kind):
			continue
		var state: String = str(e.get("class_state", ""))
		if state == "UNCLASSIFIED":
			continue
		_seen_evidence[str(eid)] = true
		var tid: String = _store.ingest(e, now)
		if tid != "":
			touched.append(tid)
	return touched


## 是否已有该证据（调试/测试用）。
func has_evidence(eid: String) -> bool:
	return _seen_evidence.has(str(eid))
