class_name TmaSolver
extends RefCounted
## tma_solver.gd — TMA（纯方位运动分析）解算器。
##
## 两层 API：
##   1. solve()           — 单初值带阻尼高斯-牛顿局部优化（底层原语，向后兼容）。
##   2. solve_auto()      — 完整自动拟合流水线（阶段三重构，符合 TMA 需求文档）：
##       输入预处理 → 全局多初值候选搜索（对数距离 × 航向 × 航速）
##       → 有边界 LM 局部优化（Huber 稳健损失）→ 候选聚类去重
##       → 备选假设权重 exp[-(J-Jmin)/2] → 雅可比 SVD 可观测性检查
##       → 目标机动检测 → TmaFitResult（状态机 + 协方差 + 诊断）。
##
## 数学约定（全局唯一，见 nav_utils.gd）：
##   - x 向东，y 向北（米）；方位：正北 0° 顺时针 [0,360)
##   - 残差 r_i = wrap180(预测方位 - 实测方位) ∈ [-180,180)
##   - 状态 x = [pE, pN, vE, vN]，参考时刻取最新一条有效测量（减少外推误差）
##   - 目标匀速直线：p(t_i) = p_ref + v·(t_i - t_ref)
##
## Truth 隔离：本模块输入只有测量字典（时间戳/本艇历史位置/方位/σ），
## 接口上不存在任何 Truth 访问路径（验收测试 12）。

const MAX_ITER: int = 60
const MIN_STEP: float = 1e-8
const COST_REL_TOL: float = 1e-9

# 自动拟合默认参数（可被 options 覆盖）
const DEF_MIN_RANGE_M: float = 200.0
const DEF_MAX_RANGE_M: float = 50000.0
const DEF_MIN_SPEED_KN: float = 0.0
const DEF_MAX_SPEED_KN: float = 35.0
const DEF_TOP_K: int = 6  # 全局搜索保留并局部优化的候选数
const DEF_STALE_S: float = 600.0  # 超过此秒数无新测量 → STALE
const DEF_HUBER_K: float = 2.0  # Huber 门限（标准化残差单位）
const DEF_OUTLIER_U: float = 3.0  # |u| 超过此值 → 离群测量
const DEF_MANEUVER_U: float = 2.0  # 机动检测的标准化残差游程门限
const DEF_MANEUVER_COUNT: int = 3  # 连续同号超限测量数 → MANEUVER_SUSPECTED
const POS_SCALE_M: float = 1000.0  # 雅可比尺度归一化（位置）
const VEL_SCALE_MS: float = 5.0  # 雅可比尺度归一化（速度）
const MULTIMODAL_WEIGHT_RATIO: float = 0.25  # 次优/最优权重 ≥ 此值 → MULTIMODAL
const CLUSTER_POS_M: float = 800.0
const CLUSTER_SPEED_KN: float = 3.0
const CLUSTER_COURSE_DEG: float = 15.0

## 一条解算输入的测量（普通 Dictionary）：
##   { "time": float, "observer_e": float, "observer_n": float,
##     "bearing": float, "sigma": float }
## bearing 为从本艇看目标的方位（度，从北顺时针）；observer_* 必须是
## 测量发生时刻的本艇位置，不得用当前帧位置代替。

# =====================================================================
#  对外主入口：solve_auto
# =====================================================================


