class_name SonarUI
extends Control
## main_ui.gd — 主 UI 装配与仿真驱动（TMA 可视化重构版）。
## 布局：左方位盘 | 中海图 | 右控制面板(280px) | 底部诊断区 BT/残差可切换
##   （CLOSED/BT/RESIDUAL/SPLIT，关闭释放空间、重开保留数据）。
## 要点：selected_track_id 只拟合选中接触；脏标记驱动重建；BT↔海图↔残差
##   三方悬停联动；Truth 仅 Show Truth 开发开关打开时才进海图。

const SCENARIO_NAME: String = "stage1_basic_passive"
const PANEL_W: float = 280.0
const BT_H: float = 240.0
const RES_H: float = 150.0

# 底部诊断区显示模式（需求§一.1）：CLOSED / BT / RESIDUAL / SPLIT
const DIAG_CLOSED: int = 0
const DIAG_BT: int = 1
const DIAG_RESIDUAL: int = 2
const DIAG_SPLIT: int = 3

var world: World = null
var tracker: Tracker = null
var trial: TrialSolution = null
var system_sol: SystemSolution = null
var dot_stack: DotStack = null
var last_fit: Dictionary = {}  # 最近一次 TmaFitResult（含 track_id）
var selected_track_id: String = ""
var op: OperatorSonar = null  # Sonar Operator Layer（Truth 只进这里）
var _op_panel: OperatorPanel = null
var _ping_ctrl: ActivePingController = null  # S1-04 主动 Ping 接线（拆出，控行数）

var _chart: ChartView = null
var _bearing: BearingDisplay = null
var _bt_plot: BearingTimePlot = null
var _res_plot: ResidualPlot = null
var _diag_box: VBoxContainer = null  # 包裹两个诊断图的底部容器
var _diag_mode: int = DIAG_BT  # 默认只显示 BT（需求§一.1）
var _panel: VBoxContainer = null

# 控制面板控件
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
var _spin_own_course: SpinBox = null
var _spin_own_speed: SpinBox = null
var _contact_rows: Dictionary = {}  # track_id -> Button
var _chk_layers: Dictionary = {}  # layer key -> CheckButton
var _lbl_own_cmd: Label = null  # S1-02：ACT→CMD 航向/航速显示

var _time_scale: float = 2.0
var _sim_accum: float = 0.0
var _paused: bool = false
var _processed_meas: int = 0
var _track_colors: Dictionary = {}  # track_id -> Color
# 脏标记：只有这些变化才重建 LOB/BT/残差数组
var _dirty: bool = true
var _last_meas_count: int = -1
var _fit_version: int = 0
var _own_track_pts: Array = []


func _ready() -> void:
	var vp: Vector2 = get_viewport_rect().size
	set_size(vp)
	resized.connect(_on_self_resized)
	_build_ui()

	world = World.new()
	var scenario: Dictionary = ConfigLoader.load_scenario(SCENARIO_NAME)
	world.load_scenario(scenario)
	world.set_time_scale(_time_scale)

	tracker = Tracker.new()
	var rng: RandomNumberGenerator = world.world.get("rng", null)
	if rng != null:
		tracker.set_rng(rng)
	tracker.set_capacity(8)
	tracker.set_auto_interval(5.0)

	# 主动 Ping 控制器（S1-04）：接线 World.issue_ping → Tracker → 面板/状态摘要
	_ping_ctrl = ActivePingController.new()
	_ping_ctrl.world = world
	_ping_ctrl.tracker = tracker
	_ping_ctrl.on_status = _update_status
	_ping_ctrl.on_dirty = func(): _dirty = true
	# S1-04B：回波命中已喂 Tracker → 自动选中该接触并 REFIT（range 进 TMA）
	_ping_ctrl.on_echo_hits = _on_ping_echo_hits
	# S1-04C：撤销一次自动关联后刷新视图（REFIT REQUIRED 语义）。
	_ping_ctrl.on_assoc_undone = func(_tid: String):
		_dirty = true
		_update_status("Active echo association undone — REFIT REQUIRED")

	# Operator Layer：关闭自动测量，Truth 只能经声场/阵列采样进入操作员视图
	world.auto_measurements = false
	op = OperatorSonar.new()
	op.setup(world.world)
	# S1-01：本艇无拖曳阵硬件时禁用 TOWED 选项（不提供虚构回退）
	if _op_panel != null:
		_op_panel.set_towed_available(op.towed_available())

	trial = TrialSolution.new()
	system_sol = null
	dot_stack = DotStack.new()

	# 武器面板依赖 world.weapons（此时已就绪），补绑定并默认无解禁火
	if _weapon_panel != null and world.weapons != null:
		_weapon_panel.bind(world.weapons, _chart, func(): _dirty = true)
		_weapon_panel.set_solution_available(false)

	if _spin_own_course != null:
		_spin_own_course.set_value_no_signal(world.world["own"].course_deg)
	if _spin_own_speed != null:
		_spin_own_speed.set_value_no_signal(world.world["own"].speed_kn)

	_update_status("ready: click a contact, then Auto Fit TMA")


