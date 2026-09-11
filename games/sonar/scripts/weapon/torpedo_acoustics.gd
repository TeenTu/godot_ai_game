class_name TorpedoAcoustics
extends RefCounted
## torpedo_acoustics.gd — S1-11：鱼雷声学采样/回波/噪声/放线链（从 torpedo.gd 拆出）。
##
## 纯转发：全部状态仍在 Torpedo 自身字段上读写（tp 入参），本类不持有引用、
## 不读 Truth。拆分只为把 torpedo.gd 压回 gdlint 1200 行上限以内。


## 航行噪声：按周期广播，源级随速度模式。
static func advance_running_noise(tp, dt: float) -> void:
	if not tp._in_water():
		return
	tp._noise_timer_s -= dt
	if tp._noise_timer_s > 0.0:
		return
	tp._noise_timer_s = tp.RUNNING_NOISE_CADENCE_S
	(
		tp
		. _emitter
		. running_noise(
			Vector3(tp.pos_east_m, tp.pos_north_m, tp.actual_depth_m),
			tp._sim_time,
			WeaponProgram.speed_mode_name(tp.speed_mode),
			tp.RUNNING_NOISE_CADENCE_S,
		)
	)


## 放线推进（§5.4）：超长且 break_on_excess_length → BROKEN → fallback。
static func advance_wire(tp, dt: float, v_ms: float) -> bool:
	if not tp._in_water():
		return false
	if not tp.wire_link.update(dt, v_ms):
		return false
	(
		tp
		. event_occurred
		. emit(
			tp.torpedo_id,
			"WIRE_BROKEN",
			{
				"paid_out_m": tp.wire_link.paid_out_m,
				"max_length_m": tp.wire_link.max_length_m,
			},
		)
	)
	tp._enter_fallback()
	return true


## 被动按周期经 adapter 采样；miss 帧无 return；adapter 为 null 时跳过。
static func advance_seeker_passive(tp, dt: float, sim_time: float) -> void:
	if tp._sensor_adapter == null or not tp.passive_receiver_on:
		return
	if not tp._in_water():
		return
	tp._passive_sample_timer_s -= dt
	if tp._passive_sample_timer_s > 0.0:
		return
	tp._passive_sample_timer_s = tp.PASSIVE_SAMPLE_INTERVAL_S
	var returns: Array = (
		tp
		. _sensor_adapter
		. sample_passive(
			tp.pos_east_m,
			tp.pos_north_m,
			tp.actual_depth_m,
			tp.speed_kn,
			tp.course_deg,
			tp.acoustic_profile,
			sim_time,
		)
	)
	record_seeker_returns(tp, returns)
	if tp._seeker != null:
		tp._seeker.notify_passive_scan(sim_time)


## 主动回波：adapter 到点结算的 ACTIVE return 收集。
static func collect_active_returns(tp, sim_time: float) -> void:
	if tp._sensor_adapter == null:
		return
	if not tp._in_water():
		return
	var returns: Array = (
		tp
		. _sensor_adapter
		. collect_due_active_returns(
			tp.torpedo_id,
			tp.pos_east_m,
			tp.pos_north_m,
			tp.actual_depth_m,
			tp.speed_kn,
			tp.acoustic_profile,
			sim_time,
		)
	)
	record_seeker_returns(tp, returns)
	for r in returns:
		var pid := str(r.ping_id)
		if pid != "" and tp._active_pings_outstanding.has(pid):
			tp._active_pings_outstanding[pid]["heard"] = true
			tp.event_occurred.emit(tp.torpedo_id, "ECHO_RECEIVED", {"ping_id": pid})
	var listen_window: float = tp._sensor_adapter.active_listen_window_s
	var done: Array = []
	var unheard_emit_ts: Array = []
	for pid2 in tp._active_pings_outstanding:
		var rec: Dictionary = tp._active_pings_outstanding[pid2]
		if sim_time - float(rec["emit_t"]) > listen_window:
			done.append(pid2)
			if not bool(rec["heard"]):
				tp.event_occurred.emit(
					tp.torpedo_id, "LISTEN_COMPLETE_NO_RETURN", {"ping_id": pid2}
				)
				unheard_emit_ts.append(float(rec["emit_t"]))
	for pid3 in done:
		tp._active_pings_outstanding.erase(pid3)
	if tp._seeker != null:
		for emit_t in unheard_emit_ts:
			tp._seeker.notify_active_miss(sim_time, emit_t)


## 净化 return 记录 + 喂 Seeker 航迹机（拒绝 OWN/FRIENDLY 接管）。
static func record_seeker_returns(tp, returns: Array) -> void:
	var eligible: Array = []
	for r in returns:
		var tok: String = str(r.source_token)
		if tok == "OWN" or tok == "FRIENDLY":
			tp.event_occurred.emit(tp.torpedo_id, "CONTACT_REJECTED_SAFETY", {"source_token": tok})
			continue
		tp.seeker_returns.append(r)
		eligible.append(r)
	while tp.seeker_returns.size() > 256:
		tp.seeker_returns.pop_front()
	if tp._seeker != null and not eligible.is_empty():
		tp._seeker.process_returns(eligible, tp._sim_time)


## 主动 Ping：TOF/回波由 adapter 按 tau=2R/c 延迟结算；唯一 ping_id 串联事件。
static func emit_active_ping(tp) -> void:
	tp._ping_seq += 1
	var pid: String = "%s-P%03d" % [tp.torpedo_id, tp._ping_seq]
	tp._active_pings_outstanding[pid] = {"emit_t": tp._sim_time, "heard": false}
	tp.event_occurred.emit(tp.torpedo_id, "ACTIVE_TX_PING", {"ping_id": pid})
	tp._emitter.active_ping(
		Vector3(tp.pos_east_m, tp.pos_north_m, tp.actual_depth_m), tp._sim_time, pid
	)
	if tp._sensor_adapter != null:
		(
			tp
			. _sensor_adapter
			. schedule_active_echoes(
				tp.torpedo_id,
				tp.pos_east_m,
				tp.pos_north_m,
				tp.course_deg,
				tp.acoustic_profile,
				tp._sim_time,
				pid,
				tp.actual_depth_m,
				tp.speed_kn,
			)
		)
