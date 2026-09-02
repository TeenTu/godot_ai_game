class_name TmaLinalg
extends RefCounted
## tma_linalg.gd — TMA 求解用的小型线性代数原语（纯函数、静态）。
##
## 从 tma_solver.gd 拆出，供 TmaSolver 与 TmaLegacySolver 共用：
##   - solve_4x4        高斯消元解 4x4 线性方程组（带部分主元）
##   - solve_damped     解 (A + λ·diag(A)) δ = -b（LM 阻尼方程）
##   - sym_eigenvalues  对称 4x4 Jacobi 特征值分解（用于雅可比 SVD 等价量）


## 求解 (A + λ·diag(A)) δ = -b。
static func solve_damped(mat: Array, b: Array, lam: float) -> Dictionary:
	var mat2: Array = []
	for a in range(4):
		var row: Array = []
		for c in range(4):
			row.append(mat[a][c])
		row[a] += lam * maxf(mat[a][a], 1e-6)
		mat2.append(row)
	var rhs := Vector4(-b[0], -b[1], -b[2], -b[3])
	var sol: Dictionary = solve_4x4(mat2, rhs)
	if not sol["ok"]:
		return {"ok": false}
	return {"ok": true, "delta": sol["x"]}


## 高斯消元解 4x4 线性方程组 mat·x = rhs（带部分主元）。
static func solve_4x4(mat: Array, rhs: Vector4) -> Dictionary:
	var a: Array = []
	for r in range(4):
		var row: Array = []
		for c in range(4):
			row.append(float(mat[r][c]))
		row.append([rhs.x, rhs.y, rhs.z, rhs.w][r])
		a.append(row)
	for col in range(4):
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


## 对称 4x4 矩阵 Jacobi 特征值分解，返回特征值数组（无序）。
static func sym_eigenvalues(a_in: Array) -> Array:
	var a: Array = []
	for r in range(4):
		var row: Array = []
		for c in range(4):
			row.append(float(a_in[r][c]))
		a.append(row)
	for sweep in range(60):
		# 找最大非对角元
		var p: int = 0
		var q: int = 1
		var off: float = 0.0
		for r in range(4):
			for c in range(r + 1, 4):
				if absf(a[r][c]) > off:
					off = absf(a[r][c])
					p = r
					q = c
		if off < 1e-14:
			break
		var app: float = a[p][p]
		var aqq: float = a[q][q]
		var apq: float = a[p][q]
		var theta: float = 0.5 * atan2(2.0 * apq, aqq - app)
		var cs: float = cos(theta)
		var sn: float = sin(theta)
		for k in range(4):
			var akp: float = a[k][p]
			var akq: float = a[k][q]
			a[k][p] = cs * akp - sn * akq
			a[k][q] = sn * akp + cs * akq
		for k in range(4):
			var apk: float = a[p][k]
			var aqk: float = a[q][k]
			a[p][k] = cs * apk - sn * aqk
			a[q][k] = sn * apk + cs * aqk
	var out: Array = []
	for r in range(4):
		out.append(a[r][r])
	return out
