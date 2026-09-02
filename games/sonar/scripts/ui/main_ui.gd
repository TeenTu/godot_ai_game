class_name SonarUI
extends Control
## main_ui.gd — 阶段三主 UI 装配与仿真驱动（TMA 重构版）。
##
## 布局：
##   ┌──────────┬──────────────────────────────┬──────────────┐
##   │ 方位盘    │       海图（ChartView）        │  控制面板     │
##   │ 220px     │      （自适应填充）            │  280px        │
##   ├──────────┴──────────────────────────────┴──────────────┤
##   │              Bearing-Time 图（150px）                    │
##   └─────────────────────────────────────────────────────────┘
##
## 职责：
##   - 构建全部 UI 控件（纯代码）
##   - 持有 World / Tracker / TrialSolution / SystemSolution / DotStack
##   - 按 time_scale 推进仿真，把新测量喂给 Tracker
##   - 每帧把显示数据注入 ChartView / BearingDisplay / BearingTimePlot
##   - 交互：Mark 接触、Auto Fit TMA（多初值全局搜索）、调整 Trial、Enter Solution
##
## TMA 重构要点（对应需求文档）：
##   - 历史全部 LOB 显示（从测量时刻本艇位置发出，带 σ 扇区、时间衰减）
##   - 拟合用 TmaSolver.solve_auto：多初值全局搜索 + 可观测性检查 + 多假设
##   - 拟合轨迹按时间刻度画在海图上（刻度落在对应 LOB 上）
##   - 自动拟合结果进入 Trial（Auto Trial），只有玩家 Enter 才进 System
##   - Dot Stack 只用被拟合 track 的测量
##
## Truth 隔离：只有 Show Truth 调试开关打开时，才把 Truth 位置传给海图。

const SCENARIO_NAME: String = "stage1_basic_passive"

var world: World = null
var tracker: Tracker = null
var trial: TrialSolution = null
var system_sol: SystemSolution = null
var dot_stack: DotStack = null
var last_fit: Dictionary = {}  # 最近一次 TmaFitResult

var _chart: ChartView = null
var _bearing: BearingDisplay = null
var _bt_plot: BearingTimePlot = null
var _panel: VBoxContainer = null

# 控制面板控件
var _btn_pause: Button = null
var _lbl_status: Label = null
var _btn_show_truth: Button = null
var _btn_mark: Button = null
var _btn_fit: Button = null
var _btn_enter: Button = null
var _lbl_track: Label = null
var _lbl_tma: Label = null
var _spin_bearing: SpinBox = null
var _spin_range: SpinBox = null
var _spin_course: SpinBox = null
var _spin_speed: SpinBox = null
var _lbl_dot: Label = null
# 本艇机动控制
var _spin_own_course: SpinBox = null
var _spin_own_speed: SpinBox = null

var _time_scale: float = 2.0
var _sim_accum: float = 0.0  # 跨帧累积的仿真时间（dt 步长推进）
var _paused: bool = false
var _processed_meas: int = 0
var _track_colors: Dictionary = {}  # track_id -> Color


func _ready() -> void:
	# SonarUI 自身是 Control，但被 main.gd 加到 Node2D 根下，
	# Node2D 不传递 Control 的锚点系统；这里显式跟随 viewport 撑满。
	var vp: Vector2 = get_viewport_rect().size
	set_size(vp)
	resized.connect(_on_self_resized)
	_build_ui()

	# 初始化仿真世界
	world = World.new()
	var scenario: Dictionary = ConfigLoader.load_scenario(SCENARIO_NAME)
	world.load_scenario(scenario)
	world.set_time_scale(_time_scale)

	# 接触管理
	tracker = Tracker.new()
	var rng: RandomNumberGenerator = world.world.get("rng", null)
	if rng != null:
		tracker.set_rng(rng)
	tracker.set_capacity(8)
	tracker.set_auto_interval(5.0)

	trial = TrialSolution.new()
	system_sol = null
	dot_stack = DotStack.new()

	# 用场景里本艇的初始航向/航速初始化 SpinBox（避免默认 0 与场景不一致）
	if _spin_own_course != null:
		_spin_own_course.set_value_no_signal(world.world["own"].course_deg)
	if _spin_own_speed != null:
		_spin_own_speed.set_value_no_signal(world.world["own"].speed_kn)

	_update_status("ready")


