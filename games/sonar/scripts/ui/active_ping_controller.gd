class_name ActivePingController
extends RefCounted
## active_ping_controller.gd — S1-04/S1-04B/S1-04C 主动声呐 Ping 的装配接线。
##
## 把 main_ui 的 Ping 信号接到 World.issue_ping()（PingSession 状态机），
## 回波按 τ=2R/c 往返传播延迟到达（声速 ~1500m/s）；World 在到达时刻结算并
## 生成带测距的 Measurement（REQ-19 同源基准，进入 world.measurements）。
## 本控制器职责（纯逻辑，无 UI 节点）：
##   - 每帧排空 World 已结算结果（take_arrived_echoes）；
##   - detected 命中喂 Tracker（等价一次玩家主动 Mark，source "P"）；
##   - 记录最近返回行（Latest Returns）与最近一次自动关联（Undo 入口）；
##   - 把完整卡片数据组装给 OperatorPanel 的 ActiveSonarCard（REQ-01）；
##   - 状态/徽标完全来自 world.ping_state_name() 与本艇发射时钟，不读 Truth
##     推导的回波倒计时（ISSUE-06）。

const MAX_RETURNS: int = 8

var world: World = null
var tracker: Tracker = null
## 注入回调：update_status(text)、notify_dirty()。
var on_status: Callable = Callable()
var on_dirty: Callable = Callable()
## 命中回调：detected 回波已喂 Tracker 后调用，参数 [{measurement, track, summary}]。
var on_echo_hits: Callable = Callable()
## 撤销回调：一次关联被撤销后调用（main_ui 刷新视图/状态）。
var on_assoc_undone: Callable = Callable()

## 最近一次回波/发射摘要（面板显示，空串则不显示）。
var last_summary: String = ""
## 最近返回行（Latest Returns 数据源）：[{ping_id,time,bearing_deg,range_m,
##   range_sigma_m,se_db,track_id}]，最新在尾，保留 ≤MAX_RETURNS。
var return_rows: Array = []
## 最近一次自动关联（Undo 目标）：{measurement, track}；手动 Mark 不在此列。
var _last_assoc: Dictionary = {}


## 主 UI 每帧调用：排空已结算回波并刷新卡片。
## op_panel 可空（无头测试）：只排空回波/喂 Tracker，不刷面板。
func refresh_panel(op_panel: OperatorPanel) -> void:
	if world == null:
		return
	_process_arrived_echoes()
	if op_panel == null:
		return
	op_panel.set_active_sonar(_card_data())


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
		_last_assoc = {"measurement": m, "track": t}
		_append_return_row(m, t)
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


## 撤销最近一次自动关联（S1-04C-REQ-03 UI 允许撤销/改绑一次主动回波）：
## 把该测量从 Track 移除并触发刷新回调。返回是否真的撤销了。
func undo_last_association() -> bool:
	if _last_assoc.is_empty():
		return false
	var m: Measurement = _last_assoc.get("measurement")
	var t: Track = _last_assoc.get("track")
	_last_assoc = {}
	if m == null or t == null:
		return false
	if not t.remove_measurement(m):
		return false
	if on_assoc_undone.is_valid():
		on_assoc_undone.call(t.track_id)
	return true


func has_undo() -> bool:
	return not _last_assoc.is_empty()


## 当前卡片应显示的关联 Track id（无则 "-"）。
func linked_track_id() -> String:
	if _last_assoc.is_empty():
		return "-"
	var t: Track = _last_assoc.get("track")
	if t == null:
		return "-"
	return t.track_id


func _append_return_row(m: Measurement, t: Track) -> void:
	(
		return_rows
		. append(
			{
				"ping_id": m.ping_id,
				"time": m.timestamp,
				"bearing_deg": m.measured_bearing_deg,
				"range_m": m.measured_range_m,
				"range_sigma_m": m.range_sigma_m,
				"se_db": m.signal_excess_db,
				"track_id": t.track_id if t != null else "-",
			}
		)
	)
	if return_rows.size() > MAX_RETURNS:
		return_rows.pop_front()


## 组装 ActiveSonarCard 完整数据（REQ-01）。徽标由 PingSession 状态 + 本艇
## 发射时钟派生（TRANSMITTING=发射后 1s 内；RETURN/NO_RETURN 冷却期=COOLDOWN）。
## 固定参数来自 world 的主动阵配置（本艇事实，非目标 Truth）。
func _card_data() -> Dictionary:
	var state: String = world.ping_state_name()
	var cd: float = world.ping_cooldown_remaining()
	if state == "LISTENING":
		var emit: float = world.ping_emit_time()
		if emit >= 0.0 and world.sim_time - emit <= 1.0:
			state = "TRANSMITTING"
	elif state == "RETURN" or state == "NO_RETURN":
		if cd > 0.0:
			state = "COOLDOWN"
	var disabled_reason: String = ""
	if state == "UNAVAILABLE":
		disabled_reason = "No active sonar fitted on this platform."
	elif state != "READY":
		disabled_reason = "Single ping in flight / recharging — wait for it to return."
	elif not world.can_ping():
		disabled_reason = "Ping recharging."
	var params := {
		"mode": "Single pulse",
		"freq_khz": world.ping_center_freq_hz() / 1000.0,
		"sl_db": world.ping_sl_db,
		"listen_s": world.ping_listen_window_s,
		"max_range_km": world.ping_max_range_m() / 1000.0,
		"exposure": "HIGH — enemy may intercept",
	}
	var linked: String = linked_track_id()
	var evidence: String = "ACTIVE RANGE ADDED" if linked != "-" else "-"
	var tma := {"track": linked, "evidence": evidence, "fit": "-"}
	return {
		"state": state,
		"cooldown": cd,
		"params": params,
		"returns": return_rows.duplicate(),
		"tma": tma,
		"undo_enabled": has_undo(),
		"ping_disabled_reason": disabled_reason,
	}


func _call_status(text: String) -> void:
	if on_status.is_valid():
		on_status.call(text)


func notify_dirty() -> void:
	if on_dirty.is_valid():
		on_dirty.call()
