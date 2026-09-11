class_name ActivePositionObs
extends RefCounted
## active_position_obs.gd — S1-11 §3.6 / AT-55 + PG-04：主动观测的位置/运动分档。
##
## PG-04 规则（"单次定位与完整 TMA 分离"）：
##   - 单次 bearing+range 观测只输出 POSITION_ONLY：位置有效、航速航向未知。
##     不得用"证据不足 4 条"拦截位置输出（4 条方位证据同样不等于好解）。
##   - 多个不同观测时刻且几何可观测后，才输出 MOTION_ESTIMATE（含完整误差）。
##   - 位置误差用**完整观测协方差**，不做强制对角化：
##       p = (o_e + r·sin b, o_n + r·cos b)
##       J = [[sin b, r·cos b], [cos b, −r·sin b]]
##       P_pos = J · diag(σ_r², σ_b²) · Jᵀ + P_observer + σ_bias²·I
##     其中 P_observer 来自本艇导航位置不确定度，σ_bias 是"统一参考时刻"的运动
##     近似偏差（Measurement.motion_bias_m）——基准混用的误差显式入协方差，
##     不伪装成高精度。
##   - 角误差大（σ_b > SECTOR_SIGMA_DEG）时输出极坐标扇区描述（is_sector），
##     不允许把大角误差画成"看起来很准"的小椭圆。
##   - 二维 bearing+range 只收缩水平位置误差，不生成深度（§7.2）。
##   - 只消费 Measurement，无真值实体、无目标内部 ID。

## 运动估计所需的最小独立历元数与时间跨度。
const MIN_EPOCHS_FOR_MOTION := 3
const MIN_TIME_SPAN_S := 20.0
## 方位不确定度超过该值 → 位置用极坐标扇区表达（不画伪精确小椭圆）。
const SECTOR_SIGMA_DEG := 3.0
## 本艇导航位置 1σ 缺省（m）；Measurement.observer_pos_sigma_m 可覆盖。
const DEFAULT_OBSERVER_POS_SIGMA_M := 40.0
## 失联后位置误差增长速率（m/s，1σ）——预测误差随失联时间增长。
const PROCESS_SIGMA_M_PER_S := 15.0

const KIND_NONE: int = 0
const KIND_POSITION_ONLY: int = 1
const KIND_MOTION_ESTIMATE: int = 2
const KIND_NAMES: Array = ["NONE", "POSITION_ONLY", "MOTION_ESTIMATE"]


static func kind_name(k: int) -> String:
	return KIND_NAMES[clampi(k, 0, KIND_NAMES.size() - 1)]


## 单次观测（一条 bearing+range Measurement）的位置与误差描述。
## 返回 {valid, east_m, north_m, cov, major_m, minor_m, angle_deg, is_sector, ...}。
static func observation_of(m: Measurement) -> Dictionary:
	if m == null or not m.has_range():
		return {"valid": false}
	var station: Dictionary = m.reference_station()
	var cov: Array = position_covariance(m)
	var el: Dictionary = ellipse_of_cov(cov)
	return {
		"valid": true,
		"east_m":
		float(station["east_m"]) + m.measured_range_m * sin(deg_to_rad(m.measured_bearing_deg)),
		"north_m":
		float(station["north_m"]) + m.measured_range_m * cos(deg_to_rad(m.measured_bearing_deg)),
		"cov": cov,
		"major_m": float(el["major_m"]),
		"minor_m": float(el["minor_m"]),
		"angle_deg": float(el["angle_deg"]),
		"is_sector": m.bearing_sigma_deg > SECTOR_SIGMA_DEG,
		"bearing_deg": m.measured_bearing_deg,
		"bearing_sigma_deg": m.bearing_sigma_deg,
		"range_m": m.measured_range_m,
		"range_sigma_m": m.range_sigma_m,
		"observer_east_m": float(station["east_m"]),
		"observer_north_m": float(station["north_m"]),
		"reference_time_s": float(station["time_s"]),
		"motion_bias_m": m.motion_bias_m,
	}