func _on_self_resized() -> void:
	# 留作未来扩展（窗口大小变化时通知子节点）。
	pass


func _build_ui() -> void:
	# SonarUI 自己是 Control 但挂在 Node2D 下，Node2D 不传锚点系统，
	# 这里完全用手动 size/position 布局（不用 PRESET_FULL_RECT）。
	var root := VBoxContainer.new()
	root.size = size
	root.position = Vector2.ZERO
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var main_row := HBoxContainer.new()
	main_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_theme_constant_override("separation", 4)
	root.add_child(main_row)

	# 左：方位盘
	_bearing = BearingDisplay.new()
	_bearing.custom_minimum_size = Vector2(220, 0)
	main_row.add_child(_bearing)

	# 中：海图
	_chart = ChartView.new()
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_child(_chart)

	# 右：控制面板（内容多，包进 ScrollContainer 支持滚动）
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(280, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_row.add_child(scroll)

	_panel = VBoxContainer.new()
	_panel.custom_minimum_size = Vector2(280, 0)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.add_theme_constant_override("separation", 6)
	scroll.add_child(_panel)

	var title := Label.new()
	title.text = "Submarine Sonar / TMA"
	title.add_theme_font_size_override("font_size", 18)
	_panel.add_child(title)

	# --- 仿真控制 ---
	var row_pause := HBoxContainer.new()
	row_pause.add_theme_constant_override("separation", 6)
	_panel.add_child(row_pause)
	_btn_pause = Button.new()
	_btn_pause.text = "⏸ Pause"
	_btn_pause.pressed.connect(_on_pause)
	row_pause.add_child(_btn_pause)
	_btn_mark = Button.new()
	_btn_mark.text = "Mark Contact"
	_btn_mark.pressed.connect(_on_mark)
	row_pause.add_child(_btn_mark)

	var row_speed := HBoxContainer.new()
	row_speed.add_theme_constant_override("separation", 6)
	_panel.add_child(row_speed)
	var spd_lbl := Label.new()
	spd_lbl.text = "Speed"
	spd_lbl.custom_minimum_size = Vector2(40, 0)
	row_speed.add_child(spd_lbl)
	var opt_speed := OptionButton.new()
	for s in [1, 2, 4, 8]:
		opt_speed.add_item("%dx" % s)
	opt_speed.select(1)  # 2x
	opt_speed.item_selected.connect(_on_speed)
	row_speed.add_child(opt_speed)

	_btn_show_truth = Button.new()
	_btn_show_truth.text = "Show Truth (debug)"
	_btn_show_truth.toggle_mode = true
	_btn_show_truth.toggled.connect(_on_show_truth)
	_panel.add_child(_btn_show_truth)

	_lbl_status = Label.new()
	_lbl_status.text = ""
	_lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_status.custom_minimum_size = Vector2(0, 52)
	_panel.add_child(_lbl_status)

	_panel.add_child(HSeparator.new())

	# --- 接触信息 ---
	_lbl_track = Label.new()
	_lbl_track.text = "Contacts: none"
	_lbl_track.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_track.custom_minimum_size = Vector2(0, 64)
	_panel.add_child(_lbl_track)

	_panel.add_child(HSeparator.new())

	# --- 本艇机动控制（关键：让 TMA 收窄近慢/远快歧义）---
	var own_title := Label.new()
	own_title.text = "Own Ship Maneuver"
	own_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(own_title)

	_spin_own_course = _add_spin("Own Course (°)", 0, 359, 1, 0)
	_spin_own_speed = _add_spin("Own Speed (kn)", 0, 30, 0.5, 0)
	_spin_own_course.value_changed.connect(_on_own_course)
	_spin_own_speed.value_changed.connect(_on_own_speed)

	# 快速 ±5°/±2kn 按钮
	var row_turn := HBoxContainer.new()
	row_turn.add_theme_constant_override("separation", 4)
	_panel.add_child(row_turn)
	var btn_l := Button.new()
	btn_l.text = "Left 5°"
	btn_l.pressed.connect(_on_turn_left)
	row_turn.add_child(btn_l)
	var btn_r := Button.new()
	btn_r.text = "Right 5°"
	btn_r.pressed.connect(_on_turn_right)
	row_turn.add_child(btn_r)
	var btn_faster := Button.new()
	btn_faster.text = "+2kn"
	btn_faster.pressed.connect(_on_speed_up)
	row_turn.add_child(btn_faster)
	var btn_slower := Button.new()
	btn_slower.text = "-2kn"
	btn_slower.pressed.connect(_on_slow_down)
	row_turn.add_child(btn_slower)

	_panel.add_child(HSeparator.new())

	# --- TMA ---
	var tma_title := Label.new()
	tma_title.text = "TMA Solution (Auto Fit)"
	tma_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(tma_title)

	_btn_fit = Button.new()
	_btn_fit.text = "🔄 Auto Fit TMA"
	_btn_fit.pressed.connect(_on_fit_tma)
	_panel.add_child(_btn_fit)

	# 拟合状态详情（状态机/可观测性/多假设等）
	_lbl_tma = Label.new()
	_lbl_tma.text = "No fit yet. Maneuver, mark, then Auto Fit."
	_lbl_tma.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_tma.custom_minimum_size = Vector2(0, 120)
	_panel.add_child(_lbl_tma)

	_spin_bearing = _add_spin("Bearing (°)", 0, 359, 1, 0)
	_spin_range = _add_spin("Range (m)", 100, 50000, 100, 0)
	_spin_course = _add_spin("Course (°)", 0, 359, 1, 0)
	_spin_speed = _add_spin("Speed (kn)", 0, 40, 0.5, 0)
	_spin_bearing.value_changed.connect(func(v): trial.set_bearing(v))
	_spin_range.value_changed.connect(func(v): trial.set_range(v))
	_spin_course.value_changed.connect(func(v): trial.set_course(v))
	_spin_speed.value_changed.connect(func(v): trial.set_speed(v))

	_btn_enter = Button.new()
	_btn_enter.text = "✅ Accept as System Solution"
	_btn_enter.pressed.connect(_on_enter_solution)
	_panel.add_child(_btn_enter)

	# --- Dot Stack ---
	_lbl_dot = Label.new()
	_lbl_dot.text = "Dot Stack: —"
	_lbl_dot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_dot.custom_minimum_size = Vector2(0, 40)
	_panel.add_child(_lbl_dot)

	# 底部：Bearing-Time 图
	_bt_plot = BearingTimePlot.new()
	_bt_plot.custom_minimum_size = Vector2(0, 150)
	root.add_child(_bt_plot)


## 渲染入口
func _draw() -> void:
	# 背景兜底：万一父容器没填满
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.06, 0.08, 1.0))


