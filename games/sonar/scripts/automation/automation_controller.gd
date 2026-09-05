class_name AutomationController
extends RefCounted
## automation_controller.gd — S1-05 三态自动化（REQ-AU-01..04，AU-1..5）。
##
## REQ-AU-01 三态 + ROE：
##   - MANUAL：绝不自动产生任何动作/提案（只有操作员动作）；
##   - ASSISTED：只产出"提案"（proposal），由操作员 Apply 后才执行；
##   - FULL_AUTO：在 ROE（交战规则）允许范围内自动执行；
##   - ROE = {auto_refit, auto_fire, auto_decoy}——FULL_AUTO 也绝不越过 ROE。
##
## REQ-AU-02 tracker 槽位簿记：slot = {track_id, last_evidence_id, last_new_t,
##   state}。同一 evidence_id 只处理一次（去重）；证据陈旧按 slot_timeout_s
##   计龄，超时释放槽位（state STALE → 移除）。
##
## REQ-AU-03 状态机 + Fit 质量门：
##   NEW → TRACKING → FIT_READY（质量门通过）→ FITTED（已执行/已采纳）→
##   STALE（超时）→ 释放。质量门按证据数量/新鲜度/（可选）拟合残差评估，
##   绝不使用"必须跨两个航向腿"的一刀切规则（两腿一刀切已删除）。
##
## REQ-AU-04 Take Control / PLAYER OVERRIDE / 命令记录：
##   - take_control(track_id) 立即置 PLAYER OVERRIDE——下一次 update()（一
##     tick 内）自动化就不再触碰该航迹；
##   - 所有自动化命令/提案/模式与 ROE 变更全部写入 command_log（审计）。

enum Mode { MANUAL, ASSISTED, FULL_AUTO }

const MODE_NAMES: Array = ["MANUAL", "ASSISTED", "FULL_AUTO"]

const MODE_MANUAL: int = Mode.MANUAL
const MODE_ASSISTED: int = Mode.ASSISTED
const MODE_FULL_AUTO: int = Mode.FULL_AUTO

## 槽位状态（REQ-AU-03 状态机）。
const SLOT_NEW: String = "NEW"
const SLOT_TRACKING: String = "TRACKING"
const SLOT_FIT_READY: String = "FIT_READY"
const SLOT_FITTED: String = "FITTED"
const SLOT_STALE: String = "STALE"

var mode: int = Mode.MANUAL
## REQ-AU-01 交战规则：FULL_AUTO 的动作边界（缺省只允许自动重拟合）。
var roe: Dictionary = {"auto_refit": true, "auto_fire": false, "auto_decoy": false}
## REQ-AU-02 槽位簿记与计龄。
var slots: Dictionary = {}  # track_id -> slot dict
var slot_timeout_s: float = 120.0
## REQ-AU-03 Fit 质量门参数。
var min_fit_evidences: int = 4
var max_fit_rms_deg: float = 0.8
var acceptable_fit_status: Array = ["CONVERGED", "ROBUST"]

## REQ-AU-04 PLAYER OVERRIDE 与审计。
var override_tracks: Dictionary = {}  # track_id -> true
var command_log: Array = []  # [{t, kind, detail}]


func set_mode(m: int, now: float) -> bool:
	if m < Mode.MANUAL or m > Mode.FULL_AUTO or m == mode:
		return false
	mode = m
	log_command("MODE", MODE_NAMES[m], now)
	return true


func set_roe(key: String, value: bool, now: float) -> void:
	roe[key] = value
	log_command("ROE", "%s=%s" % [key, str(value)], now)


func mode_name() -> String:
	return MODE_NAMES[mode]


## REQ-AU-04：Take Control —— 一 tick 生效的 PLAYER OVERRIDE。
func take_control(track_id: String, now: float) -> void:
	override_tracks[track_id] = true
	log_command("OVERRIDE", track_id, now)


func release_control(track_id: String, now: float) -> void:
	if override_tracks.erase(track_id):
		log_command("RELEASE", track_id, now)


## REQ-AU-03 Fit 质量门：证据数量 + 新鲜度 +（可选）拟合结果质量。
## fit_result 可为空（仅按证据门）；提供时其 status 与 rms 参与判定。
## 刻意不包含任何"观测必须跨越两个航向腿"类的一刀切条件。
func fit_gate(track: Track, _now: float, fit_result: Dictionary = {}) -> bool:
	if track == null or override_tracks.has(track.track_id):
		return false
	if not track.is_usable():
		return false
	if track.evidence_count() < min_fit_evidences:
		return false
	if not fit_result.is_empty():
		var st: String = str(fit_result.get("status", ""))
		if st != "" and not acceptable_fit_status.has(st):
			return false
		var rms: float = float(fit_result.get("rms_deg", -1.0))
		if rms >= 0.0 and rms > max_fit_rms_deg:
			return false
	return true


