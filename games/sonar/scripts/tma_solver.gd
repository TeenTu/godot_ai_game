class_name TmaSolver
extends RefCounted
## tma_solver.gd — TMA（纯方位运动分析）最小二乘解算器。
##
## 从一组带噪 LOB 测量估计目标匀速运动参数：
##   目标位置 p(t) = p0 + v·(t - t0)
##   参数向量 x = [p0_e, p0_n, v_e, v_n]
##
## 每个测量 i：本艇位置 o_i、测得方位 θ_hat_i、权重 w_i = 1/σ_i²。
## 残差：r_i = wrap180( atan2(p(t_i) - o_i) - θ_hat_i )
## 目标：min Σ w_i·r_i²
##
## 用带阻尼高斯-牛顿（Levenberg-Marquardt 式）迭代，数值雅可比，
## 纯函数、确定性、无状态可复现。支持多起点 → 找到近慢/远快等多个局部解。

const MAX_ITER: int = 60
const MIN_STEP: float = 1e-8
const COST_REL_TOL: float = 1e-9


## 一条解算输入的测量。用普通 Dictionary 即可：
##   { "time": float, "observer_e": float, "observer_n": float,
##     "bearing": float, "sigma": float }
## bearing 为从本艇看目标的方位（度，从北顺时针）。


## 解算目标状态。返回 Dictionary：
##   { "p0_e", "p0_n", "v_e_ms", "v_n_ms", "t0",
##     "course_deg", "speed_kn", "range_m", "bearing_deg",
##     "rms_residual_deg", "converged", "iterations", "success" }
## t0 取首条测量时间（解算的参考时刻）。
static func solve(measurements: Array, start: Dictionary = {}) -> Dictionary:
	if measurements.size() < 2:
		return _fail("need >=2 measurements")

	var t0: float = float(measurements[0]["time"])
	var n: int = measurements.size()

	# 初始猜测（若调用方未给，用简单的运动学估计）
	var x0 := Vector4(
		float(start.get("p0_e", 0.0)),
		float(start.get("p0_n", 0.0)),
		float(start.get("v_e_ms", 0.0)),
		float(start.get("v_n_ms", 0.0))
	)
	if not start.has("p0_e"):
		x0 = _initial_guess(measurements, t0)

	# 构建权重向量（预先算好）
	var w: Array = []
	for i in range(n):
		var sigma: float = maxf(float(measurements[i].get("sigma", 1.0)), 0.1)
		w.append(1.0 / (sigma * sigma))

	# 阻尼高斯-牛顿 + 回溯线搜索
	var x := x0
	var lam: float = 1e-3
	var prev_cost: float = _cost(measurements, t0, x, w)
	var converged: bool = false
	var iters: int = 0

	for iter in range(MAX_ITER):
		iters = iter + 1
		var r: Array = _residuals(measurements, t0, x)
		var jacob := _numerical_jacobian(measurements, t0, x)
		# 法方程 A = Jᵀ W J，b = Jᵀ W r
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

		# 阻尼：求解 (A + λ·diag(A)) δ = -b（δ 为下降方向）
		var solved: Dictionary = _solve_damped(mat, b, lam)
		if not solved["ok"]:
			break
		var delta := solved["delta"] as Vector4
		if delta.length() < 1e-12:
			converged = true
			break

		# 回溯线搜索：从 full step 开始，若不降则减半
		var step: float = 1.0
		var x_new := Vector4(x.x, x.y, x.z, x.w)
		var new_cost: float = INF
		var accepted: bool = false
		for _ls in range(20):
			x_new = Vector4(
				x.x + step * delta.x,
				x.y + step * delta.y,
				x.z + step * delta.z,
				x.w + step * delta.w,
			)
			new_cost = _cost(measurements, t0, x_new, w)
			if new_cost < prev_cost:
				accepted = true
				break
			step *= 0.5

		if accepted:
			var rel_improve: float = (prev_cost - new_cost) / maxf(prev_cost, 1e-12)
			x = x_new
			prev_cost = new_cost
			lam = maxf(lam * 0.3, 1e-8)
			if rel_improve < COST_REL_TOL and delta.length() * step < MIN_STEP:
				converged = true
				break
		else:
			# 无法下降：增大阻尼再试一次；若仍不行则停止
			lam = minf(lam * 10.0, 1e8)
			if lam >= 1e8:
				break

	if iters >= MAX_ITER:
		converged = true

	return _result(measurements, t0, x, w, prev_cost, converged, iters)


