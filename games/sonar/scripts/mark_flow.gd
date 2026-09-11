class_name MarkFlow
extends RefCounted
## mark_flow.gd — Mark 组选择/关联/编辑流的**唯一状态源**。
##
## 职责：把"玩家点击瀑布"到"证据进入 Track"的裁决集中到此控制器，
## main_ui / MarkGroupPanel 只做渲染，不自持 active_group_id / association_mode
## 的第二份副本（MK-01：面板只渲染快照，否则地图菜单改的组在面板上看不到，
## 刷新一次又被面板的旧值覆盖回去）。
##
## 规则：
##   - active_group_id 与 selected_contact_id 分离（**看不等于加**）；
##   - MK-02：锁定目的组**优先于**去重分支与自动关联。普通点击、已有点高亮、
##     自动船员、Ping 回波、告警都不改写入组，也不抢走当前查看接触；
##   - MK-03：同一物理证据重复点击不增加独立 evidence 计数，也不悄悄切组；
##     已归属别处时给「移入当前组」显式操作；
##   - MK-04：有效瀑布数据区任意点击都能落点/选取（不查峰值/SE/Pd/8° 门）；
##   - MK-05：LOCKED 无目的组 → 首次手动点击即建组并立即锁定；原组失效则
##     保留待处理点并给恢复/新建入口，绝不静默转投别组；
##   - MK-06：SUGGEST 先**纯计算**候选，接受前不改动其他航迹；接受/拒绝只
##     影响当前建议，已有 Fit / 历史 Mark / 其他组不被重算或重绑；
##   - 同一 row_id+peak_id 重复点击 = 选中既有 Mark，不新增物理证据
##     （OperatorSonar 层去重，此处兜底 world 流检测）。

const ASSOC_LOCKED := "LOCKED"
const ASSOC_SUGGEST := "SUGGEST"
const ASSOC_AUTO := "AUTO"

var tracker: Tracker = null
var op: RefCounted = null
var world: World = null

## 手动落点写入组（"" = 未指定，交给自动关联）。唯一状态源。
var active_group_id: String = ""
var association_mode: String = ASSOC_LOCKED
var audit: Array = []  # 审计日志（最新在尾）
## 最近一次 Shift 临时追加的目的组（MK-02：必须显式显示临时目的组）。
var last_temp_destination: String = ""
## 一次撤销：{track: Track（恢复回哪）, group: Array[Measurement],
## detach_from: Track|null（先从哪摘掉）}。单位是"物理证据组"（A/B 镜像两支
## 一起搬），避免撤销后留下半条证据或同一证据在两处各有一份。
var _undo: Dictionary = {}
## MK-06 待 Apply 的建议：{track_id, group, evidence_id}（track_id = 建议改绑到谁）。
var _suggest: Dictionary = {}
## MK-05 待处理的落点：目的组不可用时保留，等玩家恢复/新建。
var _pending: Dictionary = {}  # {group, brg, reason}
## MK-03 最近一次点击命中的既有证据（"移入当前组"用）。
var _last_clicked: Measurement = null
var _last_clicked_owner: String = ""


func _log(msg: String) -> void:
	audit.append("[%.0fs] %s" % [world.sim_time if world != null else 0.0, msg])
	if audit.size() > 50:
		audit.pop_front()


# ---------------------------------------------------------------- 状态入口
## MK-01：切换目的组（面板/地图菜单共用同一入口，杜绝两处状态分叉）。
func select_group(group_id: String) -> void:
	active_group_id = group_id
	if group_id != "":
		# MK-05：组一旦明确，待处理点直接归入（玩家已给出目的）。
		if not _pending.is_empty():
			attach_pending(group_id)
	_log("ACTIVE GROUP %s" % (group_id if group_id != "" else "(auto)"))


func set_mode(mode: String) -> void:
	if mode != ASSOC_LOCKED and mode != ASSOC_SUGGEST and mode != ASSOC_AUTO:
		return
	association_mode = mode
	if mode != ASSOC_SUGGEST:
		_suggest = {}
	_log("ASSOC MODE %s" % mode)


## MK-01：面板只渲染这个快照（两个信息分开显示，不再靠显示文本反推业务 ID）。
func status_snapshot(view_id: String) -> Dictionary:
	return {
		"view_id": view_id,
		"write_id": active_group_id,
		"mode": association_mode,
		"locked": association_mode == ASSOC_LOCKED and active_group_id != "",
		"suggestion": pending_suggestion_track_id(),
		"pending": not _pending.is_empty(),
		"temp_destination": last_temp_destination,
	}