func _on_self_resized() -> void:
	pass


# ---- UI 构建 ----


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
	main_row.add_child(_chart)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_W, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_row.add_child(scroll)

	_panel = VBoxContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_W, 0)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.add_theme_constant_override("separation", 5)
	scroll.add_child(_panel)

	_build_panel()
	_build_bottom(root)


func _build_panel() -> void:
	var title := Label.new()
	title.text = "Submarine Sonar / TMA"
	title.add_theme_font_size_override("font_size", 18)
	_panel.add_child(title)

	var row0 := HBoxContainer.new()
	row0.add_theme_constant_override("separation", 6)
	_panel.add_child(row0)
	_btn_pause = Button.new()
	_btn_pause.text = "⏸ Pause"
	_btn_pause.pressed.connect(_on_pause)
	row0.add_child(_btn_pause)
	_btn_mark = Button.new()
	_btn_mark.text = "Mark"
	_btn_mark.pressed.connect(_on_mark)
	row0.add_child(_btn_mark)
	var spd_lbl := Label.new()
	spd_lbl.text = "Speed"
	row0.add_child(spd_lbl)
	var opt_speed := OptionButton.new()
	for s in [1, 2, 4, 8]:
		opt_speed.add_item("%dx" % s)
	opt_speed.select(1)
	opt_speed.item_selected.connect(_on_speed)
	row0.add_child(opt_speed)

	# ---- Sonar Operator Layer（核心操作区，置于面板顶部）----
	var op_sec := _make_section("Sonar Operator")
	_op_panel = OperatorPanel.new()
	_section_body(op_sec).add_child(_op_panel)
	_op_panel.mark_requested.connect(_on_op_mark)
	_op_panel.array_changed.connect(
		func(aid: String):
			op.set_array(aid)
			_update_status("Array -> " + aid)
			# S1-03：不再自动布放——拖曳阵缆长完全由操作员命令控制
	)
	_op_panel.autocrew_toggled.connect(
		func(on: bool): _update_status("Autocrew " + ("ON" if on else "OFF"))
	)
	_op_panel.towed_deploy_requested.connect(_on_towed_deploy)
	_op_panel.towed_retract_requested.connect(_on_towed_retract)
	_op_panel.towed_hold_requested.connect(_on_towed_hold)
	_op_panel.towed_length_commanded.connect(_on_towed_length_commanded)
	_op_panel.ping_requested.connect(_on_ping_requested)
	_op_panel.active_undo_requested.connect(_on_active_undo)
	_op_panel.active_return_selected.connect(_on_active_return_selected)
	_panel.add_child(op_sec)
	_panel.add_child(HSeparator.new())

	# 关键信息区（验收：1280x720 无需滚动可见）
	_lbl_status = Label.new()
	_lbl_status.text = ""
	_lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_status.add_theme_font_size_override("font_size", 14)
	var sec_status := _make_section("Status")
	_section_body(sec_status).add_child(_lbl_status)
	_panel.add_child(sec_status)

	_lbl_selected = Label.new()
	_lbl_selected.text = "Selected: none"
	_lbl_selected.add_theme_font_size_override("font_size", 16)
	_panel.add_child(_lbl_selected)

	_btn_fit = Button.new()
	_btn_fit.text = "🔄 Auto Fit TMA (selected)"
	_btn_fit.pressed.connect(_on_fit_tma)
	_panel.add_child(_btn_fit)

	_lbl_tma = Label.new()
	_lbl_tma.text = "No fit yet."
	_lbl_tma.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_tma.add_theme_font_size_override("font_size", 14)
	_sec_fit = _make_section("Fit Details")
	_section_body(_sec_fit).add_child(_lbl_tma)
	_panel.add_child(_sec_fit)

	_btn_enter = Button.new()
	_btn_enter.text = "✅ Accept as System"
	_btn_enter.pressed.connect(_on_enter_solution)
	_panel.add_child(_btn_enter)

	# ---- 武器面板（阶段四：只读 SystemSolution）----
	_weapon_panel = WeaponPanelUI.new()
	_panel.add_child(_weapon_panel)
	_weapon_panel.fire_requested.connect(_on_fire_torpedo)

	_panel.add_child(HSeparator.new())
	_build_contact_list()
	_panel.add_child(HSeparator.new())
	_build_layer_toggles()

	_panel.add_child(HSeparator.new())

	# 本艇机动
	var own_title := Label.new()
	own_title.text = "Own Ship Maneuver"
	own_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(own_title)
	_spin_own_course = _add_spin("Own Course (°)", 0, 359, 1, 0)
	_spin_own_speed = _add_spin("Own Speed (kn)", 0, 30, 0.5, 0)
	_lbl_own_cmd = Label.new()
	_lbl_own_cmd.add_theme_font_size_override("font_size", 13)
	_panel.add_child(_lbl_own_cmd)
	_spin_own_course.value_changed.connect(_on_own_course)
	_spin_own_speed.value_changed.connect(_on_own_speed)
	var row_turn := HBoxContainer.new()
	row_turn.add_theme_constant_override("separation", 4)
	_panel.add_child(row_turn)
	for cfg in [
		["Left 5°", _on_turn_left],
		["Right 5°", _on_turn_right],
		["+2kn", _on_speed_up],
		["-2kn", _on_slow_down]
	]:
		var b := Button.new()
		b.text = cfg[0] as String
		b.pressed.connect(cfg[1] as Callable)
		row_turn.add_child(b)

	_panel.add_child(HSeparator.new())
	# 相机控制
	var cam_title := Label.new()
	cam_title.text = "Camera / View"
	cam_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(cam_title)
	var row_cam := HBoxContainer.new()
	row_cam.add_theme_constant_override("separation", 4)
	_panel.add_child(row_cam)
	var btn_reset := Button.new()
	btn_reset.text = "Reset View"
	btn_reset.pressed.connect(func(): _chart.reset_view())
	row_cam.add_child(btn_reset)
	var btn_frame := Button.new()
	btn_frame.text = "Auto Frame"
	btn_frame.pressed.connect(func(): _chart.auto_frame())
	row_cam.add_child(btn_frame)
	var chk_all_lob := CheckButton.new()
	chk_all_lob.text = "All LOB History"
	chk_all_lob.toggled.connect(func(on: bool): _chart.show_all_lobs = on)
	_panel.add_child(chk_all_lob)

	_panel.add_child(HSeparator.new())
	# Trial 参数微调
	var tma_title := Label.new()
	tma_title.text = "Trial Params (manual)"
	tma_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(tma_title)
	_spin_bearing = _add_spin("Bearing (°)", 0, 359, 1, 0)
	_spin_range = _add_spin("Range (m)", 100, 50000, 100, 0)
	_spin_course = _add_spin("Course (°)", 0, 359, 1, 0)
	_spin_speed = _add_spin("Speed (kn)", 0, 40, 0.5, 0)
	_spin_bearing.value_changed.connect(func(v): trial.set_bearing(v))
	_spin_range.value_changed.connect(func(v): trial.set_range(v))
	_spin_course.value_changed.connect(func(v): trial.set_course(v))
	_spin_speed.value_changed.connect(func(v): trial.set_speed(v))

	_btn_show_truth = Button.new()
	_btn_show_truth.text = "Show Truth (dev)"
	_btn_show_truth.toggle_mode = true
	_btn_show_truth.toggled.connect(_on_show_truth)
	_panel.add_child(_btn_show_truth)