## 计算每个测量时刻的方位残差（度，已 wrap180）。
## 供 Dot Stack / UI 使用。
static func residuals_at(
	measurements: Array, t0: float, p0_e: float, p0_n: float, v_e_ms: float, v_n_ms: float
) -> Array:
	var out: Array = []
	var x := Vector4(p0_e, p0_n, v_e_ms, v_n_ms)
	var r: Array = _residuals(measurements, t0, x)
	for i in range(measurements.size()):
		var sigma: float = maxf(float(measurements[i].get("sigma", 1.0)), 0.1)
		out.append(
			{
				"time": float(measurements[i]["time"]),
				"residual_deg": r[i],
				"normalized": r[i] / sigma,
			}
		)
	return out


# ---------- 内部实现 ----------

static func _initial_guess(measurements: Array, _t0: float) -> Vector4:
	# 用首尾两测 LOB 求最接近交点作为位置初值；速度初值设 0（由迭代修正）。
	var m0: Dictionary = measurements[0]
	var ml: Dictionary = measurements[measurements.size() - 1]
	# 把"从本艇看目标"的方位转成方向向量（从北顺时针）
	var b0: float = deg_to_rad(m0["bearing"])
	var bl: float = deg_to_rad(ml["bearing"])
	# 本艇到目标的近似方向向量
	var d0 := Vector2(sin(b0), cos(b0))
	var dl := Vector2(sin(bl), cos(bl))
	var o0 := Vector2(float(m0["observer_e"]), float(m0["observer_n"]))
	var ol := Vector2(float(ml["observer_e"]), float(ml["observer_n"]))
	# 求两条 LOB 最近点，取其中点
	var near: Array = _closest_point_between_lines(o0, d0, ol, dl)
	var p: Vector2 = (near[0] + near[1]) * 0.5
	return Vector4(p.x, p.y, 0.0, 0.0)


## 两条射线（点+单位方向）最近点。返回 [pa, pb]。
static func _closest_point_between_lines(
	pa: Vector2, da: Vector2, pb: Vector2, db: Vector2
) -> Array:
	var r: Vector2 = pa - pb
	var a: float = da.dot(da)
	var e: float = db.dot(db)
	var f: float = db.dot(r)
	if a <= 1e-9 or e <= 1e-9:
		return [pa, pb]
	var c: float = da.dot(r)
	var b: float = da.dot(db)
	var denom: float = a * e - b * b
	var s: float = 0.0
	var t: float = 0.0
	if absf(denom) > 1e-9:
		s = (b * f - c * e) / denom
		t = (a * f - b * c) / denom
	return [pa + da * s, pb + db * t]


static func _residuals(measurements: Array, t0: float, x: Vector4) -> Array:
	var out: Array = []
	for m in measurements:
		var t: float = float(m["time"]) - t0
		var p := Vector2(x.x + x.z * t, x.y + x.w * t)
		var o := Vector2(float(m["observer_e"]), float(m["observer_n"]))
		var d: Vector2 = p - o
		var pred_bearing: float = rad_to_deg(atan2(d.x, d.y))  # 从北顺时针
		var meas_bearing: float = float(m["bearing"])
		out.append(NavUtils.wrap180(pred_bearing - meas_bearing))
	return out


## 数值雅可比：J[a][i] = ∂r_i / ∂x_a（a: 4 参数，i: 测量索引）。
static func _numerical_jacobian(measurements: Array, t0: float, x: Vector4) -> Array:
	var h: float = 1e-5
	var jacob: Array = []  # [param][meas]
	for a in range(4):
		var xp := x
		var xm := x
		if a == 0:
			xp.x += h
			xm.x -= h
		elif a == 1:
			xp.y += h
			xm.y -= h
		elif a == 2:
			xp.z += h
			xm.z -= h
		else:
			xp.w += h
			xm.w -= h
		var rp: Array = _residuals(measurements, t0, xp)
		var rm: Array = _residuals(measurements, t0, xm)
		var row: Array = []
		for i in range(measurements.size()):
			row.append((rp[i] - rm[i]) / (2.0 * h))
		jacob.append(row)
	return jacob


