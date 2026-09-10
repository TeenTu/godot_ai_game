class_name WeaponPanelUI
extends VBoxContainer
## weapon_panel.gd — 武器发射面板（阶段四，从 main_ui 拆出控制行数）。
##
## 信息链纪律：S1-11 D-01 起玩家唯一发射方式是**地图航线**（MAP_ROUTE），
## 本面板不再有 SOLUTION/BEARING_ONLY/MANUAL 选择器，只发出「触发绘制 /
## 撤销 / 清除 / 发射」请求，执行与联锁仍交由 main_ui → FireExecutor。
## 本面板不持有 Truth own、不直接调用 weapons.fire。

signal fire_requested
signal route_draw_toggled(on: bool)  # S1-11 D-01：进入/退出地图航线绘制
signal route_undo_requested  # 撤销最后一个航路点
signal route_clear_requested  # 清除整条航线
signal status(msg: String)

const MAX_LOG: int = 5
## REQ-01：浅水攻击定深（米）——勾选后发射程序带 initial_depth_m=12。
const SHALLOW_ATTACK_DEPTH_M: float = 12.0

var weapons: WeaponSystem = null
var chart: ChartView = null
var now_time: float = 0.0  # 由 main_ui 每帧注入（脉冲动画/龄期衰减用）
## REQ-B4-01/02：发射前编程控制器（玩家可编辑项 + 推荐默认构建）。
var programmer := LaunchProgrammer.new()

var _btn_fire: Button = null
var _chk_route: CheckButton = null  # S1-11 D-01：地图航线绘制开关
var _lbl_route: Label = null  # 航线状态（航路点数 / 可发射性）
var _chk_shallow: CheckBox = null
var _sel_preset: OptionButton = null
var _lbl_fire_hint: Label = null
var _lbl_prog_notice: Label = null  # REQ-B4-02：推荐默认/授权条件明示
var _lbl_weapons: Label = null
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
	# 4 个未来航路点）。旧 SOLUTION/BEARING_ONLY/MANUAL 选择器随契约作废删除；
	# 本面板只负责「触发绘制 + 撤销/清除 + 状态明示」，绘制与坐标全在地图层。
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
	# REQ-01：浅水攻击定深开关（水面/浅深目标；有限升降速率逼近，非瞬移）。
	_chk_shallow = CheckBox.new()
	_chk_shallow.text = UiText.t("chk_shallow")
	_chk_shallow.button_pressed = false
	_chk_shallow.add_theme_font_size_override("font_size", 12)
	_chk_shallow.toggled.connect(
		func(on: bool):
			if weapons != null:
				weapons.default_attack_depth_m = SHALLOW_ATTACK_DEPTH_M if on else -1.0
	)
	add_child(_chk_shallow)
	# REQ-DEP-02：搜索深度预设 SURFACE/UPPER/LOWER/CUSTOM（浅水数值配置化，
	# 程序侧仍按深度模型/武器限制鈐制）。玩家浅水开关优先于预设。
	_sel_preset = OptionButton.new()
	for i in WeaponProgram.SearchDepthPreset.size():
		_sel_preset.add_item(UiText.depth_preset(WeaponProgram.search_depth_preset_name(i)), i)
	_sel_preset.selected = WeaponProgram.SearchDepthPreset.UPPER
	_sel_preset.add_theme_font_size_override("font_size", 12)
	_sel_preset.item_selected.connect(
		func(i: int):
			if weapons != null:
				weapons.search_depth_preset = i
	)
	add_child(_sel_preset)
	_build_program_editor()
	_lbl_fire_hint = Label.new()
	_lbl_fire_hint.text = ""
	_lbl_fire_hint.add_theme_font_size_override("font_size", 12)
	_lbl_fire_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_fire_hint)
	_lbl_weapons = Label.new()
	_lbl_weapons.text = UiText.t("tubes_placeholder")
	_lbl_weapons.add_theme_font_size_override("font_size", 14)
	_lbl_weapons.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # P1-03.2
	add_child(_lbl_weapons)


func bind(p_weapons: WeaponSystem, p_chart: ChartView, p_on_dirty: Callable) -> void:
	weapons = p_weapons
	chart = p_chart
	_chart_dirty = p_on_dirty
	if weapons != null:
		weapons.weapon_event.connect(_on_weapon_event)
		if _chk_shallow != null:
			weapons.default_attack_depth_m = (
				SHALLOW_ATTACK_DEPTH_M if _chk_shallow.button_pressed else -1.0
			)
		if _sel_preset != null:
			weapons.search_depth_preset = _sel_preset.selected
	_refresh()


