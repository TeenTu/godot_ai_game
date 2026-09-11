class_name SonarUI
extends Control
## main_ui.gd — 主 UI 装配与仿真驱动（脏标记重建；Truth 仅 Show Truth 进海图）。
const PANEL_W: float = 280.0
const BT_H: float = 240.0
const RES_H: float = 150.0

const DIAG_CLOSED: int = 0
const DIAG_BT: int = 1
const DIAG_RESIDUAL: int = 2
const DIAG_SPLIT: int = 3

var world: World = null
var tracker: Tracker = null
var trial: TrialSolution = null
var system_sol: SystemSolution = null
var dot_stack: DotStack = null
var last_fit: Dictionary = {}  # 视图别名：当前选中 Contact 的 Fit（REQ-B1-03）
# REQ-B1-01/03/04：per-Track 上下文控制器 + 显式 Mark 组/发射模式状态。
var fcc := FireControlContext.new()
var mark_flow := MarkFlow.new()
var fire_exec := FireExecutor.new()
var mark_panel: MarkGroupPanel = null
var selected_track_id: String = ""
var op: OperatorSonar = null  # Sonar Operator Layer（Truth 只进这里）
var _op_panel: OperatorPanel = null
var _pager: RightSidebarPager = null  # S109 §8 右栏分页（固定顶栏+四页）
var _ctx_actions: ChartContextActions = null  # S109 §9.3 海图右键菜单动作
var _threat_hud: ThreatHud = null  # §8.3 顶栏固定告警条（banner-only）
var _threat_list: ThreatHud = null  # 航迹页威胁列表（list-only）
var _ping_ctrl: ActivePingController = null  # S1-04 主动 Ping 接线（拆出，控行数）

var _chart: ChartView = null
var _bearing: BearingDisplay = null
var _bt_plot: BearingTimePlot = null
var _res_plot: ResidualPlot = null
var _diag_box: VBoxContainer = null  # 包裹两个诊断图的底部容器
var _diag_mode: int = DIAG_BT  # 默认只显示 BT（需求§一.1）
var _contact_rows_box: VBoxContainer = null  # 接触按钮动态容器（航迹页）
var _lbl_time: Label = null  # S109 §8.1 顶栏任务时间

var _btn_pause: Button = null
var _lbl_status: Label = null
var _btn_show_truth: Button = null
var _btn_mark: Button = null
var _btn_fit: Button = null
var _btn_enter: Button = null
var _weapon_panel: WeaponPanelUI = null
var _lbl_selected: Label = null
var _lbl_tma: Label = null
var _sec_fit: VBoxContainer = null
var _spin_bearing: SpinBox = null
var _spin_range: SpinBox = null
var _spin_course: SpinBox = null
var _spin_speed: SpinBox = null
var _own_panel: OwnManeuverPanel = null  # 本艇机动/深度控制簇（拆出控行数）
var _in_water_panel: InWaterWeaponPanel = null  # §11.2 在水武器控制台
var _cm_panel: CountermeasurePanel = null  # §8.5 诱饵面板
var _alert_panel: AlertPanel = null  # §11.5 告警/战果证据
var _depth_bar: DepthBandDisplay = null  # §11.4 侧边深度条
var _contact_rows: Dictionary = {}  # track_id -> Button
var _chk_layers: Dictionary = {}  # layer key -> CheckButton

var _time_scale: float = 2.0
var _sim_accum: float = 0.0
var _paused: bool = false
var _processed_meas: int = 0
var _track_colors: Dictionary = {}  # track_id -> Color
var _dirty: bool = true
var _last_meas_count: int = -1
var _lowq_confirmed: bool = false
var _own_track_pts: Array = []
var _scenario_name: String = ""  # P0-08 实际加载的场景名
var _game_over: GameOverOverlay = null  # REQ-B5-04 终局覆盖层
var _towed := TowedUi.new()  # S1-03 拖曳阵操作胶水（拆出控行数）
var _route_overlay: MapRouteOverlay = null  # S1-11 D-01 地图航线绘制层（由 _wmc 持有）
var _wmc: WeaponMapControl = null  # S1-11 Batch 5：地图武器交互总控
var _wire_depth: WireDepthRelay = WireDepthRelay.new()  # S1-11 §7.5 导线深度回传中继


