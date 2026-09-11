class_name InWaterWeaponPanel
extends VBoxContainer
## in_water_weapon_panel.gd — 在水武器控制台（S1-11 Batch 5：摘要列表 + 状态遥测）。
##
## S1-11 §9.1/§9.3/AT-25：玩家武器页不再有左/右 5°、速度循环、授权自主、返回
## 线导、接受航迹；发射方向/航线/深度/主动开机/重画全部移到地图（WeaponMapControl）。
## 本面板只保留：鱼雷标题行（点击 → 地图选中并居中，AT-26）、净化状态遥测
## （五正交状态/导线/燃料/深度/候选），以及「主动开关 / 切断导线」两个安全动作。
##
## 信息链纪律：只读己方武器自身状态（合法）；Seeker 候选来自净化摘要
## （track_summaries，无 target_id/Truth）。

signal row_clicked(torpedo_id: String)

var _world: World = null
var _sections: Dictionary = {}  # torpedo_id -> {lbl, btns...}
var _note: Label = null
var _cards: VBoxContainer = null  # P1-03.4：动态武器卡专用容器
var _seen_ids: Array = []
var _finished: Dictionary = {}
var _tp_refs: Dictionary = {}


func _init() -> void:
	var title := Label.new()
	title.text = UiText.t("in_water_title")
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_note = Label.new()
	_note.text = UiText.t("no_in_water")
	_note.add_theme_font_size_override("font_size", 12)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_note)
	_cards = VBoxContainer.new()
	_cards.add_theme_constant_override("separation", 4)
	add_child(_cards)


func bind(w: World) -> void:
	_world = w


## 每帧同步：鱼雷集合变化时重建（只清 _cards）；状态文本逐帧轻刷新。
func sync() -> void:
	if _world == null or _world.weapons == null:
		return
	var tps: Array = _world.weapons.torpedoes
	var ids: Array = []
	for tp in tps:
		ids.append(str(tp.torpedo_id))
	if str(ids) != str(_seen_ids):
		for tid2 in _seen_ids:
			if not (tid2 as String) in ids and _tp_refs.has(tid2):
				var gone: RefCounted = _tp_refs[tid2]
				if gone.is_dead() and not _finished.has(tid2):
					_finished[tid2] = _final_summary(gone)
		_rebuild(tps)
		_seen_ids = ids
	for tp in tps:
		_tp_refs[str(tp.torpedo_id)] = tp
		_refresh_section(tp)
		if tp.is_dead():
			_finished[str(tp.torpedo_id)] = _final_summary(tp)
	if tps.is_empty():
		if _finished.is_empty():
			_note.text = UiText.t("no_in_water")
		else:
			var last_tid: String = _finished.keys()[-1]
			_note.text = UiText.t("last_weapon_fmt") % [last_tid, _finished[last_tid]]
	else:
		_note.text = ""


## REQ-11：终局摘要（净化事实：脱靶根因 / 最近通过距离 / 结束事件类型）。
func _final_summary(tp: RefCounted) -> String:
	var out: String = UiText.tp_state(str(tp.mission_state_name()))
	if str(tp.miss_reason) != "":
		out += " | " + UiText.t("miss_reason") + "：" + UiText.miss(str(tp.miss_reason))
	if _world != null:
		var mp: Variant = _world._fuze_min_pass.get(str(tp.torpedo_id), null)
		if mp != null and float(mp) < 1.0e8:
			out += " | " + UiText.t("min_pass_fmt") % float(mp)
	return out


func _rebuild(tps: Array) -> void:
	for c in _cards.get_children():
		c.queue_free()
	_sections.clear()
	if tps.is_empty():
		return
	for tp in tps:
		_cards.add_child(_build_section(tp))


func _build_section(tp: RefCounted) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var tid := str(tp.torpedo_id)
	var row_head := HBoxContainer.new()
	row_head.add_theme_constant_override("separation", 4)
	box.add_child(row_head)
	var sel := Button.new()
	sel.text = UiText.t("summary_select") % tid
	sel.add_theme_font_size_override("font_size", 12)
	sel.pressed.connect(func(): row_clicked.emit(tid))
	sel.tooltip_text = UiText.t("summary_select_tip")
	row_head.add_child(sel)
	var btns := {}
	btns["active"] = _mk_btn(
		row_head, UiText.t("iw_btn_active_on"), func(): _cmd(tp, "active", true)
	)
	btns["cut"] = _mk_btn(row_head, UiText.t("iw_btn_cut"), func(): _cmd(tp, "cut", 0.0))
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(lbl)
	_sections[tid] = {"lbl": lbl, "btns": btns}
	return box


