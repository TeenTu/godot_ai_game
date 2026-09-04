class_name InWaterWeaponPanel
extends VBoxContainer
## in_water_weapon_panel.gd — 在水武器控制台（S1-07 §11.2，Commit 11）。
##
## 每枚在水鱼雷一节：五正交状态（P1-01：Receiver / Transmitter / Track /
## Authority / Steering，逐帧从权威状态刷新，不等 phase 变化）+ 导线/深度/
## 速度/燃料 + 控制按钮。命令失败显示具体原因（tp.last_cmd_reject_reason：
## WIRE CUT / LAUNCHING / NO CANDIDATE / INVALID STATE ...），不是统一
## rejected (CONNECTED)。
##
## P1-03.4：静态 header（标题）保留，动态武器卡只在专用 _cards 容器内重建，
## _rebuild 不再 queue_free 标题。
##
## 信息链纪律：只读己方武器自身状态（合法）；命令只走 Torpedo 线控通道
## （wire CONNECTED 门控）；Seeker 候选来自净化摘要（track_summaries，无
## target_id/Truth）。

var _world: World = null
var _sections: Dictionary = {}  # torpedo_id -> {labels, buttons...}
var _note: Label = null
var _cards: VBoxContainer = null  # P1-03.4：动态武器卡专用容器
var _seen_ids: Array = []


func _init() -> void:
	var title := Label.new()
	title.text = "In-Water Weapons"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_note = Label.new()
	_note.text = "No torpedoes in water"
	_note.add_theme_font_size_override("font_size", 12)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # P1-03.2：不撑宽侧栏
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
		_rebuild(tps)
		_seen_ids = ids
	for tp in tps:
		_refresh_section(tp)
	if tps.is_empty():
		_note.text = "No torpedoes in water"
	else:
		_note.text = ""


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
	var title := Label.new()
	title.text = "--- %s ---" % tid
	title.add_theme_font_size_override("font_size", 13)
	box.add_child(title)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # P1-03.2
	box.add_child(lbl)
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 3)
	box.add_child(row1)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 3)
	box.add_child(row2)
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 3)
	box.add_child(row3)
	var btns := {}
	btns["left"] = _mk_btn(row1, "◀5°", func(): _cmd(tp, "course", -5.0))
	btns["right"] = _mk_btn(row1, "▶5°", func(): _cmd(tp, "course", 5.0))
	btns["upper"] = _mk_btn(row1, "▲Up", func(): _cmd(tp, "band", WeaponProgram.DEPTH_BAND_UPPER))
	btns["lower"] = _mk_btn(row1, "▼Low", func(): _cmd(tp, "band", WeaponProgram.DEPTH_BAND_LOWER))
	btns["speed"] = _mk_btn(row1, "Speed", func(): _cmd(tp, "speed", 0.0))
	btns["active"] = _mk_btn(row2, "Active ON", func(): _cmd(tp, "active", true))
	btns["autonomy"] = _mk_btn(row2, "Autonomy", func(): _cmd(tp, "autonomy", 0.0))
	btns["wireonly"] = _mk_btn(row2, "Wire-Only", func(): _cmd(tp, "wireonly", 0.0))
	btns["accept"] = _mk_btn(row3, "Accept Trk", func(): _cmd(tp, "accept", 0.0))
	btns["cut"] = _mk_btn(row3, "Cut Wire", func(): _cmd(tp, "cut", 0.0))
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
func _cmd(tp: RefCounted, kind: String, arg: Variant) -> void:
	var ok: bool = false
	match kind:
		"course":
			ok = tp.command_course(NavUtils.wrap360(float(tp.course_deg) + float(arg)))
		"band":
			ok = tp.command_depth_band(str(arg))
		"speed":
			var next_mode: int = (int(tp.speed_mode) + 1) % WeaponProgram.SpeedMode.size()
			ok = tp.command_speed_mode(next_mode)
		"active":
			ok = tp.set_active_tx(int(tp.active_tx_state) == Torpedo.ActiveTxState.OFF)
		"autonomy":
			ok = tp.authorize_autonomy()
		"wireonly":
			ok = tp.return_to_wire_only()
		"accept":
			ok = _accept_best_track(tp)
		"cut":
			ok = tp.cut_wire()
	if not ok:
		var reason_v: Variant = tp.get("last_cmd_reject_reason")
		var reason: String = str(reason_v) if reason_v != null else ""
		_note.text = (
			"%s CMD rejected (%s)"
			% [str(tp.torpedo_id), reason if reason != "" else "INVALID TRANSITION"]
		)