func _ready() -> void:
	var vp: Vector2 = get_viewport_rect().size
	theme = load("res://assets/fonts/ui_theme.tres")
	set_size(vp)
	resized.connect(_on_self_resized)
	_build_ui()

	world = World.new()
	# P0-08：场景解析（默认旧被动教程；SONAR_SCENARIO 可选 s1_combat）。
	_scenario_name = UiContract.resolve_scenario_name()
	var scenario: Dictionary = ConfigLoader.load_scenario(_scenario_name)
	var seed_ov: int = UiContract.resolve_seed_override()
	if seed_ov >= 0:
		scenario["seed"] = seed_ov  # REQ-AI-01：StartMenu 指定 seed 优先于 JSON
	world.load_scenario(scenario)
	world.set_time_scale(_time_scale)

	tracker = Tracker.new()
	var rng: RandomNumberGenerator = world.world.get("rng", null)
	if rng != null:
		tracker.set_rng(rng)
	tracker.set_capacity(8)
	tracker.set_auto_interval(5.0)

	_ping_ctrl = ActivePingController.new()
	_ping_ctrl.world = world
	_ping_ctrl.tracker = tracker
	_ping_ctrl.on_status = _update_status
	_ping_ctrl.on_dirty = func(): _dirty = true
	_ping_ctrl.on_echo_hits = _on_ping_echo_hits
	_ping_ctrl.on_fit_requested = _on_ping_fit_requested
	_ping_ctrl.on_assoc_undone = func(_tid: String):
		_dirty = true
		_update_status(UiText.t("st_undo"))

	world.auto_measurements = false
	op = OperatorSonar.new()
	op.setup(world.world)
	mark_flow.tracker = tracker
	mark_flow.op = op
	mark_flow.world = world
	fire_exec.fcc = fcc
	fire_exec.tracker = tracker
	if _op_panel != null:
		_op_panel.set_towed_available(op.towed_available())
	# S1-03：拖曳阵操作胶水（信号 → 世界命令 + 状态行），从本文件拆出控行数。
	_towed.world = world
	_towed.op = op
	_towed.op_panel = _op_panel
	_towed.status = _update_status

	trial = TrialSolution.new()
	system_sol = null
	dot_stack = DotStack.new()

	if _weapon_panel != null and world.weapons != null:
		_weapon_panel.bind(world.weapons, _chart, func(): _dirty = true)
		_weapon_panel.set_fire_context("")  # 初值：航线状态行已给"未绘制"，不重复一行
	# S1-11 Batch 5：地图武器总控注入 world / fire_exec（发射链与地图命令）。
	if _wmc != null:
		_wmc.setup(self, world, _chart, fire_exec)
	# S1-11 §7.5：导线深度回传台账按任务复位。
	_wire_depth.reset()

	if _own_panel != null:
		_own_panel.bind_world(world)
	if _in_water_panel != null:
		_in_water_panel.bind(world)
	if _cm_panel != null:
		_cm_panel.bind(world)
	if _alert_panel != null:
		_alert_panel.bind(world, Callable(self, "_alert_track_bearings"))
	if _depth_bar != null:
		_depth_bar.bind(world, tracker)

	# REQ-B5-04：Game Over 覆盖层（终局锁定 + 同 seed 重玩 / 回主菜单）。
	_game_over = GameOverOverlay.new()
	add_child(_game_over)
	_game_over.restart_requested.connect(_on_game_restart)
	_game_over.menu_requested.connect(_on_game_menu)
	world.mission_ended.connect(
		func(result: Dictionary):
			_game_over.show_result(result, _scenario_name, UiContract.resolve_seed_override())
	)

	_update_status(UiText.t("st_ready"))


func _on_game_restart() -> void:
	get_parent().call_deferred("_on_start", _scenario_name, UiContract.resolve_seed_override())


func _on_game_menu() -> void:
	get_parent().call_deferred("_show_menu")


func _on_self_resized() -> void:
	pass


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size = size
	root.position = Vector2.ZERO
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var main_row := HBoxContainer.new()
	main_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_theme_constant_override("separation", 4)
	root.add_child(main_row)

	_bearing = BearingDisplay.new()
	_bearing.custom_minimum_size = Vector2(200, 0)
	main_row.add_child(_bearing)

	_chart = ChartView.new()
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chart.tick_selected.connect(_on_tick_selected)
	_chart.threat_selected.connect(_on_threat_selected)
	# S1-11 §4.3：地图点击选中鱼雷 → 浮动控制栏。
	_chart.torpedo_selected.connect(_on_map_torpedo_selected)
	# S1-11 §5.3/D-01：地图武器交互总控（发射前航线绘制 + 在水鱼雷地图控制）。
	# 覆盖在海图上，空闲时不挡地图交互（不侵入 ChartView 的 _draw）。
	_wmc = WeaponMapControl.new()
	_wmc.setup(self, null, _chart, fire_exec)
	_wmc.status.connect(_update_status)
	_wmc.route_state_changed.connect(_on_route_changed)
	_route_overlay = _wmc.route_overlay
	_chart.add_child(_wmc)
	main_row.add_child(_chart)
	_depth_bar = DepthBandDisplay.new()
	main_row.add_child(_depth_bar)

	# S109 §8：右栏 = 固定顶栏 + 四页（P1-03.1 宽度契约鈐制在 _process 里施加于 _pager）。
	_pager = RightSidebarPager.new()
	_pager.custom_minimum_size = Vector2(UiContract.SIDEBAR_PREF_W, 0)
	_pager.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_pager.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_child(_pager)

	_build_sidebar()
	_ctx_actions = ChartContextActions.new()  # S109 §9：右键菜单（复用命令门）
	_ctx_actions.setup(self, _chart, _pager)
	_build_bottom(root)


## S109 §8 右栏：固定顶栏（时间/暂停/倍速 + 选中摘要 + 告警条）+ 四页。
func _build_sidebar() -> void:
	var title := Label.new()
	title.text = UiText.t("app_title")
	title.add_theme_font_size_override("font_size", 18)
	_pager.top_bar.add_child(title)
	_lbl_time = Label.new()
	_lbl_time.text = "T+0s"
	_pager.time_row.add_child(_lbl_time)
	_btn_pause = Button.new()
	_btn_pause.text = UiText.t("pause")
	_btn_pause.pressed.connect(_on_pause)
	_pager.time_row.add_child(_btn_pause)
	var spd_lbl := Label.new()
	spd_lbl.text = UiText.t("speed")
	_pager.time_row.add_child(spd_lbl)
	var opt_speed := OptionButton.new()
	for s in [1, 2, 4, 8]:
		opt_speed.add_item("%dx" % s)
	opt_speed.select(1)
	opt_speed.item_selected.connect(_on_speed)
	_pager.time_row.add_child(opt_speed)
	# §8.3 固定信息：选中摘要 + 最高优先级来袭鱼雷告警条（不随切页消失）。
	_lbl_selected = Label.new()
	_lbl_selected.text = UiText.t("selected_none")
	_lbl_selected.add_theme_font_size_override("font_size", 16)
	_pager.selection_slot.add_child(_lbl_selected)
	_threat_hud = ThreatHud.install(_pager.alert_slot, _chart, true, false)
	_build_sonar_page(_pager.add_page("sonar", UiText.t("page_sonar")))
	_build_tactics_page(_pager.add_page("tactics", UiText.t("page_tactics")))
	_build_weapons_page(_pager.add_page("weapons", UiText.t("page_weapons")))
	_pager.select("sonar")