## 求解 (A + λ·diag(A)) δ = -b。
static func _solve_damped(mat: Array, b: Array, lam: float) -> Dictionary:
	var mat2: Array = []
	for a in range(4):
		var row: Array = []
		for c in range(4):
			row.append(mat[a][c])
		row[a] += lam * maxf(mat[a][a], 1e-6)  # 阻尼在 diag
		mat2.append(row)
	var rhs := Vector4(-b[0], -b[1], -b[2], -b[3])
	var sol: Dictionary = _solve_4x4(mat2, rhs)
	if not sol["ok"]:
		return {"ok": false}
	return {"ok": true, "delta": sol["x"]}


## 高斯消元解 4x4 线性方程组 mat·x = rhs（带部分主元）。
static func _solve_4x4(mat: Array, rhs: Vector4) -> Dictionary:
	# 构造 4x5 增广矩阵
	var a: Array = []
	for r in range(4):
		var row: Array = []
		for c in range(4):
			row.append(float(mat[r][c]))
		row.append([rhs.x, rhs.y, rhs.z, rhs.w][r])
		a.append(row)
	# 前向消元 + 回代（高斯-约当）
	for col in range(4):
		# 选主元
		var piv: int = col
		for r in range(col + 1, 4):
			if absf(a[r][col]) > absf(a[piv][col]):
				piv = r
		if absf(a[piv][col]) < 1e-12:
			return {"ok": false}
		var tmp: Array = a[col]
		a[col] = a[piv]
		a[piv] = tmp
		var piv_val: float = a[col][col]
		for r in range(4):
			if r == col:
				continue
			var factor: float = a[r][col] / piv_val
			for c in range(col, 5):
				a[r][c] -= factor * a[col][c]
	var x := Vector4(0, 0, 0, 0)
	for r in range(4):
		var v: float = a[r][4] / a[r][r]
		x.x = v if r == 0 else x.x
		x.y = v if r == 1 else x.y
		x.z = v if r == 2 else x.z
		x.w = v if r == 3 else x.w
	return {"ok": true, "x": x}


static func _cost(measurements: Array, t0: float, x: Vector4, w: Array) -> float:
	var r: Array = _residuals(measurements, t0, x)
	var c: float = 0.0
	for i in range(measurements.size()):
		c += w[i] * r[i] * r[i]
	return c


static func _result(
	measurements: Array, t0: float, x: Vector4, w: Array, cost: float, converged: bool, iters: int
) -> Dictionary:
	var v_e_ms: float = x.z
	var v_n_ms: float = x.w
	var course: float = NavUtils.wrap360(rad_to_deg(atan2(v_e_ms, v_n_ms)))
	var speed_ms: float = sqrt(v_e_ms * v_e_ms + v_n_ms * v_n_ms)
	var rms: float = sqrt(cost / maxf(float(measurements.size()), 1.0))
	# 参考时刻目标相对本艇的方位/距离（用最后一条测量时刻）
	var last: Dictionary = measurements[measurements.size() - 1]
	var tl: float = float(last["time"]) - t0
	var p_end := Vector2(x.x + x.z * tl, x.y + x.w * tl)
	var o_end := Vector2(float(last["observer_e"]), float(last["observer_n"]))
	var d: Vector2 = p_end - o_end
	var range_m: float = d.length()
	var bearing_deg: float = NavUtils.wrap360(rad_to_deg(atan2(d.x, d.y)))
	return {
		"p0_e": x.x,
		"p0_n": x.y,
		"v_e_ms": v_e_ms,
		"v_n_ms": v_n_ms,
		"t0": t0,
		"course_deg": course,
		"speed_kn": NavUtils.ms_to_kn(speed_ms),
		"range_m": range_m,
		"bearing_deg": bearing_deg,
		"rms_residual_deg": rms,
		"converged": converged,
		"iterations": iters,
		"success": true,
	}


static func _fail(msg: String) -> Dictionary:
	return {"success": false, "error": msg}