func _build_contact_list() -> void:
	var ct_title := Label.new()
	ct_title.text = "Contacts (click to select)"
	ct_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(ct_title)


func _build_layer_toggles() -> void:
	var lt := Label.new()
	lt.text = "Layers"
	lt.add_theme_font_size_override("font_size", 15)
	_panel.add_child(lt)
	for key in ["lob", "sigma", "fit", "alt", "trial", "system", "truth"]:
		var cb := CheckButton.new()
		cb.text = key.capitalize() if key != "alt" else "Alternatives"
		cb.button_pressed = bool(_chart.layers.get(key, true))
		cb.toggled.connect(_on_layer_toggle.bind(key))
		_panel.add_child(cb)
		_chk_layers[key] = cb
	var ob := OptionButton.new()
	ob.add_item("BT Axis: Local (auto)")
	ob.add_item("BT Axis: 360° Overview")
	ob.item_selected.connect(
		func(i: int):
			_bt_plot.overview_mode = i == 1
			_bt_plot.queue_redraw()
	)
	_panel.add_child(ob)

	# 诊断区显示模式（需求§一.1）：CLOSED / BT(默认) / RESIDUAL / SPLIT
	var diag_lbl := Label.new()
	diag_lbl.text = "Diagnostics:"
	diag_lbl.add_theme_font_size_override("font_size", 15)
	_panel.add_child(diag_lbl)
	var diag_ob := OptionButton.new()
	diag_ob.add_item("CLOSED")
	diag_ob.add_item("BT")
	diag_ob.add_item("RESIDUAL")
	diag_ob.add_item("SPLIT")
	diag_ob.select(DIAG_BT)
	diag_ob.item_selected.connect(_set_diag_mode)
	_panel.add_child(diag_ob)


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

	# 应用默认显示模式（BT）：BT 显示、残差隐藏
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