## 发射上下文提示（S1-11 §5.3）：航线就绪度 / 发射拒绝原因 / 在水状态。
## Fire 可用性不依赖解，只依赖有装填管（_refresh 内判定）。
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


## REQ-B4-01：完整发射前程序编辑区（搜索扇区/模式、主动/自治授权条件、
## 导线、引信、解保距离、速度模式）。所有项写入 programmer 草稿，Fire 时
## 经 FireExecutor→LaunchProgrammer.build_program 合成不可变程序快照。
func _build_program_editor() -> void:
	var t := Label.new()
	t.text = UiText.t("program_prelaunch")
	t.add_theme_font_size_override("font_size", 13)
	add_child(t)
	_lbl_prog_notice = Label.new()
	_lbl_prog_notice.add_theme_font_size_override("font_size", 11)
	_lbl_prog_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_prog_notice)
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 3)
	_add_lbl(row_a, UiText.t("iw_btn_speed"))
	var sp := OptionButton.new()
	for i in WeaponProgram.SpeedMode.size():
		sp.add_item(UiText.speed_mode(WeaponProgram.speed_mode_name(i)), i)
	sp.select(WeaponProgram.SpeedMode.CRUISE)
	sp.item_selected.connect(func(i: int): programmer.speed_mode = i)
	row_a.add_child(sp)
	_add_lbl(row_a, UiText.t("prog_search_half"))
	var half := SpinBox.new()
	half.min_value = 0.0
	half.max_value = 180.0
	half.step = 5.0
	half.value = 0.0  # 0 = 用推荐默认
	half.value_changed.connect(func(v: float): programmer.search_half_angle_deg = v)
	row_a.add_child(half)
	add_child(row_a)
	var row_b := HBoxContainer.new()
	row_b.add_theme_constant_override("separation", 3)
	_add_lbl(row_b, UiText.t("prog_pattern"))
	var pat := OptionButton.new()
	pat.add_item(UiText.t("auto_label"))
	for i in WeaponProgram.SearchPattern.size():
		pat.add_item(UiText.pattern(str(WeaponProgram.SearchPattern.keys()[i])), i + 1)
	pat.item_selected.connect(func(i: int): programmer.search_pattern = i if i > 0 else -1)
	row_b.add_child(pat)
	_add_lbl(row_b, UiText.t("prog_active"))
	var am := OptionButton.new()
	am.add_item(UiText.t("auto_label"))
	for i in WeaponProgram.ActiveEnableMode.size():
		am.add_item(UiText.enmode(str(WeaponProgram.ActiveEnableMode.keys()[i])), i + 1)
	am.item_selected.connect(func(i: int): programmer.active_enable_mode = i if i > 0 else -1)
	row_b.add_child(am)
	add_child(row_b)
	var row_c := HBoxContainer.new()
	row_c.add_theme_constant_override("separation", 3)
	_add_lbl(row_c, UiText.t("prog_autonomy"))
	var um := OptionButton.new()
	um.add_item(UiText.t("auto_label"))
	for i in WeaponProgram.AutonomyEnableMode.size():
		um.add_item(UiText.enmode(str(WeaponProgram.AutonomyEnableMode.keys()[i])), i + 1)
	um.item_selected.connect(func(i: int): programmer.autonomy_enable_mode = i if i > 0 else -1)
	row_c.add_child(um)
	_add_lbl(row_c, UiText.t("prog_val"))
	var av := SpinBox.new()
	av.min_value = 0.0
	av.max_value = 20000.0
	av.step = 100.0
	av.value = 0.0
	av.value_changed.connect(func(v: float): programmer.autonomy_enable_value = v)
	row_c.add_child(av)
	add_child(row_c)
	var row_d := HBoxContainer.new()
	row_d.add_theme_constant_override("separation", 3)
	_add_lbl(row_d, UiText.t("prog_fuze"))
	var fz := OptionButton.new()
	for f in [
		FuzeController.FUZE_CONTACT,
		FuzeController.FUZE_ACOUSTIC_PROXIMITY,
		FuzeController.FUZE_MAGNETIC_PROXIMITY
	]:
		fz.add_item(UiText.fuze_mode(str(f)))
	fz.item_selected.connect(
		func(i: int):
			programmer.fuze_mode = [
				FuzeController.FUZE_CONTACT,
				FuzeController.FUZE_ACOUSTIC_PROXIMITY,
				FuzeController.FUZE_MAGNETIC_PROXIMITY,
			][i]
	)
	row_d.add_child(fz)
	_add_lbl(row_d, UiText.t("prog_arm"))
	var arm := SpinBox.new()
	arm.min_value = 0.0
	arm.max_value = 5000.0
	arm.step = 50.0
	arm.value = 300.0
	arm.value_changed.connect(func(v: float): programmer.warhead_arm_distance_m = v)
	row_d.add_child(arm)
	var wire := CheckBox.new()
	wire.text = UiText.t("wire_label")
	wire.button_pressed = true
	wire.add_theme_font_size_override("font_size", 11)
	wire.toggled.connect(func(on: bool): programmer.wire_guidance_enabled = on)
	row_d.add_child(wire)
	add_child(row_d)


