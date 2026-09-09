class_name TorpedoThreatEstimator
extends RefCounted
## torpedo_threat_estimator.gd — S109 §4 鱼雷位置自动解算（标量量测 EKF）。
##
## 状态 x = [east_m, north_m, vel_e, vel_n]；协方差 P 为完整 4x4 对称阵
## （Batch 3 修正：predict 施加 CV 转移 FPF'——位置-速度交叉块由它生成，
## 速度块才能从方位序列获得信息；早前版本 P_pv 恒零 → bearing-only 漂移）。
## 量测：被动方位（§4.2，观测时刻本艇位置 + bearing_sigma）/ 主动距离
## （§4.4）。标量量测 → 更新无需矩阵求逆。
##
## 单位纪律：方位 innov/雅可比/噪声一律弧度（旧版 deg·rad 混用把增益放大
## ~3000×，位置跳飞 3×10⁶ m）。
##
## 信息边界：
##   - 初始距离不可从 Truth 取得——沿 LOB 使用全威胁一致的先验
##     [range_prior_min_m, range_prior_max_m]（§4.2 通用认知）；
##   - 单次被动方位不可确定距离 → 协方差沿 LOB 保持大先验（AT-10，
##     "位置未收敛"）；只有多方位/主动测距后验才收敛；
##   - 无新证据时位置协方差随过程噪声扩大（AT-12），绝不缩小。
##
## 确定性：纯数学，无 RNG。

const RANGE_PRIOR_MIN_M: float = 500.0
const RANGE_PRIOR_MAX_M: float = 9000.0
## 位置收敛判据：95% 椭圆最大半轴 < CONVERGED_MAX_AXIS_M → 可显示估计点。
const CONVERGED_MAX_AXIS_M: float = 1500.0
## 过程噪声（CV 模型加速度扩散的保守对角近似）：每秒方差增量。
const Q_POS: float = 4.0  # m^2/s
## 速度过程/先验参数（§4.2 场景公开通用威胁速度认知，MC 统计口径定标，
## AT-11）：MC 扫参显示 Q_VEL 主导——大速度扩散（0.05）让 EKF 持续追逐
## "冻结相对几何"脊：方位残差完美但把本艇机动吸收成伪目标速度，协方差
## 塌缩到错误模态（覆盖率 0）。直航鱼雷口径 0.005 (m/s)^2/s 下覆盖率
## 0.93-0.97、平均位置误差 ~220m；高速/转弯威胁的滞后由主动测距融合
## 纠偏（AT-13/14），不靠放大过程噪声掩盖。实例变量供测试注入。
var q_vel_mps2_s: float = 0.005  # (m/s)^2/s 加速度扩散
var vel_prior_var_mps2: float = 100.0  # (m/s)^2，0±10 m/s
## 速度块方差地板。MC（AT-11）显示设高会重新激活"冻结相对几何"脊、
## 拉低覆盖率，故保持 0；过度收敛导致真实回波被伪 σ 误拒的问题，改由
## ThreatTrackManager.GATE_MIN_RANGE_SIGMA_M（距离门 σ 地板）在门控层干净
## 解决（AT-14/AT-15 兼得），不在估计器里放大不确定度掩盖。
var vel_floor_var: float = 0.0  # (m/s)^2，供测试扫参

var x: Array = [0.0, 0.0, 0.0, 0.0]  # [e, n, ve, vn]
## 4x4 对称协方差上三角（i<=j）。
var p11: float = 0.0
var p12: float = 0.0
var p13: float = 0.0
var p14: float = 0.0
var p22: float = 0.0
var p23: float = 0.0
var p24: float = 0.0
var p33: float = 0.0
var p34: float = 0.0
var p44: float = 0.0
var last_update_time: float = -1.0


## 初始化：沿 LOB 在先验中点放置，距离不确定度=先验全宽，横向=方位 sigma。
func init_from_bearing(
	brg_deg: float, sigma_deg: float, obs_e: float, obs_n: float, now: float
) -> void:
	var b: float = deg_to_rad(brg_deg)
	var r0: float = 0.5 * (RANGE_PRIOR_MIN_M + RANGE_PRIOR_MAX_M)
	x = [obs_e + sin(b) * r0, obs_n + cos(b) * r0, 0.0, 0.0]
	var r_span: float = 0.5 * (RANGE_PRIOR_MAX_M - RANGE_PRIOR_MIN_M)
	var r_var: float = (r_span * r_span) / 3.0
	var x_var: float = pow(deg_to_rad(sigma_deg) * r0, 2.0) / 3.0
	# LOB 方向单位向量 u=(sin b, cos b)；横向 v=(cos b, -sin b)。
	var ux: float = sin(b)
	var uy: float = cos(b)
	p11 = r_var * ux * ux + x_var * uy * uy
	p22 = r_var * uy * uy + x_var * ux * ux
	p12 = r_var * ux * uy - x_var * ux * uy
	p33 = vel_prior_var_mps2
	p44 = vel_prior_var_mps2
	p13 = 0.0
	p14 = 0.0
	p23 = 0.0
	p24 = 0.0
	p34 = 0.0
	last_update_time = now


