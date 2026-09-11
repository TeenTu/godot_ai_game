class_name WeaponPanelUI
extends VBoxContainer
## weapon_panel.gd — 武器页（S1-11 D-02/§9.3：摘要 + 事件；发射/航线在地图）。
##
## S1-11 D-01/D-02：玩家唯一发射方式是**地图航线**（MAP_ROUTE），本面板不再有
## SOLUTION/BEARING_ONLY/MANUAL 选择器，也不再有浅水攻击/搜索深度/速度模式/
## 搜索半角/搜索图形/主动开机模式/自治授权/引信类型/解保距离/导线开关等底层
## 编辑项（D-08：内核继续执行，玩家不必逐次填写）。本面板只保留：
##   - 已装填数量与水雷摘要（点击摘要行 → 地图选中并居中，AT-26）；
##   - 「绘制航线 / 撤销航点 / 清除航线 / 发射」四个地图动作触发；
##   - 武器事件日志与终局摘要。
## 本面板不持有 Truth own、不直接调用 weapons.fire。

signal fire_requested
signal route_draw_toggled(on: bool)  # S1-11 D-01：进入/退出地图航线绘制
signal route_undo_requested  # 撤销最后一个航路点
signal route_clear_requested  # 清除整条航线
signal summary_row_clicked(torpedo_id: String)  # AT-26：摘要行 → 地图选中
signal status(msg: String)

const MAX_LOG: int = 5

var weapons: WeaponSystem = null
var chart: ChartView = null
var now_time: float = 0.0  # 由 main_ui 每帧注入（脉冲动画/龄期衰减用）
var programmer := LaunchProgrammer.new()  # 发射前编程控制器（内核默认值，不由面板编辑）

var _btn_fire: Button = null
var _chk_route: CheckButton = null  # S1-11 D-01：地图航线绘制开关
var _lbl_route: Label = null  # 航线状态（航路点数 / 可发射性）
var _lbl_fire_hint: Label = null
var _lbl_weapons: Label = null
var _rows: VBoxContainer = null  # 摘要行容器（每枚在水鱼雷一行）
var _row_btns: Dictionary = {}  # torpedo_id -> Button
var _weapon_log: Array = []
var _chart_dirty: Callable = Callable()


func _init() -> void:
	_build()


func _build() -> void:
	_btn_fire = Button.new()
	_btn_fire.text = UiText.t("btn_fire")
	_btn_fire.pressed.connect(func(): fire_requested.emit())
	_btn_fire.disabled = true
	add_child(_btn_fire)
	# S1-11 D-01：玩家唯一发射方式 = 地图航线（起点吸附本艇实测位置，最多
	# 4 个未来航路点）。本面板只负责「触发绘制 + 撤销/清除 + 状态明示」，
	# 绘制与坐标全在地图层。
	var rt_row := HBoxContainer.new()
	rt_row.add_theme_constant_override("separation", 3)
	_chk_route = CheckButton.new()
	_chk_route.text = UiText.t("btn_route_draw")
	_chk_route.add_theme_font_size_override("font_size", 12)
	_chk_route.toggled.connect(func(on: bool): route_draw_toggled.emit(on))
	rt_row.add_child(_chk_route)
	var btn_undo := Button.new()
	btn_undo.text = UiText.t("btn_route_undo")
	btn_undo.add_theme_font_size_override("font_size", 12)
	btn_undo.pressed.connect(func(): route_undo_requested.emit())
	rt_row.add_child(btn_undo)
	var btn_clear := Button.new()
	btn_clear.text = UiText.t("btn_route_clear")
	btn_clear.add_theme_font_size_override("font_size", 12)
	btn_clear.pressed.connect(func(): route_clear_requested.emit())
	rt_row.add_child(btn_clear)
	add_child(rt_row)
	_lbl_route = Label.new()
	_lbl_route.text = UiText.t("route_none")
	_lbl_route.add_theme_font_size_override("font_size", 12)
	_lbl_route.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_route)
	_lbl_fire_hint = Label.new()
	_lbl_fire_hint.text = ""
	_lbl_fire_hint.add_theme_font_size_override("font_size", 12)
	_lbl_fire_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_fire_hint)
	var sum_lbl := Label.new()
	sum_lbl.text = UiText.t("tubes_summary")
	sum_lbl.add_theme_font_size_override("font_size", 13)
	add_child(sum_lbl)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	add_child(_rows)
	_lbl_weapons = Label.new()
	_lbl_weapons.text = UiText.t("tubes_placeholder")
	_lbl_weapons.add_theme_font_size_override("font_size", 12)
	_lbl_weapons.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_weapons)


func bind(p_weapons: WeaponSystem, p_chart: ChartView, p_on_dirty: Callable) -> void:
	weapons = p_weapons
	chart = p_chart
	_chart_dirty = p_on_dirty
	if weapons != null:
		weapons.weapon_event.connect(_on_weapon_event)
	_refresh()


## 发射上下文提示（S1-11 §5.3）：航线就绪度 / 发射拒绝原因 / 在水状态。
func set_fire_context(text: String) -> void:
	if _lbl_fire_hint != null:
		_lbl_fire_hint.text = text


## 航线状态明示（航路点数 / 可发射性 / 当前是否在绘制）。
func set_route_status(text: String) -> void:
	if _lbl_route != null:
		_lbl_route.text = text


