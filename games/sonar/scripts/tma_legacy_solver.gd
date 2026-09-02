class_name TmaLegacySolver
extends RefCounted
## tma_legacy_solver.gd — 旧版单初值局部优化（保留兼容既有调用方/测试）。
##
## 从 tma_solver.gd 拆出：带阻尼高斯-牛顿（LM 式）+ 回溯线搜索，
## 单初值、无边界、无稳健损失。新代码请使用 TmaSolver.solve_auto()。
##
## 从一组带噪 LOB 测量估计目标匀速运动参数：
##   目标位置 p(t) = p0 + v·(t - t0)
##   参数向量 x = [p0_e, p0_n, v_e, v_n]
## 每个测量 i：本艇位置 o_i、测得方位 θ_hat_i、权重 w_i = 1/σ_i²。
## 残差：r_i = wrap180( atan2(p(t_i) - o_i) - θ_hat_i )
## 目标：min Σ w_i·r_i²

const MAX_ITER: int = 60
const MIN_STEP: float = 1e-8
const COST_REL_TOL: float = 1e-9


## 解算目标状态。返回 Dictionary：
##   { "p0_e", "p0_n", "v_e_ms", "v_n_ms", "t0",
##     "course_deg", "speed_kn", "range_m", "bearing_deg",
##     "rms_residual_deg", "converged", "iterations", "success" }
## t0 取首条测量时间（解算的参考时刻）。
static func solve(measurements: Array, start: Dictionary = {}) -> Dictionary:
	if measurements.size() < 2:
		return {"success": false, "error": "need >=2 measurements"}

	var t0: float = float(measurements[0]["time"])
	var n: int = measurements.size()

	var x0 := Vector4(
		float(start.get("p0_e", 0.0)),
		float(start.get("p0_n", 0.0)),
		float(start.get("v_e_ms", 0.0)),
		float(start.get("v_n_ms", 0.0))
	)
	if not start.has("p0_e"):
		x0 = _initial_guess(measurements, t0)

	var w: Array = []
	for i in range(n):
		var sigma: float = maxf(float(measurements[i].get("sigma", 1.0)), 0.1)
		w.append(1.0 / (sigma * sigma))

	var x := x0
	var lam: float = 1e-3
	var prev_cost: float = _cost(measurements, t0, x, w)
	var converged: bool = false
	var iters: int = 0

	for iter in range(MAX_ITER):
		iters = iter + 1
		var r: Array = _residuals(measurements, t0, x)
		var jacob := _numerical_jacobian(measurements, t0, x)
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
		if delta.length() < 1e-12:
			converged = true
			break

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
			lam = minf(lam * 10.0, 1e8)
			if lam >= 1e8:
				break

	if iters >= MAX_ITER:
		converged = true

	return _result(measurements, t0, x, w, prev_cost, converged, iters)


# ---------- 内部实现 ----------


static func _initial_guess(measurements: Array, _t0: float) -> Vector4:
	var m0: Dictionary = measurements[0]
	var ml: Dictionary = measurements[measurements.size() - 1]
	var b0: float = deg_to_rad(m0["bearing"])
	var bl: float = deg_to_rad(ml["bearing"])
	var d0 := Vector2(sin(b0), cos(b0))
	var dl := Vector2(sin(bl), cos(bl))
	var o0 := Vector2(float(m0["observer_e"]), float(m0["observer_n"]))
	var ol := Vector2(float(ml["observer_e"]), float(ml["observer_n"]))
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
		out.append(NavUtils.wrap180(pred_bearing - float(m["bearing"])))
	return out


## 数值雅可比：J[a][i] = ∂r_i / ∂x_a（度/单位）。
## 扰动步长按物理量纲取：位置 1m、速度 0.01m/s（过小扰动低于浮点精度）。
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
