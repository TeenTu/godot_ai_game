class_name FireExecutor
extends RefCounted
## fire_executor.gd — REQ-0908 Batch 1：发射执行与联锁（REQ-B1-04）。
##
## main_ui 只传"模式 + 选中 Contact"，判定与发射都在此控制器：
##   - SOLUTION：只读选中 Contact 自己的解（fcc 门：其他 Track/stale/超龄拒绝）；
##   - BEARING_ONLY：只用选中 Contact 的最新测量方位（无距离/无提前量）；
##   - MANUAL：玩家显式航向，不读任何解。
## 返回 {ok, tp, mode, reason}；ok=false 表示被联锁拒绝。

var fcc: FireControlContext = null
var tracker: Tracker = null


func execute(ws: WeaponSystem, world: World, mode: String, selected_id: String) -> Dictionary:
	var out: Dictionary = {"ok": false, "tp": null, "mode": mode, "reason": ""}
	var own: RefCounted = world.world["own"]
	if mode == "SOLUTION":
		var gate: Dictionary = fcc.solution_for_fire(selected_id, world.sim_time)
		if not bool(gate.get("ok", false)):
			out["reason"] = str(gate.get("reason", "?"))
			return out
		out["tp"] = (
			ws
			. fire(
				gate["solution"],
				float(own.position_east_m),
				float(own.position_north_m),
				world.sim_time,
				float(own.depth_m),
			)
		)
	elif mode == "BEARING_ONLY":
		var track: Track = tracker.track_by_id(selected_id) if tracker != null else null
		var lm: Measurement = track.latest_measurement() if track != null else null
		if lm == null:
			out["reason"] = "no measurement on selected contact"
			return out
		out["tp"] = (
			ws
			. fire_bearing_only(
				lm.measured_bearing_deg,
				float(own.position_east_m),
				float(own.position_north_m),
				world.sim_time,
				float(own.depth_m),
			)
		)
	else:
		out["tp"] = (
			ws
			. fire_manual(
				own.course_deg,
				float(own.position_east_m),
				float(own.position_north_m),
				world.sim_time,
				float(own.depth_m),
			)
		)
	out["ok"] = true
	return out