## 页面一声呐：Operator 控制面板（阵列/瀑布图设置/拖曳阵/主动声呐）。
func _build_sonar_page(pg: VBoxContainer) -> void:
	var op_sec := UiSection.make(UiText.t("sec_sonar_operator"))
	_op_panel = OperatorPanel.new()
	UiSection.body(op_sec).add_child(_op_panel)
	_op_panel.mark_requested.connect(_on_op_mark)
	_op_panel.array_changed.connect(
		func(aid: String):
			op.set_array(aid)
			_update_status(UiText.t("st_array_to") + " " + aid)
	)
	_op_panel.autocrew_toggled.connect(
		func(on: bool):
			_update_status(UiText.t("st_autocrew_on") if on else UiText.t("st_autocrew_off"))
	)
	_op_panel.towed_deploy_requested.connect(_towed.on_deploy)
	_op_panel.towed_retract_requested.connect(_towed.on_retract)
	_op_panel.towed_hold_requested.connect(_towed.on_hold)
	_op_panel.towed_length_commanded.connect(_towed.on_length_commanded)
	_op_panel.ping_requested.connect(_on_ping_requested)
	_op_panel.active_undo_requested.connect(_on_active_undo)
	_op_panel.active_return_selected.connect(_on_active_return_selected)
	_op_panel.active_fit_mode_requested.connect(func(m: String): _ping_ctrl.set_fit_mode(m))
	_op_panel.active_take_control_requested.connect(func(): _ping_ctrl.take_control())
	_op_panel.active_apply_requested.connect(func(): _ping_ctrl.apply_pending())
	pg.add_child(op_sec)


## 页面二战术：接触卡/威胁列表 + Mark 组 + Fit/Trial + 本艇机动与图层（S109 §8.2 / S1-11 D-18）。
func _build_tactics_page(pg: VBoxContainer) -> void:
	_btn_mark = Button.new()
	_btn_mark.text = UiText.t("btn_mark")
	_btn_mark.pressed.connect(_on_mark)
	pg.add_child(_btn_mark)
	_build_contact_list(pg)
	_threat_list = ThreatHud.install(pg, _chart, false, true)
	mark_panel = MarkGroupPanel.new()  # REQ-B1-01/05：Mark 组/Remove/Reassign/Undo
	mark_panel.association_changed.connect(
		func(m: String):
			mark_flow.association_mode = m
			_update_status(UiText.t("st_assoc_mode") + " " + UiText.assoc(m))
	)
	mark_panel.active_group_changed.connect(
		func(g: String):
			mark_flow.active_group_id = g
			_update_status(UiText.t("st_mark_group") + (g if g != "" else UiText.t("auto_pick")))
	)
	mark_panel.flow = mark_flow
	mark_panel.selected_provider = func() -> String: return selected_track_id
	mark_panel.operation_result.connect(_on_mark_operation)
	var m_sec := UiSection.make(UiText.t("sec_mark_groups"))
	UiSection.body(m_sec).add_child(mark_panel)
	pg.add_child(m_sec)
	_btn_fit = Button.new()
	_btn_fit.text = UiText.t("btn_auto_fit")
	_btn_fit.pressed.connect(_on_fit_tma)
	pg.add_child(_btn_fit)
	_lbl_tma = Label.new()
	_lbl_tma.text = UiText.t("no_fit_yet")
	_lbl_tma.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_tma.add_theme_font_size_override("font_size", 14)
	_sec_fit = UiSection.make(UiText.t("sec_fit_details"))
	UiSection.body(_sec_fit).add_child(_lbl_tma)
	pg.add_child(_sec_fit)
	_btn_enter = Button.new()
	_btn_enter.text = UiText.t("btn_accept_system")
	_btn_enter.pressed.connect(_on_enter_solution)
	pg.add_child(_btn_enter)
	var tma_title := Label.new()
	tma_title.text = UiText.t("trial_params")
	tma_title.add_theme_font_size_override("font_size", 15)
	pg.add_child(tma_title)
	_spin_bearing = UiSection.spin_row(pg, UiText.t("spin_bearing"), 0, 359, 1, 0)
	_spin_range = UiSection.spin_row(pg, UiText.t("spin_range"), 100, 50000, 100, 0)
	_spin_course = UiSection.spin_row(pg, UiText.t("spin_course"), 0, 359, 1, 0)
	_spin_speed = UiSection.spin_row(pg, UiText.t("spin_speed"), 0, 40, 0.5, 0)
	_spin_bearing.value_changed.connect(func(v): trial.set_bearing(v))
	_spin_range.value_changed.connect(func(v): trial.set_range(v))
	_spin_course.value_changed.connect(func(v): trial.set_course(v))
	_spin_speed.value_changed.connect(func(v): trial.set_speed(v))
	_build_own_page(pg)  # S1-11 D-18：本艇页并入战术页，不再有第四个顶级页


## 页面三武器：发射管/编程、在水武器、诱饵、战果评估（S109 §8.2）。
func _build_weapons_page(pg: VBoxContainer) -> void:
	_weapon_panel = WeaponPanelUI.new()
	pg.add_child(_weapon_panel)
	_weapon_panel.fire_requested.connect(_on_fire_torpedo)
	_weapon_panel.route_draw_toggled.connect(_on_route_draw_toggled)
	_weapon_panel.route_undo_requested.connect(_on_route_undo)
	_weapon_panel.route_clear_requested.connect(_on_route_clear)
	# S1-11 §9.3/AT-26：摘要行点击 → 地图选中并居中该鱼雷（武器页只读摘要）。
	_weapon_panel.summary_row_clicked.connect(_on_summary_row_clicked)
	fire_exec.programmer = _weapon_panel.programmer  # REQ-B4-01 发射前编程
	_in_water_panel = InWaterWeaponPanel.new()
	pg.add_child(_in_water_panel)
	_in_water_panel.row_clicked.connect(_on_summary_row_clicked)
	_cm_panel = CountermeasurePanel.new()
	_cm_panel.status.connect(func(m: String): _update_status(m))
	pg.add_child(_cm_panel)
	_alert_panel = AlertPanel.new()  # §11.5 告警/战果评估
	pg.add_child(_alert_panel)