## 完整观测协方差（2×2，东/北 m²）：J·diag(σ_r², σ_b²)·Jᵀ + P_observer + σ_bias²I。
static func position_covariance(m: Measurement) -> Array:
	var r: float = maxf(m.measured_range_m, 0.0)
	var s_r: float = maxf(m.range_sigma_m, 1.0)
	var s_b: float = deg_to_rad(maxf(m.bearing_sigma_deg, 0.05))
	var b: float = deg_to_rad(m.measured_bearing_deg)
	var sin_b: float = sin(b)
	var cos_b: float = cos(b)
	# J 第 1 列 = ∂p/∂r，第 2 列 = ∂p/∂b（PG-04 给定形式）。
	var p11: float = s_r * s_r * sin_b * sin_b + (r * r * s_b * s_b) * cos_b * cos_b
	var p12: float = (s_r * s_r - r * r * s_b * s_b) * sin_b * cos_b
	var p22: float = s_r * s_r * cos_b * cos_b + (r * r * s_b * s_b) * sin_b * sin_b
	var s_o: float = m.observer_pos_sigma_m
	if s_o <= 0.0:
		s_o = DEFAULT_OBSERVER_POS_SIGMA_M
	var extra: float = s_o * s_o + m.motion_bias_m * m.motion_bias_m
	return [[p11 + extra, p12], [p12, p22 + extra]]


## 对称 2×2 协方差 → 1σ 椭圆（半长/半短/朝向）。朝向以 +东轴为 0°。
static func ellipse_of_cov(cov: Array) -> Dictionary:
	var a: float = float(cov[0][0])
	var b: float = float(cov[0][1])
	var c: float = float(cov[1][1])
	var tr: float = a + c
	var det: float = a * c - b * b
	var disc: float = maxf(tr * tr - 4.0 * det, 0.0)
	var l1: float = 0.5 * (tr + sqrt(disc))
	var l2: float = 0.5 * (tr - sqrt(disc))
	return {
		"major_m": sqrt(maxf(l1, 0.0)),
		"minor_m": sqrt(maxf(l2, 0.0)),
		"angle_deg": 0.5 * rad_to_deg(atan2(2.0 * b, a - c)),
	}


## 评估一条 Track 的主动位置观测档位（PG-04：POSITION_ONLY / MOTION_ESTIMATE）。
## 返回 {has_position, has_motion, kind, kind_name, epochs, time, east_m, north_m,
##       sigma_m, cov, major_m, minor_m, angle_deg, is_sector, span_s, age_s}；
##       无测距证据 → {has_position:false, has_motion:false, epochs:0, kind:0}。
static func evaluate(track: Track, now_s: float = 0.0) -> Dictionary:
	var ranged: Array = _ranged_epochs(track)
	if ranged.is_empty():
		return {
			"has_position": false,
			"has_motion": false,
			"kind": KIND_NONE,
			"kind_name": kind_name(KIND_NONE),
			"epochs": 0,
		}
	ranged.sort_custom(
		func(a: Measurement, b: Measurement) -> bool:
			return float(a.reference_station()["time_s"]) < float(b.reference_station()["time_s"])
	)
	var first: Measurement = ranged[0]
	var last: Measurement = ranged[ranged.size() - 1]
	var obs: Dictionary = observation_of(last)
	var t_last: float = float(obs["reference_time_s"])
	var out: Dictionary = {
		"has_position": true,
		"has_motion": false,
		"kind": KIND_POSITION_ONLY,
		"kind_name": kind_name(KIND_POSITION_ONLY),
		"epochs": ranged.size(),
		"time": t_last,
		"east_m": float(obs["east_m"]),
		"north_m": float(obs["north_m"]),
		"sigma_m": float(obs["major_m"]),
		"cov": obs["cov"],
		"major_m": float(obs["major_m"]),
		"minor_m": float(obs["minor_m"]),
		"angle_deg": float(obs["angle_deg"]),
		"is_sector": bool(obs["is_sector"]),
		"bearing_deg": float(obs["bearing_deg"]),
		"bearing_sigma_deg": float(obs["bearing_sigma_deg"]),
		"range_m": float(obs["range_m"]),
		"range_sigma_m": float(obs["range_sigma_m"]),
		"observer_east_m": float(obs["observer_east_m"]),
		"observer_north_m": float(obs["observer_north_m"]),
		"span_s": t_last - float(first.reference_station()["time_s"]),
		"age_s": maxf(now_s - t_last, 0.0),
	}
	if ranged.size() < MIN_EPOCHS_FOR_MOTION or float(out["span_s"]) < MIN_TIME_SPAN_S:
		return out
	var fit: Dictionary = _least_squares_velocity(ranged)
	if bool(fit.get("ok", false)):
		out["has_motion"] = true
		out["kind"] = KIND_MOTION_ESTIMATE
		out["kind_name"] = kind_name(KIND_MOTION_ESTIMATE)
		out["course_deg"] = float(fit["course_deg"])
		out["speed_kn"] = float(fit["speed_kn"])
	return out


