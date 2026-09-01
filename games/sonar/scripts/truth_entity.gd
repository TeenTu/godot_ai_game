class_name TruthEntity
extends RefCounted
## truth_entity.gd — Truth 层：后台真实平台状态与运动学更新。
##
## 属于"Truth"层级，正常游戏界面绝不直接读取它的实时位置用于显示，
## 只有仿真引擎（world）和调试"Show Truth"能接触它。
## 运动学严格遵循 DESIGN.md §1 的从北顺时针公式。

var id: String = ""
var class_id: String = ""  # 船型/平台类型标识
var side: String = ""  # "blue"(友/自) / "red"(敌) / "neutral"
var platform_type: String = "submarine"

var position_east_m: float = 0.0
var position_north_m: float = 0.0
var depth_m: float = 0.0  # 向下为正

var course_deg: float = 0.0  # 从北顺时针
var speed_kn: float = 0.0
var turn_rate_deg_s: float = 0.0  # >0 顺时针
var acceleration_kn_s: float = 0.0

var damage_state: String = "ok"


## 推进一个固定步长（dt 秒）。返回 true 表示平台仍存活。
func advance(dt: float) -> bool:
	if damage_state == "sunk":
		return false

	# 变速
	if acceleration_kn_s != 0.0:
		speed_kn = clampf(speed_kn + acceleration_kn_s * dt, 0.0, 60.0)

	# 转向（改变航向）
	if turn_rate_deg_s != 0.0:
		course_deg = NavUtils.wrap360(course_deg + turn_rate_deg_s * dt)

	# 平移
	var v_ms: float = NavUtils.kn_to_ms(speed_kn)
	var next: Dictionary = NavUtils.advance_pos(
		position_east_m, position_north_m, course_deg, v_ms, dt
	)
	position_east_m = next["x"]
	position_north_m = next["y"]
	return true


## 从 JSON 字典加载初始状态。
func from_dict(d: Dictionary) -> void:
	id = str(d.get("id", id))
	class_id = str(d.get("class_id", class_id))
	side = str(d.get("side", side))
	platform_type = str(d.get("platform_type", platform_type))
	position_east_m = float(d.get("position_east_m", 0.0))
	position_north_m = float(d.get("position_north_m", 0.0))
	depth_m = float(d.get("depth_m", 0.0))
	course_deg = NavUtils.wrap360(float(d.get("course_deg", 0.0)))
	speed_kn = float(d.get("speed_kn", 0.0))
	turn_rate_deg_s = float(d.get("turn_rate_deg_s", 0.0))
	acceleration_kn_s = float(d.get("acceleration_kn_s", 0.0))
	damage_state = str(d.get("damage_state", "ok"))