func _add_lbl(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	parent.add_child(l)


func _on_weapon_event(tid: String, kind: String, detail: Dictionary) -> void:
	# P1-03.6：文案映射与真实事件名一致（SEEKER_PHASE / TRACK_ACCEPTED /
	# WIRE_CUT / ACTIVE_TX_ON/OFF / DETONATION / FUZE_ARMED / ECHO_RECEIVED /
	# LISTEN_COMPLETE_NO_RETURN / AUTONOMY_AUTHORIZED ...），删除已失效的
	# ACQUIRE/ENABLE 特判。UI-07/08：绝不显示 target_id，绝不即时
	# CONFIRMED KILL（爆炸证据走 AlertPanel）。
	var txt: String = ""
	match kind:
		"DETONATION":
			txt = "%s 起爆（最近通过 %.0fm）" % [tid, float(detail.get("min_distance_m", -1.0))]
		"SEEKER_PHASE":
			txt = "%s 导引头 %s" % [tid, UiText.seeker(str(detail.get("state", "")))]
		"TRACK_ACCEPTED":
			txt = "%s 已接受航迹 #%s（辅助）" % [tid, str(detail.get("track_id", "?"))]
		"ACTIVE_TX_PING":
			txt = "%s 主动脉冲 %s 已发射" % [tid, str(detail.get("ping_id", ""))]
		"ECHO_RECEIVED":
			txt = "%s 收到回波" % tid
		"LISTEN_COMPLETE_NO_RETURN":
			txt = "%s 监听结束 — 无回波" % tid
		"FUZE_ARMED":
			txt = "%s 引信已解保（已航行 %.0fm）" % [tid, float(detail.get("traveled_m", 0.0))]
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
	# REQ-B4-02：推荐默认/风险说明明示（含自治授权距离/时间推导）。
	if _lbl_prog_notice != null:
		_lbl_prog_notice.text = programmer.last_notice
	_lbl_weapons.text = (
		"鱼雷管：%d/%d 已装填　在水：%d"
		% [weapons.loaded_count(), weapons.tubes.size(), weapons.torpedoes.size()]
	)
	if _btn_fire != null:
		# S1-11 D-01：随时可发射 = 有装填管 + 有可发射地图航线（main_ui 判定）。
		_btn_fire.disabled = weapons.loaded_count() == 0
	if not _weapon_log.is_empty():
		# P1-03.2：一行一事件（不用长 " | " 拼接），配合 autowrap 不撑宽侧栏。
		_lbl_weapons.text += "\n" + "\n".join(_weapon_log)
	if chart == null:
		return
	var chart_data: Array = []
	for tp in weapons.torpedoes:
		# S1-07 §11.3（Commit 11）：海图叠加——轨迹/任务状态 + 线导连线 +
		# 搜索扇区/Seeker FOV + 选中航迹方位（全部来自己方武器状态与净化摘要）。
		# 评审 P0-10/P1-02：扇区由 SeekerBeamState 单一真源驱动（物理门与
		# 绘制同参数）；地图用真实 torpedo_id（绝不用数组序号）；主动脉冲由
		# tx_state 驱动（不由 ATTACK/TERMINAL 猜测）；±σ 用航迹真实方差。
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