## 页面四本艇：状态/自动化/机动、镜头与图层、开发选项（S109 §8.2）。
func _build_own_page(pg: VBoxContainer) -> void:
	_lbl_status = Label.new()
	_lbl_status.text = ""
	_lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_status.add_theme_font_size_override("font_size", 14)
	var sec_status := UiSection.make(UiText.t("sec_status"))
	UiSection.body(sec_status).add_child(_lbl_status)
	pg.add_child(sec_status)
	var auto_panel := AutomationPanelUI.new()
	auto_panel.bind(tracker, _auto_refit_track, world)
	var auto_sec := UiSection.make(UiText.t("sec_automation"))
	UiSection.body(auto_sec).add_child(auto_panel)
	pg.add_child(auto_sec)
	_own_panel = OwnManeuverPanel.new()
	pg.add_child(_own_panel)
	var cam_title := Label.new()
	cam_title.text = UiText.t("cam_view")
	cam_title.add_theme_font_size_override("font_size", 15)
	pg.add_child(cam_title)
	var row_cam := HBoxContainer.new()
	row_cam.add_theme_constant_override("separation", 4)
	pg.add_child(row_cam)
	var btn_reset := Button.new()
	btn_reset.text = UiText.t("btn_reset_view")
	btn_reset.pressed.connect(func(): _chart.reset_view())
	row_cam.add_child(btn_reset)
	var btn_frame := Button.new()
	btn_frame.text = UiText.t("btn_auto_frame")
	btn_frame.pressed.connect(func(): _chart.auto_frame())
	row_cam.add_child(btn_frame)
	var chk_all_lob := CheckButton.new()
	chk_all_lob.text = UiText.t("chk_all_lob")
	chk_all_lob.toggled.connect(func(on: bool): _chart.show_all_lobs = on)
	pg.add_child(chk_all_lob)
	# REQ-B3-03：Selected Track only / All Tracks 切换（默认突出当前 Track）。
	var chk_sel_only := CheckButton.new()
	chk_sel_only.text = UiText.t("chk_sel_only")
	chk_sel_only.toggled.connect(func(on: bool): _chart.show_selected_only = on)
	pg.add_child(chk_sel_only)
	_build_layer_toggles(pg)
	_btn_show_truth = Button.new()
	_btn_show_truth.text = UiText.t("btn_show_truth")
	_btn_show_truth.toggle_mode = true
	_btn_show_truth.toggled.connect(_on_show_truth)
	pg.add_child(_btn_show_truth)


func _build_contact_list(pg: Control) -> void:
	var ct_title := Label.new()
	ct_title.text = UiText.t("contacts_title")
	ct_title.add_theme_font_size_override("font_size", 15)
	pg.add_child(ct_title)
	_contact_rows_box = VBoxContainer.new()
	pg.add_child(_contact_rows_box)
	ContactCard.install(pg, self)  # S1-11 D-17：接触卡仅四个直接动作 + 详情折叠


func _build_layer_toggles(pg: Control) -> void:
	var lt := Label.new()
	lt.text = UiText.t("layers")
	lt.add_theme_font_size_override("font_size", 15)
	pg.add_child(lt)
	for key in ["lob", "sigma", "fit", "alt", "trial", "system", "truth", "threat"]:
		var cb := CheckButton.new()
		cb.text = UiText.t("legend_alt") if key == "alt" else UiText.t("legend_" + key)
		cb.button_pressed = bool(_chart.layers.get(key, true))
		cb.toggled.connect(_on_layer_toggle.bind(key))
		pg.add_child(cb)
		_chk_layers[key] = cb
	var ob := OptionButton.new()
	ob.add_item(UiText.t("bt_local"))
	ob.add_item(UiText.t("bt_360"))
	ob.item_selected.connect(
		func(i: int):
			_bt_plot.overview_mode = i == 1
			_bt_plot.queue_redraw()
	)
	pg.add_child(ob)

	var diag_lbl := Label.new()
	diag_lbl.text = UiText.t("diagnostics")
	diag_lbl.add_theme_font_size_override("font_size", 15)
	pg.add_child(diag_lbl)
	var diag_ob := OptionButton.new()
	diag_ob.add_item(UiText.t("diag_closed"))
	diag_ob.add_item(UiText.t("diag_bt"))
	diag_ob.add_item(UiText.t("diag_residual"))
	diag_ob.add_item(UiText.t("diag_split"))
	diag_ob.select(DIAG_BT)
	diag_ob.item_selected.connect(_set_diag_mode)
	pg.add_child(diag_ob)


func _build_bottom(root: VBoxContainer) -> void:
	_diag_box = VBoxContainer.new()
	_diag_box.add_theme_constant_override("separation", 0)
	root.add_child(_diag_box)

	_bt_plot = BearingTimePlot.new()
	_bt_plot.custom_minimum_size = Vector2(0, BT_H)
	_bt_plot.hover_changed.connect(_on_hover_changed)
	_bt_plot.mouse_exited.connect(_bt_plot.mouse_exited_notify)
	_diag_box.add_child(_bt_plot)

	_res_plot = ResidualPlot.new()
	_res_plot.custom_minimum_size = Vector2(0, RES_H)
	_res_plot.hover_changed.connect(_on_hover_changed)
	_res_plot.mouse_exited.connect(_res_plot.mouse_exited_notify)
	_diag_box.add_child(_res_plot)

	_apply_diag_mode()