## 完整自动拟合。返回 TmaFitResult（Dictionary），字段见 _empty_result()。
## options（全部可选）：
##   min_range_m / max_range_m / min_speed_kn / max_speed_kn
##   top_k / stale_threshold_s / robust (bool) / huber_k
##   demon_speed_kn (-1=无) / demon_sigma_kn
##   now_time (当前仿真时间，用于 staleness；默认用最后测量时间)
##   exclude_indices (Array[int]，人工排除的测量)
static func solve_auto(measurements: Array, options: Dictionary = {}) -> Dictionary:
	var res: Dictionary = _empty_result()

	# ---------- 1. 输入预处理 ----------
	var valid: Array = _validate(measurements, res, options)
	var n: int = valid.size()
	if res["status"] == "NO_DATA" or res["status"] == "INSUFFICIENT_MEASUREMENTS":
		return res

	var t_ref: float = float(valid[n - 1]["time"])
	var o_ref := Vector2(float(valid[n - 1]["observer_e"]), float(valid[n - 1]["observer_n"]))

	var min_r: float = float(options.get("min_range_m", DEF_MIN_RANGE_M))
	var max_r: float = float(options.get("max_range_m", DEF_MAX_RANGE_M))
	var min_v: float = NavUtils.kn_to_ms(float(options.get("min_speed_kn", DEF_MIN_SPEED_KN)))
	var max_v: float = NavUtils.kn_to_ms(float(options.get("max_speed_kn", DEF_MAX_SPEED_KN)))
	var top_k: int = int(options.get("top_k", DEF_TOP_K))
	var robust: bool = bool(options.get("robust", true))
	var huber_k: float = float(options.get("huber_k", DEF_HUBER_K))
	var demon_kn: float = float(options.get("demon_speed_kn", -1.0))
	var demon_sigma: float = float(options.get("demon_sigma_kn", 2.0))

	# ---------- 2. 全局候选搜索 ----------
	var seeds: Array = _global_candidates(valid, t_ref, o_ref, min_r, max_r, min_v, max_v, demon_kn)
	# 按代价排序取前 top_k
	seeds.sort_custom(func(a, b): return a["cost"] < b["cost"])
	var kept: Array = []
	for i in range(mini(top_k, seeds.size())):
		kept.append(seeds[i])

	# ---------- 3. 有边界局部优化（每个候选） ----------
	var hyps: Array = []
	var any_boundary: bool = false
	for seed in kept:
		var x0 := seed["x"] as Vector4
		var ref_res: Dictionary = _refine(
			valid, t_ref, x0, min_v, max_v, robust, huber_k, demon_kn, demon_sigma
		)
		if bool(ref_res.get("boundary_hit", false)):
			any_boundary = true
		var xf: Vector4 = ref_res["x"]
		var cost: float = float(ref_res["cost"])
		hyps.append(_make_hypothesis(valid, t_ref, xf, cost, 0.0))
	hyps.sort_custom(func(a, b): return a["cost"] < b["cost"])

	# ---------- 4. 候选聚类去重 ----------
	hyps = _cluster(hyps)
	if hyps.is_empty():
		res["status"] = "INSUFFICIENT_MEASUREMENTS"
		return res

	# ---------- 5. 目标机动检测（必须先于离群剔除：连续同方向大残差
	# 是疑似机动的特征，不是离群点；稳健损失不得掩盖目标转向） ----------
	var best: Dictionary = hyps[0]
	var maneuver: bool = _detect_maneuver(valid, t_ref, best["x"])
	var inlier_mask: Array = []
	for i in range(n):
		inlier_mask.append(true)
	var rejected: Array = []
	if robust and n >= 6 and not maneuver:
		var us: Array = _normalized_residuals(valid, t_ref, best["x"])
		for i in range(n):
			if absf(float(us[i])) > DEF_OUTLIER_U:
				inlier_mask[i] = false
				rejected.append(i)
		if not rejected.is_empty():
			var sub: Array = []
			for i in range(n):
				if inlier_mask[i]:
					sub.append(valid[i])
			var r2: Dictionary = _refine(
				sub, t_ref, best["x"], min_v, max_v, robust, huber_k, demon_kn, demon_sigma
			)
			best = _make_hypothesis(valid, t_ref, r2["x"], float(r2["cost"]), 0.0)
			# 重新对全部测量算代价（保持可比性），聚类与权重基于 inlier 代价
			for h in hyps:
				h["cost"] = _robust_cost(
					valid, t_ref, h["x"], robust, huber_k, demon_kn, demon_sigma
				)
			hyps.sort_custom(func(a, b): return a["cost"] < b["cost"])
			best = hyps[0]

	# ---------- 6. 备选假设权重 ----------
	var j_min: float = float(best["cost"])
	for h in hyps:
		h["weight"] = exp(-0.5 * (float(h["cost"]) - j_min))
	var alt_weight_max: float = 0.0
	for i in range(1, hyps.size()):
		alt_weight_max = maxf(alt_weight_max, float(hyps[i]["weight"]))

	# ---------- 7. 残差与统计 ----------
	var residuals: Array = []
	var sq_sum_deg: float = 0.0
	var sq_sum_w: float = 0.0
	var used_count: int = 0
	var us2: Array = _normalized_residuals(valid, t_ref, best["x"])
	for i in range(n):
		var sigma: float = maxf(float(valid[i].get("sigma", 1.0)), 0.1)
		var r_deg: float = _single_residual(valid[i], t_ref, best["x"])
		(
			residuals
			. append(
				{
					"index": int(valid[i].get("_orig_index", i)),
					"time": float(valid[i]["time"]),
					"residual_deg": r_deg,
					"normalized": float(us2[i]),
					"inlier": inlier_mask[i],
				}
			)
		)
		if inlier_mask[i]:
			used_count += 1
			sq_sum_deg += r_deg * r_deg
			sq_sum_w += float(us2[i]) * float(us2[i])
	var angular_rmse: float = sqrt(sq_sum_deg / maxf(used_count, 1))
	var weighted_rmse: float = sqrt(sq_sum_w / maxf(used_count, 1))

	# ---------- 8. 可观测性（雅可比 SVD，尺度归一化） ----------
	var svd: Dictionary = _observability(valid, t_ref, best["x"], inlier_mask)
	var rank: int = int(svd["rank"])
	var cond: float = float(svd["condition_number"])
	var legs: int = _count_legs(valid)

	# ---------- 9. 机动已在第 5 步检测（先于离群剔除） ----------

	# ---------- 10. 状态机 ----------
	var status: String = "CONVERGED"
	if n < 4:
		status = "INSUFFICIENT_MEASUREMENTS"
	elif legs < 2 or rank < 4 or cond > 1.0e4:
		status = "INSUFFICIENT_GEOMETRY"
	elif alt_weight_max >= MULTIMODAL_WEIGHT_RATIO:
		status = "MULTIMODAL"
	elif maneuver:
		status = "MANEUVER_SUSPECTED"
	elif any_boundary:
		status = "BOUNDARY_HIT"
	elif not bool(best.get("converged", true)):
		status = "PROVISIONAL"

	var now_t: float = float(options.get("now_time", float(valid[n - 1]["time"])))
	var stale: float = maxf(now_t - float(valid[n - 1]["time"]), 0.0)
	if stale > float(options.get("stale_threshold_s", DEF_STALE_S)):
		status = "STALE"

	# ---------- 11. 协方差（仅单峰可观测时） ----------
	var cov: Dictionary = {}
	var pos_unc: float = -1.0
	var vel_unc: float = -1.0
	if (
		rank == 4
		and status in ["CONVERGED", "PROVISIONAL", "BOUNDARY_HIT", "STALE", "MANEUVER_SUSPECTED"]
	):
		var c: Dictionary = _covariance(valid, t_ref, best["x"], inlier_mask)
		if not c.is_empty():
			cov = c
			pos_unc = sqrt(maxf(float(c.get("p_e", 0.0)), 0.0)) * POS_SCALE_M
			vel_unc = sqrt(maxf(float(c.get("v_e", 0.0)), 0.0)) * VEL_SCALE_MS
			if status == "STALE":
				# 外推过程噪声：不确定度随 staleness 扩大
				pos_unc = sqrt(pos_unc * pos_unc + pow(0.5 * stale, 2.0))

	# ---------- 12. 组装结果 ----------
	best["converged"] = bool(best.get("converged", true))
	res["status"] = status
	res["reference_time"] = t_ref
	res["best"] = best
	res["alternatives"] = hyps.slice(1)
	res["measurements_used"] = used_count
	res["measurements_rejected"] = rejected
	res["residuals"] = residuals
	res["weighted_cost"] = j_min
	res["angular_rmse"] = angular_rmse
	res["weighted_rmse"] = weighted_rmse
	res["jacobian_rank"] = rank
	res["condition_number"] = cond
	res["singular_values"] = svd["singular_values"]
	res["covariance"] = cov
	res["position_uncertainty_m"] = pos_unc
	res["velocity_uncertainty_ms"] = vel_unc
	res["maneuver_suspected"] = maneuver
	res["mirror_resolved"] = true  # 拖曳阵镜像属于阶段4，此处无镜像输入
	res["boundary_hit"] = any_boundary
	res["stale_seconds"] = stale
	res["legs"] = legs
	res["hypothesis_count"] = hyps.size()
	res["success"] = true
	res["diagnostics"] = {"seeds_evaluated": seeds.size(), "outliers": rejected}
	return res


