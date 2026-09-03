class_name TruthEntity
extends RefCounted
## truth_entity.gd — Truth 层：后台真实平台状态与运动学更新。
##
## 属于"Truth"层级，正常游戏界面绝不直接读取它的实时位置用于显示，
## 只有仿真引擎（world）和调试"Show Truth"能接触它。
## 运动学严格遵循 DESIGN.md §1 的从北顺时针公式。

# 命令逼近的缺省速率（场景未配置 turn_rate/acceleration 时的兜底，配置化默认）
const DEFAULT_TURN_RATE_DEG_S: float = 1.5
const DEFAULT_ACCEL_KN_S: float = 0.25

var id: String = ""
var class_id: String = ""  # 船型/平台类型标识
var side: String = ""  # "blue"(友/自) / "red"(敌) / "neutral"
var platform_type: String = "submarine"

var position_east_m: float = 0.0
var position_north_m: float = 0.0
var depth_m: float = 0.0  # 向下为正

var course_deg: float = 0.0  # 实际艏向（从北顺时针）
var speed_kn: float = 0.0  # 实际航速
var turn_rate_deg_s: float = 0.0  # >0 顺时针（最大转向率，G-05/S1-02）
var acceleration_kn_s: float = 0.0  # 加/减速度限制

# S1-02 / G-05 命令值与实际值分离：UI/决策层只能通过 command_course/
# command_speed 下令，实际状态按转向率/加速度限制逼近。
# <0 表示无活动命令（保持当前航向直航；兼容未配速率的 AI 目标与旧测试）。
var commanded_course_deg: float = -1.0
var commanded_speed_kn: float = -1.0

var damage_state: String = "ok"

# 拖曳阵（批次2+ / S1-03）：own 平台可挂一条物理拖曳声学阵（可控长度状态机
# 与转向航向滞后）。为 null 表示本艇未配置拖曳硬件，此时 TOWED 不可用
# （OperatorSonar 禁用，不提供"跟艇+满可用"的虚构回退）。
var towed: TowedArray = null

# 一旦下达过命令，旧常率转向/常加速路径退役（S1-02：命令与旧 AI 机动互斥）
var _motion_commanded: bool = false


## 拖曳阵物理航向(deg, 从北顺时针)。未挂阵时返回本艇航向，但此时 TOWED
## 阵列本身不可用（towed==null）。
func get_array_heading_deg() -> float:
	if towed != null:
		return towed.array_heading_deg
	return course_deg


## 下令转向（S1-02）：只写命令值，实际艏向按最大转向率逼近。
func command_course(deg: float) -> void:
	commanded_course_deg = NavUtils.wrap360(deg)
	_motion_commanded = true


## 下令变速（S1-02）：只写命令值，实际航速按加/减速度限制逼近。
func command_speed(kn: float) -> void:
	commanded_speed_kn = clampf(kn, 0.0, 60.0)
	_motion_commanded = true


## 是否有未完成的转向命令（UI 显示 CMD→ACT 与预计稳定时间用）。
func has_course_command() -> bool:
	return (
		commanded_course_deg >= 0.0
		and absf(NavUtils.wrap180(commanded_course_deg - course_deg)) > 0.05
	)


## 是否有未完成的速度命令。
func has_speed_command() -> bool:
	return commanded_speed_kn >= 0.0 and absf(commanded_speed_kn - speed_kn) > 0.01


## 推进一个固定步长（dt 秒）。返回 true 表示平台仍存活。
func advance(dt: float) -> bool:
	if damage_state == "sunk":
		return false

	# ---- 转向（S1-02：实际艏向按最大转向率逼近命令艏向）----
	if commanded_course_deg >= 0.0:
		var err: float = NavUtils.wrap180(commanded_course_deg - course_deg)
		var rate: float = turn_rate_deg_s if turn_rate_deg_s > 0.0 else DEFAULT_TURN_RATE_DEG_S
		course_deg = NavUtils.wrap360(course_deg + clampf(err, -rate * dt, rate * dt))
		if absf(NavUtils.wrap180(commanded_course_deg - course_deg)) < 0.05:
			course_deg = NavUtils.wrap360(commanded_course_deg)
			commanded_course_deg = -1.0  # ON ORDERED COURSE：命令完成
	elif turn_rate_deg_s != 0.0 and not _motion_commanded:
		# 无命令时的旧常率转向（AI 巡航/旧测试兼容）
		course_deg = NavUtils.wrap360(course_deg + turn_rate_deg_s * dt)

	# ---- 变速（S1-02：实际航速按加/减速度限制逼近命令航速）----
	if commanded_speed_kn >= 0.0:
		var dv: float = commanded_speed_kn - speed_kn
		var a: float = acceleration_kn_s if acceleration_kn_s > 0.0 else DEFAULT_ACCEL_KN_S
		speed_kn = clampf(speed_kn + clampf(dv, -a * dt, a * dt), 0.0, 60.0)
		if absf(commanded_speed_kn - speed_kn) < 0.01:
			speed_kn = commanded_speed_kn
			commanded_speed_kn = -1.0
	elif acceleration_kn_s != 0.0 and not _motion_commanded:
		speed_kn = clampf(speed_kn + acceleration_kn_s * dt, 0.0, 60.0)

	# 平移
	var v_ms: float = NavUtils.kn_to_ms(speed_kn)
	var next: Dictionary = NavUtils.advance_pos(
		position_east_m, position_north_m, course_deg, v_ms, dt
	)
	position_east_m = next["x"]
	position_north_m = next["y"]

	# 推进拖曳阵（若存在）：缆长收放 + 阵航向随本艇转向滞后收敛
	# （S1-03：tau 必须与实际缆长和本艇实际航速相关 → 注入实际速度）。
	if towed != null:
		towed.step(dt, course_deg, v_ms)
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
	commanded_course_deg = float(d.get("commanded_course_deg", -1.0))
	commanded_speed_kn = float(d.get("commanded_speed_kn", -1.0))
	if commanded_course_deg >= 0.0 or commanded_speed_kn >= 0.0:
		_motion_commanded = true