## 按 _diag_mode 应用底部诊断区可见性（plot 内数据不随隐藏丢失）。
func _apply_diag_mode() -> void:
	if _diag_box == null or _bt_plot == null or _res_plot == null:
		return
	match _diag_mode:
		DIAG_CLOSED:
			_diag_box.visible = false
		DIAG_BT:
			_diag_box.visible = true
			_bt_plot.visible = true
			_res_plot.visible = false
		DIAG_RESIDUAL:
			_diag_box.visible = true
			_bt_plot.visible = false
			_res_plot.visible = true
		DIAG_SPLIT:
			_diag_box.visible = true
			_bt_plot.visible = true
			_res_plot.visible = true
	queue_redraw()


func _set_diag_mode(mode: int) -> void:
	_diag_mode = mode
	_apply_diag_mode()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.06, 0.08, 1.0))


func _process(delta: float) -> void:
	if world == null:
		return
	var dt: float = world.world["dt"]
	_sim_accum += delta * _time_scale
	var steps: int = 0
	while _sim_accum >= dt and steps < 500:
		world.tick()
		_sim_accum -= dt
		steps += 1

	_feed_new_measurements()
	_op_step()
	if world.measurements.size() != _last_meas_count:
		_last_meas_count = world.measurements.size()
		_dirty = true
	if _dirty:
		_rebuild_display_data()
	if _weapon_panel != null:
		_weapon_panel.now_time = world.sim_time
		_weapon_panel.refresh()
	if _in_water_panel != null:
		_in_water_panel.sync()
	if _wmc != null:
		_wmc.refresh()
	# S1-11 §7.5/AT-32：鱼雷导线回传 → 所关联接触的深度概率（断线自动停）。
	_wire_depth.advance(world, tracker, world.sim_time)
	if _cm_panel != null:
		_cm_panel.sync()
	if _alert_panel != null:
		_alert_panel.sync()
	if _depth_bar != null:
		_depth_bar.sync()
	_update_displays_light()
	_update_panel()
	if _pager != null:  # P1-03.1 侧栏宽度契约鈐制（S109：施加于分页器）
		_pager.size.x = UiContract.sidebar_clamp_x(_pager.size.x)


func _feed_new_measurements() -> void:
	var ms: Array = world.measurements
	while _processed_meas < ms.size():
		var m: Measurement = ms[_processed_meas]
		if not m.detected:
			_processed_meas += 1
			continue
		if world.auto_measurements:
			if _processed_meas == 0:
				tracker.mark(m, "S")
			else:
				var t: Track = tracker.feed(m)
				if t == null:
					tracker.mark(m, "S")
		_processed_meas += 1


## 重建 LOB / meas_index / BT 点列 / 残差数组（装配逻辑见 UiChartData）。
func _rebuild_display_data() -> void:
	UiChartData.rebuild(self)


func _selected_track() -> Track:
	if selected_track_id == "":
		return null
	for t in tracker.all_tracks():
		if t.track_id == selected_track_id:
			return t
	return null


func _update_displays_light() -> void:
	UiChartData.update_light(self)


## 非 LOST 威胁数：航迹页按钮徽标计数（S109 §8.3，AT-30）。
func _active_threat_count() -> int:
	var n: int = 0
	for s in _chart.threat_snapshots:
		if str(s["state"]) != "LOST":
			n += 1
	return n


func _update_panel() -> void:
	if world == null:
		return
	var status: String = (
		UiText.t("status_fmt") % [world.sim_time, world.measurements.size()]
		+ " | %dx%s" % [int(_time_scale), "（已暂停）" if _paused else ""]
	)
	_lbl_status.text = status
	_lbl_time.text = "T+%.0fs" % world.sim_time  # S109 §8.1 顶栏任务时间
	var brcs: String = ""
	if trial.range_m > 0.0:
		brcs = (
			"  方位%.0f° 距离%.0f 米 航向%.0f° 航速%.1f 节"
			% [trial.bearing_deg, trial.range_m, trial.course_deg, trial.speed_kn]
		)
	_lbl_selected.text = (
		(
			UiText.t("selected_none")
			if selected_track_id == ""
			else UiText.t("selected_prefix") + selected_track_id
		)
		+ brcs
	)
	_update_contact_rows()

	if trial.range_m > 0.0:
		if not _spin_bearing.has_focus():
			_spin_bearing.set_value_no_signal(trial.bearing_deg)
		if not _spin_range.has_focus():
			_spin_range.set_value_no_signal(trial.range_m)
		if not _spin_course.has_focus():
			_spin_course.set_value_no_signal(trial.course_deg)
		if not _spin_speed.has_focus():
			_spin_speed.set_value_no_signal(trial.speed_kn)
	if _own_panel != null:
		_own_panel.sync()


## 接触列表（可点击按钮，选中高亮）。集合变化时才重建按钮。
func _update_contact_rows() -> void:
	var active: Array = []
	for t in tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE:
			active.append(t)
	var ids: Array = []
	for t in active:
		ids.append(t.track_id)
	for tid in _contact_rows.keys():
		if not (tid as String) in ids:
			(_contact_rows[tid] as Button).queue_free()
			_contact_rows.erase(tid)
	for t in active:
		var label := TmaUiData.contact_label(t)
		if _contact_rows.has(t.track_id):
			(_contact_rows[t.track_id] as Button).text = label
		else:
			var b := Button.new()
			b.text = label
			b.toggle_mode = true
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.add_theme_font_size_override("font_size", 14)
			b.pressed.connect(_on_contact_selected.bind(t.track_id))
			_contact_rows_box.add_child(b)
			_contact_rows[t.track_id] = b
		var btn := _contact_rows[t.track_id] as Button
		# REQ-03/06 关联徽章色阶：R（测距门控）绿 / P（预测门控）橙 / B（纯方位）灰
		var badge: String = TmaUiData.association_badge(t)
		var badge_col := Color(0.9, 0.92, 0.94)
		if badge.begins_with("R"):
			badge_col = Color(0.4, 1.0, 0.6)
		elif badge.begins_with("P"):
			badge_col = Color(1.0, 0.82, 0.4)
		elif badge.begins_with("B"):
			badge_col = Color(0.8, 0.85, 0.92)
		btn.add_theme_color_override("font_color", badge_col)
		btn.set_pressed_no_signal(t.track_id == selected_track_id)


