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
##   - S1-04C-REQ-02 TMA 拟合模式机：AUTO 自动重拟合命中接触；ASSISTED
##     （默认）提示"Apply range evidence to Trial?"（Apply/Reject）；MANUAL
##     只入 Track、Trial 不动并显示 REFIT REQUIRED；Take Control → MANUAL
##     但保留证据。任何模式都不自动提交 System Solution（main_ui 控制）。

const MAX_RETURNS: int = 8
const MODE_AUTO: String = "AUTO"
const MODE_ASSISTED: String = "ASSISTED"
const MODE_MANUAL: String = "MANUAL"

var world: World = null
var tracker: Tracker = null
## 注入回调：update_status(text)、notify_dirty()。
var on_status: Callable = Callable()
var on_dirty: Callable = Callable()
## 命中回调：detected 回波已喂 Tracker 后调用，参数 [{measurement, track, summary}]，
## 数组已按 REQ-02 优先级排序（当前选中 Track 优先，再按 association_confidence
## + SE 降序）——主 UI 取 fed[0] 即最高优先命中。
var on_echo_hits: Callable = Callable()
## 拟合请求回调：AUTO 命中或 ASSISTED 玩家点 Apply 后触发，参数 track_id。
## 由持有拟合状态/UI 的调用方（main_ui）执行 select+refit。
var on_fit_requested: Callable = Callable()
## 撤销回调：一次关联被撤销后调用（main_ui 刷新视图/状态）。
var on_assoc_undone: Callable = Callable()

## S1-04C-REQ-02：TMA 拟合模式（MANUAL/ASSISTED/AUTO，默认 ASSISTED）。
var fit_mode: String = MODE_ASSISTED
## 多回波优先级（REQ-02）：当前选中 Track id；命中该 Track 的回波排最前。
var preferred_track_id: String = ""
## 最近一次回波/发射摘要（面板显示，空串则不显示）。
var last_summary: String = ""
## 最近返回行（Latest Returns 数据源）：[{ping_id,time,bearing_deg,range_m,
##   range_sigma_m,se_db,track_id}]，最新在尾，保留 ≤MAX_RETURNS。
var return_rows: Array = []
## 证据显示状态（卡片 TMA Link Fit 行）："" / REFIT_REQUIRED / PENDING_APPLY /
## RANGE_AIDED / REJECTED。由本控制器按模式置位，main_ui 拟合后经
## mark_range_applied() 校正。
var evidence_state: String = ""
## 最近一次自动关联（Undo 目标）：{measurement, track}；手动 Mark 不在此列。
var _last_assoc: Dictionary = {}
## ASSISTED 待玩家裁决的"range 证据 → Trial"申请：{measurement, track}。
var _pending_apply: Dictionary = {}


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
## S1-04C-REQ-02：喂完 Tracker 后按 fit_mode 裁决（AUTO 重拟合 / ASSISTED
## 挂起待 Apply / MANUAL 只入 Track），证据三种模式都已进 Track。
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
			# 全新接触由主动回波直接锚定：range 即初始证据，置信度取高。
			t.association_confidence = 0.9
			t.last_association_mode = "range"
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
	_route_fed_by_mode(fed)
	if on_echo_hits.is_valid() and not fed.is_empty():
		on_echo_hits.call(fed)


## REQ-02 优先级：当前选中 Track 的回波最前，再按 association_confidence 降序、
## SE 降序。主 UI 取 fed[0] 即最高优先命中（选中/高置信/强回波）。
func _sort_hits_by_priority(fed: Array) -> void:
	fed.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var ta: Track = a.get("track") as Track
			var tb: Track = b.get("track") as Track
			var ka: int = 0 if (ta != null and ta.track_id == preferred_track_id) else 1
			var kb: int = 0 if (tb != null and tb.track_id == preferred_track_id) else 1
			if ka != kb:
				return ka < kb
			var ca: float = ta.association_confidence if ta != null else 0.0
			var cb: float = tb.association_confidence if tb != null else 0.0
			if absf(ca - cb) > 1.0e-6:
				return ca > cb
			var sa: float = float(a.get("summary", {}).get("se_db", 0.0))
			var sb: float = float(b.get("summary", {}).get("se_db", 0.0))
			return sa > sb
	)


