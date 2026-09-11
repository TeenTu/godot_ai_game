class_name FireControlContext
extends RefCounted
## fire_control_context.gd — REQ-0908 Batch 1：per-Track Fit/Trial/Solution
## 上下文与发射联锁（REQ-B1-03/REQ-B1-04）。
##
## 全局单份 last_fit/trial/system_sol 改为按 track_id 隔离：
##   fit_by_track_id             TmaFitResult dict（注入 fit_version/source_*）
##   trial_by_track_id           TrialSolution（绑定 source_track_id/版本）
##   system_solution_by_track_id SystemSolution（已提交快照，不随新证据变化）
##   evidence_revision_by_track_id  Track.evidence_revision 的镜像
##   stale_by_track_id           Fit/Solution 是否 stale
##
## 规则：
##   - 切换 Contact 只改 UI 视图，不动任何此处状态；
##   - 只有证据增删/改绑/人工修改使 revision 递增并置 stale（sync_revision）；
##   - System Solution 提交时绑定 source_track_id/source_fit_version/
##     source_evidence_revision，此后 revision 变化即 SOLUTION_STALE；
##   - SOLUTION 发射只允许选中 Contact 自己的、未 stale、未超龄的解。

var fit_by_track_id: Dictionary = {}
var trial_by_track_id: Dictionary = {}
var system_solution_by_track_id: Dictionary = {}
var evidence_revision_by_track_id: Dictionary = {}
var stale_by_track_id: Dictionary = {}
var _fit_version_counter: int = 0


func evidence_revision(track_id: String) -> int:
	return int(evidence_revision_by_track_id.get(track_id, 0))


func is_stale(track_id: String) -> bool:
	return bool(stale_by_track_id.get(track_id, false))


## S1-11 §3.6/AT-57：Fit 缓存是否需要重算 —— 仅当无缓存或 evidence_revision 变化。
## 切换目标/切页/折叠详情不改变 revision，故不会触发重抽样或重建 Mark。
func needs_refit(track: Track) -> bool:
	var cached: Dictionary = fit_by_track_id.get(track.track_id, {})
	if cached.is_empty():
		return true
	return int(cached.get("source_evidence_revision", -1)) != track.evidence_revision


## 返回缓存的 Fit（不重算、不重抽样）。无缓存返回空字典。
func cached_fit(track_id: String) -> Dictionary:
	return fit_by_track_id.get(track_id, {})


## 证据结构变化后调用：镜像 Track.evidence_revision，变化即置 stale。
func sync_revision(track: Track) -> void:
	var tid: String = track.track_id
	var old: int = evidence_revision(tid)
	evidence_revision_by_track_id[tid] = track.evidence_revision
	if track.evidence_revision != old:
		stale_by_track_id[tid] = true


## 存储一次 Fit（成功时同时生成并绑定 TrialSolution）。返回 fit_version。
## r 为 TmaSolver.solve_auto 结果 dict；sim_time 仅用于 trial.solution_time。
func store_fit(track: Track, r: Dictionary, sim_time: float) -> int:
	var tid: String = track.track_id
	_fit_version_counter += 1
	var v: int = _fit_version_counter
	r["fit_version"] = v
	r["source_track_id"] = tid
	r["source_evidence_revision"] = track.evidence_revision
	fit_by_track_id[tid] = r
	stale_by_track_id[tid] = false
	if bool(r.get("success", false)):
		var best: Dictionary = r.get("best", {})
		var trial := TrialSolution.new()
		trial.bearing_deg = float(best.get("bearing_deg", 0.0))
		trial.range_m = float(best.get("range_m", 0.0))
		trial.course_deg = float(best.get("course_deg", 0.0))
		trial.speed_kn = float(best.get("speed_kn", 0.0))
		trial.solution_time = sim_time
		var dt_now: float = sim_time - float(best.get("t_ref", sim_time))
		var vec := best.get("v_ms", Vector2.ZERO) as Vector2
		trial.estimated_position_east_m = (best["p_ref"] as Vector2).x + vec.x * dt_now
		trial.estimated_position_north_m = (best["p_ref"] as Vector2).y + vec.y * dt_now
		trial.source_track_id = tid
		trial.source_fit_version = v
		trial.source_evidence_revision = track.evidence_revision
		trial_by_track_id[tid] = trial
	return v