## PG-04：把观测档位外推到 now_s。预测误差随失联时间增长；没有速度估计时只能
## 显示"最近估计位置"（不允许把历史点冒充实时精确位置）。
static func snapshot_at(obs: Dictionary, now_s: float) -> Dictionary:
	if not bool(obs.get("has_position", false)):
		return {"valid": false, "kind_name": kind_name(KIND_NONE)}
	var age: float = maxf(now_s - float(obs.get("time", now_s)), 0.0)
	var grow: float = PROCESS_SIGMA_M_PER_S * age
	var var0: float = float(obs.get("sigma_m", 0.0))
	var sigma: float = sqrt(var0 * var0 + grow * grow)
	var e: float = float(obs["east_m"])
	var n: float = float(obs["north_m"])
	var has_motion: bool = bool(obs.get("has_motion", false))
	if has_motion:
		var v_ms: float = NavUtils.kn_to_ms(float(obs["speed_kn"]))
		var c: float = deg_to_rad(float(obs["course_deg"]))
		e += v_ms * sin(c) * age
		n += v_ms * cos(c) * age
	return {
		"valid": true,
		"has_motion": has_motion,
		"kind": int(obs.get("kind", KIND_POSITION_ONLY)),
		"kind_name": str(obs.get("kind_name", kind_name(KIND_POSITION_ONLY))),
		"east_m": e,
		"north_m": n,
		"sigma_m": sigma,
		"observation_time_s": float(obs.get("time", now_s)),
		"age_s": age,
		"is_sector": bool(obs.get("is_sector", false)),
		"predicted": has_motion and age > 1.0,
		# 无运动估计 → 只能声称"最近估计位置"（不是实时精确位置）。
		"label_key": "est_predicted" if has_motion else "est_last_known",
	}


static func _ranged_epochs(track: Track) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	if track == null:
		return out
	for m in track.measurement_history:
		if not (m is Measurement) or not m.detected or not m.has_range():
			continue
		var key: String = m.evidence_id if m.evidence_id != "" else "obj_%d" % m.measurement_id
		if seen.has(key):
			continue
		seen[key] = true
		out.append(m)
	return out


## 三个以上历元的最小二乘常速拟合（对 east/north 各做一元线性回归）。
static func _least_squares_velocity(ranged: Array) -> Dictionary:
	var n: int = ranged.size()
	var t0: float = float((ranged[0] as Measurement).reference_station()["time_s"])
	var st: float = 0.0
	var stt: float = 0.0
	var se: float = 0.0
	var sn: float = 0.0
	var ste: float = 0.0
	var stn: float = 0.0
	for m in ranged:
		var mm: Measurement = m
		var dt: float = float(mm.reference_station()["time_s"]) - t0
		var p: Vector2 = _obs_position(mm)
		st += dt
		stt += dt * dt
		se += p.x
		sn += p.y
		ste += dt * p.x
		stn += dt * p.y
	var denom: float = n * stt - st * st
	if absf(denom) < 1e-9:
		return {"ok": false}
	var ve: float = (n * ste - st * se) / denom  # m/s
	var vn: float = (n * stn - st * sn) / denom
	var speed_ms: float = sqrt(ve * ve + vn * vn)
	var course: float = NavUtils.wrap360(rad_to_deg(atan2(ve, vn)))
	return {"ok": true, "course_deg": course, "speed_kn": speed_ms * 1.94384, "ve": ve, "vn": vn}


static func _obs_position(m: Measurement) -> Vector2:
	var brg: float = deg_to_rad(m.measured_bearing_deg)
	var station: Dictionary = m.reference_station()
	return Vector2(
		float(station["east_m"]) + m.measured_range_m * sin(brg),
		float(station["north_m"]) + m.measured_range_m * cos(brg)
	)
