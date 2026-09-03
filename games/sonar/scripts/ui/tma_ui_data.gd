class_name TmaUiData
extends RefCounted
## tma_ui_data.gd — TmaFitResult → UI 显示数据的纯函数转换层。
## 从 main_ui 拆出（max-file-lines），全部 static，不持有状态。
##
## 公式约定（与 TmaSolver 一致）：
##   p_i = p_ref + v * (t_i - t_ref)
##   θ̂_i = atan2(p_i.east - o_i.east, p_i.north - o_i.north)
##   e_i = wrap180(z_i - θ̂_i)，normalized = e_i / sigma_i
##   P_now = F P Fᵀ + Q，F = [[I, Δt I], [0, I]]

const MAX_ALTS: int = 3
const CHI2_95: float = 5.991
const POS_SCALE: float = 1000.0  # solver 协方差位置尺度（m）
const VEL_SCALE: float = 5.0  # solver 协方差速度尺度（m/s）
const QA: float = 0.02  # 过程噪声：目标加速度 σ (m/s²)


## 海图假设列表：最优 + 权重最高的 ≤3 个备选（A/B/C 编号）。
static func chart_hypotheses(last_fit: Dictionary, sel_id: String) -> Array:
	if last_fit.is_empty() or not bool(last_fit.get("success", false)):
		return []
	if str(last_fit.get("track_id", "")) != sel_id:
		return []
	var best: Dictionary = last_fit.get("best", {})
	if best.is_empty():
		return []
	var hyps: Array = []
	(
		hyps
		. append(
			{
				"p_ref": best["p_ref"],
				"v_ms": best["v_ms"],
				"t_ref": float(best["t_ref"]),
				"weight": 1.0,
				"is_best": true,
				"speed_kn": float(best.get("speed_kn", 0.0)),
				"course_deg": float(best.get("course_deg", 0.0)),
				"label": "FIT",
			}
		)
	)
	var alts: Array = last_fit.get("alternatives", []).duplicate()
	alts.sort_custom(func(a, b): return float(a.get("weight", 0.0)) > float(b.get("weight", 0.0)))
	var names: Array = ["A", "B", "C"]
	var i: int = 0
	for alt in alts:
		if i >= MAX_ALTS:
			break
		alt["is_best"] = false
		alt["label"] = "Alt " + (names[i] as String)
		hyps.append(alt)
		i += 1
	return hyps


## ≤12 个时间刻度：观测腿边界（就近 inlier）+ 首末测量 + 均匀抽样。
static func fit_tick_times(last_fit: Dictionary, sel_id: String, leg_bounds: Array) -> Array:
	if last_fit.is_empty() or str(last_fit.get("track_id", "")) != sel_id:
		return []
	var times: Array = []
	for res in last_fit.get("residuals", []):
		if bool(res.get("inlier", true)):
			times.append(float(res["time"]))
	if times.is_empty():
		return []
	times.sort()
	var chosen: Array = [times[0], times[times.size() - 1]]
	for bt in leg_bounds:
		var nearest: float = times[0]
		var bd: float = INF
		for t in times:
			var d: float = absf(t - float(bt))
			if d < bd:
				bd = d
				nearest = t
		if not chosen.has(nearest):
			chosen.append(nearest)
	var remaining: int = 12 - chosen.size()
	if remaining > 0 and times.size() > chosen.size():
		var stride: float = float(times.size() - 1) / float(remaining + 1)
		for k in range(remaining):
			var t2: float = times[int(round((k + 1) * stride))]
			if not chosen.has(t2):
				chosen.append(t2)
	chosen.sort()
	return chosen


