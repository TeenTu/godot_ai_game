class_name TorpedoRouteState
extends RefCounted
## torpedo_route_state.gd — S1-11 §8.3 / D-01 / §4.2：鱼雷航路状态。
##
## 航路点是**空间位置命令**，不是目标绑定：本结构绝不含目标内部 ID、
## 真值实体引用或真实目标位置。单一发射方式（MAP_ROUTE）与"未锁定绝不转弯
## 搜索"都建立在这份纯几何航路上：
##   - 单段航线：首段方向 = 出管初始航向；到达终点后保持该段最后航向直行
##     （绝不解释成"开始蛇形搜索"）；
##   - 多段航线：按顺序追踪航路点，进入 waypoint_accept_radius_m 后切下一点；
##     航向变化始终受 max_turn_rate 限制，不能瞬间折线；
##   - 线导重画是**原子替换**剩余航路（从鱼雷当前已知位置起算，revision 递增）。

const MAX_FUTURE_POINTS: int = 4  # 起点之外最多 4 个未来航路点（§4.1）
const WAYPOINT_ACCEPT_RADIUS_M: float = 80.0
const SOURCE_PRELAUNCH := "PRELAUNCH"
const SOURCE_WIRE_UPDATE := "WIRE_UPDATE"
const SOURCE_FALLBACK := "FALLBACK"

var points: Array = []  # Array[Vector2]（世界 east/north），含起点
var current_index: int = 0
var route_progress_m: float = 0.0
var last_course_deg: float = 0.0
var source: String = SOURCE_PRELAUNCH
var revision: int = 0


## 原子替换整条航线（发射前或线导重画）。起点应为本艇/鱼雷当前已知位置。
## 返回是否接受（点集为空或超过上限则拒绝，不改动现状）。
func set_route(pts: Array, src: String = SOURCE_PRELAUNCH) -> bool:
	if pts.is_empty() or pts.size() > MAX_FUTURE_POINTS + 1:
		return false
	for p in pts:
		if not (p is Vector2):
			return false
	points = pts.duplicate()
	current_index = 1  # 起点本身不是目标；首个未来航路点即下标 1
	route_progress_m = 0.0
	source = src
	revision += 1
	if points.size() >= 2:
		last_course_deg = _course_between(points[0], points[1])
	return true


## 线导重画：从当前已知位置重建剩余航路（新点集首点即当前位置）。
func replace_from(pos: Vector2, future_pts: Array) -> bool:
	var pts: Array = [pos]
	for p in future_pts:
		pts.append(p)
	return set_route(pts, SOURCE_WIRE_UPDATE)


func has_route() -> bool:
	return not points.is_empty()


func target_point() -> Vector2:
	if current_index >= points.size():
		return Vector2.INF
	return points[current_index]


## 剩余未走完的航段点（含当前位置点，便于线导重画与显示）。
func remaining_points() -> Array:
	var from: int = maxi(current_index - 1, 0)
	if from >= points.size():
		return []
	return points.slice(from)


func total_length_m() -> float:
	var total: float = 0.0
	for i in range(1, points.size()):
		total += (points[i] as Vector2).distance_to(points[i - 1])
	return total


## 按当前朝向向目标点转向（受转向率限制），并推进航路进度。
## 返回 {course_deg, saturated, waypoint_reached, at_end}。
## 到达最后一个点后不再改变航向（保持最后航向直行，绝不蛇形）。
func steer(
	pos: Vector2, current_course_deg: float, speed_m_s: float, dt: float, max_turn_rate_deg_s: float
) -> Dictionary:
	if not has_route() or current_index >= points.size():
		route_progress_m += maxf(speed_m_s * dt, 0.0)
		return {
			"course_deg": last_course_deg,
			"saturated": false,
			"waypoint_reached": false,
			"at_end": true,
		}
	var reached: bool = false
	var wp: Vector2 = target_point()
	if pos.distance_to(wp) <= WAYPOINT_ACCEPT_RADIUS_M:
		reached = true
		current_index += 1
	var at_end: bool = current_index >= points.size()
	var desired: float = last_course_deg
	if not at_end:
		desired = _course_between(pos, target_point())
		var step: float = max_turn_rate_deg_s * dt
		var delta: float = NavUtils.wrap180(desired - current_course_deg)
		var saturated: bool = absf(delta) > step
		if saturated:
			desired = NavUtils.wrap360(current_course_deg + signf(delta) * step)
		last_course_deg = desired
		route_progress_m += maxf(speed_m_s * dt, 0.0)
		return {
			"course_deg": desired,
			"saturated": saturated,
			"waypoint_reached": reached,
			"at_end": false,
		}
	# 末段：保持最后航向直行。
	route_progress_m += maxf(speed_m_s * dt, 0.0)
	return {
		"course_deg": last_course_deg,
		"saturated": false,
		"waypoint_reached": reached,
		"at_end": true,
	}


## S1-11 §6.3：把世界点投影到折线上，返回沿折线的累计距离（m，钳制到 [0,总长]）。
static func project_along(points: Array, p: Vector2) -> float:
	if points.size() < 2:
		return 0.0
	var best: float = 0.0
	var best_d: float = INF
	var acc: float = 0.0
	for i in range(1, points.size()):
		var a: Vector2 = points[i - 1]
		var b: Vector2 = points[i]
		var seg: Vector2 = b - a
		var seg_len: float = seg.length()
		if seg_len < 0.001:
			continue
		var t: float = clampf((p - a).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
		var d: float = a.lerp(b, t).distance_to(p)
		if d < best_d:
			best_d = d
			best = acc + seg_len * t
		acc += seg_len
	return best


func _course_between(a: Vector2, b: Vector2) -> float:
	return NavUtils.wrap360(rad_to_deg(atan2(b.x - a.x, b.y - a.y)))