## 供面板控件调用：设置诊断区显示模式。
func _set_diag_mode(mode: int) -> void:
	_diag_mode = mode
	_apply_diag_mode()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.06, 0.08, 1.0))


func _add_spin(title: String, min_v: float, max_v: float, step: float, val: float) -> SpinBox:
	var lbl := Label.new()
	lbl.text = title
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = step
	sp.value = val
	sp.allow_greater = true
	sp.allow_lesser = true
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(lbl)
	box.add_child(sp)
	_panel.add_child(box)
	return sp


# ---- 仿真推进 ----


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
		_weapon_panel.refresh()
	_update_displays_light()
	_update_panel()


func _feed_new_measurements() -> void:
	var ms: Array = world.measurements
	while _processed_meas < ms.size():
		var m: Measurement = ms[_processed_meas]
		# S1-00（GAP-DATA-01）第三层过滤：miss 样本绝不吃进 Tracker/TMA。
		if not m.detected:
			_processed_meas += 1
			continue
		if world.auto_measurements:
			# 旧模式：自动关联/建 Track
			if _processed_meas == 0:
				tracker.mark(m, "S")
			else:
				var t: Track = tracker.feed(m)
				if t == null:
					tracker.mark(m, "S")
		# Operator 模式：测量已在 Mark/Autocrew 时喂 Tracker，这里只推游标。
		_processed_meas += 1


# ---- 数据重建（脏标记触发） ----


## 重建 LOB / meas_index / BT 点列 / 残差数组。
func _rebuild_display_data() -> void:
	_dirty = false
	var now: float = world.sim_time
	var sel: Track = _selected_track()
	var outlier_times: Dictionary = TmaUiData.outlier_times(last_fit, selected_track_id)
	# 1) LOB（选中接触高亮着色，其他接触降到 alpha 由 chart 处理色弱化标记）
	var all_lobs: Array = []
	var meas_index: Array = []
	var leg_bounds: Array = TmaUiData.leg_boundary_times(world.measurements)
	for t in tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var col: Color = _color_for_track(t.track_id)
		var is_sel: bool = t.track_id == selected_track_id
		for m in t.measurement_history:
			var inlier: bool = not outlier_times.has(m.timestamp)
			var a: float = 1.0 if is_sel else 0.12
			(
				all_lobs
				. append(
					{
						"origin": Vector2(m.observer_east_m, m.observer_north_m),
						"bearing_deg": m.measured_bearing_deg,
						"color": Color(col.r, col.g, col.b, a),
						"id": t.track_id,
						"track_id": t.track_id,
						"time": m.timestamp,
						"sigma_deg": maxf(m.bearing_sigma_deg, 0.5),
						"inlier": inlier,
					}
				)
			)
			if is_sel:
				(
					meas_index
					. append(
						{
							"time": m.timestamp,
							"origin": Vector2(m.observer_east_m, m.observer_north_m),
							"bearing_deg": m.measured_bearing_deg,
							"sigma_deg": maxf(m.bearing_sigma_deg, 0.5),
							"inlier": inlier,
							"track_id": t.track_id,
						}
					)
				)
	_chart.lobs = all_lobs
	_chart.meas_index = meas_index
	_chart.leg_boundary_times = leg_bounds
	_chart.fit_now_time = now
	_chart.fit_track_id = selected_track_id
	_chart.fit_status = (
		str(last_fit.get("status", "NO_FIT")) if not last_fit.is_empty() else "NO_FIT"
	)
	if last_fit.is_empty() or str(last_fit.get("track_id", "")) != selected_track_id:
		_chart.fit_status = "NO_FIT"
	_chart.fit_hypotheses = TmaUiData.chart_hypotheses(last_fit, selected_track_id)
	_chart.fit_ticks = TmaUiData.fit_tick_times(
		last_fit, selected_track_id, TmaUiData.leg_boundary_times(world.measurements)
	)
	_chart.fit_cov_pos = TmaUiData.propagated_cov(last_fit, now)

	# 2) Bearing-Time（选中 track，标注 track_id）
	var points: Array = []
	var t_min: float = INF
	var t_max: float = -INF
	if sel != null:
		var col2: Color = _color_for_track(sel.track_id)
		for m in sel.measurement_history:
			(
				points
				. append(
					{
						"time": m.timestamp,
						"bearing_deg": m.measured_bearing_deg,
						"sigma_deg": maxf(m.bearing_sigma_deg, 0.5),
						"color": col2,
						"inlier": not outlier_times.has(m.timestamp),
						"track_id": sel.track_id,
					}
				)
			)
			t_min = minf(t_min, m.timestamp)
			t_max = maxf(t_max, m.timestamp)
	_bt_plot.meas_points = points
	_bt_plot.model_curves = TmaUiData.bt_curves(last_fit, selected_track_id)
	_bt_plot.turn_times = TmaUiData.own_turn_times(world.measurements)
	_bt_plot.track_id = selected_track_id
	_bt_plot.set_time_window(
		t_min if t_min != INF else 0.0, maxf(t_max, now) if t_max != -INF else 1.0
	)

	# 3) 残差图（REQ-05：只喂方位残差行——range 行是米量纲，禁混进 deg 轴）
	var res: Array = []
	if not last_fit.is_empty() and str(last_fit.get("track_id", "")) == selected_track_id:
		res = TmaUiData.bearing_residuals(last_fit.get("residuals", []))
	_res_plot.residuals = res
	_res_plot.track_id = selected_track_id
	_res_plot.sigma_ref_deg = TmaUiData.mean_sigma(res)
	_res_plot.set_time_window(
		t_min if t_min != INF else 0.0, maxf(t_max, now) if t_max != -INF else 1.0
	)


