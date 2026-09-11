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
##
## P1-A 变更（PG-01/PG-03/PG-04）：
##   - 模式不再自持第二份状态：`fit_mode` 是全局 AutomationController 的派生视图
##     （T21），卡片切模式 = 切全局模式；
##   - 到达即显示：每个有效回波在到达帧生成稳定的"临时位置点 + 误差区"（待关联），
##     监听窗关闭后统一归属，替换临时标签而**不新增**重复证据（PG-03）；
##   - 单次观测立即产出 POSITION_ONLY 系统位置估计（不受"4 条证据"门限约束），
##     多历元且几何可观测才升为 MOTION_ESTIMATE（PG-04）；
##   - 无回波时监听结束明确给出"本次未获得有效回波"及已知因素，不保留上次成功摘要。

const MAX_RETURNS: int = 8
const MODE_AUTO: String = "AUTO"
const MODE_ASSISTED: String = "ASSISTED"
const MODE_MANUAL: String = "MANUAL"
## PG-01：自动 TMA 的最小证据数（"条件充分"）。位置估计（POSITION_ONLY）一律
## 不受此门限约束——T14 明确禁止用"4 条证据"拦截位置输出。
const MIN_EVIDENCE_FOR_AUTO_TMA: int = 4
## PG-03：临时（待关联）位置点上限 / 归属后标签保留秒数。
const MAX_TEMP_CONTACTS: int = 12
const RESOLVED_TEMP_HOLD_S: float = 8.0
## 本艇航速超过该值时，无回波解释里列出"自噪升高"这一已知因素。
const OWN_NOISE_SPEED_KN: float = 8.0
## 海况达到该值时，无回波解释里列出"环境噪声高"这一已知因素。
const HIGH_SEA_STATE: float = 4.0

var world: World = null
var tracker: Tracker = null
## PG-01：唯一自动化模式源（main_ui 注入）。非空时 fit_mode 只是派生视图。
var automation: AutomationController = null
## 注入回调：update_status(text)、notify_dirty()。
var on_status: Callable = Callable()
var on_dirty: Callable = Callable()
## 命中回调：detected 回波已喂 Tracker 后调用，参数 [{measurement, track, summary}]，
## 数组已按 REQ-02 优先级排序（当前选中 Track 优先，再按 association_confidence
## + SE 降序）。P1-A/T18：消费方必须遍历**全部**命中（自动更新每个被更新航迹），
## 不得只取 fed[0]。
var on_echo_hits: Callable = Callable()
## 拟合请求回调：AUTO 命中或 ASSISTED 玩家点 Apply 后触发，参数 track_id。
## 由持有拟合状态/UI 的调用方（main_ui）执行 select+refit。
var on_fit_requested: Callable = Callable()
## PG-01：自动系统估计回调（ASSIST/AUTO 且条件充分时），参数 track_id。
## 与 on_fit_requested 分离：这条路径只更新"系统估计"，绝不改动玩家草案。
var on_auto_estimate: Callable = Callable()
## 撤销回调：一次关联被撤销后调用（main_ui 刷新视图/状态）。
var on_assoc_undone: Callable = Callable()

## S1-04C-REQ-02：TMA 拟合模式（MANUAL/ASSISTED/AUTO，默认 ASSISTED）。
## PG-01：派生视图——读写都落到唯一模式源 `automation`（未注入时用本地兼容值）。
var fit_mode: String:
	get:
		return _canon_mode()
	set(value):
		_apply_fit_mode(value)