## REQ-B1-03：切换/清除 Contact 只刷新视图别名，不动 Fit/Trial/Sol。
func _refresh_fit_view() -> void:
	var tid := selected_track_id
	last_fit = fcc.fit_by_track_id.get(tid, {}) if tid != "" else {}
	var tr: TrialSolution = fcc.trial_by_track_id.get(tid, null) if tid != "" else null
	trial = tr if tr != null else TrialSolution.new()
	system_sol = fcc.system_solution_by_track_id.get(tid, null) if tid != "" else null


func _on_contact_selected(track_id: String) -> void:
	if selected_track_id == track_id:
		# REQ-09：再次点击同一接触 = 取消选择。
		selected_track_id = ""
		_refresh_fit_view()
		if _ping_ctrl != null:
			_ping_ctrl.preferred_track_id = ""
		_lbl_selected.text = UiText.t("selected_none")
		_dirty = true
		_rebuild_display_data()
		_update_status(UiText.t("selection_cleared"))
		return
	selected_track_id = track_id
	_refresh_fit_view()
	# REQ-02 多回波优先级：命中当前选中 Track 的回波排最前。
	if _ping_ctrl != null:
		_ping_ctrl.preferred_track_id = track_id
	_lbl_selected.text = UiText.t("selected_prefix") + track_id
	_dirty = true
	_rebuild_display_data()
	_update_status(track_id + " " + UiText.t("st_selected_hint"))


func _on_layer_toggle(on: bool, key: String) -> void:
	_chart.layers[key] = on
	if key == "truth":
		_chart.show_truth = on
	_chart.queue_redraw()


## BT / 残差图悬停 → 海图联动（o_i、LOB、p_i、z/θ̂/e 数值）。
func _on_hover_changed(time: float) -> void:
	_chart.hover_time = time
	_res_plot.set_highlight(time)
	_chart.queue_redraw()


func _on_tick_selected(time: float) -> void:
	_res_plot.set_highlight(time)  # 时间刻度点击 → 残差图高亮
	_res_plot.queue_redraw()


func _on_threat_selected(evidence_id: int) -> void:
	if _alert_panel != null:  # 地图 LOB 点击 → 告警卡高亮（反向联动属 Patch E）
		_alert_panel.highlight_evidence_id = evidence_id


func _on_pause() -> void:
	_paused = not _paused
	world.set_paused(_paused)
	_btn_pause.text = UiText.t("resume") if _paused else UiText.t("pause")


func _on_speed(index: int) -> void:
	_time_scale = [1, 2, 4, 8][index]
	world.set_time_scale(_time_scale)


func _on_show_truth(on: bool) -> void:
	_chart.show_truth = on
	_chart.layers["truth"] = on
	if _chk_layers.has("truth"):
		(_chk_layers["truth"] as CheckButton).set_pressed_no_signal(on)


func _on_mark() -> void:
	var m: Measurement = TmaUiData.latest_measurement(world)
	if m == null:
		return
	tracker.mark(m, "S")
	_update_status(UiText.t("st_manual_mark"))


## Auto Fit：只拟合 selected_track_id（主动回波 REFIT 复用）。
func _on_fit_tma() -> void:
	var sel: Track = _selected_track()
	if sel == null:
		_update_status(UiText.t("st_no_contact"))
		return
	# 门槛按物理 evidence 计数（拖曳 A/B 一次到达 = 一个证据）。
	if sel.evidence_count() < 4:
		_update_status(UiText.t("evt_needs_evidence") + " " + sel.track_id + " ≥4 条证据")
		return
	fcc.solve_and_store(sel, op, world.sim_time)
	_present_fit(sel.track_id, true)
	_dirty = true
	_rebuild_display_data()


## REQ-B1-03：把某 Track 的 Fit/Trial/Solution 视图别名刷到前台。
func _present_fit(tid: String, announce: bool) -> void:
	var r: Dictionary = fcc.fit_by_track_id.get(tid, {})
	last_fit = r
	var tr: TrialSolution = fcc.trial_by_track_id.get(tid, null)
	trial = tr if tr != null else TrialSolution.new()
	system_sol = fcc.system_solution_by_track_id.get(tid, null)
	var sel: Track = tracker.track_by_id(tid)
	if bool(r.get("success", false)) and sel != null:
		TmaUiData.dot_stack_compute(dot_stack, r, sel)
		_lbl_tma.text = TmaUiData.summary(r, sel)
	if announce and not r.is_empty():
		var st_txt: String = UiText.fit(str(r.get("status", "?")))
		if fcc.is_stale(tid):
			st_txt = "已过期 · " + st_txt
		if bool(r.get("success", false)):
			_update_status(
				(
					"TMA %s %s | 方位%.0f° 距离%.0f 米 航向%.0f° 航速%.1f 节"
					% [
						tid,
						st_txt,
						trial.bearing_deg,
						trial.range_m,
						trial.course_deg,
						trial.speed_kn
					]
				)
			)
		else:
			_update_status(UiText.t("st_tma_result") + " %s：%s" % [tid, st_txt])


## S1-05/REQ-B1-03：FULL_AUTO 后台 REFIT 只更新 fit_by_track_id[tid]，绝不改选中。
func _auto_refit_track(tid: String) -> void:
	var t: Track = tracker.track_by_id(tid)
	if t == null or t.evidence_count() < 4:
		return
	fcc.solve_and_store(t, op, world.sim_time)
	if tid == selected_track_id:
		_present_fit(tid, false)