## 按 REQ-02 fit_mode 裁决命中后的动作。证据始终已进 Track；任何模式都不
## 自动提交 System Solution（提交只由 main_ui 的 Accept 按钮触发）。
func _route_fed_by_mode(fed: Array) -> void:
	if fed.is_empty():
		return
	_sort_hits_by_priority(fed)
	var primary: Dictionary = fed[0]
	var tr: Track = primary.get("track") as Track
	if tr == null:
		return
	var tid: String = tr.track_id
	_pending_apply = {}
	match fit_mode:
		MODE_AUTO:
			evidence_state = ""
			_call_status("Active range on %s (AUTO) — refitting Trial…" % tid)
			if on_fit_requested.is_valid():
				on_fit_requested.call(tid)
		MODE_ASSISTED:
			evidence_state = "PENDING_APPLY"
			_pending_apply = _last_assoc.duplicate()
			_call_status("Active range on %s — Apply range evidence to Trial?" % tid)
		MODE_MANUAL:
			evidence_state = "REFIT_REQUIRED"
			_call_status("Active range on %s (MANUAL) — Trial unchanged, REFIT REQUIRED" % tid)


## 撤销最近一次自动关联（S1-04C-REQ-03 UI 允许撤销/改绑一次主动回波）：
## 把该测量从 Track 移除并触发刷新回调。ASSISTED 模式下同时撤下待 Apply
## 申请（=Reject），证据状态置 REJECTED。返回是否真的撤销了。
func undo_last_association() -> bool:
	if _last_assoc.is_empty():
		return false
	var m: Measurement = _last_assoc.get("measurement")
	var t: Track = _last_assoc.get("track")
	_last_assoc = {}
	_pending_apply = {}
	if m == null or t == null:
		return false
	if not t.remove_measurement(m):
		return false
	evidence_state = "REJECTED"
	if on_assoc_undone.is_valid():
		on_assoc_undone.call(t.track_id)
	return true


func has_undo() -> bool:
	return not _last_assoc.is_empty()


# ------------------------------------------------------------------
#  S1-04C-REQ-02：TMA 拟合模式控制
# ------------------------------------------------------------------


## 切换拟合模式（AUTO/ASSISTED/MANUAL）。只影响后续回波裁决；已有证据不动。
func set_fit_mode(mode: String) -> void:
	if mode not in [MODE_AUTO, MODE_ASSISTED, MODE_MANUAL]:
		return
	if fit_mode == mode:
		return
	fit_mode = mode
	if mode == MODE_MANUAL:
		# 落入 MANUAL：撤下待 Apply 提示但保留证据 → REFIT REQUIRED。
		if not _pending_apply.is_empty():
			_pending_apply = {}
			evidence_state = "REFIT_REQUIRED"
	notify_dirty()


## Take Control：模式切回 MANUAL，保留已有 range 证据（不再自动/半自动改
## Trial，由操作员手动 Auto Fit 后 Accept）。等价 set_fit_mode(MANUAL) +
## 撤掉待 Apply 提示（若有）。
func take_control() -> void:
	fit_mode = MODE_MANUAL
	if not _pending_apply.is_empty():
		_pending_apply = {}
		evidence_state = "REFIT_REQUIRED"
	notify_dirty()


## ASSISTED 玩家点 Apply：把待裁决的 range 证据应用到 Trial（请求调用方重
## 拟合命中接触）。无待裁决时返回 false。
func apply_pending() -> bool:
	if _pending_apply.is_empty():
		return false
	var t: Track = _pending_apply.get("track")
	_pending_apply = {}
	if t == null:
		return false
	evidence_state = "PENDING_APPLY"  # 拟合完成后由 mark_range_applied 校正
	if on_fit_requested.is_valid():
		on_fit_requested.call(t.track_id)
	return true


## 是否有待玩家 Apply 裁决的 range 证据（ASSISTED 提示行显示用）。
func has_pending_apply() -> bool:
	return not _pending_apply.is_empty()


## 拟合已执行后由调用方校正证据状态：success=true → RANGE AIDED，
## 否则（几何不足/失败）→ REFIT REQUIRED（证据仍在，操作员可继续手动处理）。
func mark_range_applied(success: bool) -> void:
	evidence_state = "RANGE_AIDED" if success else "REFIT_REQUIRED"
	notify_dirty()


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
	var fit_txt: String = "-"
	match evidence_state:
		"PENDING_APPLY":
			fit_txt = "AWAITING APPLY"
		"REFIT_REQUIRED":
			fit_txt = "REFIT REQUIRED"
		"RANGE_AIDED":
			fit_txt = "RANGE AIDED"
		"REJECTED":
			fit_txt = "REJECTED"
	var tma := {
		"track": linked,
		"evidence": evidence,
		"fit": fit_txt,
		"fit_mode": fit_mode,
	}
	return {
		"state": state,
		"cooldown": cd,
		"params": params,
		"returns": return_rows.duplicate(),
		"tma": tma,
		"fit_mode": fit_mode,
		"pending_apply": has_pending_apply(),
		"undo_enabled": has_undo(),
		"ping_disabled_reason": disabled_reason,
	}


func _call_status(text: String) -> void:
	if on_status.is_valid():
		on_status.call(text)


func notify_dirty() -> void:
	if on_dirty.is_valid():
		on_dirty.call()