## P_now = F P Fᵀ + Q（白噪声加速度模型），返回位置 2x2 子块（m²）。
## solver 协方差为尺度归一化空间：p/1000m、v/5ms⁻¹。
## rank<4、cond>1e4 或 MULTIMODAL 时返回 []（禁止虚假小椭圆）。
static func propagated_cov(last_fit: Dictionary, now: float) -> Array:
	if last_fit.is_empty() or not bool(last_fit.get("success", false)):
		return []
	if int(last_fit.get("jacobian_rank", 0)) < 4:
		return []
	if float(last_fit.get("condition_number", 0.0)) > 1.0e4:
		return []
	if str(last_fit.get("status", "")) == "MULTIMODAL":
		return []
	var mat: Array = last_fit.get("covariance", {}).get("matrix", [])
	if mat.size() != 4:
		return []
	var dt: float = maxf(now - float(last_fit.get("reference_time", now)), 0.0)
	var p_mat: Array = _rescale(mat)
	var q2: float = pow(QA, 2.0) * pow(dt, 4.0) * 0.25
	var pee: float = p_mat[0][0] + dt * (p_mat[0][2] + p_mat[2][0]) + dt * dt * p_mat[2][2] + q2
	var pnn: float = p_mat[1][1] + dt * (p_mat[1][3] + p_mat[3][1]) + dt * dt * p_mat[3][3] + q2
	var pen: float = p_mat[0][1] + dt * (p_mat[0][3] + p_mat[2][1]) + dt * dt * p_mat[2][3] + q2
	return [[pee, pen], [pen, pnn]]


## 尺度归一化 4x4 → 实际单位（m / m·s⁻¹）。
static func _rescale(mat: Array) -> Array:
	var out: Array = []
	for i in range(4):
		var row: Array = []
		var si: float = POS_SCALE if i < 2 else VEL_SCALE
		for j in range(4):
			var sj: float = POS_SCALE if j < 2 else VEL_SCALE
			row.append(float(mat[i][j]) * si * sj)
		out.append(row)
	return out


## Bearing-Time 模型曲线：最优（橙、置顶）+ 备选 A/B/C。
static func bt_curves(last_fit: Dictionary, sel_id: String) -> Array:
	var curves: Array = []
	if last_fit.is_empty() or not bool(last_fit.get("success", false)):
		return curves
	if str(last_fit.get("track_id", "")) != sel_id:
		return curves
	var best: Dictionary = last_fit.get("best", {})
	if not best.is_empty():
		curves.append(model_curve(last_fit, best, Color(0.98, 0.55, 0.15), true))
	var i: int = 0
	for alt in last_fit.get("alternatives", []):
		if i >= MAX_ALTS:
			break
		curves.append(model_curve(last_fit, alt, Color(0.55, 0.75, 1.0, 0.8), false))
		i += 1
	return curves


static func model_curve(
	last_fit: Dictionary, hyp: Dictionary, col: Color, is_best: bool
) -> Dictionary:
	var pts: Array = []
	var pred: Array = hyp.get("pred_bearings", [])
	# S1-04B-REQ-08：主动测量展开为 BEARING+RANGE 两残差行；pred_bearings 只含
	# BEARING 行（range 行无独立方位预测），逐行配对时必须跳过 kind=="range"。
	var bi: int = 0
	for res in last_fit.get("residuals", []):
		if str(res.get("kind", "bearing")) == "range":
			continue
		if bi < pred.size():
			pts.append({"time": float(res["time"]), "bearing_deg": float(pred[bi])})
		bi += 1
	return {"points": pts, "color": col, "best": is_best}


## 只取方位残差行（残差图按度显示；range 行是米量纲，不能混入同轴）。
static func bearing_residuals(res: Array) -> Array:
	return _kind_rows(res, "bearing")


## 只取测距残差行（REQ-06：range 通道独立成图/独立 σ 参考，单位 m）。
static func range_residuals(res: Array) -> Array:
	return _kind_rows(res, "range")


static func _kind_rows(res: Array, kind: String) -> Array:
	var out: Array = []
	for r in res:
		if str(r.get("kind", "bearing")) == kind:
			out.append(r)
	return out


## 方位参考σ（deg）：由 inlier 方位残差对的 |raw/normalized| 中位数估计。
## 输入可含 range 行（内部按 kind 过滤），兼容旧调用。
static func mean_sigma(res: Array) -> float:
	return _median_sigma_kind(res, "bearing")


## 测距参考σ（m）：同上，但只取 range 行——区间带与真实测距波动对齐，
## 不做"残差长度归一化传播"式的拟合尺度换算（REQ-06 单位分离）。
static func mean_sigma_range(res: Array) -> float:
	return _median_sigma_kind(res, "range")


static func _median_sigma_kind(res: Array, kind: String) -> float:
	var ratios: Array = []
	for r in res:
		if str(r.get("kind", "bearing")) != kind:
			continue
		var n: float = absf(float(r.get("normalized", 0.0)))
		if n > 1e-6:
			ratios.append(absf(float(r["raw_value"])) / n)
	if ratios.is_empty():
		return 1.0
	ratios.sort()
	return ratios[ratios.size() / 2]


