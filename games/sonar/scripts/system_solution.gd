class_name SystemSolution
extends RefCounted
## system_solution.gd — 已提交火控解（System Solution）。
##
## 玩家点击 "Enter Solution" 后，由 TrialSolution 复制生成。
## 这是火控系统和武器唯一允许读取的"目标解"：
##   - 地图目标符号按 System Solution 推演
##   - 武器发射的初始目标点来自 System Solution
##   - 绝不读取目标 Truth
##
## 提交后，后续新 Measurement 不会自动修改它；
## 玩家必须重新调整 Trial 并再次 Enter Solution 才会更新。

var bearing_deg: float = 0.0
var range_m: float = 0.0
var course_deg: float = 0.0
var speed_kn: float = 0.0
var solution_time: float = 0.0  # 提交时刻（仿真时间）
var estimated_position_east_m: float = 0.0
var estimated_position_north_m: float = 0.0
var confidence: float = 0.0

## 该解已经过多少秒（用于"解随时间变旧"）。
var age: float = 0.0


## 推进解的年龄（供上层每秒调用）。
func update_age(dt: float) -> void:
	age += dt


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
		"age": age,
	}