## MK-05：LOCKED 且无目的组时，首次手动点击建立一个组并立即锁定。
func ensure_locked_group() -> String:
	if active_group_id != "" and tracker != null and tracker.track_by_id(active_group_id) != null:
		return active_group_id
	if tracker == null:
		return ""
	var t: Track = tracker.create_empty_track()
	active_group_id = t.track_id
	_log("LOCK AUTO-NEW GROUP %s" % t.track_id)
	return active_group_id


# ---------------------------------------------------------------- 主流程
## 点击瀑布裁决。返回供 main_ui 应用视图效果：
## {select, status, dirty, track, active_group, temp_destination,
##  can_move_to_lock, existing_owner, pending, pending_promoted}
## explicit_append=true（Shift＋点击）表示玩家显式把该点追加到 selected_id 接触。
func handle_mark(
	x_brg: float, as_true: bool, row: Dictionary, selected_id: String, explicit_append: bool = false
) -> Dictionary:
	var out: Dictionary = _empty_result()
	if tracker == null or op == null or world == null:
		return out
	var group: Array = op.create_mark_group(x_brg, world.sim_time, "", as_true, row)
	if group.is_empty():
		return out
	var pm: Measurement = group[0] as Measurement
	var target: String = _resolve_target(out, selected_id, explicit_append)
	# MK-03：同一物理证据重复点击 → 不新增证据、不改写入组、不抢查看。
	if world.measurements.has(pm):
		return _dedup_result(out, pm, target)
	# MK-05：LOCKED 无目的组 → 首次有效手动点击建立一个组并立即锁定。
	if association_mode == ASSOC_LOCKED and target == "":
		target = ensure_locked_group()
		if target != "":
			out["pending_promoted"] = not _pending.is_empty()
		out["active_group"] = active_group_id
	elif association_mode == ASSOC_SUGGEST and target != "" and tracker.track_by_id(target) == null:
		target = ""
	if target != "":
		return _append_to_target(out, group, target, x_brg, explicit_append)
	return _auto_associate(out, group, pm, x_brg)


## MK-02：目的组裁决。锁定目的组优先；Shift＋点击是显式临时命令，必须明示。
## 这里只取"已明确的组"，不急着建新组（重复点一条既有证据不该顺手产出空组）。
func _resolve_target(out: Dictionary, selected_id: String, explicit_append: bool) -> String:
	var target: String = ""
	last_temp_destination = ""
	if explicit_append and selected_id != "":
		target = selected_id
		last_temp_destination = selected_id
		out["temp_destination"] = selected_id
	elif association_mode == ASSOC_LOCKED or association_mode == ASSOC_SUGGEST:
		target = active_group_id
	out["active_group"] = active_group_id
	return target


## MK-03：重复点击既有证据的裁决——只报告归属，绝不改写入组、绝不抢当前查看接触；
## 若证据已归属别处，给一个显式的「移入当前组」入口。
func _dedup_result(out: Dictionary, pm: Measurement, target: String) -> Dictionary:
	var owner: Track = tracker.track_of_measurement(pm)
	var owner_id: String = owner.track_id if owner != null else ""
	_last_clicked = pm
	_last_clicked_owner = owner_id
	out["existing_owner"] = owner_id
	out["track"] = owner
	if owner_id != "" and target != "" and owner_id != target:
		out["can_move_to_lock"] = true
		out["status"] = (
			(
				"Mark already exists (owner %s) - no new evidence;"
				+ " use Move-to-current-group to rebind %s"
			)
			% [owner_id, target]
		)
		_log("DUP click on %s (owner %s, lock %s)" % [pm.evidence_id, owner_id, target])
	else:
		out["status"] = (
			"Mark already exists%s - no new evidence"
			% ("" if owner_id == "" else " (%s)" % owner_id)
		)
		_log("DUP click on %s (no new evidence)" % pm.evidence_id)
	return out