## 多回波优先级（REQ-02）：当前选中 Track id；命中该 Track 的回波排最前。
var preferred_track_id: String = ""
## 最近一次回波/发射摘要（面板显示，空串则不显示）。
var last_summary: String = ""
## PG-03：本次监听窗结论（"" / "RETURN" / "NO_RETURN"）。
var last_outcome: String = ""
## PG-03：无回波时的可解释已知因素（UiText 键：nr_window / nr_own_noise / nr_recharge）。
var no_return_reasons: Array = []
## PG-03：到达即显示的临时位置点/误差区（待关联）。监听窗关闭后替换为最终归属标签。
## [{temp_id, ping_id, measurement, east_m, north_m, sigma_m, major_m, minor_m,
##   angle_deg, is_sector, bearing_deg, bearing_sigma_deg, range_m, range_sigma_m,
##   observation_time_s, awaiting, resolved_track_id, resolved_at_s}]
var pending_contacts: Array = []
## PG-04：每个被更新航迹的系统位置/运动估计（track_id -> ActivePositionObs.evaluate）。
## 独立于玩家手动草案；POSITION_ONLY 单次观测即产出。
var position_estimates: Dictionary = {}
## 最近返回行（Latest Returns 数据源）：[{ping_id,time,bearing_deg,range_m,
##   range_sigma_m,se_db,track_id}]，最新在尾，保留 ≤MAX_RETURNS。
var return_rows: Array = []
## 证据显示状态（卡片 TMA Link Fit 行）："" / REFIT_REQUIRED / PENDING_APPLY /
## RANGE_AIDED / REJECTED。由本控制器按模式置位，main_ui 拟合后经
## mark_range_applied() 校正。
var evidence_state: String = ""
## PG-01：未注入 AutomationController 时的本地兼容模式值（唯一源缺失才用）。
var _fit_mode_legacy: String = MODE_ASSISTED
## PG-03：临时位置点序号（只为生成稳定 temp_id，不参与归属判决）。
var _temp_seq: int = 0
## PG-03：最近观察到的已关闭监听窗 id（用于识别"本次无回波"）。
var _last_closed_seen: int = -1
## PG-01：已请求自动系统估计的 evidence_revision（同一证据不重复请求）。
var _auto_fit_revision: Dictionary = {}
## S109 §5.1 ActiveReturnRecord 台账（P0-07：禁止单份 _last_assoc 承载多回波）：
## [{local_return_id, ping_id, measurement, track, track_id, association_score,
##   se_db, received_time}]，最新在尾，保留 ≤MAX_RETURNS。
var _records: Array = []
var _next_return_seq: int = 1
## S1-11 §3.5：按 ping_id 缓存的回波批次（{ping_id: [echo summary]}），
## 监听窗关闭后统一一对一分配，保证同 Ping 内不重复占用航迹（AT-51/53）。
var _pending_batch: Dictionary = {}
## ASSISTED 待玩家裁决的"range 证据 → Trial"申请：{measurement, track,
## local_return_id}。S109 §5.2：取本次 Ping 全局最高优先回波，非最后写入。
var _pending_apply: Dictionary = {}


## 主 UI 每帧调用：排空已结算回波并刷新卡片。
## op_panel 可空（无头测试）：只排空回波/喂 Tracker，不刷面板。
func refresh_panel(op_panel: OperatorPanel) -> void:
	if world == null:
		return
	_process_arrived_echoes()
	# PG-01/T18：ASSIST/AUTO 都自动更新全部已关联接触的系统位置估计。
	_refresh_track_estimates()
	if op_panel == null:
		return
	op_panel.set_active_sonar(_card_data())


## PG-01：当前模式（来自唯一模式源；未注入 AutomationController 时用本地兼容值）。
func _canon_mode() -> String:
	if automation == null:
		return _fit_mode_legacy
	match automation.mode:
		AutomationController.Mode.MANUAL:
			return MODE_MANUAL
		AutomationController.Mode.FULL_AUTO:
			return MODE_AUTO
		_:
			return MODE_ASSISTED


## PG-01：设置模式 = 设置全局模式（T21）。未注入时只改本地兼容值。
func _apply_fit_mode(value: String) -> void:
	if automation == null:
		if value in [MODE_AUTO, MODE_ASSISTED, MODE_MANUAL]:
			_fit_mode_legacy = value
	else:
		automation.set_mode(
			AutomationController.from_canon_name(value), world.sim_time if world != null else 0.0
		)
	# 落入 MANUAL：撤下待 Apply 提示但保留证据 → REFIT REQUIRED。
	if _canon_mode() == MODE_MANUAL and not _pending_apply.is_empty():
		_pending_apply = {}
		evidence_state = "REFIT_REQUIRED"
	notify_dirty()