## 同步绘制开关（取消/提交后由 main_ui 回写，避免 UI 与地图层状态不一致）。
func set_route_drawing(on: bool) -> void:
	if _chk_route != null and _chk_route.button_pressed != on:
		_chk_route.set_pressed_no_signal(on)


func _on_weapon_event(tid: String, kind: String, detail: Dictionary) -> void:
	# UI-07/08：绝不显示 target_id，绝不即时 CONFIRMED KILL（爆炸证据走 AlertPanel）。
	var txt: String = ""
	match kind:
		"DETONATION":
			txt = UiText.t("evt_detonation_fmt") % [tid, float(detail.get("min_distance_m", -1.0))]
		"SEEKER_PHASE":
			txt = (
				"%s %s %s"
				% [tid, UiText.t("seeker_phase"), UiText.seeker(str(detail.get("state", "")))]
			)
		"TRACK_ACCEPTED":
			txt = UiText.t("evt_track_accepted_fmt") % [tid, str(detail.get("track_id", "?"))]
		"ACTIVE_TX_PING":
			txt = UiText.t("evt_active_ping_fmt") % [tid, str(detail.get("ping_id", ""))]
		"ECHO_RECEIVED":
			txt = UiText.t("evt_echo_fmt") % tid
		"LISTEN_COMPLETE_NO_RETURN":
			txt = UiText.t("evt_listen_no_return_fmt") % tid
		"FUZE_ARMED":
			txt = UiText.t("evt_fuze_armed_fmt") % [tid, float(detail.get("traveled_m", 0.0))]
		"ROUTE_UPDATE":
			txt = UiText.t("evt_route_update_fmt") % tid
		"ROUTE_CLEARED":
			txt = UiText.t("evt_route_cleared_fmt") % tid
		_:
			txt = "%s %s" % [tid, UiText.event(kind)]
	_weapon_log.push_front(txt)
	if _weapon_log.size() > MAX_LOG:
		_weapon_log.pop_back()
	_refresh()


## 每帧轻刷新：管数 / 在水鱼雷 / 海图鱼雷轨迹。
func refresh() -> void:
	_refresh()


func _refresh() -> void:
	if weapons == null or _lbl_weapons == null:
		return
	_lbl_weapons.text = (
		UiText.t("tubes_fmt")
		% [weapons.loaded_count(), weapons.tubes.size(), weapons.torpedoes.size()]
	)
	if _btn_fire != null:
		_btn_fire.disabled = weapons.loaded_count() == 0
	if not _weapon_log.is_empty():
		_lbl_weapons.text += "\n" + "\n".join(_weapon_log)
	_refresh_rows()
	if chart == null:
		return
	var chart_data: Array = []
	for tp in weapons.torpedoes:
		var beam: Dictionary = SeekerBeamState.new_from(tp).to_dict()
		var entry := {
			"trail": tp.trail,
			"state": tp.mission_state_name(),
			"torpedo_id": str(tp.torpedo_id),
			"course_deg": tp.course_deg,
			"wire_state": tp.wire_state_name(),
			"tx_state": tp.active_tx_state_name(),
			"beam": beam,
			"search_center_deg": beam["search_center_true_deg"],
			"search_half_deg": beam["search_half_angle_deg"],
			"fov_half_deg": beam["passive_half_angle_deg"],
			"track_bearing_deg": -1.0,
			"track_sigma_deg": 0.0,
		}
		if tp._seeker != null:
			var sel: SeekerTrack = tp._seeker.selected_track()
			if sel != null:
				entry["track_bearing_deg"] = sel.bearing_estimate_deg
				entry["track_sigma_deg"] = sqrt(maxf(sel.bearing_var_deg2, 0.0))
		chart_data.append(entry)
	chart.torpedoes = chart_data
	chart.now_time = now_time
	chart.queue_redraw()


## AT-26：每枚在水鱼雷一行摘要，点击 → 地图选中并居中（真实 torpedo_id）。
func _refresh_rows() -> void:
	if _rows == null:
		return
	var ids: Array = []
	for tp in weapons.torpedoes:
		ids.append(str(tp.torpedo_id))
	for tid in _row_btns.keys():
		if not (tid as String) in ids:
			(_row_btns[tid] as Button).queue_free()
			_row_btns.erase(tid)
	for tp in weapons.torpedoes:
		var tid2: String = str(tp.torpedo_id)
		if not _row_btns.has(tid2):
			var b := Button.new()
			b.add_theme_font_size_override("font_size", 11)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(func(): summary_row_clicked.emit(tid2))
			_rows.add_child(b)
			_row_btns[tid2] = b
		(_row_btns[tid2] as Button).text = _summary_line(tp)


func _summary_line(tp: RefCounted) -> String:
	var d: Dictionary = tp.depth_estimate_summary()
	return (
		UiText.t("summary_line_fmt")
		% [
			str(tp.torpedo_id),
			UiText.tp_state(str(tp.mission_state_name())),
			UiText.onoff("on" if int(tp.active_tx_state) != Torpedo.ActiveTxState.OFF else "off"),
			UiText.wire(str(tp.wire_state_name())),
			tp.fuel_left_s,
			UiText.depth_band_summary(d),
		]
	)