## 显式目的组：直接追加（命令不是判决，不经 8° 自动关联门）。
func _append_to_target(
	out: Dictionary, group: Array, target: String, x_brg: float, explicit_append: bool
) -> Dictionary:
	var tt: Track = tracker.track_by_id(target)
	if tt == null or tt.state == Track.TrackState.MERGED:
		# MK-05：原组失效 → 保留待处理点，给恢复/新建入口，绝不静默转投别组。
		_pending = {"group": group, "brg": x_brg, "reason": "target_unavailable"}
		out["pending"] = true
		out["track"] = null
		out["status"] = (
			"Group %s unavailable - mark kept pending (new group / pick another)" % target
		)
		_log("PENDING %.1f deg (target %s unavailable)" % [x_brg, target])
		return out
	var t2: Track = tracker.append_group_direct(tt, group)
	if t2 == null:
		_pending = {"group": group, "brg": x_brg, "reason": "append_rejected"}
		out["pending"] = true
		out["status"] = "Group %s rejected the mark - kept pending" % target
		return out
	_pending = {}
	for gm in group:
		world.measurements.append(gm)
	_undo = {}
	_log("MARK %.1f deg -> %s%s" % [x_brg, t2.track_id, " (LR pair)" if group.size() > 1 else ""])
	out["dirty"] = true
	out["track"] = t2
	# MK-06：SUGGEST 只做**纯计算**候选，不改动任何其他航迹。
	if association_mode == ASSOC_SUGGEST:
		_suggest_pending_candidate(group, t2.track_id)
		if not _suggest.is_empty():
			out["status"] = (
				"Marked %s - Apply to rebind to %s" % [t2.track_id, str(_suggest["track_id"])]
			)
			return out
		out["status"] = "Marked %.1f deg -> %s" % [x_brg, t2.track_id]
		return out
	# 显式组 / Shift＋追加：加 Mark 不抢选中（看与加分离，AT-48）。
	out["status"] = (
		"Marked %.1f deg -> %s%s"
		% [x_brg, t2.track_id, " (temp Shift destination)" if explicit_append else ""]
	)
	return out


## AUTO（或 SUGGEST 未指定组）：自动关联评分；失败则新建接触，绝不吞掉点击。
func _auto_associate(out: Dictionary, group: Array, pm: Measurement, x_brg: float) -> Dictionary:
	var t: Track = tracker.feed_evidence_group(group, "", 8.0)
	if t == null:
		t = tracker.mark(pm, "M")
		for j in range(1, group.size()):
			t.add_measurement(group[j] as Measurement)
	for gm in group:
		world.measurements.append(gm)
	_log("MARK %.1f deg -> %s%s" % [x_brg, t.track_id, " (LR pair)" if group.size() > 1 else ""])
	_undo = {}
	out["select"] = t.track_id
	out["dirty"] = true
	out["track"] = t
	out["status"] = (
		"Marked %.1f deg -> %s%s" % [x_brg, t.track_id, " (LR pair)" if group.size() > 1 else ""]
	)
	return out


func _empty_result() -> Dictionary:
	return {
		"select": "",
		"status": "",
		"dirty": false,
		"track": null,
		"active_group": "",
		"temp_destination": "",
		"can_move_to_lock": false,
		"existing_owner": "",
		"pending": false,
		"pending_promoted": false,
	}


## MK-06：纯计算候选（不写任何航迹），排除目的地自身后取最邻近者作为建议。
func _suggest_pending_candidate(group: Array, destination_id: String) -> void:
	_suggest = {}
	if tracker == null:
		return
	var cands: Array = tracker.score_group_candidates(group, 8.0)
	for c in cands:
		var ct: Track = c["track"]
		if ct != null and ct.track_id != destination_id:
			var pm: Measurement = group[0] as Measurement
			_suggest = {
				"track_id": ct.track_id,
				"group": group,
				"evidence_id": pm.evidence_id,
			}
			_log("SUGGEST associate %s (pending Apply)" % ct.track_id)
			return


# ---------------------------------------------------------------- SUGGEST
## SUGGEST Apply：把待定证据组（保持同一 evidence_id）改绑到建议的 Track。
func apply_pending_suggestion() -> Dictionary:
	if _suggest.is_empty():
		var out: Dictionary = {"status": "No pending suggestion", "dirty": false, "track": null}
		return out
	return apply_suggestion(str(_suggest["track_id"]))


## 显式改绑：把 SUGGEST 待定证据组原子地移到 target_track_id。
## 拒绝（不调用本函数）只清掉建议，已落下的证据保持原地，不被重算或重绑。
func apply_suggestion(target_track_id: String) -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null}
	if _suggest.is_empty() or tracker == null:
		out["status"] = "No pending suggestion"
		return out
	var group: Array = _suggest["group"]
	var to_t: Track = tracker.track_by_id(target_track_id)
	if to_t == null:
		_suggest = {}
		out["status"] = "Suggestion dropped"
		return out
	var from_t: Track = tracker.track_of_measurement(group[0] as Measurement)
	var moved: Array = tracker.move_evidence_group(group, to_t, from_t)
	_suggest = {}
	_log("REASSIGN -> %s (%d meas, same evidence_id)" % [to_t.track_id, moved.size()])
	if moved.is_empty():
		out["status"] = "Suggestion dropped"
		return out
	_undo = {"track": from_t, "group": moved, "detach_from": to_t}
	out["dirty"] = true
	out["track"] = to_t
	out["status"] = "Reassigned %d measurement(s) -> %s" % [moved.size(), to_t.track_id]
	return out


