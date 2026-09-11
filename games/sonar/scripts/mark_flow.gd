class_name MarkFlow
extends RefCounted
## mark_flow.gd — REQ-0908 Batch 1：显式 Mark 组选择/关联/编辑流
## （REQ-B1-01/REQ-B1-02/REQ-B1-05）。
##
## 职责：把"玩家点击瀑布"到"证据进入 Track"的裁决集中到此控制器，
## main_ui 只做视图刷新。规则：
##   - active_mark_group_id 与 selected_contact_id 分离（看不等于加）；
##   - LOCKED（默认）：只向 active 组追加，方位门不一致明确拒绝，
##     不静默切组/新建/污染世界测量流；
##   - SUGGEST：只提示"建议关联 M0x"，玩家 Apply 前不改绑；
##   - AUTO：全局最近邻关联（旧行为）；
##   - 同一 row_id+peak_id 重复点击 = 选中既有 Mark，不新增物理证据
##     （OperatorSonar 层去重，此处兜底 world 流检测）；
##   - Remove/Reassign 保留同一物理 evidence_id；编辑记审计日志，可撤销一次。

const ASSOC_LOCKED := "LOCKED"
const ASSOC_SUGGEST := "SUGGEST"
const ASSOC_AUTO := "AUTO"

var tracker: Tracker = null
var op: RefCounted = null
var world: World = null

var active_group_id: String = ""  # ""=自动/新建
var association_mode: String = ASSOC_LOCKED
var audit: Array = []  # 审计日志（最新在尾）
var _undo: Dictionary = {}  # 一次撤销：{op, track, meas}
var _suggest: Dictionary = {}  # SUGGEST 待 Apply：{track_id, group}


func _log(msg: String) -> void:
	audit.append("[%.0fs] %s" % [world.sim_time if world != null else 0.0, msg])
	if audit.size() > 50:
		audit.pop_front()


## 点击瀑布裁决。返回供 main_ui 应用视图效果：
## {select: String, status: String, dirty: bool, track: Track}
## explicit_append=true（Shift＋点击）表示玩家显式把该点追加到 selected_id 接触。
func handle_mark(
	x_brg: float, as_true: bool, row: Dictionary, selected_id: String, explicit_append: bool = false
) -> Dictionary:
	var out: Dictionary = {"select": "", "status": "", "dirty": false, "track": null}
	if tracker == null or op == null or world == null:
		return out
	var group: Array = op.create_mark_group(x_brg, world.sim_time, "", as_true, row)
	if group.is_empty():
		return out
	var pm: Measurement = group[0] as Measurement
	# REQ-B1-02：重复点击同一 row_id+peak_id → 选中已有 Mark，不新增证据。
	if world.measurements.has(pm):
		var owner: Track = tracker.track_of_measurement(pm)
		if owner != null:
			out["select"] = owner.track_id
			out["status"] = "Mark exists — selected %s (no new evidence)" % owner.track_id
			out["track"] = owner
		return out

	var t: Track = null
	# S1-11 §3.3/D-13：手动 Mark 是"修正命令"，不是探测判决。
	# ① Shift＋点击（explicit_append）→ 直接追加到当前查看的接触；
	# ② 明确选组（active_group_id）→ 直接追加，空组首点同样成立；
	# ③ 未指定组 → 自动关联评分；失败则新建接触，绝不吞掉点击。
	# 任何显式路径都不检查声强/Pd/8° 方位门，8° 只留给①以外的自动关联。
	var explicit_target: String = ""
	if explicit_append and selected_id != "":
		explicit_target = selected_id
	elif association_mode == ASSOC_LOCKED and active_group_id != "":
		explicit_target = active_group_id
	if explicit_target != "":
		t = tracker.append_group_direct(tracker.track_by_id(explicit_target), group)
		if t == null:
			out["status"] = "Mark ignored: %s unavailable" % explicit_target
			return out
	else:
		t = tracker.feed_evidence_group(group, "", 8.0)
		if t == null:
			t = tracker.mark(pm, "M")
			for j in range(1, group.size()):
				t.add_measurement(group[j] as Measurement)
		elif (
			association_mode == ASSOC_SUGGEST
			and active_group_id != ""
			and t.track_id != active_group_id
		):
			# SUGGEST：先照常入最邻 Track，但只提示，Apply 前不改绑 active 组。
			for gm in group:
				world.measurements.append(gm)
			_suggest = {"track_id": t.track_id, "group": group}
			_log("SUGGEST associate %s (pending Apply)" % t.track_id)
			out["dirty"] = true
			out["track"] = t
			out["status"] = (
				"Suggest associate %s — Apply to rebind to %s" % [t.track_id, active_group_id]
			)
			return out
	for gm in group:
		world.measurements.append(gm)
	_log("MARK %.1f deg -> %s%s" % [x_brg, t.track_id, " (LR pair)" if group.size() > 1 else ""])
	_undo = {}
	# 显式组 / Shift＋追加：加 Mark 不抢选中（看与加分离，AT-48）。
	if not (association_mode == ASSOC_LOCKED and active_group_id != "") and not explicit_append:
		out["select"] = t.track_id
	out["dirty"] = true
	out["track"] = t
	out["status"] = (
		"Marked %.1f deg -> %s%s" % [x_brg, t.track_id, " (LR pair)" if group.size() > 1 else ""]
	)
	return out