## 拟合结果摘要（REQ-05/06：物理证据 + bearing/range/rejected 行计数分列）。
## sel 传入时附"物理证据 N"（Track 去重 evidence_id）；纯结果路径可不传。
## 计数口径：残差行 = TMA 展开后的观测量行（主动一条 = B+R 两行）；物理证据
## = Track 去重后的真实探测数——两者分离展示，禁止混为一谈。
static func summary(r: Dictionary, sel: Track = null) -> String:
	var lines: Array = []
	lines.append("Track %s  Status: %s" % [str(r.get("track_id", "?")), str(r.get("status", "?"))])
	if bool(r.get("maneuver_suspected", false)):
		lines.append("!! Target maneuver suspected - re-maneuver & refit")
	if int(r.get("hypothesis_count", 0)) > 1:
		var n_alt: int = mini(int(r.get("hypothesis_count", 1)) - 1, MAX_ALTS)
		lines.append("Alternatives: %d (A/B/C on chart)" % n_alt)
	var b_used: int = 0
	var b_rej: int = 0
	var r_used: int = 0
	var r_rej: int = 0
	for row in r.get("residuals", []):
		if str(row.get("kind", "bearing")) == "range":
			if bool(row.get("inlier", true)):
				r_used += 1
			else:
				r_rej += 1
		else:
			if bool(row.get("inlier", true)):
				b_used += 1
			else:
				b_rej += 1
	(
		lines
		. append(
			(
				"Ref t=%.0fs stale=%.0fs legs=%d"
				% [
					float(r.get("reference_time", 0.0)),
					float(r.get("stale_seconds", 0.0)),
					int(r.get("legs", 0)),
				]
			)
		)
	)
	var ev_txt: String = ""
	if sel != null:
		ev_txt = "  Ev %d phys" % sel.evidence_count()
	if r_used + r_rej > 0:
		lines.append(
			"Rows B used %d rej %d | R used %d rej %d%s" % [b_used, b_rej, r_used, r_rej, ev_txt]
		)
	else:
		lines.append("Rows B used %d rej %d%s" % [b_used, b_rej, ev_txt])
	var cond: float = float(r.get("condition_number", 0.0))
	var cond_txt: String = "inf" if is_inf(cond) else "%.0f" % cond
	(
		lines
		. append(
			(
				"RMSE %.2f° rank=%d cond=%s"
				% [
					float(r.get("angular_rmse", 0.0)),
					int(r.get("jacobian_rank", 0)),
					cond_txt,
				]
			)
		)
	)
	# S1-04B-REQ-15：主动测距进入拟合时明确标注 RANGE AIDED 与采用的测距数。
	if bool(r.get("has_range_measurements", false)):
		var rng_rmse: String = (
			"%.0fm" % float(r.get("range_rmse_m", 0.0))
			if float(r.get("range_rmse_m", -1.0)) >= 0.0
			else "n/a"
		)
		(
			lines
			. append(
				(
					"RANGE AIDED: active ranges used %d (rejected %d)  R_RMSE %s"
					% [
						int(r.get("active_range_rows_used", 0)),
						int(r.get("active_range_rows_rejected", 0)),
						rng_rmse,
					]
				)
			)
		)
	var unc: float = float(r.get("position_uncertainty_m", -1.0))
	if unc > 0.0:
		(
			lines
			. append(
				(
					"Pos 95%% ±%.0fm  Spd ±%.1fkn"
					% [
						unc,
						NavUtils.ms_to_kn(float(r.get("velocity_uncertainty_ms", 0.0))),
					]
				)
			)
		)
	else:
		lines.append("Uncertainty: N/A (insufficient geometry / multi-modal)")
	if bool(r.get("boundary_hit", false)):
		lines.append("!! BOUNDARY_HIT: solution at parameter limit")
	var text: String = ""
	for ln in lines:
		text += ln + "\n"
	return text


static func outlier_times(last_fit: Dictionary, track_id: String) -> Dictionary:
	var out: Dictionary = {}
	if last_fit.is_empty() or str(last_fit.get("track_id", "")) != track_id:
		return out
	for res in last_fit.get("residuals", []):
		if not bool(res.get("inlier", true)):
			out[float(res["time"])] = true
	return out


