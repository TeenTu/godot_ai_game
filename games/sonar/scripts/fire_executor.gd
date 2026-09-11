class_name FireExecutor
extends RefCounted
## fire_executor.gd — REQ-0908 Batch 1：发射执行与联锁（REQ-B1-04）。
##
## main_ui 只传"模式 + 选中 Contact"，判定与发射都在此控制器：
##   - MAP_ROUTE：S1-11 D-01 玩家唯一发射方式——消费编程器携带的地图航线；
##   - SOLUTION：只读选中 Contact 自己的解（fcc 门：其他 Track/stale/超龄拒绝）；
##   - BEARING_ONLY：只用选中 Contact 的最新测量方位（无距离/无提前量）；
##   - MANUAL：玩家显式航向，不读任何解（敌方 AI 内部路径）。
## 返回 {ok, tp, mode, reason}；ok=false 表示被联锁拒绝。

var fcc: FireControlContext = null
var tracker: Tracker = null
## REQ-B4-01/02：发射前编程控制器（可为 null = 旧默认路径）。
var programmer: LaunchProgrammer = null


func execute(ws: WeaponSystem, world: World, mode: String, selected_id: String) -> Dictionary:
	var out: Dictionary = {"ok": false, "tp": null, "mode": mode, "reason": ""}
	# REQ-B5-05：任务终局后一切发射命令拒绝（统一命令门）。
	var mission_gate: String = world.command_reject_reason()
	if mission_gate != "":
		out["reason"] = mission_gate
		return out
	# S1-11 D-01：MAP_ROUTE 必须携带地图航线程序——无编程器时拒绝，
	# 绝不静默退化为 MANUAL（玩家唯一发射方式必须可追溯）。
	if mode == "MAP_ROUTE" and programmer == null:
		out["reason"] = "MAP_ROUTE requires a route program"
		return out
	# REQ-B4-01：编程控制器路径——程序由面板编辑项 + 推荐默认构建，
	# SOLUTION 解绑定/stale 联锁在 build_program 内经 fcc 把关。
	if programmer != null:
		return _execute_programmed(ws, world, mode, selected_id, out)
	return _execute_legacy(ws, world, mode, selected_id, out)


func _execute_programmed(
	ws: WeaponSystem, world: World, mode: String, selected_id: String, out: Dictionary
) -> Dictionary:
	var own: RefCounted = world.world["own"]
	var pr: Dictionary = programmer.build_program(mode, ws, world, fcc, tracker, selected_id)
	if not bool(pr.get("ok", false)):
		out["reason"] = str(pr.get("reason", "?"))
		return out
	out["tp"] = (
		ws
		. fire_program(
			pr["program"],
			float(own.position_east_m),
			float(own.position_north_m),
			world.sim_time,
			float(own.depth_m),
		)
	)
	if out["tp"] == null:
		out["reason"] = "program rejected by weapon system"
		return out
	out["ok"] = true
	return out


func _execute_legacy(
	ws: WeaponSystem, world: World, mode: String, selected_id: String, out: Dictionary
) -> Dictionary:
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