# =====================================================================
#  输入预处理
# =====================================================================


## 校验测量：时间戳递增、方位有效、σ>0、去重。无效数据不静默进入优化器。
## 通过 res 直接写 "status"；返回有效测量数组（附 _orig_index）。
static func _validate(measurements: Array, res: Dictionary, options: Dictionary) -> Array:
	if measurements.is_empty():
		res["status"] = "NO_DATA"
		return []
	var exclude: Dictionary = {}
	for idx in options.get("exclude_indices", []):
		exclude[int(idx)] = true
	var out: Array = []
	var last_t: float = -1e18
	var seen: Dictionary = {}
	for i in range(measurements.size()):
		if exclude.has(i):
			continue
		var m: Dictionary = measurements[i]
		var t: float = float(m.get("time", NAN))
		var brg: float = float(m.get("bearing", NAN))
		var sig: float = float(m.get("sigma", 0.0))
		if is_nan(t) or is_nan(brg) or sig <= 0.0:
			continue  # 无效测量：直接丢弃（记入诊断）
		if t < last_t:
			# 时间戳非递增：仍接受，但按原序（调用方应先排序）
			pass
		last_t = t
		var key: String = "%.3f_%.2f_%.1f" % [t, float(m.get("observer_e", 0.0)), brg]
		if seen.has(key):
			continue  # 重复测量
		seen[key] = true
		var copy: Dictionary = m.duplicate()
		copy["_orig_index"] = i
		out.append(copy)
	if out.is_empty():
		res["status"] = "NO_DATA"
	elif out.size() < 2:
		res["status"] = "INSUFFICIENT_MEASUREMENTS"
	else:
		res["status"] = ""  # 校验通过，清空骨架默认状态
	return out