## CV 传播：x += V dt；P = F P Fᵀ + Q（交叉块 P_xv 在此生成——方位信息
## 经它进入速度块，bearing-only 才能收敛）。
func predict(now: float) -> void:
	if last_update_time < 0.0:
		last_update_time = now
		return
	var dt: float = maxf(now - last_update_time, 0.0)
	if dt <= 0.0:
		return
	x[0] = float(x[0]) + float(x[2]) * dt
	x[1] = float(x[1]) + float(x[3]) * dt
	var np11: float = p11 + 2.0 * dt * p13 + dt * dt * p33 + Q_POS * dt
	var np22: float = p22 + 2.0 * dt * p24 + dt * dt * p44 + Q_POS * dt
	var np12: float = p12 + dt * (p14 + p23) + dt * dt * p34
	var np13: float = p13 + dt * p33
	var np14: float = p14 + dt * p34
	var np23: float = p23 + dt * p34
	var np24: float = p24 + dt * p44
	p11 = np11
	p22 = np22
	p12 = np12
	p13 = np13
	p14 = np14
	p23 = np23
	p24 = np24
	p33 += q_vel_mps2_s * dt
	p44 += q_vel_mps2_s * dt
	last_update_time = now


## 被动方位更新（§4.2）：z = atan2(de, dn) + v，全弧度口径。历史 LOB 起点
## 冻结在观测时刻——调用方传观测时刻的本艇位置快照。
## 迭代更新（IEKF/Gauss-Newton，3 轮）：正横穿越附近方位量测强非线性，
## 单次线性化产生系统性偏差（MC 覆盖率 0、均值位置误差发散）；迭代把
## 每帧更新拉回当前量测的 MAP，协方差用末轮线性化。
func bearing_update(brg_meas_deg: float, sigma_deg: float, obs_e: float, obs_n: float) -> void:
	var s_meas: float = maxf(pow(deg_to_rad(sigma_deg), 2.0), 1e-12)
	var xp: Array = x.duplicate()
	var xi: Array = xp
	for _it in range(3):
		var h_deg: float = _bearing_at(float(xi[0]), float(xi[1]), obs_e, obs_n)
		var hb: Array = _dh_at(float(xi[0]), float(xi[1]), obs_e, obs_n)
		var resid: float = deg_to_rad(NavUtils.wrap180(brg_meas_deg - NavUtils.wrap360(h_deg)))
		resid += hb[0] * (float(xp[0]) - float(xi[0])) + hb[1] * (float(xp[1]) - float(xi[1]))
		var ph: Array = _p_times(hb)
		var s: float = float(hb[0]) * float(ph[0]) + float(hb[1]) * float(ph[1]) + s_meas
		if s <= 0.0:
			return
		xi = [
			float(xp[0]) + float(ph[0]) * resid / s,
			float(xp[1]) + float(ph[1]) * resid / s,
			float(xp[2]) + float(ph[2]) * resid / s,
			float(xp[3]) + float(ph[3]) * resid / s,
		]
	x = xi
	# P_update = (I - K·H)·P_pred，用末轮（= 最终线性化点）的 K。
	var hb2: Array = _dh_at(float(x[0]), float(x[1]), obs_e, obs_n)
	var ph2: Array = _p_times(hb2)
	var s2: float = float(hb2[0]) * float(ph2[0]) + float(hb2[1]) * float(ph2[1]) + s_meas
	if s2 > 0.0:
		_subtract_outer(ph2, s2)


## 主动距离更新（§4.4）：z = dist + v。
func range_update(rng_m: float, sigma_m: float, obs_e: float, obs_n: float) -> void:
	var de: float = float(x[0]) - obs_e
	var dn: float = float(x[1]) - obs_n
	var d: float = maxf(sqrt(de * de + dn * dn), 1.0)
	var innov: float = rng_m - d
	var s_inv: float = 1.0 / maxf(sigma_m * sigma_m, 1.0)
	_scalar_update(innov, [de / d, dn / d], s_inv)