## 单条 Measurement → TmaSolver.solve_auto 输入字典（主 UI / DotStack 共用）。
## S1-04B-REQ-08：主动测距 range/range_sigma 成对有效才透传，解算器在
## _validate/_expand_range 展开为距离残差行（REQ-06）；纯方位被动测量不带
## range 键 → 零展开，行为与旧版一致。歧义支路标识随附（S1-03A/S1-06）。
static func fit_meas_dict(m: Measurement) -> Dictionary:
	var d: Dictionary = {
		"time": m.timestamp,
		"observer_e": m.observer_east_m,
		"observer_n": m.observer_north_m,
		"bearing": m.measured_bearing_deg,
		"sigma": m.bearing_sigma_deg,
		"measurement_id": m.measurement_id,
		"evidence_id": m.evidence_id,
	}
	if m.has_range():
		d["range_m"] = m.measured_range_m
		d["range_sigma_m"] = m.range_sigma_m
	if m.ambiguous_pair_id != "":
		d["ambiguous_pair_id"] = m.ambiguous_pair_id
		d["ambiguity_branch"] = m.ambiguity_branch
	return d


static func leg_boundary_times(meas: Array) -> Array:
	var ms: Array = meas
	var turns: Array = []
	if ms.size() < 3:
		return turns
	var anchor := Vector2(ms[0].observer_east_m, ms[0].observer_north_m)
	var prev_heading: float = INF
	for i in range(1, ms.size()):
		var cur := Vector2(ms[i].observer_east_m, ms[i].observer_north_m)
		var d: Vector2 = cur - anchor
		if d.length() < 10.0:
			continue
		var heading: float = rad_to_deg(atan2(d.x, d.y))
		if prev_heading != INF and absf(NavUtils.angle_diff(heading, prev_heading)) > 15.0:
			turns.append(ms[i].timestamp)
		prev_heading = heading
		anchor = cur
	return turns


static func own_turn_times(ms: Array) -> Array:
	return leg_boundary_times(ms)


## 玩家/Truth 位置点去重轨迹（本艇路径，供海图）。cap 控制点数。
static func sample_own_track(world: World, cap: int = 400) -> Array:
	var pts: Array = []
	pts.append(Vector2(world.world["own"].position_east_m, world.world["own"].position_north_m))
	for m in world.measurements:
		pts.append(Vector2(m.observer_east_m, m.observer_north_m))
	var out: Array = []
	var seen := {}
	for p in pts:
		var key: String = "%d_%d" % [int(p.x), int(p.y)]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(p)
		if out.size() > cap:
			break
	return out


## 每个 track 最新一条 LOB（方位盘用）。
static func latest_lobs_for_dial(lobs: Array) -> Array:
	var newest: Dictionary = {}
	for lob in lobs:
		var tid: String = str(lob["track_id"])
		if not newest.has(tid) or float(lob["time"]) > float(newest[tid]["time"]):
			newest[tid] = lob
	return newest.values()


## Truth 目标位置（仅供 Show Truth 开关显示，非操作依据）。
static func collect_truth(world: World) -> Array:
	var out: Array = []
	for t in world.world["targets"]:
		out.append({"pos": Vector2(t.position_east_m, t.position_north_m), "id": t.id})
	return out


## Dot Stack 等价计算（从 main_ui 拆出，控行数）：只用 inlier 测量 + 最优解。
static func dot_stack_compute(ds: DotStack, r: Dictionary, sel: Track) -> void:
	var best: Dictionary = r.get("best", {})
	if best.is_empty():
		return
	var inlier_set: Dictionary = {}
	for res in r.get("residuals", []):
		if bool(res.get("inlier", true)):
			inlier_set[float(res["time"])] = true
	var inlier_meas: Array = []
	for m in sel.measurement_history:
		if inlier_set.has(m.timestamp):
			inlier_meas.append(fit_meas_dict(m))
	if inlier_meas.is_empty():
		return
	var p0: Vector2 = best["p_ref"] as Vector2
	var v0: Vector2 = best["v_ms"] as Vector2
	ds.compute(inlier_meas, p0.x, p0.y, v0.x, v0.y, float(best.get("t_ref", 0.0)))


## 最近一次测量。
static func latest_measurement(world: World) -> Measurement:
	if world.measurements.is_empty():
		return null
	return world.measurements[world.measurements.size() - 1]