## SUGGEST Apply：把待定证据组（保持同一 evidence_id）改绑到目标 Track。
func apply_suggestion(target_track_id: String) -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null}
	if _suggest.is_empty() or tracker == null:
		out["status"] = "No pending suggestion"
		return out
	var from_t: Track = tracker.track_by_id(str(_suggest["track_id"]))
	var to_t: Track = tracker.track_by_id(target_track_id)
	if from_t == null or to_t == null or to_t == from_t:
		_suggest = {}
		out["status"] = "Suggestion dropped"
		return out
	var moved: int = 0
	for m in _suggest["group"]:
		if tracker.reassign_measurement(m, to_t):
			moved += 1
	_suggest = {}
	_log("REASSIGN %s -> %s (%d meas, same evidence_id)" % [from_t.track_id, to_t.track_id, moved])
	out["dirty"] = moved > 0
	out["track"] = to_t
	out["status"] = (
		"Reassigned %d measurement(s) %s -> %s" % [moved, from_t.track_id, to_t.track_id]
	)
	return out


## Remove：删除目标 Track 最新一条 Measurement（保留对象，可撤销一次）。
func remove_last_mark(track_id: String) -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null}
	if tracker == null:
		return out
	var t: Track = tracker.track_by_id(track_id)
	if t == null or t.measurement_history.is_empty():
		out["status"] = "Nothing to remove on %s" % track_id
		return out
	var m: Measurement = t.measurement_history[t.measurement_history.size() - 1]
	if not tracker.remove_measurement_from(t, m):
		out["status"] = "Remove failed on %s" % track_id
		return out
	_undo = {"track": t, "meas": m}
	if op != null and op.has_method("drop_mark_cache"):
		op.drop_mark_cache(m)
	_log("REMOVE last mark on %s (%s)" % [t.track_id, m.evidence_id])
	out["dirty"] = true
	out["track"] = t
	out["status"] = "Removed last mark on %s (undo available)" % t.track_id
	return out


## 撤销最近一次编辑（Remove/Reassign），仅一层。
func undo_last_edit() -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null}
	if _undo.is_empty() or tracker == null:
		out["status"] = "Nothing to undo"
		return out
	var t: Track = _undo["track"]
	var m: Measurement = _undo["meas"]
	t.add_measurement(m)
	_undo = {}
	_log("UNDO restore %s on %s" % [m.evidence_id, t.track_id])
	out["dirty"] = true
	out["track"] = t
	out["status"] = "Undo: restored last mark on %s" % t.track_id
	return out


## REQ-B1-01：显式新建空 Mark 组并切换 active 组（不携带任何证据）。
func new_group() -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null, "active_group": ""}
	if tracker == null:
		out["status"] = "No tracker"
		return out
	var t: Track = tracker.create_empty_track()
	active_group_id = t.track_id
	_log("NEW GROUP %s (active)" % t.track_id)
	out["status"] = "New mark group %s (active)" % t.track_id
	out["track"] = t
	out["active_group"] = t.track_id
	return out


func pending_suggestion_track_id() -> String:
	return str(_suggest.get("track_id", "")) if not _suggest.is_empty() else ""