# =====================================================================
#  全局候选搜索
# =====================================================================


## 沿最新 LOB 对数采样距离 × 航向 × 航速 网格，返回 [{x: Vector4, cost: float}]。
## 若有 DEMON 速度先验，围绕其增加高密度航速采样。
static func _global_candidates(
	valid: Array,
	t_ref: float,
	o_ref: Vector2,
	min_r: float,
	max_r: float,
	min_v: float,
	max_v: float,
	demon_kn: float
) -> Array:
	var brg_ref: float = float(valid[valid.size() - 1]["bearing"])
	var brad: float = deg_to_rad(brg_ref)
	var dir_lob := Vector2(sin(brad), cos(brad))
	var ranges: Array = _log_space(maxf(min_r, 300.0), max_r, 8)
	var courses: Array = []
	for c in range(0, 360, 30):
		courses.append(float(c))
	var speeds: Array = [0.0, 2.0, 5.0, 8.0, 12.0, 16.0, 20.0, 25.0, 30.0]
	if demon_kn > 0.0:
		for dk in [-2.0, -1.0, 1.0, 2.0]:
			speeds.append(maxf(demon_kn + dk, 0.0))
	var out: Array = []
	for r in ranges:
		for cdeg in courses:
			var crad: float = deg_to_rad(cdeg)
			for skn in speeds:
				var v_ms: float = NavUtils.kn_to_ms(skn)
				if v_ms < min_v - 0.01 or v_ms > max_v + 0.01:
					continue
				var p: Vector2 = o_ref + dir_lob * r
				var v := Vector2(v_ms * sin(crad), v_ms * cos(crad))
				var x := Vector4(p.x, p.y, v.x, v.y)
				out.append({"x": x, "cost": _raw_cost(valid, t_ref, x)})
	return out


static func _log_space(a: float, b: float, n: int) -> Array:
	var out: Array = []
	var la: float = log(maxf(a, 1.0))
	var lb: float = log(maxf(b, a * 1.01))
	for i in range(n):
		out.append(exp(la + (lb - la) * float(i) / float(n - 1)))
	return out


# =====================================================================
#  局部优化（有边界 LM + Huber IRLS）
# =====================================================================