func _mk_btn(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


## 命令分发：全部经 Torpedo 线控通道（内部有 _cmd_gate 门控并记录
## last_cmd_reject_reason）。失败时显示具体原因（P1-01）。
## 注：玩家侧的航向/深度/重画/开机点已移至地图（WeaponMapControl），此处只保留
## 主动开关与切断导线；其余 kind 仍保留以兼容测试与开发调用。
func _cmd(tp: RefCounted, kind: String, arg: Variant) -> void:
	if _world != null and not _world.is_mission_running():
		if _note != null:
			_note.text = UiText.reject("MISSION_ENDED")
		return
	var ok: bool = false
	match kind:
		"course":
			ok = tp.command_course(NavUtils.wrap360(float(tp.course_deg) + float(arg)))
		"band":
			ok = tp.command_depth_band(str(arg))
		"depth":
			ok = tp.command_depth(float(arg))
		"active":
			ok = tp.set_active_tx(int(tp.active_tx_state) == Torpedo.ActiveTxState.OFF)
		"cut":
			ok = tp.cut_wire()
	if not ok:
		var reason_v: Variant = tp.get("last_cmd_reject_reason")
		var reason: String = str(reason_v) if reason_v != null else ""
		_note.text = (
			UiText.t("cmd_rejected_fmt")
			% UiText.reject(reason if reason != "" else "INVALID TRANSITION")
		)


## 逐帧刷新（P1-01：五正交状态每帧从权威状态读取）。
func _refresh_section(tp: RefCounted) -> void:
	var sec: Dictionary = _sections.get(str(tp.torpedo_id), {})
	if sec.is_empty():
		return
	var lbl: Label = sec["lbl"]
	var btns: Dictionary = sec["btns"]
	var connected: bool = tp.wire_link.accepts_commands() and tp._wire_accepts_command()
	var txt: String = (
		"%s\n接收机 %s | 发射机 %s\n航迹 %s | 权限 %s\n转向 %s"
		% [
			UiText.tp_state(tp.mission_state_name()),
			UiText.rx("PASSIVE_ON" if bool(tp.passive_receiver_on) else "PASSIVE_OFF"),
			UiText.tx(tp.active_tx_state_name()),
			UiText.seeker(tp.seeker_state_name()),
			UiText.auth(tp.guidance_authority_name()),
			UiText.steer(str(SeekerBeamState.new_from(tp).steering_source)),
		]
	)
	txt += (
		"\n导线 %s（剩 %.0fm）| %s | %.0f节 | 燃料 %.0fs"
		% [
			UiText.wire(tp.wire_state_name()),
			tp.wire_remaining_m(),
			UiText.speed_mode(WeaponProgram.speed_mode_name(tp.speed_mode)),
			tp.speed_kn,
			tp.fuel_left_s,
		]
	)
	txt += "\n航向 %.0f°" % tp.course_deg
	var sat: String = UiText.t("sat_suffix") if bool(tp.turn_saturated) else ""
	txt += (
		"\n转弯指令 %.2f°/s | 实际 %.2f°/s%s"
		% [float(tp.commanded_turn_rate_deg_s), float(tp.actual_turn_rate_deg_s), sat]
	)
	if tp._guidance_mode == tp.GuidanceMode.RATE:
		txt += "\n" + UiText.t("guidance_pn")
	elif tp._guidance_mode == tp.GuidanceMode.COURSE and tp._guidance_course_deg >= 0.0:
		txt += "\n" + UiText.t("guidance_course_fmt") % tp._guidance_course_deg
	if tp.commanded_depth_m >= 0.0:
		var vz: float = float(tp.max_vertical_speed_m_s)
		var eta: float = absf(tp.commanded_depth_m - tp.actual_depth_m) / vz if vz > 0.0 else INF
		var eta_txt: String = "N/A" if is_inf(eta) else "%.0fs" % maxf(eta, 0.0)
		txt += (
			"\n"
			+ (
				UiText.t("depth_cmd_fmt")
				% [tp.commanded_depth_m, UiText.src(str(tp.depth_command_source)), eta_txt]
			)
		)
	else:
		txt += "\n" + UiText.t("depth_actual_fmt") % tp.actual_depth_m
	txt += "\n" + UiText.t("depth_policy_row") % UiText.depth_policy(str(tp.depth_policy()))
	txt += "\n" + UiText.t("fuze_row") % UiText.fuze_state(tp.fuze_state_name())
	# Seeker 深度估计摘要（S1-11 §7.5：只读所锁 SeekerTrack 自己的深度估计摘要）。
	txt += "\n" + UiText.t("depth_est_row") % UiText.depth_band_summary(tp.depth_estimate_summary())
	var summaries: Array = tp._seeker.track_summaries() if tp._seeker != null else []
	var guid_id: int = -1
	if int(tp.guidance_authority) == tp.GuidanceAuthority.AUTONOMOUS and tp._seeker != null:
		guid_id = int(tp._seeker.selected_track_id)
	elif int(tp.guidance_authority) == tp.GuidanceAuthority.ASSISTED:
		guid_id = int(tp._assist_track_id)
	var top: Dictionary = {}
	if guid_id >= 0:
		for s in summaries:
			if int(s.get("track_id", -1)) == guid_id:
				top = s
				break
	if top.is_empty() and not summaries.is_empty():
		top = summaries[0]
	if not top.is_empty():
		txt += (
			"\n%s#%s 方位 %.0f° σ%.1f° 质量 %.2f（%d 候选）"
			% [
				str(UiText.t("iw_trk")),
				str(top.get("track_id", "?")),
				float(top.get("bearing_est_deg", 0.0)),
				float(top.get("bearing_sigma_deg", 0.0)),
				float(top.get("lock_quality", 0.0)),
				summaries.size(),
			]
		)
		if str(tp.miss_reason) != "":
			txt += "\n" + UiText.t("miss_reason") + "：" + UiText.miss(str(tp.miss_reason))
	lbl.text = txt
	var wire_txt: String = tp.wire_state_name()
	for k in btns:
		var b: Button = btns[k]
		if k == "cut":
			b.disabled = not connected
			b.tooltip_text = UiText.t("tip_cut_wire")
		else:
			b.text = (
				UiText.t("iw_btn_active_off")
				if int(tp.active_tx_state) != Torpedo.ActiveTxState.OFF
				else UiText.t("iw_btn_active_on")
			)
			b.disabled = not connected
			b.tooltip_text = UiText.t("iw_tx_tip") % UiText.wire(wire_txt)
