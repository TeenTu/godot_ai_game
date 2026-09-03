class_name DotStack
extends RefCounted
## dot_stack.gd — Dot Stack 方位残差显示数据。
##
## Dot Stack 显示各时间点的方位残差（拟合残差，不是"真实度百分比"）：
##   - 最上面的点对应最新 LOB
##   - 点位于中线 → 该时刻预测方位与测量方位一致（残差≈0）
##   - 左右偏移方向 → 残差正负
##   - 偏移距离与 |r_i| / σ_i 相关
##
## 即使所有点居中，也只能说明当前解符合观测，不能保证是唯一真实解。
## 本类只负责计算残差数据，渲染交给 UI 层。

var measurements: Array = []  # 解算输入（同 TmaSolver 的格式）
var residual_entries: Array = []  # [{time, raw_value, raw_unit, normalized, age_rank}]


## 基于一组测量 + 一个 TMA 解（参数）计算残差序列。
## 参数直接给目标状态：p0_e/p0_n/v_e_ms/v_n_ms/t0。
## residual_entries 按时间升序；age_rank=0 为最新。
func compute(
	meas: Array, p0_e: float, p0_n: float, v_e_ms: float, v_n_ms: float, t0: float
) -> void:
	measurements = meas
	var entries: Array = TmaSolver.residuals_at(meas, t0, p0_e, p0_n, v_e_ms, v_n_ms)
	# 排序并标注最新
	var sorted := entries.duplicate()
	sorted.sort_custom(func(a, b): return a["time"] < b["time"])
	var n: int = sorted.size()
	residual_entries.clear()
	for i in range(n):
		var e: Dictionary = sorted[i]
		e["age_rank"] = n - 1 - i  # 0=最新
		residual_entries.append(e)


## 最新一条残差（最上面那个点）。
func latest() -> Dictionary:
	if residual_entries.is_empty():
		return {}
	return residual_entries[residual_entries.size() - 1]


## 所有点是否都接近中线（|残差| < tol_deg，本类只收 bearing 残差）。
func all_centered(tol_deg: float = 0.5) -> bool:
	for e in residual_entries:
		if absf(float(e["raw_value"])) > tol_deg:
			return false
	return true


## 残差总量（RMS，度）。越小说明当前解越符合观测。
func rms_residual_deg() -> float:
	if residual_entries.is_empty():
		return 0.0
	var s: float = 0.0
	for e in residual_entries:
		s += float(e["raw_value"]) * float(e["raw_value"])
	return sqrt(s / float(residual_entries.size()))