## 从初值 x0 精化。返回 {x, cost, converged, iterations, boundary_hit}。
static func _refine(
	valid: Array,
	t_ref: float,
	x0: Vector4,
	min_v: float,
	max_v: float,
	robust: bool,
	huber_k: float,
	demon_kn: float,
	demon_sigma: float
) -> Dictionary:
	var x := _clamp_state(x0, min_v, max_v)
	var lam: float = 1e-3
	var prev_cost: float = _robust_cost(valid, t_ref, x, robust, huber_k, demon_kn, demon_sigma)
	var converged: bool = false
	var iters: int = 0
	var boundary_hit: bool = false

	for iter in range(MAX_ITER):
		iters = iter + 1
		var r: Array = _residuals(valid, t_ref, x)
		var us: Array = _normalized_residuals(valid, t_ref, x)
		var jacob := _numerical_jacobian(valid, t_ref, x)
		var n: int = valid.size()

		# IRLS 权重：w_i * huber'(u_i)/(2u_i)
		var w: Array = []
		for i in range(n):
			var sigma: float = maxf(float(valid[i].get("sigma", 1.0)), 0.1)
			var wi: float = 1.0 / (sigma * sigma)
			if robust:
				var u: float = absf(float(us[i]))
				if u > huber_k:
					wi *= huber_k / u
			w.append(wi)

		# 法方程
		var mat: Array = []
		for a in range(4):
			var row: Array = []
			for c in range(4):
				row.append(0.0)
			mat.append(row)
		var b: Array = [0.0, 0.0, 0.0, 0.0]
		for i in range(n):
			var wi: float = w[i]
			for a in range(4):
				var ja: float = jacob[a][i]
				b[a] += ja * wi * r[i]
				for c in range(4):
					mat[a][c] += ja * wi * jacob[c][i]

		var solved: Dictionary = TmaLinalg.solve_damped(mat, b, lam)
		if not solved["ok"]:
			break
		var delta := solved["delta"] as Vector4

		var step: float = 1.0
		var x_new: Vector4 = x
		var new_cost: float = INF
		var accepted: bool = false
		for _ls in range(20):
			x_new = _clamp_state(
				Vector4(
					x.x + step * delta.x,
					x.y + step * delta.y,
					x.z + step * delta.z,
					x.w + step * delta.w
				),
				min_v,
				max_v
			)
			new_cost = _robust_cost(valid, t_ref, x_new, robust, huber_k, demon_kn, demon_sigma)
			if new_cost < prev_cost:
				accepted = true
				break
			step *= 0.5

		if accepted:
			var rel: float = (prev_cost - new_cost) / maxf(prev_cost, 1e-12)
			x = x_new
			prev_cost = new_cost
			lam = maxf(lam * 0.3, 1e-8)
			if rel < COST_REL_TOL and delta.length() * step < MIN_STEP:
				converged = true
				break
		else:
			lam = minf(lam * 10.0, 1e8)
			if lam >= 1e8:
				break

	if iters >= MAX_ITER:
		converged = true
	# 边界检测：终态速度贴边界 → BOUNDARY_HIT
	var spd: float = Vector2(x.z, x.w).length()
	if spd <= min_v + 0.05 or spd >= max_v - 0.05:
		boundary_hit = true
	return {
		"x": x,
		"cost": prev_cost,
		"converged": converged,
		"iterations": iters,
		"boundary_hit": boundary_hit
	}


static func _clamp_state(x: Vector4, min_v: float, max_v: float) -> Vector4:
	var v := Vector2(x.z, x.w)
	var spd: float = clampf(v.length(), min_v, max_v)
	if spd > 0.0 and v.length() > 1e-9:
		v = v.normalized() * spd
	else:
		v = Vector2.ZERO
	return Vector4(x.x, x.y, v.x, v.y)


# =====================================================================
#  残差 / 代价
# =====================================================================


static func _residuals(measurements: Array, t0: float, x: Vector4) -> Array:
	var out: Array = []
	for m in measurements:
		out.append(_single_residual(m, t0, x))
	return out


static func _single_residual(m: Dictionary, t0: float, x: Vector4) -> float:
	var t: float = float(m["time"]) - t0
	var p := Vector2(x.x + x.z * t, x.y + x.w * t)
	var o := Vector2(float(m["observer_e"]), float(m["observer_n"]))
	var d: Vector2 = p - o
	var pred_bearing: float = rad_to_deg(atan2(d.x, d.y))  # 从北顺时针
	return NavUtils.wrap180(pred_bearing - float(m["bearing"]))


static func _normalized_residuals(measurements: Array, t0: float, x: Vector4) -> Array:
	var out: Array = []
	var rs: Array = _residuals(measurements, t0, x)
	for i in range(measurements.size()):
		var sigma: float = maxf(float(measurements[i].get("sigma", 1.0)), 0.1)
		out.append(float(rs[i]) / sigma)
	return out


## 普通加权平方代价（全局打分用，不需要 IRLS）。
static func _raw_cost(measurements: Array, t0: float, x: Vector4) -> float:
	var rs: Array = _residuals(measurements, t0, x)
	var c: float = 0.0
	for i in range(measurements.size()):
		var sigma: float = maxf(float(measurements[i].get("sigma", 1.0)), 0.1)
		var u: float = rs[i] / sigma
		c += u * u
	return c