## 可折叠区块：标题按钮 + 内容容器，再次点击标题折叠/展开。
func _make_section(title_text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var head := Button.new()
	head.text = "▾ " + title_text
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 14)
	var body := VBoxContainer.new()
	head.pressed.connect(
		func():
			body.visible = not body.visible
			head.text = ("▾ " if body.visible else "▸ ") + title_text
	)
	box.add_child(head)
	box.add_child(body)
	box.set_meta("body", body)
	return box


func _section_body(box: VBoxContainer) -> VBoxContainer:
	return box.get_meta("body") as VBoxContainer


func _selected_track() -> Track:
	if selected_track_id == "":
		return null
	for t in tracker.all_tracks():
		if t.track_id == selected_track_id:
			return t
	return null


# ---- 轻量每帧更新（不重建数组） ----


func _update_displays_light() -> void:
	var own: TruthEntity = world.world["own"]
	_chart.own_pos = Vector2(own.position_east_m, own.position_north_m)
	_chart.own_course_deg = own.course_deg  # S1-01.4：本艇符号随实际艏向旋转
	_chart.own_track = _own_track_cache()
	_chart.trial_pos = Vector2(trial.estimated_position_east_m, trial.estimated_position_north_m)
	_chart.trial_active = trial.range_m > 0.0
	if _chart.trial_active:
		var v_ms: float = NavUtils.kn_to_ms(trial.speed_kn)
		_chart.trial_velocity = Vector2(
			v_ms * sin(deg_to_rad(trial.course_deg)), v_ms * cos(deg_to_rad(trial.course_deg))
		)
	else:
		_chart.trial_velocity = Vector2.ZERO
	if system_sol != null:
		_chart.system_pos = Vector2(
			system_sol.estimated_position_east_m, system_sol.estimated_position_north_m
		)
		_chart.system_active = true
	else:
		_chart.system_active = false
	_chart.truth_positions = (
		TmaUiData.collect_truth(world)
		if _chart.show_truth or bool(_chart.layers.get("truth", false))
		else []
	)
	_chart.queue_redraw()

	_bearing.own_course_deg = own.course_deg
	_bearing.lobs = TmaUiData.latest_lobs_for_dial(_chart.lobs)
	var latest: Measurement = TmaUiData.latest_measurement(world)
	if latest != null:
		_bearing.latest_bearing_deg = latest.measured_bearing_deg
		_bearing.latest_color = _color_for_track("LATEST")
	else:
		_bearing.latest_bearing_deg = -1.0
	_bearing.queue_redraw()
	_bt_plot.queue_redraw()
	_res_plot.queue_redraw()


func _own_track_cache() -> Array:
	# 本艇轨迹点只随新测量增长，复用缓存
	if _own_track_pts.is_empty() or _last_meas_count > _own_track_pts.size() - 1:
		_own_track_pts = TmaUiData.sample_own_track(world)
	return _own_track_pts


func _color_for_track(id: String) -> Color:
	if _track_colors.has(id):
		return _track_colors[id]
	var palette: Array = [
		Color(1.0, 0.85, 0.3),
		Color(0.4, 1.0, 0.6),
		Color(0.5, 0.7, 1.0),
		Color(1.0, 0.5, 0.9),
		Color(0.9, 0.6, 0.4),
	]
	var c: Color = palette[_track_colors.size() % palette.size()]
	_track_colors[id] = c
	return c


# ---- 面板 ----