## Ping 按钮 → 发射一次主动脉冲。UNAVAILABLE（无硬件 REQ-20）只提示；
## LISTENING/冷却（单在途 REQ-16/17）中被拒只提示不发脉冲。
func request_ping() -> void:
	if world == null or tracker == null:
		return
	if world.ping_state_name() == "UNAVAILABLE":
		_call_status(UiText.t("st_ping_unavailable"))
		return
	if not world.can_ping():
		_call_status(UiText.t("st_ping_recharge"))
		return
	if not world.issue_ping():
		return
	notify_dirty()
	last_summary = "脉冲在途"
	_call_status(UiText.t("st_ping_tx"))


## 每帧排空 World 已结算回波：按 ping_id 缓入批次，监听窗关闭（World 报告
## last_closed_ping_id）后一次性做一对一分配，再按 fit_mode 裁决。
## auto_measurements=true（旧自动模式）时回波已 append 进 world.measurements，
## 由测量流消费方（main_ui._feed_new_measurements）消费，本控制器只排空缓冲。
## S1-11 §3.5/D-14/AT-51..54：同一 Ping 内每条回波只喂一个目标，每条普通航迹
## 同一 Ping 只吸收一条回波；顺序无关；最优/次优接近时保留未归属。
func _process_arrived_echoes() -> void:
	var echoes: Array = world.take_arrived_echoes()
	if world.auto_measurements:
		return
	var closed: int = world.last_closed_ping_id()
	for e in echoes:
		if not bool(e["detected"]):
			continue
		var pid: int = int(e.get("ping_id", -1))
		if not _pending_batch.has(pid):
			_pending_batch[pid] = []
		_pending_batch[pid].append(e)
		# PG-03：到达即显示——同一帧内生成稳定的临时位置点 + 误差区（"待关联"）。
		# 在途回波绝不提前显示（只有 take_arrived_echoes 交付的到达帧才登记）。
		_register_temp_contact(e)
	if _pending_batch.has(closed):
		_flush_return_batch(closed)
	elif closed >= 0 and closed != _last_closed_seen:
		_seal_no_return()
	_last_closed_seen = closed
	_prune_temp_contacts()


## PG-03：登记一个"待关联"临时位置点（稳定 temp_id，跨刷新不重编号）。
func _register_temp_contact(e: Dictionary) -> void:
	var m: Measurement = e.get("measurement")
	var obs: Dictionary = ActivePositionObs.observation_of(m)
	if not bool(obs.get("valid", false)):
		return
	_temp_seq += 1
	(
		pending_contacts
		. append(
			{
				"temp_id": "T%02d" % _temp_seq,
				"ping_id": int(e.get("ping_id", -1)),
				"measurement": m,
				"east_m": float(obs["east_m"]),
				"north_m": float(obs["north_m"]),
				"sigma_m": float(obs["major_m"]),
				"major_m": float(obs["major_m"]),
				"minor_m": float(obs["minor_m"]),
				"angle_deg": float(obs["angle_deg"]),
				"is_sector": bool(obs["is_sector"]),
				"bearing_deg": float(obs["bearing_deg"]),
				"bearing_sigma_deg": float(obs["bearing_sigma_deg"]),
				"range_m": float(obs["range_m"]),
				"range_sigma_m": float(obs["range_sigma_m"]),
				"observation_time_s": float(obs["reference_time_s"]),
				"awaiting": true,
				"resolved_track_id": "",
				"resolved_at_s": -1.0,
			}
		)
	)
	while pending_contacts.size() > MAX_TEMP_CONTACTS:
		pending_contacts.pop_front()


## PG-03：监听窗关闭后统一归属——把临时标签替换为最终航迹 id（同一条证据对象，
## 不新增重复证据）。归属到既有航迹的临时点保留 RESOLVED_TEMP_HOLD_S 秒后收起。
func _resolve_temp_contacts(fed: Array) -> void:
	var owner: Dictionary = {}
	for f in fed:
		var t: Track = f.get("track")
		if t != null:
			owner[f.get("measurement")] = str(t.track_id)
	var now: float = world.sim_time
	for c in pending_contacts:
		var m: Measurement = c.get("measurement")
		if not bool(c["awaiting"]) or m == null or not owner.has(m):
			continue
		c["awaiting"] = false
		c["resolved_track_id"] = str(owner[m])
		c["resolved_at_s"] = now