## Huber 稳健代价 + 可选 DEMON 软约束。
static func _robust_cost(
	measurements: Array,
	t0: float,
	x: Vector4,
	robust: bool,
	huber_k: float,
	demon_kn: float,
	demon_sigma: float
) -> float:
	var us: Array = _normalized_residuals(measurements, t0, x)
	var c: float = 0.0
	for u_v in us:
		var u: float = float(u_v)
		if robust and absf(u) > huber_k:
			c += huber_k * (2.0 * absf(u) - huber_k)
		else:
			c += u * u
	# DEMON 速度软约束
	if demon_kn > 0.0 and demon_sigma > 0.0:
		var spd_kn: float = NavUtils.ms_to_kn(Vector2(x.z, x.w).length())
		var uv: float = (spd_kn - demon_kn) / demon_sigma
		c += uv * uv
	return c


# =====================================================================
#  假设构建 / 聚类
# =====================================================================


static func _make_hypothesis(
	valid: Array, t_ref: float, x: Vector4, cost: float, weight: float
) -> Dictionary:
	var v := Vector2(x.z, x.w)
	var o_ref := Vector2(
		float(valid[valid.size() - 1]["observer_e"]), float(valid[valid.size() - 1]["observer_n"])
	)
	var d: Vector2 = Vector2(x.x, x.y) - o_ref
	# 预测方位序列（供 Bearing-Time 图画模型曲线）
	var pred: Array = []
	for m in valid:
		var t: float = float(m["time"]) - t_ref
		var p := Vector2(x.x + x.z * t, x.y + x.w * t)
		var dd: Vector2 = p - Vector2(float(m["observer_e"]), float(m["observer_n"]))
		pred.append(NavUtils.wrap360(rad_to_deg(atan2(dd.x, dd.y))))
	return {
		"x": x,
		"p_ref": Vector2(x.x, x.y),
		"v_ms": v,
		"t_ref": t_ref,
		"bearing_deg": NavUtils.wrap360(rad_to_deg(atan2(d.x, d.y))),
		"range_m": d.length(),
		"course_deg": NavUtils.wrap360(rad_to_deg(atan2(v.x, v.y))),
		"speed_kn": NavUtils.ms_to_kn(v.length()),
		"cost": cost,
		"weight": weight,
		"pred_bearings": pred,
	}


## 合并数值上接近的重复解，保留空间位置/航向/速度明显不同的独立模式。
static func _cluster(hyps: Array) -> Array:
	var out: Array = []
	for h in hyps:
		var dup: bool = false
		for k in out:
			var dp: float = (h["p_ref"] as Vector2).distance_to(k["p_ref"])
			var dv: float = absf(float(h["speed_kn"]) - float(k["speed_kn"]))
			var dc: float = absf(
				NavUtils.angle_diff(float(h["course_deg"]), float(k["course_deg"]))
			)
			if dp < CLUSTER_POS_M and dv < CLUSTER_SPEED_KN and dc < CLUSTER_COURSE_DEG:
				dup = true
				break
		if not dup:
			out.append(h)
	return out


# =====================================================================
#  可观测性：数值雅可比 → 尺度归一化 → JᵀJ 特征值（Jacobi）→ 秩/条件数
# =====================================================================


## 数值雅可比：J[a][i] = ∂r_i / ∂x_a（未归一化残差，度）。
## 扰动步长按物理量纲取：位置 1m、速度 0.01m/s（1e-5 级扰动低于浮点精度，
## 会产生垃圾雅可比导致 LM 提前停滞）。
static func _numerical_jacobian(measurements: Array, t0: float, x: Vector4) -> Array:
	var steps: Array = [1.0, 1.0, 0.01, 0.01]
	var jacob: Array = []  # [param][meas]
	for a in range(4):
		var xp := x
		var xm := x
		if a == 0:
			xp.x += steps[a]
			xm.x -= steps[a]
		elif a == 1:
			xp.y += steps[a]
			xm.y -= steps[a]
		elif a == 2:
			xp.z += steps[a]
			xm.z -= steps[a]
		else:
			xp.w += steps[a]
			xm.w -= steps[a]
		var rp: Array = _residuals(measurements, t0, xp)
		var rm: Array = _residuals(measurements, t0, xm)
		var row: Array = []
		for i in range(measurements.size()):
			row.append((rp[i] - rm[i]) / (2.0 * steps[a]))
		jacob.append(row)
	return jacob