## 提交 System Solution（REQ-B1-04 检查：trial 属于该 Track、fit 版本仍在、
## revision 一致）。返回 {ok, reason, solution}。
func commit_solution(track_id: String, solution_time: float) -> Dictionary:
	var trial: TrialSolution = trial_by_track_id.get(track_id, null)
	if trial == null:
		return {"ok": false, "reason": "NO_TRIAL", "solution": null}
	if trial.source_track_id != track_id:
		return {"ok": false, "reason": "TRIAL_TRACK_MISMATCH", "solution": null}
	if not fit_by_track_id.has(track_id):
		return {"ok": false, "reason": "FIT_VERSION_GONE", "solution": null}
	if trial.source_evidence_revision != evidence_revision(track_id):
		return {"ok": false, "reason": "FIT_STALE", "solution": null}
	var sol: SystemSolution = trial.commit(solution_time)
	sol.source_track_id = track_id
	sol.source_fit_version = trial.source_fit_version
	sol.source_evidence_revision = trial.source_evidence_revision
	system_solution_by_track_id[track_id] = sol
	return {"ok": true, "reason": "", "solution": sol}


## SOLUTION 发射门（REQ-B1-04）：只允许选中 Contact 自己的解；其他 Track、
## stale、超龄、来源版本消失一律拒绝，不得自动退化。
func solution_for_fire(
	selected_track_id: String, now_time: float, max_age_s: float = 600.0
) -> Dictionary:
	var sol: SystemSolution = system_solution_by_track_id.get(selected_track_id, null)
	var reason: String = ""
	if selected_track_id == "":
		reason = "NO_TRACK_SELECTED"
	elif sol == null:
		reason = "NO_SOLUTION_FOR_TRACK"
	elif str(sol.source_track_id) != selected_track_id:
		reason = "SOLUTION_TRACK_MISMATCH"
	elif not fit_by_track_id.has(selected_track_id):
		reason = "FIT_VERSION_GONE"
	elif sol.source_evidence_revision != evidence_revision(selected_track_id):
		reason = "SOLUTION_STALE"
	elif now_time - sol.solution_time > max_age_s:
		reason = "SOLUTION_TOO_OLD"
	return {"ok": reason == "", "reason": reason, "solution": sol if reason == "" else null}


## 求解并写入 per-Track 上下文（REQ-B1-03：唯一写入口，前台/后台共用）。
func solve_and_store(track: Track, op: RefCounted, sim_time: float) -> Dictionary:
	var meas: Array = []
	for m in track.measurement_history:
		meas.append(TmaUiData.fit_meas_dict(m))
	var opts: Dictionary = {"now_time": sim_time}
	# DEMON 航速仅作为带 sigma 的软约束，不替代 bearing-only 拟合
	if op != null and not op.demon_estimate.is_empty():
		var de: Dictionary = op.demon_estimate
		if float(de.get("confidence", 0.0)) > 0.3 and float(de.get("speed_sigma_kn", 99.0)) < 6.0:
			opts["demon_speed_kn"] = float(de["speed_kn"])
			opts["demon_sigma_kn"] = float(de["speed_sigma_kn"])
	var r: Dictionary = TmaSolver.solve_auto(meas, opts)
	r["track_id"] = track.track_id
	store_fit(track, r, sim_time)
	return r


## UI 提交入口：低质量 Fit 需二次确认（lowq_confirmed 状态由调用方持有）。
func commit_solution_checked(
	track_id: String, solution_time: float, fit_status: String, lowq_confirmed: bool
) -> Dictionary:
	var out: Dictionary = {"ok": false, "reason": "", "solution": null, "lowq_pending": false}
	if fit_status in ["INSUFFICIENT_GEOMETRY", "MULTIMODAL", "STALE"] and not lowq_confirmed:
		out["lowq_pending"] = true
		return out
	var res: Dictionary = commit_solution(track_id, solution_time)
	out["ok"] = res["ok"]
	out["reason"] = res["reason"]
	out["solution"] = res["solution"]
	return out