## 添加带标题的 SpinBox 到控制面板，返回 SpinBox。
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


func _process(delta: float) -> void:
	if world == null:
		return
	# 推进仿真（固定步长，按倍速累计；accumulator 跨帧累积，避免真实
	# 帧率下 delta*scale < dt 导致永不推进）
	var dt: float = world.world["dt"]
	_sim_accum += delta * _time_scale
	var steps: int = 0
	while _sim_accum >= dt and steps < 500:
		world.tick()
		_sim_accum -= dt
		steps += 1

	_feed_new_measurements()
	_update_displays()
	_update_panel()


func _feed_new_measurements() -> void:
	var ms: Array = world.measurements
	while _processed_meas < ms.size():
		var m: Measurement = ms[_processed_meas]
		if _processed_meas == 0:
			# 第一条测量：自动建首个接触（Mark）
			tracker.mark(m, "S")
		else:
			var t: Track = tracker.feed(m)
			if t == null:
				# 无法关联到已有 ACTIVE 接触 → 新建接触
				tracker.mark(m, "S")
		_processed_meas += 1


func _update_displays() -> void:
	var own: TruthEntity = world.world["own"]

	# 海图数据
	_chart.own_pos = Vector2(own.position_east_m, own.position_north_m)
	_chart.own_track = _sample_own_track()
	_chart.lobs = _collect_lobs()
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
	_chart.truth_positions = _collect_truth()
	_inject_fit_data()
	_chart.queue_redraw()

	# 方位盘数据
	_bearing.own_course_deg = own.course_deg
	var latest_lobs: Array = _collect_lobs()
	# 方位盘只显示每条 track 最新一条 LOB
	var newest: Dictionary = {}
	for lob in latest_lobs:
		newest[lob["id"]] = lob
	var disk_lobs: Array = newest.values()
	_bearing.lobs = disk_lobs
	var latest: Measurement = _latest_measurement()
	if latest != null:
		_bearing.latest_bearing_deg = latest.measured_bearing_deg
		_bearing.latest_color = _color_for_track("LATEST")
	else:
		_bearing.latest_bearing_deg = -1.0
	_bearing.queue_redraw()

	# Bearing-Time 图
	_update_bt_plot()
	_bt_plot.queue_redraw()


