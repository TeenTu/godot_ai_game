class_name ActivePositionObs
extends RefCounted
## active_position_obs.gd — S1-11 §3.6 / AT-55：主动测距的位置观测与运动估计分档。
##
## 规则：
##   - 单次主动 bearing+range 只给"位置观测 + 误差区"，绝不显示航向/速度
##     （一次回波不能唯一解出运动）；
##   - 至少三个不同历元并满足几何/时间跨度条件后，才给出运动估计；
##   - 二维 bearing+range 只收缩水平位置误差，不生成深度（§7.2）；
##   - 只消费 Measurement，无真值实体或目标内部 ID。

## 运动估计所需的最小独立历元数与时间跨度。
const MIN_EPOCHS_FOR_MOTION := 3
const MIN_TIME_SPAN_S := 20.0


## 评估一条 Track 的主动位置观测档位。
## 返回 {has_position, epochs, time, east_m, north_m, sigma_m,
##       has_motion, course_deg, speed_kn, span_s}。
static func evaluate(track: Track, _now_s: float = 0.0) -> Dictionary:
	var ranged: Array = _ranged_epochs(track)
	if ranged.is_empty():
		return {"has_position": false, "has_motion": false, "epochs": 0}
	ranged.sort_custom(
		func(a: Measurement, b: Measurement) -> bool: return a.timestamp < b.timestamp
	)
	var last: Measurement = ranged[ranged.size() - 1]
	var pos: Vector2 = _obs_position(last)
	var out: Dictionary = {
		"has_position": true,
		"has_motion": false,
		"epochs": ranged.size(),
		"time": last.timestamp,
		"east_m": pos.x,
		"north_m": pos.y,
		"sigma_m": _obs_sigma(last),
	}
	var span: float = float(last.timestamp) - float((ranged[0] as Measurement).timestamp)
	out["span_s"] = span
	if ranged.size() >= MIN_EPOCHS_FOR_MOTION and span >= MIN_TIME_SPAN_S:
		var fit: Dictionary = _least_squares_velocity(ranged)
		if bool(fit.get("ok", false)):
			out["has_motion"] = true
			out["course_deg"] = float(fit["course_deg"])
			out["speed_kn"] = float(fit["speed_kn"])
	return out


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


## 单次 bearing+range 的位置观测（绝对平面坐标，米）。
static func _obs_position(m: Measurement) -> Vector2:
	var brg: float = deg_to_rad(m.measured_bearing_deg)
	return Vector2(
		m.observer_east_m + m.measured_range_m * sin(brg),
		m.observer_north_m + m.measured_range_m * cos(brg)
	)


## 位置误差：横向 = range·σθ，径向 = σR，取各向独立合成。
static func _obs_sigma(m: Measurement) -> float:
	var theta_rad: float = deg_to_rad(m.bearing_sigma_deg)
	var lateral: float = m.measured_range_m * theta_rad
	return sqrt(lateral * lateral + m.range_sigma_m * m.range_sigma_m)


## 三个以上历元的最小二乘常速拟合（对 east/north 各做一元线性回归）。
static func _least_squares_velocity(ranged: Array) -> Dictionary:
	var n: int = ranged.size()
	var t0: float = float((ranged[0] as Measurement).timestamp)
	var st: float = 0.0
	var stt: float = 0.0
	var se: float = 0.0
	var sn: float = 0.0
	var ste: float = 0.0
	var stn: float = 0.0
	for m in ranged:
		var mm: Measurement = m
		var dt: float = float(mm.timestamp) - t0
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