func _prune_temp_contacts() -> void:
	var now: float = world.sim_time if world != null else 0.0
	var keep: Array = []
	for c in pending_contacts:
		if bool(c["awaiting"]) or now - float(c["resolved_at_s"]) <= RESOLVED_TEMP_HOLD_S:
			keep.append(c)
	pending_contacts = keep


## PG-03：监听结束无有效回波——明确文案 + 已知因素，并清掉上次成功摘要。
func _seal_no_return() -> void:
	last_outcome = "NO_RETURN"
	no_return_reasons = _no_return_reasons()
	return_rows.clear()
	_pending_apply = {}
	evidence_state = ""
	last_summary = str(UiText.t("st_ping_no_return")) + " " + no_return_text()
	_call_status(last_summary)
	notify_dirty()


## PG-03：无回波的已知因素（监听窗时延上限/本艇航速自噪/海况环境噪声）。
## 只列本艇与设备事实，绝不透露未探测目标的深度等 Truth。
func _no_return_reasons() -> Array:
	var out: Array = ["nr_window"]
	if world == null:
		return out
	var own: TruthEntity = world.world.get("own", null)
	if own != null and float(own.speed_kn) >= OWN_NOISE_SPEED_KN:
		out.append("nr_own_noise")
	var env: RefCounted = world.world.get("env", null)
	if env != null and float(env.sea_state) >= HIGH_SEA_STATE:
		out.append("nr_ambient")
	return out


func no_return_text() -> String:
	var parts: Array = []
	for k in no_return_reasons:
		parts.append(str(UiText.t(str(k))))
	var head: String = str(UiText.t("no_return_window")) % (world.ping_max_range_m() / 1000.0)
	if parts.is_empty():
		return head
	return head + "；" + "，".join(parts)


## PG-03/测试与面板用只读快照（不含 Measurement 引用与任何身份字段）。
func temp_contacts_snapshot() -> Array:
	var out: Array = []
	for c in pending_contacts:
		(
			out
			. append(
				{
					"temp_id": str(c["temp_id"]),
					"ping_id": int(c["ping_id"]),
					"east_m": float(c["east_m"]),
					"north_m": float(c["north_m"]),
					"sigma_m": float(c["sigma_m"]),
					"is_sector": bool(c["is_sector"]),
					"bearing_deg": float(c["bearing_deg"]),
					"bearing_sigma_deg": float(c["bearing_sigma_deg"]),
					"range_m": float(c["range_m"]),
					"range_sigma_m": float(c["range_sigma_m"]),
					"observation_time_s": float(c["observation_time_s"]),
					"awaiting": bool(c["awaiting"]),
					"resolved_track_id": str(c["resolved_track_id"]),
				}
			)
		)
	return out


## PG-01/T18：刷新全部 ACTIVE 航迹的系统位置估计（不限于本次命中/当前选中）。
func _refresh_track_estimates() -> void:
	if tracker == null or world == null:
		return
	var alive: Dictionary = {}
	for t in tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		alive[t.track_id] = ActivePositionObs.evaluate(t, world.sim_time)
	position_estimates = alive


## PG-04：本次命中航迹的系统估计 + 条件充分时的自动 TMA 请求（ASSIST/AUTO）。
func _refresh_estimates(fed: Array) -> void:
	var now: float = world.sim_time
	for f in fed:
		var t: Track = f.get("track")
		if t == null:
			continue
		var obs: Dictionary = ActivePositionObs.evaluate(t, now)
		position_estimates[t.track_id] = obs
		if not bool(obs.get("has_position", false)) or fit_mode == MODE_MANUAL:
			continue
		# PG-01：ASSIST/AUTO 都自动刷新概率分类与系统估计。
		t.set_classification(TrackClassification.assess(t, now))
		if t.evidence_count() < MIN_EVIDENCE_FOR_AUTO_TMA:
			continue
		if int(_auto_fit_revision.get(t.track_id, -1)) == t.evidence_revision:
			continue
		if on_auto_estimate.is_valid():
			_auto_fit_revision[t.track_id] = t.evidence_revision
			on_auto_estimate.call(t.track_id)