## 注入自动拟合结果到海图（轨迹时间刻度 / 备选解 / 不确定区）。
func _inject_fit_data() -> void:
	_chart.fit_hypotheses = []
	_chart.fit_meas_times = []
	_chart.fit_pos_unc_m = -1.0
	_chart.fit_now_time = world.sim_time
	_chart.fit_stale_s = float(last_fit.get("stale_seconds", 0.0))
	if last_fit.is_empty() or not bool(last_fit.get("success", false)):
		return
	var hyps: Array = []
	var best: Dictionary = last_fit.get("best", {})
	if best.is_empty():
		return
	(
		hyps
		. append(
			{
				"p_ref": best["p_ref"],
				"v_ms": best["v_ms"],
				"t_ref": float(best["t_ref"]),
				"weight": 1.0,
				"is_best": true,
				"speed_kn": float(best.get("speed_kn", 0.0)),
				"course_deg": float(best.get("course_deg", 0.0)),
			}
		)
	)
	var alt_idx: int = 0
	for alt in last_fit.get("alternatives", []):
		# 只显示有权重（代价接近）的备选解
		if float(alt.get("weight", 0.0)) < 0.02:
			continue
		alt["is_best"] = false
		alt_idx += 1
		hyps.append(alt)
	_chart.fit_hypotheses = hyps
	# 时间刻度 = 被使用测量的时刻
	var times: Array = []
	for res in last_fit.get("residuals", []):
		if bool(res.get("inlier", true)):
			times.append(float(res["time"]))
	_chart.fit_meas_times = times
	_chart.fit_pos_unc_m = float(last_fit.get("position_uncertainty_m", -1.0))


## 更新 Bearing-Time 图数据。
func _update_bt_plot() -> void:
	# 实测点：所有 ACTIVE track 的全部测量（按 track 着色）
	var points: Array = []
	var t_min: float = INF
	var t_max: float = -INF
	for t in tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var col: Color = _color_for_track(t.track_id)
		for m in t.measurement_history:
			(
				points
				. append(
					{
						"time": m.timestamp,
						"bearing_deg": m.measured_bearing_deg,
						"sigma_deg": maxf(m.bearing_sigma_deg, 0.5),
						"color": col,
					}
				)
			)
			t_min = minf(t_min, m.timestamp)
			t_max = maxf(t_max, m.timestamp)
	if points.is_empty():
		_bt_plot.meas_points = []
		_bt_plot.model_curves = []
		_bt_plot.turn_times = []
		_bt_plot.set_time_window(0.0, 1.0)
		return
	# 模型曲线：最优解 + 有权重的备选解
	var curves: Array = []
	if not last_fit.is_empty() and bool(last_fit.get("success", false)):
		var best: Dictionary = last_fit.get("best", {})
		if not best.is_empty():
			curves.append(_model_curve(best, Color(0.95, 0.45, 0.15), true))
		for alt in last_fit.get("alternatives", []):
			if float(alt.get("weight", 0.0)) >= 0.02:
				curves.append(_model_curve(alt, Color(0.55, 0.65, 0.85, 0.8), false))
	_bt_plot.meas_points = points
	_bt_plot.model_curves = curves
	_bt_plot.turn_times = _own_turn_times()
	_bt_plot.set_time_window(t_min, maxf(t_max, world.sim_time))


## 由假设的 pred_bearings（与被拟合测量一一对应）构造曲线点列。
func _model_curve(hyp: Dictionary, col: Color, is_best: bool) -> Dictionary:
	var pts: Array = []
	var pred: Array = hyp.get("pred_bearings", [])
	var i: int = 0
	for res in last_fit.get("residuals", []):
		if i < pred.size():
			pts.append({"time": float(res["time"]), "bearing_deg": float(pred[i])})
		i += 1
	return {"points": pts, "color": col, "width": 2.0 if is_best else 1.0, "best": is_best}