## ASSISTED：接受当前最优净化候选（track_summaries 无 Truth）。
func _accept_best_track(tp: RefCounted) -> bool:
	if tp._seeker == null:
		tp.last_cmd_reject_reason = "NO CANDIDATE"
		return false
	var best_id: int = -1
	var best_q: float = -1.0
	for s in tp._seeker.track_summaries():
		if float(s.get("lock_quality", 0.0)) > best_q:
			best_q = float(s.get("lock_quality", 0.0))
			best_id = int(s.get("track_id", -1))
	if best_id < 0:
		tp.last_cmd_reject_reason = "NO CANDIDATE"
		return false
	return tp.accept_seeker_track(best_id)


## 逐帧刷新（P1-01：五正交状态每帧从权威状态读取，绝不在 phase 变化时才刷）。
func _refresh_section(tp: RefCounted) -> void:
	var sec: Dictionary = _sections.get(str(tp.torpedo_id), {})
	if sec.is_empty():
		return
	var lbl: Label = sec["lbl"]
	var btns: Dictionary = sec["btns"]
	var connected: bool = tp.wire_link.accepts_commands() and tp._wire_accepts_command()
	# 五正交状态（P1-01）：Receiver / Transmitter / Track / Authority / Steering。
	var txt: String = (
		"%s\nRecv %s | TX %s\nTrk %s | Auth %s\nSteer %s"
		% [
			tp.mission_state_name(),
			"PASSIVE_ON" if bool(tp.passive_receiver_on) else "PASSIVE_OFF",
			tp.active_tx_state_name(),
			tp.seeker_state_name(),
			tp.guidance_authority_name(),
			str(SeekerBeamState.new_from(tp).steering_source),
		]
	)
	txt += (
		"\nWire %s (%.0fm left) | %s | %.0fkn | fuel %.0fs"
		% [
			tp.wire_state_name(),
			tp.wire_remaining_m(),
			WeaponProgram.speed_mode_name(tp.speed_mode),
			tp.speed_kn,
			tp.fuel_left_s,
		]
	)
	txt += "\nCrs %.0f°" % tp.course_deg
	if tp.commanded_depth_m >= 0.0:
		txt += " → D %.0fm (CMD)" % tp.commanded_depth_m
	else:
		txt += " | D %.0fm" % tp.actual_depth_m
	# P1-03.5：候选出现后显示 track id、bearing、sigma、quality。
	var summaries: Array = tp._seeker.track_summaries() if tp._seeker != null else []
	if not summaries.is_empty():
		var top: Dictionary = summaries[0]
		txt += (
			"\nTrk#%s brg %.0f° σ%.1f° q=%.2f (%d cand)"
			% [
				str(top.get("track_id", "?")),
				float(top.get("bearing_est_deg", 0.0)),
				float(top.get("bearing_sigma_deg", 0.0)),
				float(top.get("lock_quality", 0.0)),
				summaries.size(),
			]
		)
	lbl.text = txt
	# 不可用按钮 disabled（§11.2：说明原因）；P1-03.5：无候选 Accept 禁用。
	var wire_txt: String = tp.wire_state_name()
	for k in btns:
		var b: Button = btns[k]
		if k == "cut":
			b.disabled = not connected
			b.tooltip_text = "Cut wire (only CONNECTED)"
		elif k == "accept":
			b.disabled = not connected or summaries.is_empty()
			b.tooltip_text = (
				"No candidate track" if summaries.is_empty() else "Accept best candidate (ASSISTED)"
			)
		elif k == "active":
			b.text = (
				"Active OFF"
				if int(tp.active_tx_state) != Torpedo.ActiveTxState.OFF
				else "Active ON"
			)
			b.disabled = not connected
			b.tooltip_text = "Active TX requires wire %s" % wire_txt
		else:
			b.disabled = not connected
			b.tooltip_text = "Requires wire CONNECTED (now %s)" % wire_txt