## 拒绝建议：只清建议，不动任何已落下的证据。
func reject_suggestion() -> Dictionary:
	_suggest = {}
	_log("SUGGEST rejected (no track touched)")
	return {"status": "Suggestion rejected", "dirty": false, "track": null}


func pending_suggestion_track_id() -> String:
	return str(_suggest.get("track_id", "")) if not _suggest.is_empty() else ""


# ---------------------------------------------------------------- MK-03 移入当前组
## MK-03：把"最近一次点击命中的既有证据"（连同 A/B 镜像支）显式改绑到锁定目的组。
## 这是玩家显式命令，不是自动关联；同一 evidence_id 保留，不产生第二份证据。
func move_last_clicked_to_lock() -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null}
	if tracker == null or active_group_id == "":
		out["status"] = "No target group"
		return out
	if _last_clicked == null:
		out["status"] = "Nothing to move"
		return out
	var to_t: Track = tracker.track_by_id(active_group_id)
	if to_t == null:
		out["status"] = "Group %s unavailable" % active_group_id
		return out
	var from_t: Track = tracker.track_of_measurement(_last_clicked)
	if from_t == null:
		out["status"] = "Evidence not owned by any group"
		return out
	var group: Array = _evidence_group_of(_last_clicked, from_t)
	var moved: Array = tracker.move_evidence_group(group, to_t, from_t)
	if moved.is_empty():
		out["status"] = "Move failed (group kept intact)"
		return out
	# T02：显式改绑必须可撤销（整组一起回原组）。
	_undo = {"track": from_t, "group": moved, "detach_from": to_t}
	_log(
		(
			"MOVE evidence %s: %s -> %s (%d meas)"
			% [_last_clicked.evidence_id, from_t.track_id, to_t.track_id, moved.size()]
		)
	)
	out["dirty"] = true
	out["track"] = to_t
	out["status"] = (
		"Moved %d measurement(s) %s -> %s (undo available)"
		% [moved.size(), from_t.track_id, to_t.track_id]
	)
	return out


func last_clicked_evidence_id() -> String:
	return _last_clicked.evidence_id if _last_clicked != null else ""


func last_clicked_owner_id() -> String:
	return _last_clicked_owner


## 取同一物理证据的全部成员（A/B 镜像支共享 evidence_id）。
func _evidence_group_of(m: Measurement, owner: Track) -> Array:
	var out: Array = [m]
	if m.evidence_id == "":
		return out
	for other in owner.measurement_history:
		var o := other as Measurement
		if o != null and o != m and o.evidence_id == m.evidence_id:
			out.append(o)
	return out


# ---------------------------------------------------------------- MK-05 待处理点
func has_pending() -> bool:
	return not _pending.is_empty()


func pending_bearing() -> float:
	return float(_pending.get("brg", 0.0)) if not _pending.is_empty() else 0.0


## 把保留的落点归入指定组（恢复入口）。
func attach_pending(track_id: String) -> Dictionary:
	var out: Dictionary = {"status": "", "dirty": false, "track": null}
	if _pending.is_empty():
		out["status"] = "No pending mark"
		return out
	var t: Track = tracker.track_by_id(track_id) if tracker != null else null
	if t == null:
		out["status"] = "Group %s unavailable" % track_id
		return out
	var group: Array = _pending["group"]
	var t2: Track = tracker.append_group_direct(t, group)
	if t2 == null:
		out["status"] = "Group %s rejected the pending mark" % track_id
		return out
	for gm in group:
		if world != null:
			world.measurements.append(gm)
	_pending = {}
	active_group_id = track_id
	_log("PENDING recovered -> %s" % t2.track_id)
	out["dirty"] = true
	out["track"] = t2
	out["status"] = "Pending mark attached to %s" % t2.track_id
	return out


## 为待处理落点新建一个组并锁定（恢复入口）。
func new_group_from_pending() -> Dictionary:
	if _pending.is_empty():
		return {"status": "No pending mark", "dirty": false, "track": null}
	var ng: Dictionary = new_group()
	var ag: String = str(ng.get("active_group", ""))
	if ag == "":
		return ng
	return attach_pending(ag)


# ---------------------------------------------------------------- 编辑
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
	_undo = {"track": t, "group": [m]}
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
	var group: Array = _undo["group"]
	var detach: Track = _undo.get("detach_from", null)
	var ev: String = ""
	for gm in group:
		var m := gm as Measurement
		if m == null:
			continue
		if detach != null and detach != t:
			detach.remove_measurement(m)
		if not t.measurement_history.has(m):
			t.add_measurement(m)
		if ev == "":
			ev = m.evidence_id
		if op != null and op.has_method("drop_mark_cache"):
			op.drop_mark_cache(m)
	_undo = {}
	_log("UNDO restore %s on %s (%d meas)" % [ev, t.track_id, group.size()])
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