## 对尺度归一化的标准化残差雅可比做特征分解（等价 SVD 的奇异值）。
## 位置参数除以 POS_SCALE_M，速度参数除以 VEL_SCALE_MS；残差已按 σ 归一化。
## 有限差分：位置扰动 1m、速度扰动 0.01m/s，再乘尺度换算到归一化参数空间。
static func _observability(valid: Array, t_ref: float, x: Vector4, inlier: Array) -> Dictionary:
	var n: int = valid.size()
	var jac: Array = _scaled_jacobian(valid, t_ref, x, inlier)

	# A = JᵀJ（4x4 对称）
	var a_mat: Array = []
	for p in range(4):
		var row: Array = []
		for q in range(4):
			var s: float = 0.0
			for i in range(n):
				s += jac[p][i] * jac[q][i]
			row.append(s)
		a_mat.append(row)
	var eigs: Array = TmaLinalg.sym_eigenvalues(a_mat)
	var sv: Array = []
	for e in eigs:
		sv.append(sqrt(maxf(float(e), 0.0)))
	sv.sort()
	sv.reverse()
	var smax: float = float(sv[0])
	var smin: float = float(sv[3])
	var rank: int = 0
	for v in sv:
		if float(v) > smax * 1e-6:
			rank += 1
	var cond: float = INF if smin <= 1e-12 else smax / smin
	return {"rank": rank, "condition_number": cond, "singular_values": sv}


## 对称 4x4 特征值分解已迁至 TmaLinalg.sym_eigenvalues。


## 尺度归一化数值雅可比：∂u_i/∂(pE/POS_SCALE_M, pN/POS_SCALE_M, vE/VEL_SCALE_MS,
## vN/VEL_SCALE_MS)。返回 [param][meas]。
static func _scaled_jacobian(valid: Array, t_ref: float, x: Vector4, inlier: Array) -> Array:
	var n: int = valid.size()
	var h: Array = [1.0, 1.0, 0.01, 0.01]  # 米 / 米 / (米/秒) / (米/秒)
	var scales: Array = [POS_SCALE_M, POS_SCALE_M, VEL_SCALE_MS, VEL_SCALE_MS]
	var jac: Array = []
	for a in range(4):
		var xp := x
		var xm := x
		if a == 0:
			xp.x += h[a]
			xm.x -= h[a]
		elif a == 1:
			xp.y += h[a]
			xm.y -= h[a]
		elif a == 2:
			xp.z += h[a]
			xm.z -= h[a]
		else:
			xp.w += h[a]
			xm.w -= h[a]
		var rp: Array = _normalized_residuals(valid, t_ref, xp)
		var rm: Array = _normalized_residuals(valid, t_ref, xm)
		var row: Array = []
		for i in range(n):
			var val: float = 0.0
			if inlier[i]:
				val = (rp[i] - rm[i]) / (2.0 * h[a]) * scales[a]
			row.append(val)
		jac.append(row)
	return jac


## 法方程矩阵 A = JᵀJ（尺度归一化雅可比）。
static func _jacobian_normal_matrix(valid: Array, t_ref: float, x: Vector4, inlier: Array) -> Array:
	var jac: Array = _scaled_jacobian(valid, t_ref, x, inlier)
	var n: int = valid.size()
	var a_mat: Array = []
	for p in range(4):
		var row: Array = []
		for q in range(4):
			var s: float = 0.0
			for i in range(n):
				s += jac[p][i] * jac[q][i]
			row.append(s)
		a_mat.append(row)
	return a_mat


## 协方差 P ≈ (JᵀJ)⁻¹（尺度化空间）。返回 {p_e, p_n, v_e, v_n}（对角线，尺度化单位）。
## 奇异/条件数过大时返回空 Dictionary（不得制造虚假小协方差）。
static func _covariance(valid: Array, t_ref: float, x: Vector4, inlier: Array) -> Dictionary:
	var obs: Dictionary = _observability(valid, t_ref, x, inlier)
	if int(obs["rank"]) < 4 or float(obs["condition_number"]) > 1.0e4:
		return {}
	var a_mat: Array = _jacobian_normal_matrix(valid, t_ref, x, inlier)
	# 求逆：逐列解 A·col = e_i
	var inv: Array = []
	for c in range(4):
		var e := Vector4(
			1.0 if c == 0 else 0.0,
			1.0 if c == 1 else 0.0,
			1.0 if c == 2 else 0.0,
			1.0 if c == 3 else 0.0
		)
		var sol: Dictionary = TmaLinalg.solve_4x4(a_mat, e)
		if not sol["ok"]:
			return {}
		var col := sol["x"] as Vector4
		inv.append([col.x, col.y, col.z, col.w])
	var neg: bool = false
	for d in range(4):
		if float(inv[d][d]) <= 0.0:
			neg = true
	if neg:
		return {}
	# 完整 4x4 状态协方差（尺度归一化空间）：
	# P = [[P_EE, P_EN, ...], [P_EN, P_NN, ...], ...]
	# 位置子矩阵 P_position = [[inv[0][0], inv[0][1]], [inv[1][0], inv[1][1]]]
	return {
		"p_e": inv[0][0],
		"p_n": inv[1][1],
		"v_e": inv[2][2],
		"v_n": inv[3][3],
		"matrix": inv,
	}