## REQ-B1-04：Enter Solution 校验来源绑定；低质量解需显式二次确认。
func _on_enter_solution() -> void:
	var tid := selected_track_id
	if tid == "" or trial.range_m <= 0.0:
		_update_status("先自动拟合 TMA，再提交系统解")
		return
	var st: String = str(last_fit.get("status", "CONVERGED")) if not last_fit.is_empty() else "NONE"
	var res: Dictionary = fcc.commit_solution_checked(tid, world.sim_time, st, _lowq_confirmed)
	if bool(res.get("lowq_pending", false)):
		_lowq_confirmed = true
		_update_status("拟合质量偏低（%s）— 再次点击接受为系统解以确认" % UiText.fit(st))
		return
	_lowq_confirmed = false
	if not bool(res.get("ok", false)):
		_update_status(
			UiText.t("evt_submit_reject") + "：" + UiText.reject(str(res.get("reason", "?")))
		)
		return
	system_sol = res["solution"]
	if _weapon_panel != null:
		_weapon_panel.set_fire_context("建议航线就绪 — %s (src %s)；航线仍需在地图上绘制" % [st, tid])
	_update_status(UiText.t("evt_submit") + " " + tid + "（" + UiText.fit(st) + "）")


## ---- S1-11 §5.3 / D-01：地图航线（玩家唯一发射方式，逻辑见 WeaponMapControl）----
func _on_route_draw_toggled(on: bool) -> void:
	if _wmc == null:
		return
	if on:
		_wmc.begin_draw()
	else:
		_wmc.cancel_draw()
		_dirty = true


func _on_route_undo() -> void:
	if _wmc != null:
		_wmc.undo_point()
		_dirty = true


func _on_route_clear() -> void:
	if _wmc == null:
		return
	_wmc.cancel_draw()
	if _weapon_panel != null:
		_weapon_panel.set_route_drawing(false)
		_weapon_panel.set_route_status(UiText.t("route_none"))
	_dirty = true


## 航线层任何变化（加点/撤销/取消/提交/开机点）→ 刷新面板状态行 + 地图重绘。
func _on_route_changed() -> void:
	_dirty = true
	if _weapon_panel == null or _route_overlay == null:
		return
	# S1-11 修复：绘制开关必须跟着航线层真实状态走（右键「完成航线」后
	# active 已 false，开关若仍选中，玩家再点一次会走取消路径清掉已提交航线）。
	# set_route_drawing 内部用 set_pressed_no_signal()，不会回头触发 toggled。
	_weapon_panel.set_route_drawing(_route_overlay.active)
	var n: int = _route_overlay.future_point_count()
	if _route_overlay.active:
		_weapon_panel.set_route_status(
			UiText.t("route_drawing_fmt") % [n, MapRouteOverlay.MAX_FUTURE_POINTS]
		)
	elif _route_overlay.can_commit():
		_weapon_panel.set_route_status(UiText.t("route_ready_fmt") % n)
	else:
		_weapon_panel.set_route_status(UiText.t("route_none"))


## S1-11 D-01：发射 = 沿地图航线（唯一方式），执行/联锁仍在 FireExecutor。
func _on_fire_torpedo() -> void:
	if _wmc == null:
		return
	var res: Dictionary = _wmc.try_fire()
	if bool(res.get("ok", false)) and _weapon_panel != null:
		var tp: Torpedo = res.get("tp", null)
		_weapon_panel.set_route_drawing(false)
		if tp != null:
			_weapon_panel.set_fire_context(UiText.t("route_in_water") % str(tp.torpedo_id))
		_weapon_panel.refresh()
	_dirty = true


## §4.3：地图点击鱼雷 → 浮动控制栏（真实 torpedo_id，数组删减后不重排）。
func _on_map_torpedo_selected(tid: String) -> void:
	if _wmc != null:
		_wmc.set_selected_torpedo(tid)


## 地图右键命令：绘制/清除鱼雷航线入口（Batch 4c 收尾，与 Batch 5 同一套交互）。
func begin_route_draw() -> void:
	_on_route_draw_toggled(true)


func clear_route_draw() -> void:
	_on_route_clear()


func map_control() -> WeaponMapControl:
	return _wmc


func _set_map_torpedo(tid: String) -> void:
	if _chart != null:
		_chart.selected_torpedo_id = tid
		_chart.queue_redraw()
	if _wmc != null:
		_wmc.set_selected_torpedo(tid)


## AT-26：武器页摘要行点击 → 地图选中并居中该鱼雷（id 原样，绝不重排）。
func _on_summary_row_clicked(tid: String) -> void:
	if tid == "":
		return
	_set_map_torpedo(tid)
	if _wmc != null:
		_wmc.center(tid)


func _update_status(msg: String) -> void:
	if world != null:
		_lbl_status.text = (
			"Time %.0fs | Meas %d\n%s" % [world.sim_time, world.measurements.size(), msg]
		)
	else:
		_lbl_status.text = msg


