class_name TrialSolution
extends RefCounted
## trial_solution.gd — 玩家试算解（Trial Solution）。
##
## 玩家正在调整的目标运动假设。是"可编辑"层：
##   - 玩家可以拖动 TMA 尺、调整航向/航速/距离/方位
##   - 可以输入 Bearing/Range/Course/Speed
##   - 可以锁定已知参数
##   - 后续新 Measurement 不会自动修改它（除非玩家重新拟合）
##
## 与 SystemSolution 的区别：Trial 是玩家手头的假设，未提交；
## 点击 Enter Solution 后复制为 System Solution 才交给火控/武器。

var bearing_deg: float = 0.0
var range_m: float = 0.0
var course_deg: float = 0.0
var speed_kn: float = 0.0
var solution_time: float = 0.0  # 该解对应的仿真时间
var estimated_position_east_m: float = 0.0
var estimated_position_north_m: float = 0.0
var confidence: float = 0.0  # 0..1 玩家/系统对解的置信（分类/拟合相关，非真实度）

# 锁定标志：锁定的参数不被重新拟合覆盖
var lock_bearing: bool = false
var lock_range: bool = false
var lock_course: bool = false
var lock_speed: bool = false


## 由 TMA 解算结果填充。
func from_solver(r: Dictionary) -> void:
	bearing_deg = float(r.get("bearing_deg", 0.0))
	range_m = float(r.get("range_m", 0.0))
	course_deg = float(r.get("course_deg", 0.0))
	speed_kn = float(r.get("speed_kn", 0.0))
	solution_time = float(r.get("t0", 0.0))
	# 估算位置：用参考时刻 + 目标速度推算
	var t0: float = float(r.get("t0", 0.0))
	var p0_e: float = float(r.get("p0_e", 0.0))
	var p0_n: float = float(r.get("p0_n", 0.0))
	var v_e: float = float(r.get("v_e_ms", 0.0))
	var v_n: float = float(r.get("v_n_ms", 0.0))
	var dt: float = solution_time - t0
	estimated_position_east_m = p0_e + v_e * dt
	estimated_position_north_m = p0_n + v_n * dt


func set_bearing(v: float) -> void:
	if not lock_bearing:
		bearing_deg = NavUtils.wrap360(v)


func set_range(v: float) -> void:
	if not lock_range:
		range_m = maxf(v, 0.0)


func set_course(v: float) -> void:
	if not lock_course:
		course_deg = NavUtils.wrap360(v)


func set_speed(v: float) -> void:
	if not lock_speed:
		speed_kn = maxf(v, 0.0)


## 复制为 System Solution（提交火控解）。
func commit(solution_time: float) -> SystemSolution:
	var sys := SystemSolution.new()
	sys.bearing_deg = bearing_deg
	sys.range_m = range_m
	sys.course_deg = course_deg
	sys.speed_kn = speed_kn
	sys.solution_time = solution_time
	sys.estimated_position_east_m = estimated_position_east_m
	sys.estimated_position_north_m = estimated_position_north_m
	sys.confidence = confidence
	return sys


func to_dict() -> Dictionary:
	return {
		"bearing_deg": bearing_deg,
		"range_m": range_m,
		"course_deg": course_deg,
		"speed_kn": speed_kn,
		"solution_time": solution_time,
		"east_m": estimated_position_east_m,
		"north_m": estimated_position_north_m,
		"confidence": confidence,
		"locks":
		{
			"bearing": lock_bearing,
			"range": lock_range,
			"course": lock_course,
			"speed": lock_speed,
		},
	}