## PG-04：某航迹的系统位置估计（无 → 空字典）。
func position_estimate_for(track_id: String) -> Dictionary:
	return position_estimates.get(track_id, {})


## 批次结算：构造 Return×Track 代价矩阵 → 一对一分配 → 应用。
## 已归属回波直接追加到对应普通接触（显式 range 证据）；未归属/歧义回波
## 建立新的临时主动接触或保留未归属，绝不按到达顺序强塞。
func _flush_return_batch(ping_id: int) -> void:
	var echoes: Array = _pending_batch[ping_id]
	_pending_batch.erase(ping_id)
	if echoes.is_empty():
		return
	var returns: Array = []
	for i in range(echoes.size()):
		var mi: Measurement = echoes[i]["measurement"]
		(
			returns
			. append(
				{
					"id": "ret%02d" % i,
					"bearing_deg": mi.measured_bearing_deg,
					"bearing_sigma_deg": mi.bearing_sigma_deg,
					"range_m": mi.measured_range_m,
					"range_sigma_m": mi.range_sigma_m,
					"time": mi.timestamp,
					"freqs": mi.detected_frequencies,
				}
			)
		)
	var targets: Array = []
	var by_id: Dictionary = {}
	for tr in tracker.all_tracks():
		var t: Track = tr
		if t.state != Track.TrackState.ACTIVE:
			continue
		var lm: Measurement = t.latest_measurement()
		if lm == null:
			continue
		var rng: float = -1.0
		var rng_sig: float = 100.0
		var lrm: Measurement = t.last_valid_range_measurement()
		if lrm != null:
			rng = lrm.measured_range_m
			rng_sig = maxf(lrm.range_sigma_m, 1.0)
		(
			targets
			. append(
				{
					"id": t.track_id,
					"bearing_deg": t.predicted_bearing_at(world.sim_time),
					"bearing_sigma_deg": lm.bearing_sigma_deg,
					"range_m": rng,
					"range_sigma_m": rng_sig,
					"time": lm.timestamp,
					"freqs": lm.detected_frequencies,
				}
			)
		)
		by_id[t.track_id] = t
	var res: Dictionary = ActiveReturnBatch.assign(returns, targets)
	var assigns: Dictionary = res.get("assignments", {})
	var hits: Array = []
	var fed: Array = []
	for i in range(echoes.size()):
		var e: Dictionary = echoes[i]
		var m: Measurement = e["measurement"]
		var t2: Track = null
		var tid: String = str(assigns.get("ret%02d" % i, ""))
		if tid != "":
			t2 = by_id.get(tid)
			if t2 != null:
				tracker.append_group_direct(t2, [m])
		if t2 == null:
			t2 = tracker.mark(m, "P")
			# 全新接触由主动回波直接锚定：range 即初始证据（未归属/歧义同样
			# 建临时接触，供玩家后续确认，不偷用身份裁决）。
			t2.association_confidence = 0.9
			t2.last_association_mode = "range"
		hits.append(e)
		_next_return_seq += 1
		var rid: String = "R%03d" % _next_return_seq
		notify_dirty()
		(
			_records
			. append(
				{
					"local_return_id": rid,
					"ping_id": m.ping_id,
					"measurement": m,
					"track": t2,
					"track_id": t2.track_id,
					"association_score": t2.association_confidence,
					"se_db": m.signal_excess_db,
					"received_time": world.sim_time,
				}
			)
		)
		_next_return_id_trim()
		fed.append({"measurement": m, "track": t2, "summary": e, "local_return_id": rid})
		_append_return_row(m, t2)
	if hits.is_empty():
		last_summary = "无回波"
		_call_status(UiText.t("st_ping_no_return"))
	else:
		var best: Dictionary = hits[0]
		var multi: String = ""
		if hits.size() > 1:
			multi = "（%d 重回波）" % hits.size()
		last_summary = (
			"回波 方位 %.0f° 距离 %.2f 千米 余量%+.0f dB %s"
			% [
				float(best["bearing_deg"]),
				float(best["range_m"]) / 1000.0,
				float(best["se_db"]),
				multi,
			]
		)
		_call_status(str(UiText.t("st_ping_tx")) + " → " + last_summary)
	# PG-03：监听窗关闭 → 统一归属，把"待关联"临时标签替换为最终航迹 id
	#（同一条 Measurement 对象，绝不新增重复证据）；再刷新系统估计。
	last_outcome = "RETURN"
	_resolve_temp_contacts(fed)
	_route_fed_by_mode(fed)
	_refresh_estimates(fed)
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
			_call_status(str(UiText.t("st_active_refit")) + " " + tid)
			if on_fit_requested.is_valid():
				on_fit_requested.call(tid)
		MODE_ASSISTED:
			evidence_state = "PENDING_APPLY"
			# S109 §5.2：待 Apply 对象 = 本次 Ping 全部回波中最高优先者（跨
			# 批次），绝不取"最后写入"——P0-07 修复。
			var cand: Dictionary = _pending_candidate()
			_pending_apply = cand.duplicate() if not cand.is_empty() else primary.duplicate()
			_call_status(str(UiText.t("st_active_apply")) + " " + tid)
		MODE_MANUAL:
			evidence_state = "REFIT_REQUIRED"
			_call_status(str(UiText.t("st_active_manual")) + " " + tid)


