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
