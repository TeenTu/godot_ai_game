class_name FuzeController
extends RefCounted
## fuze_controller.gd — 引信/近炸/解保（S1-07 §10，Commit 10）。
##
## 与制导彻底分离（§10.1）：FuzeMode（CONTACT / ACOUSTIC_PROXIMITY /
## MAGNETIC_PROXIMITY 简化几何版）绝不进 Seeker TargetSelection；解保与
## active/autonomy enable 解耦（§10.2：warhead_arm_distance + min_time 双保险，
## SAFE 状态下即使几何贴近也绝不爆炸）。
##
## 物理结算边界（§10.3）：本类只做纯几何/状态判断（内核允许接触 Truth 几何）；
## 爆炸结算、伤害与声学证据由 World（仿真引擎）执行，普通 UI 只收净化后的
## EvidenceEvent（emission_sanitizer），绝不即时显示 CONFIRMED KILL（§10.4）。

const FUZE_CONTACT: String = "CONTACT"
const FUZE_ACOUSTIC_PROXIMITY: String = "ACOUSTIC_PROXIMITY"
const FUZE_MAGNETIC_PROXIMITY: String = "MAGNETIC_PROXIMITY"

# 触发半径（游戏性标定，可配置；不宣称现实参数）。
const TRIGGER_RADIUS_BY_MODE: Dictionary = {
	FUZE_CONTACT: 15.0,
	FUZE_ACOUSTIC_PROXIMITY: 40.0,
	FUZE_MAGNETIC_PROXIMITY: 25.0,
}
# 解保双保险之 min_time（§10.2）：出管后最短武装时间（s）。
const FUZE_MIN_ARM_TIME_S: float = 2.0
## 垂直触发门（P1-08）：鱼雷当前无垂向深度归向（只按深度带 hold 驱进），
## 引信在水平面 swept 判定外另设垂直容差（深度带粒度近似）。目标在另一
## 深度带（垂距 > 门限）时不触发——把深度层语义纳入引信，而不是把垂直
## 距离并进触发半径（否则跨带杀伤链全部失效；深度归向属后续制导项）。
const FUZE_VERTICAL_GATE_M: float = 25.0

var fuze_mode: String = FUZE_CONTACT
var arm_distance_m: float = 300.0


func configure(mode: String, arm_distance_m: float) -> void:
	self.fuze_mode = mode if TRIGGER_RADIUS_BY_MODE.has(mode) else FUZE_CONTACT
	self.arm_distance_m = maxf(arm_distance_m, 0.0)


func trigger_radius_m() -> float:
	return float(TRIGGER_RADIUS_BY_MODE.get(fuze_mode, 15.0))


## 是否已解保（§10.2：arm distance 与 min_time 双条件，缺一不可）。
func is_armed(traveled_m: float, since_launch_s: float) -> bool:
	if traveled_m < arm_distance_m:
		return false
	if since_launch_s < FUZE_MIN_ARM_TIME_S:
		return false
	return true


## 几何触发判定（内核边界；contacts 为 Truth 目标数组）。返回最近通过距离与
## 命中对象（Truth）；未触发返回 triggered=false。SAFE 状态绝不触发——由
## 调用方保证只在 ARMED 后调用（本类再查一次，双保险）。
func check_trigger(tp: RefCounted, contacts: Array) -> Dictionary:
	if tp.fuze_state != tp.FuzeState.ARMED:
		return {"triggered": false, "contact": null, "min_distance_m": INF}
	var radius: float = trigger_radius_m()
	var best: RefCounted = null
	var best_d: float = INF
	for c in contacts:
		var d: float = NavUtils.distance(
			tp.pos_east_m, tp.pos_north_m, float(c.position_east_m), float(c.position_north_m)
		)
		if d < best_d:
			best_d = d
			best = c
	if best != null and best_d <= radius:
		return {"triggered": true, "contact": best, "min_distance_m": best_d}
	return {"triggered": false, "contact": best, "min_distance_m": best_d}


## P1-08：swept closest approach——相对运动线段（含垂直深度分量）在 [0,1]
## 内距原点的最近距离。p0/p1 = 目标相对鱼雷的位置向量（t0/t1 两端点）。
## 高速鱼雷每 tick 位移可达 10-13m，逐点采样会在两采样点间穿越漏触发；
## 引信按连续最近通过判定。
static func swept_min_distance_m(p0: Vector3, p1: Vector3) -> float:
	var d := p1 - p0
	var dd: float = d.length_squared()
	if dd < 1e-9:
		return p0.length()
	var t: float = clampf(-p0.dot(d) / dd, 0.0, 1.0)
	return (p0 + d * t).length()


## P1-08：水平面 swept 最近通过（2D 线段距原点最近距离）。
static func swept_min_distance_h_m(p0: Vector2, p1: Vector2) -> float:
	var d := p1 - p0
	var dd: float = d.length_squared()
	if dd < 1e-9:
		return p0.length()
	var t: float = clampf(-p0.dot(d) / dd, 0.0, 1.0)
	return (p0 + d * t).length()


## P1-08：2D 线段最近点参数 t∈[0,1]（垂直分量插值用）。
static func swept_closest_t(p0: Vector2, p1: Vector2) -> float:
	var d := p1 - p0
	var dd: float = d.length_squared()
	if dd < 1e-9:
		return 0.0
	return clampf(-p0.dot(d) / dd, 0.0, 1.0)


## P1-08：连续碰撞触发判定。tp_now/tp_prev 为鱼雷本 tick/上 tick 位置
## （含深度）；prev_map: contact id → 上一 tick Vector3（缺失=首次出现，
## 退化为端点即当前点）。水平 swept 最近通过 ≤ radius 且 CPA 时刻垂直
## 距离 ≤ FUZE_VERTICAL_GATE_M 才触发；min_distance_m 为水平最近通过。
func check_trigger_swept(
	tp_now: Vector3, tp_prev: Vector3, contacts: Array, prev_map: Dictionary, radius: float
) -> Dictionary:
	var best: RefCounted = null
	var best_d: float = INF
	for c in contacts:
		if str(c.damage_state) == "sunk":
			continue
		var c_now := Vector3(float(c.position_east_m), float(c.position_north_m), float(c.depth_m))
		var c_prev: Vector3 = c_now
		if prev_map.has(str(c.id)):
			c_prev = prev_map[str(c.id)]
		var rel0 := Vector2(c_prev.x - tp_prev.x, c_prev.y - tp_prev.y)
		var rel1 := Vector2(c_now.x - tp_now.x, c_now.y - tp_now.y)
		var t: float = swept_closest_t(rel0, rel1)
		var horiz: float = swept_min_distance_h_m(rel0, rel1)
		if horiz > radius:
			continue
		var vert: float = absf(lerpf(c_prev.z - tp_prev.z, c_now.z - tp_now.z, t))
		if vert > FUZE_VERTICAL_GATE_M:
			continue
		if horiz < best_d:
			best_d = horiz
			best = c
	if best != null and best_d <= radius:
		return {"triggered": true, "contact": best, "min_distance_m": best_d}
	return {"triggered": false, "contact": best, "min_distance_m": best_d}