## 由测量附带的连续本艇位置推算转向时刻（航向变化 > 15°）。
func _own_turn_times() -> Array:
	var ms: Array = world.measurements
	var turns: Array = []
	if ms.size() < 3:
		return turns
	var prev_heading: float = INF
	var prev_t: float = -INF
	for i in range(1, ms.size()):
		var d := Vector2(
			ms[i].observer_east_m - ms[i - 1].observer_east_m,
			ms[i].observer_north_m - ms[i - 1].observer_north_m
		)
		if d.length() < 5.0:
			continue
		var heading: float = rad_to_deg(atan2(d.x, d.y))
		if prev_heading != INF and absf(NavUtils.angle_diff(heading, prev_heading)) > 15.0:
			turns.append(ms[i].timestamp)
		prev_heading = heading
		prev_t = ms[i].timestamp
	return turns


func _sample_own_track() -> Array:
	var pts: Array = []
	pts.append(Vector2(world.world["own"].position_east_m, world.world["own"].position_north_m))
	for m in world.measurements:
		pts.append(Vector2(m.observer_east_m, m.observer_north_m))
	var seen := {}
	var out: Array = []
	for p in pts:
		var key: String = "%d_%d" % [int(p.x), int(p.y)]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(p)
		if out.size() > 400:
			break
	return out


## 收集全部 ACTIVE track 的全部历史 LOB（需求文档第九节 1：
## 每条 LOB 从测量时刻本艇位置发出；age 用于透明度衰减）。
func _collect_lobs() -> Array:
	var out: Array = []
	var now: float = world.sim_time
	# 当前拟合的离群测量集合（按 time 标记）
	var outlier_times: Dictionary = {}
	if not last_fit.is_empty() and bool(last_fit.get("success", false)):
		for res in last_fit.get("residuals", []):
			if not bool(res.get("inlier", true)):
				outlier_times[float(res["time"])] = true
	for t in tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var col: Color = _color_for_track(t.track_id)
		for m in t.measurement_history:
			(
				out
				. append(
					{
						"origin": Vector2(m.observer_east_m, m.observer_north_m),
						"bearing_deg": m.measured_bearing_deg,
						"color": col,
						"id": t.track_id,
						"age_s": maxf(now - m.timestamp, 0.0),
						"sigma_deg": maxf(m.bearing_sigma_deg, 0.5),
						"inlier": not outlier_times.has(m.timestamp),
					}
				)
			)
	return out


func _collect_truth() -> Array:
	var out: Array = []
	for t in world.world["targets"]:
		(
			out
			. append(
				{
					"pos": Vector2(t.position_east_m, t.position_north_m),
					"id": t.id,
				}
			)
		)
	return out


func _latest_measurement() -> Measurement:
	if world.measurements.is_empty():
		return null
	return world.measurements[world.measurements.size() - 1]


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


func _update_panel() -> void:
	if world == null:
		return
	var status: String = (
		"Time %.0fs | Meas %d | %dx%s"
		% [
			world.sim_time,
			world.measurements.size(),
			int(_time_scale),
			" ⏸" if _paused else "",
		]
	)
	_lbl_status.text = status

	# 接触列表
	var txt: String = "Contacts:"
	var any: bool = false
	for t in tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var m: Measurement = t.latest_measurement()
		txt += (
			"\n%s  Brg %.0f°  (%d meas)"
			% [t.track_id, m.measured_bearing_deg, t.measurement_history.size()]
		)
		any = true
	if not any:
		txt += " none"
	_lbl_track.text = txt

	# Trial 参数回显（用户没在编辑时才覆盖，避免抢输入）
	if trial.range_m > 0.0:
		if not _spin_bearing.has_focus():
			_spin_bearing.set_value_no_signal(trial.bearing_deg)
		if not _spin_range.has_focus():
			_spin_range.set_value_no_signal(trial.range_m)
		if not _spin_course.has_focus():
			_spin_course.set_value_no_signal(trial.course_deg)
		if not _spin_speed.has_focus():
			_spin_speed.set_value_no_signal(trial.speed_kn)

	# Dot Stack
	if dot_stack.residual_entries.size() > 0:
		_lbl_dot.text = (
			"Dot Stack: RMS %.2f° (%d pts)"
			% [
				dot_stack.rms_residual_deg(),
				dot_stack.residual_entries.size(),
			]
		)
	else:
		_lbl_dot.text = "Dot Stack: —"

	# 本艇航向/航速回显（仅当用户没在编辑时同步 Truth 状态）
	if _spin_own_course != null and not _spin_own_course.has_focus():
		_spin_own_course.set_value_no_signal(world.world["own"].course_deg)
	if _spin_own_speed != null and not _spin_own_speed.has_focus():
		_spin_own_speed.set_value_no_signal(world.world["own"].speed_kn)