## 位置 95% 椭圆（半轴长米）。对角化 2x2 位置块。
func ellipse_95() -> Dictionary:
	var tr: float = p11 + p22
	var det: float = maxf(p11 * p22 - p12 * p12, 1e-6)
	var disc: float = sqrt(maxf(tr * tr * 0.25 - det, 0.0))
	var l1: float = tr * 0.5 + disc
	var l2: float = maxf(tr * 0.5 - disc, 1e-6)
	# 95% 缩放 ≈ sqrt(5.991) ≈ 2.448。
	var k: float = 2.448
	return {"axis_a_m": k * sqrt(l1), "axis_b_m": k * sqrt(l2)}


## 位置是否收敛（可显示单一估计点；§4.3 证据不足禁止伪精确位置）。
func converged() -> bool:
	var el: Dictionary = ellipse_95()
	return float(el["axis_a_m"]) < CONVERGED_MAX_AXIS_M


func position() -> Vector2:
	return Vector2(float(x[0]), float(x[1]))


func velocity() -> Vector2:
	return Vector2(float(x[2]), float(x[3]))


## 位置协方差二次型 h·P_pos·hᵀ（统计门控用，§4.4）。
func quad_pos(h: Array) -> float:
	var h0: float = float(h[0])
	var h1: float = float(h[1])
	return h0 * h0 * p11 + 2.0 * h0 * h1 * p12 + h1 * h1 * p22


## 方位量测雅可比行（rad/m）——门控计算公开入口。
func bearing_h_row(obs_e: float, obs_n: float) -> Array:
	return _dh_bearing(obs_e, obs_n)


func _h_bearing(obs_e: float, obs_n: float) -> float:
	return _bearing_at(float(x[0]), float(x[1]), obs_e, obs_n)


## 方位量测雅可比行 [dh/de, dh/dn]，单位 rad/m（与 rad^2 量测噪声一致）。
func _dh_bearing(obs_e: float, obs_n: float) -> Array:
	return _dh_at(float(x[0]), float(x[1]), obs_e, obs_n)


func _bearing_at(e: float, n: float, obs_e: float, obs_n: float) -> float:
	return NavUtils.wrap360(rad_to_deg(atan2(e - obs_e, n - obs_n)))


func _dh_at(e: float, n: float, obs_e: float, obs_n: float) -> Array:
	var de: float = e - obs_e
	var dn: float = n - obs_n
	var d2: float = maxf(de * de + dn * dn, 1.0)
	return [dn / d2, -de / d2]


## P·h（4 维；h 只作用位置分量，速度经由 P 交叉块受益）。
func _p_times(h: Array) -> Array:
	var h0: float = float(h[0])
	var h1: float = float(h[1])
	return [
		p11 * h0 + p12 * h1,
		p12 * h0 + p22 * h1,
		p13 * h0 + p23 * h1,
		p14 * h0 + p24 * h1,
	]


## P -= ph·phᵀ/s（K = ph/s 使外积对称闭合，全 10 个独立元素更新，
## 交叉块与速度块随之收缩——bearing-only 速度收敛的正确机制）。
func _subtract_outer(ph: Array, s: float) -> void:
	var q0: float = float(ph[0])
	var q1: float = float(ph[1])
	var q2: float = float(ph[2])
	var q3: float = float(ph[3])
	p11 -= q0 * q0 / s
	p12 -= q0 * q1 / s
	p13 -= q0 * q2 / s
	p14 -= q0 * q3 / s
	p22 -= q1 * q1 / s
	p23 -= q1 * q2 / s
	p24 -= q1 * q3 / s
	p33 = maxf(p33 - q2 * q2 / s, vel_floor_var)
	p34 -= q2 * q3 / s
	p44 = maxf(p44 - q3 * q3 / s, vel_floor_var)


## 标量量测 EKF 单次更新（主动距离等弱非线性量测用）。
func _scalar_update(innov: float, h: Array, s_inv: float) -> void:
	var ph: Array = _p_times(h)
	var s: float = float(h[0]) * float(ph[0]) + float(h[1]) * float(ph[1]) + 1.0 / s_inv
	if s <= 0.0:
		return
	x[0] = float(x[0]) + float(ph[0]) * innov / s
	x[1] = float(x[1]) + float(ph[1]) * innov / s
	x[2] = float(x[2]) + float(ph[2]) * innov / s
	x[3] = float(x[3]) + float(ph[3]) * innov / s
	_subtract_outer(ph, s)