## 撤销最近一次自动关联（S1-04C-REQ-03 UI 允许撤销/改绑一次主动回波）：
## 把该测量从 Track 移除并触发刷新回调。ASSISTED 模式下同时撤下待 Apply
## 申请（=Reject），证据状态置 REJECTED。返回是否真的撤销了。
## 撤销最近一条回波记录（等价 undo_return(最新 id)；兼容旧入口）。
func undo_last_association() -> bool:
	if _records.is_empty():
		return false
	return undo_return(str(_records[_records.size() - 1]["local_return_id"]))


## S109 §5.2：按 local_return_id 精确撤销一条主动回波关联——不依赖
## "最后一条"。Undo/Reject 均走本入口。
func undo_return(rid: String) -> bool:
	var idx: int = -1
	for i in range(_records.size()):
		if str(_records[i]["local_return_id"]) == rid:
			idx = i
			break
	if idx < 0:
		return false
	var rec: Dictionary = _records[idx]
	_records.remove_at(idx)
	if str(_pending_apply.get("local_return_id", "")) == rid:
		_pending_apply = {}
	var m: Measurement = rec.get("measurement")
	var t: Track = rec.get("track")
	if m == null or t == null:
		return false
	if not t.remove_measurement(m):
		return false
	evidence_state = "REJECTED"
	if on_assoc_undone.is_valid():
		on_assoc_undone.call(t.track_id)
	return true


## 回波记录只读摘要（测试/面板用；无 target_id 等禁止字段，§2.3）。
func records_snapshot() -> Array:
	var out: Array = []
	for rec in _records:
		var m: Measurement = rec.get("measurement")
		(
			out
			. append(
				{
					"local_return_id": str(rec["local_return_id"]),
					"ping_id": int(rec["ping_id"]),
					"track_id": str(rec["track_id"]),
					"range_m": float(m.measured_range_m) if m != null else -1.0,
				}
			)
		)
	return out


## ASSISTED 待裁决记录的命中 Track id（"" = 无）。
func pending_track_id() -> String:
	var t: Track = _pending_apply.get("track")
	return t.track_id if t != null else ""


## 本次 Ping（最后一条记录的 ping_id）中优先级最高的回波：REQ-02 排序口径
## （preferred 命中 > association_score > se_db）。
func _pending_candidate() -> Dictionary:
	if _records.is_empty():
		return {}
	var pid: int = int(_records[_records.size() - 1]["ping_id"])
	var best: Dictionary = {}
	for rec in _records:
		if int(rec["ping_id"]) != pid:
			continue
		if best.is_empty() or _rec_priority(rec) > _rec_priority(best):
			best = rec
	return best