# =====================================================================
#  本艇观测腿（legs）统计
# =====================================================================


## 由测量附带的连续本艇位置推算观测腿数：
## 累计基线法——从上一个航向样本点起累积位移向量，长度 ≥10m 才取一次航向样本
## （与采样间隔无关，1s 间隔低航速场景也能正确识别转向）；
## 航向样本间变化超过 15° 计一次转向；本艇几乎不动时 legs=1。
static func _count_legs(valid: Array) -> int:
	var headings: Array = []
	var anchor := Vector2(float(valid[0]["observer_e"]), float(valid[0]["observer_n"]))
	for i in range(1, valid.size()):
		var cur := Vector2(float(valid[i]["observer_e"]), float(valid[i]["observer_n"]))
		var d: Vector2 = cur - anchor
		if d.length() >= 10.0:
			headings.append(rad_to_deg(atan2(d.x, d.y)))
			anchor = cur
	if headings.size() < 2:
		return 1
	var legs: int = 1
	for i in range(1, headings.size()):
		if absf(NavUtils.angle_diff(headings[i], headings[i - 1])) > 15.0:
			legs += 1
	return legs


# =====================================================================
#  目标机动检测
# =====================================================================


## 目标机动检测：窗口后段若出现连续同方向、超门限的标准化残差游程，
## 说明旧匀速模型无法解释新的方位率 → 疑似目标机动。
## （残差符号在窗口内振荡是匀速拟合的正常妥协；连续同号游程才是机动特征。）
static func _detect_maneuver(valid: Array, t_ref: float, x: Vector4) -> bool:
	var us: Array = _normalized_residuals(valid, t_ref, x)
	var n: int = us.size()
	if n < 8:
		return false
	var from: int = int(n * 0.6)  # 只看窗口后 40%
	var run: int = 0
	var run_sign: float = 0.0
	for i in range(from, n):
		var u: float = float(us[i])
		if absf(u) > DEF_MANEUVER_U:
			var s: float = signf(u)
			if run > 0 and s == run_sign:
				run += 1
			else:
				run = 1
				run_sign = s
			if run >= DEF_MANEUVER_COUNT:
				return true
		else:
			run = 0
	return false


# =====================================================================
#  结果骨架 / 兼容旧 API
# =====================================================================


static func _empty_result() -> Dictionary:
	return {
		"status": "NO_DATA",
		"reference_time": 0.0,
		"best": {},
		"alternatives": [],
		"measurements_used": 0,
		"measurements_rejected": [],
		"residuals": [],
		"weighted_cost": INF,
		"angular_rmse": INF,
		"weighted_rmse": INF,
		"jacobian_rank": 0,
		"condition_number": INF,
		"singular_values": [],
		"covariance": {},
		"position_uncertainty_m": -1.0,
		"velocity_uncertainty_ms": -1.0,
		"maneuver_suspected": false,
		"mirror_resolved": true,
		"boundary_hit": false,
		"stale_seconds": 0.0,
		"legs": 0,
		"hypothesis_count": 0,
		"success": false,
		"diagnostics": {},
	}


# =====================================================================
#  旧 API 兼容入口（实现已拆至 tma_legacy_solver.gd）
# =====================================================================


## 单初值局部优化（向后兼容，内部转发 TmaLegacySolver）。
static func solve(measurements: Array, start: Dictionary = {}) -> Dictionary:
	return TmaLegacySolver.solve(measurements, start)


## 计算每个测量时刻的方位残差（度，已 wrap180）。供 Dot Stack / UI 使用。
static func residuals_at(
	measurements: Array, t0: float, p0_e: float, p0_n: float, v_e_ms: float, v_n_ms: float
) -> Array:
	var out: Array = []
	var x := Vector4(p0_e, p0_n, v_e_ms, v_n_ms)
	var r: Array = _residuals(measurements, t0, x)
	for i in range(measurements.size()):
		var sigma: float = maxf(float(measurements[i].get("sigma", 1.0)), 0.1)
		(
			out
			. append(
				{
					"time": float(measurements[i]["time"]),
					"residual_deg": r[i],
					"normalized": r[i] / sigma,
				}
			)
		)
	return out
