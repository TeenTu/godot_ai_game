class_name ActivePingController
extends RefCounted
## active_ping_controller.gd — S1-04 主动 Ping 的装配接线（纯逻辑，无 UI 节点）。
##
## 把 main_ui 的 Ping 按钮信号接到 World.issue_ping()，回波按 τ=2R/c 往返传播
## 延迟到达（声速 ~1500m/s，非光速），到达后把 detected 回波 Measurement 喂给
## Tracker——主动回波等价一次玩家主动触发的自动 Mark（与 Autocrew 语义一致）。
## 产出人读摘要供面板/状态栏显示。拆分目的是避免 main_ui 继续膨胀
## （.gdlintrc max-file-lines 1200 指引）。

var world: World = null
var tracker: Tracker = null
## 注入回调：update_status(text)、notify_dirty()。
var on_status: Callable = Callable()
var on_dirty: Callable = Callable()

var last_summary: String = ""


## 主 UI 每帧调用，同步按钮冷却/摘要。回波按 τ=2R/c 延迟到达，这里顺带
## 结算已到达回波（drain），无需额外信号。
func refresh_panel(op_panel: OperatorPanel) -> void:
	if op_panel == null or world == null:
		return
	_process_arrived_echoes()
	var summary: String = last_summary
	if world.pending_echo_count() > 0:
		summary = "echo in ~%.0fs" % maxf(world.next_echo_in(), 0.0)
	op_panel.set_ping_state(world.can_ping(), world.ping_cooldown_remaining(), summary)


## Ping 按钮 → 发射一次主动脉冲。回波不会立即返回：声呐传播有往返延迟
## （τ=2R/c，声速 ~1500m/s），冷却中被拒只提示不发脉冲。
func request_ping() -> void:
	if world == null or tracker == null:
		return
	if not world.can_ping():
		_call_status("Ping recharging")
		return
	if not world.issue_ping():
		return
	notify_dirty()
	if world.pending_echo_count() == 0:
		last_summary = "no target in area"
		_call_status("Ping transmitted — no contacts to echo")
		return
	var wait_s: float = maxf(world.next_echo_in(), 0.0)
	last_summary = "transmitting… echo in ~%.0fs" % wait_s
	_call_status("ACTIVE PING transmitted — echo in ~%.0fs (you are emitting!)" % wait_s)


## 每帧结算已到达的在途回波：喂 Tracker（等价玩家主动自动 Mark）并刷摘要。
func _process_arrived_echoes() -> void:
	var echoes: Array = world.take_arrived_echoes()
	if echoes.is_empty():
		return
	var hits: Array = []
	for e in echoes:
		if not bool(e["detected"]):
			continue
		hits.append(e)
		var m: Measurement = e["measurement"]
		var t: Track = tracker.feed(m)
		if t == null:
			tracker.mark(m, "P")
		notify_dirty()
	if hits.is_empty():
		last_summary = "no echo"
		_call_status("Ping returned — no echo")
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
		_call_status("ACTIVE PING → " + last_summary + "  (you are emitting!)")


func _call_status(text: String) -> void:
	if on_status.is_valid():
		on_status.call(text)


func notify_dirty() -> void:
	if on_dirty.is_valid():
		on_dirty.call()