## Operator 层每帧推进（OperatorSonar 内部节流）；有新行才刷新面板。
func _op_step() -> void:
	if op == null or _op_panel == null:
		return
	# P0-06：UI 路径同一声场——targets + 统一声场注册表（双方鱼雷影子/诱饵）， 经同一 OperatorSonar 概率采样出峰/测量候选/告警派生。
	var scene: Array = world._acoustic_scene_emitters()
	var scene_acs: Dictionary = world.world["target_acs"].duplicate()
	scene_acs.merge(world._acoustic_scene_acs())
	# REQ-AC-01：按仿真节拍追帧（倍速不跳行）；UI 切换不改变物理 RNG 消耗。
	op.catch_up_rows(world.sim_time, world.world["targets"] + scene, scene_acs)
	# REQ-B1-03：镜像证据修订（autocrew/主动回波等改动证据时自动置 stale）。
	for t in tracker.all_tracks():
		fcc.sync_revision(t)
	_towed.refresh_status()
	_refresh_ping_status()
	if _op_panel.autocrew_on():
		# autocrew 可能返回 A/B 镜像组（共享 evidence）——整组作为一个 证据原子走 feed_evidence_group，一次物理到达 = 一个 Track，不跨时刻分裂。
		var auto_ms: Array = op.autocrew_step(world.sim_time)
		var i2: int = 0
		while i2 < auto_ms.size():
			var pm: Measurement = auto_ms[i2]
			var grp: Array = [pm]
			i2 += 1
			while (
				i2 < auto_ms.size()
				and auto_ms[i2].evidence_id == pm.evidence_id
				and auto_ms[i2].has_ambiguity()
			):
				grp.append(auto_ms[i2])
				i2 += 1
			var tt: Track = tracker.feed_evidence_group(grp, "", 8.0)
			if tt == null:
				tt = tracker.mark(pm, "M")
				for j in range(1, grp.size()):
					tt.add_measurement(grp[j] as Measurement)
			for gm in grp:
				world.measurements.append(gm)
				_processed_meas += 1
			_dirty = true
			_update_status(UiText.t("st_autocrew_mark"))
	_op_panel.refresh(op)


func _on_ping_requested() -> void:
	if _ping_ctrl == null:
		return
	_ping_ctrl.request_ping()
	_last_meas_count = world.measurements.size()


func _refresh_ping_status() -> void:
	_ping_ctrl.refresh_panel(_op_panel)


## 撤销最近一次主动回波关联（REQ-03 DoD：改绑/拒绝后视图同步刷新）。
func _on_active_undo() -> void:
	if _ping_ctrl == null:
		return
	if _ping_ctrl.undo_last_association():
		_dirty = true
		_rebuild_display_data()


## 点击 Latest Returns 行 → 选中该返回关联的 Track（不自动 Fit）。
func _on_active_return_selected(i: int) -> void:
	if _ping_ctrl == null or i < 0 or i >= _ping_ctrl.return_rows.size():
		return
	var tid: String = str(_ping_ctrl.return_rows[i].get("track_id", ""))
	if tid == "" or tid == "-":
		return
	_on_contact_selected(tid)


## 回波命中回调（REQ-02/S109 §5.3/P0-08）：绝不抢玩家当前选中，只刷新面板。
func _on_ping_echo_hits(fed: Array) -> void:
	if fed.is_empty():
		return
	var tr: Track = fed[0].get("track")
	if tr == null:
		return
	_dirty = true
	_update_status(UiText.t("st_echo_fused") + " " + tr.track_id)


## AUTO/Apply 重拟合（REQ-02/S109 §5.3）：只更新命中航迹 per-Track Fit，不切视图。
func _on_ping_fit_requested(track_id: String) -> void:
	var t: Track = tracker.track_by_id(track_id)
	if t == null:
		return
	if t.evidence_count() < 4:
		_ping_ctrl.mark_range_applied(false)
		_update_status(UiText.t("evt_needs_evidence") + " " + track_id + " ≥4 条证据")
		return
	var r: Dictionary = fcc.solve_and_store(t, op, world.sim_time)
	if track_id == selected_track_id:
		_present_fit(track_id, true)
		_dirty = true
	_ping_ctrl.mark_range_applied(bool(r.get("success", false)))


## REQ-B1-01/02：Mark 关联流移入 MarkFlow（LOCKED/SUGGEST/AUTO + 同峰去重）。
## S1-11 §3.3/AT-48：仅查看/切换 Contact 不隐式改变 Mark 归属；Shift＋点击才
## 显式把该点追加到当前查看的接触（显式命令，不过 8° 自动关联门）。
func _on_op_mark(x_value: float, as_true: bool = false, row: Dictionary = {}) -> void:
	var explicit_append: bool = Input.is_key_pressed(KEY_SHIFT) and selected_track_id != ""
	var res: Dictionary = mark_flow.handle_mark(
		x_value, as_true, row, selected_track_id, explicit_append
	)
	var sel_id: String = str(res.get("select", ""))
	if sel_id != "":
		selected_track_id = sel_id
		if _ping_ctrl != null:
			_ping_ctrl.preferred_track_id = sel_id
		_lbl_selected.text = UiText.t("selected_prefix") + sel_id
	_apply_mark_result(res, false)


func _refresh_mark_panel() -> void:
	if mark_panel == null:
		return
	var ids: Array = []
	for t in tracker.all_tracks():
		ids.append((t as Track).track_id)
	mark_panel.set_groups(ids)
	mark_panel.show_suggestion(mark_flow.pending_suggestion_track_id())
	mark_panel.set_audit(str(mark_flow.audit[-1]) if not mark_flow.audit.is_empty() else "")


## 统一应用 Mark 操作结果：修订镜像/置脏/刷新/状态行。
func _apply_mark_result(res: Dictionary, rebuild: bool) -> void:
	var trk: Track = res.get("track", null)
	if trk != null:
		fcc.sync_revision(trk)
	if bool(res.get("dirty", false)):
		_dirty = true
		_last_meas_count = world.measurements.size()
		if rebuild:
			_rebuild_display_data()
			_refresh_mark_panel()
	_update_status(UiText.mark_status(str(res.get("status", ""))))


func _on_mark_operation(res: Dictionary) -> void:
	_apply_mark_result(res, true)
	_refresh_mark_panel()


## AlertPanel 用：当前在跟航迹的最新方位集合（战果评估）。
func _alert_track_bearings() -> Array:
	var out: Array = []
	if tracker == null:
		return out
	for t in tracker.all_tracks():
		var m: Measurement = (t as Track).latest_measurement()
		if m != null:
			out.append(m.measured_bearing_deg)
	return out