func _update_panel() -> void:
	if world == null:
		return
	var status: String = (
		"Time %.0fs | Meas %d | %dx%s"
		% [world.sim_time, world.measurements.size(), int(_time_scale), " ⏸" if _paused else ""]
	)
	_lbl_status.text = status
	# 选中接触标签始终同步（验收 10.1：无需滚动可见 selected contact + B/R/C/S）
	var brcs: String = ""
	if trial.range_m > 0.0:
		brcs = (
			"  B%.0f° R%.0fm C%.0f° S%.1fkn"
			% [trial.bearing_deg, trial.range_m, trial.course_deg, trial.speed_kn]
		)
	_lbl_selected.text = (
		"Selected: " + (selected_track_id if selected_track_id != "" else "none") + brcs
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
	if _spin_own_course != null and not _spin_own_course.has_focus():
		_spin_own_course.set_value_no_signal(world.world["own"].course_deg)
	if _spin_own_speed != null and not _spin_own_speed.has_focus():
		_spin_own_speed.set_value_no_signal(world.world["own"].speed_kn)
	# S1-02：CMD/ACT 显示（实际值 → 命令值，含预计稳定时间）
	if _lbl_own_cmd != null:
		var o: TruthEntity = world.world["own"]
		var cmd_txt: String = "ACT %.0f° %.1fkn" % [o.course_deg, o.speed_kn]
		if o.has_course_command():
			var err: float = absf(NavUtils.wrap180(o.commanded_course_deg - o.course_deg))
			var rate: float = maxf(o.turn_rate_deg_s, TruthEntity.DEFAULT_TURN_RATE_DEG_S)
			cmd_txt += " → CMD %.0f° (%.0fs)" % [o.commanded_course_deg, err / rate]
		if o.has_speed_command():
			var dv: float = absf(o.commanded_speed_kn - o.speed_kn)
			var acc: float = maxf(o.acceleration_kn_s, TruthEntity.DEFAULT_ACCEL_KN_S)
			cmd_txt += " → CMD %.1fkn (%.0fs)" % [o.commanded_speed_kn, dv / acc]
		_lbl_own_cmd.text = cmd_txt


## 接触列表（可点击按钮，选中高亮）。集合变化时才重建按钮。
func _update_contact_rows() -> void:
	var active: Array = []
	for t in tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE:
			active.append(t)
	var ids: Array = []
	for t in active:
		ids.append(t.track_id)
	# 清掉失效行
	for tid in _contact_rows.keys():
		if not (tid as String) in ids:
			(_contact_rows[tid] as Button).queue_free()
			_contact_rows.erase(tid)
	for t in active:
		var m: Measurement = t.latest_measurement()
		var label := (
			"%s  Brg %.0f°  (%d meas)"
			% [
				t.track_id,
				m.measured_bearing_deg,
				t.measurement_history.size(),
			]
		)
		if _contact_rows.has(t.track_id):
			(_contact_rows[t.track_id] as Button).text = label
		else:
			var b := Button.new()
			b.text = label
			b.toggle_mode = true
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.add_theme_font_size_override("font_size", 14)
			b.pressed.connect(_on_contact_selected.bind(t.track_id))
			_panel.add_child(b)
			_contact_rows[t.track_id] = b
		var btn := _contact_rows[t.track_id] as Button
		btn.set_pressed_no_signal(t.track_id == selected_track_id)


func _on_contact_selected(track_id: String) -> void:
	if selected_track_id == track_id:
		return
	selected_track_id = track_id
	_lbl_selected.text = "Selected: " + track_id
	_dirty = true
	_rebuild_display_data()
	_update_status("Selected " + track_id + " — Auto Fit will use this contact")


# ---- 交互回调 ----


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
	# 时间刻度点击 → 残差图高亮对应测量
	_res_plot.set_highlight(time)
	_res_plot.queue_redraw()


func _on_pause() -> void:
	_paused = not _paused
	world.set_paused(_paused)
	_btn_pause.text = "▶ Resume" if _paused else "⏸ Pause"


func _on_own_course(deg: float) -> void:
	if world == null:
		return
	# S1-02/G-05：UI 只写命令值，实际艏向按转向率逼近
	world.world["own"].command_course(NavUtils.wrap360(deg))


func _on_own_speed(kn: float) -> void:
	if world == null:
		return
	world.world["own"].command_speed(maxf(kn, 0.0))


func _on_turn_left() -> void:
	_change_own_course(-5.0)


func _on_turn_right() -> void:
	_change_own_course(5.0)


func _change_own_course(delta_deg: float) -> void:
	if world == null or _spin_own_course == null:
		return
	var new_deg: float = NavUtils.wrap360(_spin_own_course.value + delta_deg)
	_spin_own_course.set_value_no_signal(new_deg)
	world.world["own"].command_course(new_deg)


func _on_speed_up() -> void:
	_change_own_speed(2.0)


func _on_slow_down() -> void:
	_change_own_speed(-2.0)


func _change_own_speed(delta_kn: float) -> void:
	if world == null or _spin_own_speed == null:
		return
	var new_kn: float = clampf(_spin_own_speed.value + delta_kn, 0.0, 30.0)
	_spin_own_speed.set_value_no_signal(new_kn)
	world.world["own"].command_speed(new_kn)


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
	_update_status("Manual Mark: new contact")


## Auto Fit：只拟合 selected_track_id；也由主动回波 REFIT 复用。
func _on_fit_tma() -> void:
	var sel: Track = _selected_track()
	if sel == null:
		_update_status("No contact selected — click a contact first")
		return
	if sel.measurement_history.size() < 4:
		_update_status("Contact %s needs >= 4 measurements" % sel.track_id)
		return

	var meas: Array = []
	for m in sel.measurement_history:
		meas.append(TmaUiData.fit_meas_dict(m))

	var opts: Dictionary = {"now_time": world.sim_time}
	# DEMON 航速仅作为带 sigma 的软约束，不替代 bearing-only 拟合
	if op != null and not op.demon_estimate.is_empty():
		var de: Dictionary = op.demon_estimate
		if float(de.get("confidence", 0.0)) > 0.3 and float(de.get("speed_sigma_kn", 99.0)) < 6.0:
			opts["demon_speed_kn"] = float(de["speed_kn"])
			opts["demon_sigma_kn"] = float(de["speed_sigma_kn"])
	var r: Dictionary = TmaSolver.solve_auto(meas, opts)
	r["track_id"] = sel.track_id
	if not bool(r.get("success", false)):
		last_fit = r
		_fit_version += 1
		_dirty = true
		_update_status("TMA %s: %s" % [sel.track_id, str(r.get("status", "unknown"))])
		return

	last_fit = r
	_fit_version += 1
	var best: Dictionary = r.get("best", {})

	trial.bearing_deg = float(best.get("bearing_deg", 0.0))
	trial.range_m = float(best.get("range_m", 0.0))
	trial.course_deg = float(best.get("course_deg", 0.0))
	trial.speed_kn = float(best.get("speed_kn", 0.0))
	trial.solution_time = world.sim_time
	var dt_now: float = world.sim_time - float(best.get("t_ref", world.sim_time))
	var v := best.get("v_ms", Vector2.ZERO) as Vector2
	trial.estimated_position_east_m = (best["p_ref"] as Vector2).x + v.x * dt_now
	trial.estimated_position_north_m = (best["p_ref"] as Vector2).y + v.y * dt_now

	dot_stack_compute(r, sel)
	_lbl_tma.text = TmaUiData.summary(r)
	_dirty = true
	_rebuild_display_data()
	_update_status(
		(
			"TMA %s %s | B%.0f° R%.0fm C%.0f° S%.1fkn"
			% [
				sel.track_id,
				str(r.get("status", "?")),
				trial.bearing_deg,
				trial.range_m,
				trial.course_deg,
				trial.speed_kn,
			]
		)
	)


## Dot Stack（等价计算）：只用 inlier 测量 + 最优解状态。
func dot_stack_compute(r: Dictionary, sel: Track) -> void:
	var best: Dictionary = r.get("best", {})
	var inlier_set: Dictionary = {}
	for res in r.get("residuals", []):
		if bool(res.get("inlier", true)):
			inlier_set[float(res["time"])] = true
	var inlier_meas: Array = []
	for m in sel.measurement_history:
		if inlier_set.has(m.timestamp):
			inlier_meas.append(TmaUiData.fit_meas_dict(m))
	if inlier_meas.is_empty():
		return
	dot_stack.compute(
		inlier_meas,
		(best["p_ref"] as Vector2).x,
		(best["p_ref"] as Vector2).y,
		(best["v_ms"] as Vector2).x,
		(best["v_ms"] as Vector2).y,
		float(best["t_ref"])
	)


func _on_enter_solution() -> void:
	if trial.range_m <= 0.0:
		_update_status("Auto Fit TMA first, then submit")
		return
	var st: String = str(last_fit.get("status", "CONVERGED")) if not last_fit.is_empty() else "NONE"
	system_sol = trial.commit(world.sim_time)
	if _weapon_panel != null:
		_weapon_panel.set_solution_available(true)
	if st in ["INSUFFICIENT_GEOMETRY", "MULTIMODAL", "STALE"]:
		_update_status("Submitted (%s - LOW confidence, maneuver and refit!)" % st)
	else:
		_update_status("System Solution submitted (%s)" % st)


## 武器面板 Fire 请求：用已提交的 SystemSolution（绝不读 Truth）真实发射。
func _on_fire_torpedo() -> void:
	if world == null or world.weapons == null:
		return
	if system_sol == null:
		_update_status("No System Solution — Auto Fit then Accept first")
		return
	var own: RefCounted = world.world["own"]
	var tp: Torpedo = world.weapons.fire(
		system_sol, float(own.position_east_m), float(own.position_north_m), world.sim_time
	)
	if tp != null:
		_update_status("Torpedo away (%s)" % tp.torpedo_id)
		_dirty = true
		if _weapon_panel != null:
			_weapon_panel.refresh()


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
	op.update(world.sim_time, world.world["targets"], world.world["target_acs"])
	_refresh_towed_status()
	_refresh_ping_status()
	if _op_panel.autocrew_on():
		for m in op.autocrew_step(world.sim_time):
			world.measurements.append(m)
			var t: Track = tracker.feed(m)
			if t == null:
				tracker.mark(m, "M")
			_dirty = true
			_update_status("Autocrew marked a new detection")
	_op_panel.refresh(op)


# ---- TOWED 拖曳阵：部署/回收 + 状态显示 ----


func _towed_ref() -> TowedArray:
	if world == null:
		return null
	return world.world.get("own", null).get("towed")


func _on_towed_deploy() -> void:
	var t: TowedArray = _towed_ref()
	if t == null:
		return
	t.stream()
	_update_status("Towed array streaming to %.0f m..." % t.commanded_tow_length_m)


func _on_towed_retract() -> void:
	var t: TowedArray = _towed_ref()
	if t == null:
		return
	t.retrieve()
	_update_status("Retrieving towed array...")


func _on_towed_hold() -> void:
	var t: TowedArray = _towed_ref()
	if t == null:
		return
	t.hold()
	_update_status("Towed length HOLD at %.0f m" % t.actual_tow_length_m)


## S1-03：缆长命令（frac ∈ 0..1 × max_tow_length_m，来自滑条/预设按钮）。
func _on_towed_length_commanded(frac: float) -> void:
	var t: TowedArray = _towed_ref()
	if t == null:
		return
	t.set_length_command(frac * t.max_tow_length_m)
	_update_status("Towed length cmd -> %.0f m" % t.commanded_tow_length_m)


## 刷新操作员面板的 TOWED 状态行 + 控件可用性（S1-03）。
## 状态行同时显示 ACT（实际缆长）与 CMD（命令缆长）——二者分离是 S1-03 核心。
func _refresh_towed_status() -> void:
	if _op_panel == null:
		return
	var t: TowedArray = _towed_ref()
	var on_towed: bool = op != null and op.active_array_id == "TOWED"
	if t == null or not on_towed:
		_op_panel.set_towed_status("Towed: n/a", false)
		return
	var line: String = (
		"Towed: %s | ACT %.0fm / CMD %.0fm | arr %.0f° | usable %d%%"
		% [
			t.state_name(),
			t.actual_tow_length_m,
			t.commanded_tow_length_m,
			t.array_heading_deg,
			int(t.usable_fraction() * 100.0),
		]
	)
	_op_panel.set_towed_status(line, true)
	_op_panel.update_towed_controls(t)


# ---- 主动声呐 Ping：薄接线，逻辑在 ActivePingController ----


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


## 主动回波命中回调（S1-04B）：命中测量已由控制器喂 Tracker，自动选中该接触
## 并 REFIT——单腿+range 可锚定（REQ-10），命中即 RANGE AIDED。
func _on_ping_echo_hits(fed: Array) -> void:
	if fed.is_empty():
		return
	var tr: Track = fed[0].get("track")
	if tr == null:
		return
	selected_track_id = tr.track_id
	_dirty = true
	_on_fit_tma()


## BB 瀑布图点击 → 玩家 Mark（Measurement 合法来源：玩家手动）。
## x_value 为当前显示基准方位：as_true=false 是艇艏相对方位(-180..180)，
## as_true=true 是真北方位(0..360)；create_mark 内部处理。
func _on_op_mark(x_value: float, as_true: bool = false, row: Dictionary = {}) -> void:
	var brg: float = x_value
	# S1-01/03：携带被点瀑布行上下文；S1-03A：镜像峰生成 A/B 共享证据候选
	var group: Array = op.create_mark_group(brg, world.sim_time, "", as_true, row)
	var m: Measurement = group[0] as Measurement
	world.measurements.append(m)
	var t: Track = null
	if selected_track_id != "":
		for tr in tracker.all_tracks():
			if tr.track_id == selected_track_id:
				t = tracker.feed(m, 8.0)
				break
	if t == null:
		t = tracker.mark(m, "M")
	# 镜像候选进同一 Track（共享 pair_id/证据，不得当独立目标或双倍计数）
	if group.size() > 1:
		var sib: Measurement = group[1] as Measurement
		world.measurements.append(sib)
		t.add_measurement(sib)
	selected_track_id = t.track_id
	_dirty = true
	_last_meas_count = world.measurements.size()
	var amb_txt: String = " (LR mirror pair)" if group.size() > 1 else ""
	_update_status("Marked %.1f deg -> %s%s" % [brg, t.track_id, amb_txt])