## 周期推进（REQ-AU-02/03）：簿记全部航迹槽位并按模式产出动作/提案。
## tracks 为 Tracker.all_tracks()。返回 {"actions": [...], "proposals": [...]}。
func update(now: float, tracks: Array) -> Dictionary:
	var actions: Array = []
	var proposals: Array = []
	var seen: Dictionary = {}
	for t in tracks:
		if t == null:
			continue
		var tid: String = str(t.track_id)
		seen[tid] = true
		# REQ-AU-04：PLAYER OVERRIDE 一 tick 生效——被接管的航迹绝不簿记/动作。
		if override_tracks.has(tid):
			slots.erase(tid)
			continue
		var ev_key: String = _latest_evidence_key(t)
		var slot: Dictionary = slots.get(tid, {})
		if slot.is_empty():
			slot = {
				"track_id": tid,
				"last_evidence_id": ev_key,
				"last_new_t": now,
				"state": SLOT_NEW,
				"proposed_evidence_id": "",
			}
			slots[tid] = slot
			log_command("ASSIGN_SLOT", tid, now)
		elif ev_key != str(slot["last_evidence_id"]):
			# REQ-AU-02 去重：只有新 evidence id 才推进状态/重置计龄。
			slot["last_evidence_id"] = ev_key
			slot["last_new_t"] = now
			if str(slot["state"]) in [SLOT_FITTED, SLOT_STALE]:
				slot["state"] = SLOT_TRACKING
			slot["proposed_evidence_id"] = ""
		# REQ-AU-03 质量门 → FIT_READY。
		if str(slot["state"]) in [SLOT_NEW, SLOT_TRACKING] and fit_gate(t, now):
			slot["state"] = SLOT_FIT_READY
		# 按模式决策（同一 evidence id 只提案/执行一次）。
		if str(slot["state"]) == SLOT_FIT_READY and str(slot["proposed_evidence_id"]) != ev_key:
			if mode == Mode.FULL_AUTO:
				if bool(roe.get("auto_refit", false)):
					slot["state"] = SLOT_FITTED
					slot["proposed_evidence_id"] = ev_key
					actions.append({"action": "REFIT", "track_id": tid})
					log_command("AUTO_REFIT", tid, now)
				else:
					# ROE 拒绝：同一证据只记一次（不刷审计日志）。
					slot["proposed_evidence_id"] = ev_key
					log_command("ROE_DENIED", "refit:%s" % tid, now)
			elif mode == Mode.ASSISTED:
				slot["proposed_evidence_id"] = ev_key
				proposals.append({"proposal": "REFIT", "track_id": tid})
				log_command("PROPOSE_REFIT", tid, now)
	# REQ-AU-02 计龄：超时槽位 → STALE → 释放；航迹消失同样释放。
	for tid in slots.keys():
		var slot: Dictionary = slots[tid]
		if not seen.has(tid) or now - float(slot["last_new_t"]) > slot_timeout_s:
			slot["state"] = SLOT_STALE
			log_command("SLOT_STALE", tid, now)
			slots.erase(tid)
	return {"actions": actions, "proposals": proposals}


## 操作员采纳 ASSISTED 提案后回调：槽位进入 FITTED（同一证据不再重复提案）。
func mark_fitted(track_id: String, now: float) -> void:
	if slots.has(track_id):
		slots[track_id]["state"] = SLOT_FITTED
		slots[track_id]["proposed_evidence_id"] = str(slots[track_id]["last_evidence_id"])
	log_command("OPERATOR_FIT", track_id, now)


func log_command(kind: String, detail: String, now: float) -> void:
	command_log.append({"t": now, "kind": kind, "detail": detail})


## 最新证据键：按去重 evidence_id（无则按 measurement_id 兜底，与 Track 一致）。
func _latest_evidence_key(track: Track) -> String:
	var n: int = track.measurement_history.size()
	for i in range(n - 1, -1, -1):
		var m: Measurement = track.measurement_history[i]
		if m.evidence_id != "":
			return m.evidence_id
		return "obj_%d" % m.measurement_id
	return ""