func _on_pause() -> void:
	_paused = not _paused
	world.set_paused(_paused)
	_btn_pause.text = "▶ Resume" if _paused else "⏸ Pause"


## 本艇机动回调：直接改 Truth 状态，下次 tick 起生效。
func _on_own_course(deg: float) -> void:
	if world == null:
		return
	world.world["own"].course_deg = NavUtils.wrap360(deg)


func _on_own_speed(kn: float) -> void:
	if world == null:
		return
	world.world["own"].speed_kn = maxf(kn, 0.0)


func _on_turn_left() -> void:
	_change_own_course(-5.0)


func _on_turn_right() -> void:
	_change_own_course(5.0)


func _change_own_course(delta_deg: float) -> void:
	if world == null or _spin_own_course == null:
		return
	var new_deg: float = NavUtils.wrap360(_spin_own_course.value + delta_deg)
	_spin_own_course.set_value_no_signal(new_deg)
	world.world["own"].course_deg = new_deg


func _on_speed_up() -> void:
	_change_own_speed(2.0)


func _on_slow_down() -> void:
	_change_own_speed(-2.0)


func _change_own_speed(delta_kn: float) -> void:
	if world == null or _spin_own_speed == null:
		return
	var new_kn: float = clampf(_spin_own_speed.value + delta_kn, 0.0, 30.0)
	_spin_own_speed.set_value_no_signal(new_kn)
	world.world["own"].speed_kn = new_kn


func _on_speed(index: int) -> void:
	_time_scale = [1, 2, 4, 8][index]
	world.set_time_scale(_time_scale)


func _on_show_truth(on: bool) -> void:
	_chart.show_truth = on


func _on_mark() -> void:
	var m: Measurement = _latest_measurement()
	if m == null:
		return
	tracker.mark(m, "S")
	_update_status("Manual Mark: new contact")


## 自动拟合 TMA（TmaSolver.solve_auto 完整流水线）：
##   多初值全局搜索 → 有边界 LM → 聚类 → 多假设 → 可观测性 → 状态机。
## 结果写入 Trial（Auto Trial Solution）；只有玩家点击 Accept 才进 System。
func _on_fit_tma() -> void:
	var best_track: Track = null
	for t in tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE and t.measurement_history.size() >= 4:
			best_track = t
			break
	if best_track == null:
		_update_status("Need a contact with >= 4 measurements to fit")
		return

	var meas: Array = []
	for m in best_track.measurement_history:
		meas.append(_meas_to_dict(m))

	var r: Dictionary = TmaSolver.solve_auto(meas, {"now_time": world.sim_time})
	if not bool(r.get("success", false)):
		_update_status("TMA failed: " + str(r.get("status", "unknown")))
		return

	last_fit = r
	var best: Dictionary = r.get("best", {})

	# 写入 Trial（Auto Trial Solution，不自动进 System）
	trial.bearing_deg = float(best.get("bearing_deg", 0.0))
	trial.range_m = float(best.get("range_m", 0.0))
	trial.course_deg = float(best.get("course_deg", 0.0))
	trial.speed_kn = float(best.get("speed_kn", 0.0))
	trial.solution_time = world.sim_time
	# 当前估计位置：参考时刻位置 + 速度外推到当前时刻
	var dt_now: float = world.sim_time - float(best.get("t_ref", world.sim_time))
	var v := best.get("v_ms", Vector2.ZERO) as Vector2
	trial.estimated_position_east_m = (best["p_ref"] as Vector2).x + v.x * dt_now
	trial.estimated_position_north_m = (best["p_ref"] as Vector2).y + v.y * dt_now

	# Dot Stack 只用被拟合 track 的测量（修复：原来误用全量测量）
	var inlier_meas: Array = []
	var inlier_set: Dictionary = {}
	for res in r.get("residuals", []):
		if bool(res.get("inlier", true)):
			inlier_set[float(res["time"])] = true
	for m in best_track.measurement_history:
		if inlier_set.has(m.timestamp):
			inlier_meas.append(_meas_to_dict(m))
	if not inlier_meas.is_empty():
		var b := best
		dot_stack.compute(
			inlier_meas,
			(b["p_ref"] as Vector2).x,
			(b["p_ref"] as Vector2).y,
			(b["v_ms"] as Vector2).x,
			(b["v_ms"] as Vector2).y,
			float(b["t_ref"])
		)

	# 面板详情 + 立即刷新海图/曲线注入
	_lbl_tma.text = _fit_summary(r)
	_update_displays()
	_update_panel()
	_update_status(
		(
			"TMA %s | B%.0f° R%.0fm C%.0f° S%.1fkn"
			% [
				str(r.get("status", "?")),
				trial.bearing_deg,
				trial.range_m,
				trial.course_deg,
				trial.speed_kn,
			]
		)
	)