func _rec_priority(rec: Dictionary) -> float:
	var p: float = 0.0
	if preferred_track_id != "" and str(rec["track_id"]) == preferred_track_id:
		p += 1000000.0
	return p + float(rec["association_score"]) * 1000.0 + float(rec["se_db"])


func _next_return_id_trim() -> void:
	while _records.size() > MAX_RETURNS:
		_records.pop_front()


func has_undo() -> bool:
	return not _records.is_empty()


# ------------------------------------------------------------------
#  S1-04C-REQ-02：TMA 拟合模式控制
# ------------------------------------------------------------------


## 切换拟合模式（AUTO/ASSISTED/MANUAL，规范名 ASSIST/FULL_AUTO 亦接受）。
## PG-01：这就是切**全局**自动化模式（唯一模式源，T21）——卡片与自动化面板
## 不再各持一份状态；落入 MANUAL 时撤下待 Apply 提示但保留证据 → REFIT
## REQUIRED（由 _apply_fit_mode 处理）。
func set_fit_mode(mode: String) -> void:
	var norm: String = _legacy_mode_name(mode)
	if norm == "":
		return
	fit_mode = norm


## PG-01：把规范名/旧名统一成内部词（MANUAL / ASSISTED / AUTO）；未知返回 ""。
static func _legacy_mode_name(mode: String) -> String:
	var up: String = mode.strip_edges().to_upper()
	if up in [MODE_AUTO, MODE_ASSISTED, MODE_MANUAL]:
		return up
	if up in AutomationController.CANON_NAMES:
		return str(AutomationController.MODE_NAMES[AutomationController.from_canon_name(up)])
	return ""


## Take Control：模式切回 MANUAL，保留已有 range 证据（不再自动/半自动改
## Trial，由操作员手动 Auto Fit 后 Accept）。等价 set_fit_mode(MANUAL) +
## 撤掉待 Apply 提示（若有）。
func take_control() -> void:
	fit_mode = MODE_MANUAL


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


## 当前卡片应显示的关联 Track id（最新回波记录；无则 "-"）。
## PG-03：本次监听窗无有效回波时**不显示**上一次的成功关联（避免误解）。
func linked_track_id() -> String:
	if last_outcome == "NO_RETURN" or _records.is_empty():
		return "-"
	var t: Track = _records[_records.size() - 1].get("track")
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
		disabled_reason = UiText.t("ping_unavail_tip")
	elif state != "READY":
		disabled_reason = UiText.t("ping_busy_tip")
	elif not world.can_ping():
		disabled_reason = UiText.t("ping_recharge_tip")
	var params := {
		"mode": "Single pulse",  # 内部键 → UiText.ping_mode 显示
		"freq_khz": world.ping_center_freq_hz() / 1000.0,
		"sl_db": world.ping_sl_db,
		"listen_s": world.ping_listen_window_s,
		"max_range_km": world.ping_max_range_m() / 1000.0,
		"exposure": "HIGH — enemy may intercept",  # → UiText.exposure 显示
	}
	var linked: String = linked_track_id()
	var evidence: String = "已增加主动测距" if linked != "-" else "-"
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
		# PG-03/PG-04：结论说明行（无回波解释 / 系统位置估计档位）。
		"outcome": last_outcome,
		"note": note_text(),
		"temp_contacts": temp_contacts_snapshot(),
	}


## PG-03/PG-04：卡片说明行文本（公开：面板与回归都读同一入口）。
func note_text() -> String:
	if last_outcome == "NO_RETURN":
		return no_return_text()
	var tid: String = linked_track_id()
	var obs: Dictionary = position_estimates.get(tid, {}) if tid != "-" else {}
	return PosEstimateText.format(obs, world.sim_time if world != null else 0.0)


func _call_status(text: String) -> void:
	if on_status.is_valid():
		on_status.call(text)


func notify_dirty() -> void:
	if on_dirty.is_valid():
		on_dirty.call()
