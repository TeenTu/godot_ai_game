class_name ActivePingController
extends RefCounted
## active_ping_controller.gd — S1-04/S1-04B 主动声呐 Ping 的装配接线（纯逻辑，无 UI 节点）。
##
## 把 main_ui 的 Ping 按钮信号接到 World.issue_ping()（PingSession 状态机）。
## 回波按 τ=2R/c 往返传播延迟到达（声速 ~1500m/s，非光速）；World 在到达
## 时刻结算并生成带测距的 Measurement（REQ-19 同源基准，进入 world.measurements）。
## 本控制器职责：
##   - 每帧排空 World 已结算结果（take_arrived_echoes）；
##   - detected 命中喂 Tracker（等价一次玩家主动 Mark，source "P"）；
##   - 把命中（含 Track 对象）回调主 UI（on_echo_hits）→ 自动选中 + REFIT，
##     让主动 range 进入 TMA 解算（REQ-08/REQ-10）；
##   - 面板状态完全来自 world.ping_state_name()（UNAVAILABLE/READY/LISTENING/
##     RETURN/NO_RETURN），不读 Truth 推导的回波倒计时（ISSUE-06）。

var world: World = null
var tracker: Tracker = null
## 注入回调：update_status(text)、notify_dirty()。
var on_status: Callable = Callable()
var on_dirty: Callable = Callable()
## 命中回调：detected 回波已喂 Tracker 后调用，参数 [{measurement, track, summary}]。
var on_echo_hits: Callable = Callable()

## 最近一次回波/发射摘要（面板显示，空串则不显示）。
var last_summary: String = ""


## 主 UI 每帧调用：排空已结算回波并同步按钮状态/摘要。
## 状态行由 World 权威给出——不显示"还有 Xs 回波到达"（Truth 泄露）。
## op_panel 可空（无头测试）：只排空回波/喂 Tracker，不刷面板。
func refresh_panel(op_panel: OperatorPanel) -> void:
	if world == null:
		return
	_process_arrived_echoes()
	if op_panel == null:
		return
	op_panel.set_ping_state(world.ping_state_name(), world.ping_cooldown_remaining(), last_summary)


## Ping 按钮 → 发射一次主动脉冲。UNAVAILABLE（无硬件 REQ-20）只提示；
## LISTENING/冷却（单在途 REQ-16/17）中被拒只提示不发脉冲。
func request_ping() -> void:
	if world == null or tracker == null:
		return
	if world.ping_state_name() == "UNAVAILABLE":
		_call_status("Ping unavailable — no active sonar on this platform")
		return
	if not world.can_ping():
		_call_status("Ping recharging / ping in flight")
		return
	if not world.issue_ping():
		return
	notify_dirty()
	last_summary = "transmitting…"
	_call_status("ACTIVE PING transmitted — listening for echoes (you are emitting!)")


## 每帧排空 World 已结算回波：detected 命中喂 Tracker 并回调主 UI。
## auto_measurements=true（旧自动模式）时回波已 append 进 world.measurements，
## 由测量流消费方（main_ui._feed_new_measurements）自动喂 Tracker/建 Track，
## 本控制器只排空缓冲，避免同一测量被双喂（双 Track/重复关联）。
func _process_arrived_echoes() -> void:
	var echoes: Array = world.take_arrived_echoes()
	if echoes.is_empty():
		return
	if world.auto_measurements:
		return
	var hits: Array = []
	var fed: Array = []
	for e in echoes:
		if not bool(e["detected"]):
			continue
		hits.append(e)
		var m: Measurement = e["measurement"]
		var t: Track = tracker.feed(m)
		if t == null:
			t = tracker.mark(m, "P")
		notify_dirty()
		fed.append({"measurement": m, "track": t, "summary": e})
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
	if on_echo_hits.is_valid() and not fed.is_empty():
		on_echo_hits.call(fed)


func _call_status(text: String) -> void:
	if on_status.is_valid():
		on_status.call(text)


func notify_dirty() -> void:
	if on_dirty.is_valid():
		on_dirty.call()
