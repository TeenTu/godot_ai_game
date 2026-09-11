class_name PlayerTorpedoPlan
extends RefCounted
## player_torpedo_plan.gd — S1-11 §8.3 / D-01：玩家鱼雷计划（唯一发射方式）。
##
## 玩家侧只有一种发射方式：MAP_ROUTE（地图航线发射）。本结构是发射前冻结的
## 计划快照，绝不含 target_id / 真值实体 / 真实目标位置；System Solution 与
## 接触方位只能用于"预填建议航线"，不是发射许可或前置条件。

const DEPTH_AUTO := "AUTO"
const DEPTH_UPPER := "UPPER"
const DEPTH_LOWER := "LOWER"
const TRIGGER_MANUAL := "MANUAL"
const TRIGGER_ROUTE_DISTANCE := "ROUTE_DISTANCE"

var plan_id: String = ""
var created_time: float = 0.0
var route_points_world: Array = []  # Array[Vector2]
var initial_course_deg: float = 0.0
var depth_policy: String = DEPTH_AUTO
var active_trigger: String = TRIGGER_MANUAL
var active_trigger_distance_m: float = -1.0
var wire_guidance_enabled: bool = true
var safety_profile_id: String = "default"


## 由一条地图航线构造计划。首段方向决定出管初始航向；起点应为本艇实测位置。
static func from_route(plan_id_in: String, pts: Array, time_s: float) -> PlayerTorpedoPlan:
	var p := PlayerTorpedoPlan.new()
	p.plan_id = plan_id_in
	p.created_time = time_s
	p.route_points_world = pts.duplicate()
	if pts.size() >= 2 and pts[0] is Vector2 and pts[1] is Vector2:
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		p.initial_course_deg = NavUtils.wrap360(rad_to_deg(atan2(b.x - a.x, b.y - a.y)))
	return p


## 至少一个有效方向才可发射（AT-02/AT-04）。
func has_valid_route() -> bool:
	return route_points_world.size() >= 2


func set_route_distance_trigger(distance_m: float) -> void:
	active_trigger = TRIGGER_ROUTE_DISTANCE
	active_trigger_distance_m = distance_m


func to_dict() -> Dictionary:
	return {
		"plan_id": plan_id,
		"created_time": created_time,
		"route_points_world": route_points_world,
		"initial_course_deg": initial_course_deg,
		"depth_policy": depth_policy,
		"active_trigger": active_trigger,
		"active_trigger_distance_m": active_trigger_distance_m,
		"wire_guidance_enabled": wire_guidance_enabled,
		"safety_profile_id": safety_profile_id,
	}


## 信息边界（AT-35）：计划 DTO 禁止字段清单——静态扫描与运行期断言共用。
static func forbidden_keys() -> Array:
	return ["target_id", "truth_position", "true_course_deg", "true_depth_m"]