## 拟合结果摘要（状态机全字段，不得只显示笼统置信度）。
func _fit_summary(r: Dictionary) -> String:
	var lines: Array = []
	lines.append("Status: %s" % str(r.get("status", "?")))
	if bool(r.get("maneuver_suspected", false)):
		lines.append("!! Target maneuver suspected - re-maneuver & refit")
	if int(r.get("hypothesis_count", 0)) > 1:
		var n_alt: int = int(r.get("hypothesis_count", 1)) - 1
		lines.append("Alternatives: %d (multi-hypothesis)" % n_alt)
		for alt in r.get("alternatives", []):
			var w: float = float(alt.get("weight", 0.0))
			if w >= 0.02:
				var rng_m: float = float(alt.get("range_m", 0.0))
				var crs_d: float = float(alt.get("course_deg", 0.0))
				var spd_k: float = float(alt.get("speed_kn", 0.0))
				lines.append("  alt w=%.2f R%.0fm C%.0f S%.1fkn" % [w, rng_m, crs_d, spd_k])
	(
		lines
		. append(
			(
				"Ref t=%.0fs stale=%.0fs meas=%d rej=%d legs=%d"
				% [
					float(r.get("reference_time", 0.0)),
					float(r.get("stale_seconds", 0.0)),
					int(r.get("measurements_used", 0)),
					int(r.get("measurements_rejected", []).size()),
					int(r.get("legs", 0)),
				]
			)
		)
	)
	var cond: float = float(r.get("condition_number", 0.0))
	var cond_txt: String = "inf" if is_inf(cond) else "%.0f" % cond
	lines.append(
		(
			"RMSE %.2f deg rank=%d cond=%s"
			% [float(r.get("angular_rmse", 0.0)), int(r.get("jacobian_rank", 0)), cond_txt]
		)
	)
	var unc: float = float(r.get("position_uncertainty_m", -1.0))
	if unc > 0.0:
		lines.append(
			(
				"Pos +/-%.0fm Spd +/-%.1fkn"
				% [unc, NavUtils.ms_to_kn(float(r.get("velocity_uncertainty_ms", 0.0)))]
			)
		)
	else:
		lines.append("Uncertainty: N/A (not observable/unimodal)")
	if bool(r.get("boundary_hit", false)):
		lines.append("!! BOUNDARY_HIT: solution at parameter limit")
	var text: String = ""
	for ln in lines:
		text += ln + "\n"
	return text


func _meas_to_dict(m: Measurement) -> Dictionary:
	return {
		"time": m.timestamp,
		"observer_e": m.observer_east_m,
		"observer_n": m.observer_north_m,
		"bearing": m.measured_bearing_deg,
		"sigma": m.bearing_sigma_deg,
	}


func _on_enter_solution() -> void:
	if trial.range_m <= 0.0:
		_update_status("Auto Fit TMA first, then submit")
		return
	# 有效性门槛：不可观测/多解状态下提交要二次确认提示
	var st: String = str(last_fit.get("status", "CONVERGED")) if not last_fit.is_empty() else "NONE"
	system_sol = trial.commit(world.sim_time)
	if st in ["INSUFFICIENT_GEOMETRY", "MULTIMODAL", "STALE"]:
		_update_status("Submitted (%s - LOW confidence, maneuver and refit!)" % st)
	else:
		_update_status("System Solution submitted (%s)" % st)


func _update_status(msg: String) -> void:
	if world != null:
		_lbl_status.text = (
			"Time %.0fs | Meas %d\n%s" % [world.sim_time, world.measurements.size(), msg]
		)
	else:
		_lbl_status.text = msg
