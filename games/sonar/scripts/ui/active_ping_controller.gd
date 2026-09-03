class_name ActivePingController
extends RefCounted
## active_ping_controller.gd — S1-04 主动 Ping 的装配接线（纯逻辑，无 UI 节点）。
##
## 把 main_ui 的 Ping 按钮信号接到 World.issue_ping()，并把 detected 回波
## Measurement（World 内已 append）喂给 Tracker——主动回波等价一次玩家主动
## 触发的自动 Mark（与 Autocrew 语义一致）。产出人读摘要供面板/状态栏显示。
## 拆分目的是避免 main_ui 继续膨胀（.gdlintrc max-file-lines 1200 指引）。

var world: World = null
var tracker: Tracker = null
## 注入回调：update_status(text)、notify_dirty()。
var on_status: Callable = Callable()
var on_dirty: Callable = Callable()

var last_summary: String = ""


## 主 UI 每帧调用，同步按钮冷却/摘要。
func refresh_panel(op_panel: OperatorPanel) -> void:
	if op_panel == null or world == null:
		return
	op_panel.set_ping_state(world.can_ping(), world.ping_cooldown_remaining(), last_summary)


## Ping 按钮 → 发起一次主动脉冲并处理回波。冷却中被拒只提示不发脉冲。
func request_ping() -> void:
	if world == null or tracker == null or not world.can_ping():
		return
	var n0: int = world.measurements.size()
	var echoes: Array = world.issue_ping()
	if echoes.is_empty():
		_call_status("Ping recharging")
		return
	var hits: Array = []
	for e in echoes:
		if e["detected"]:
			hits.append(e)
	# detected 回波 Measurement 已 append 进 world.measurements（World 内），
	# 这里把新增的测量喂给 Tracker。
	for i in range(n0, world.measurements.size()):
		var m: Measurement = world.measurements[i]
		var t: Track = tracker.feed(m)
		if t == null:
			tracker.mark(m, "P")
		notify_dirty()
	if hits.is_empty():
		last_summary = "no echo"
		_call_status("Ping sent — no echo")
	else:
		var best: Dictionary = hits[0]
		var multi: String = ""
		if hits.size() > 1:
			multi = "  (%d echoes)" % hits.size()
		last_summary = (
			"echo brg %.0f° rng %.2fkm SE%+.0fdB%s"
			% [
				float(best["bearing_deg"]),
				float(best["range_m"]) / 1000.0,
				float(best["se_db"]),
				multi,
			]
		)
		_call_status("ACTIVE PING → " + last_summary + "  (transmitting!)")


func _call_status(text: String) -> void:
	if on_status.is_valid():
		on_status.call(text)


func notify_dirty() -> void:
	if on_dirty.is_valid():
		on_dirty.call()
