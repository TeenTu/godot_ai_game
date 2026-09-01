class_name SonarUI
extends Control
## main_ui.gd — 阶段三主 UI 装配与仿真驱动。
##
## 布局：
##   ┌──────────┬──────────────────────────────┬──────────────┐
##   │ 方位盘    │       海图（ChartView）        │  控制面板     │
##   │ 220px     │      （自适应填充）            │  280px        │
##   └──────────┴──────────────────────────────┴──────────────┘
##
## 职责：
##   - 构建全部 UI 控件（纯代码）
##   - 持有 World / Tracker / TrialSolution / SystemSolution / DotStack
##   - 按 time_scale 推进仿真，把新测量喂给 Tracker
##   - 每帧把显示数据注入 ChartView / BearingDisplay
##   - 交互：Mark 接触、Fit TMA、调整 Trial 参数、Enter Solution
##
## Truth 隔离：只有 Show Truth 调试开关打开时，才把 Truth 位置传给海图。

const SCENARIO_NAME: String = "stage1_basic_passive"

var world: World = null
var tracker: Tracker = null
var trial: TrialSolution = null
var system_sol: SystemSolution = null
var dot_stack: DotStack = null

var _chart: ChartView = null
var _bearing: BearingDisplay = null
var _panel: VBoxContainer = null

# 控制面板控件
var _btn_pause: Button = null
var _lbl_status: Label = null
var _btn_show_truth: Button = null
var _btn_mark: Button = null
var _btn_fit: Button = null
var _btn_enter: Button = null
var _lbl_track: Label = null
var _spin_bearing: SpinBox = null
var _spin_range: SpinBox = null
var _spin_course: SpinBox = null
var _spin_speed: SpinBox = null
var _lbl_dot: Label = null
# 本艇机动控制
var _spin_own_course: SpinBox = null
var _spin_own_speed: SpinBox = null

var _time_scale: float = 2.0
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
	var root := HBoxContainer.new()
	root.size = size
	root.position = Vector2.ZERO
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	# 左：方位盘
	_bearing = BearingDisplay.new()
	_bearing.custom_minimum_size = Vector2(220, 0)
	root.add_child(_bearing)

	# 中：海图
	_chart = ChartView.new()
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_chart)

	# 右：控制面板（内容多，包进 ScrollContainer 支持滚动）
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(280, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

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
	tma_title.text = "TMA Solution"
	tma_title.add_theme_font_size_override("font_size", 15)
	_panel.add_child(tma_title)

	_btn_fit = Button.new()
	_btn_fit.text = "🔄 Fit TMA"
	_btn_fit.pressed.connect(_on_fit_tma)
	_panel.add_child(_btn_fit)

	_spin_bearing = _add_spin("Bearing (°)", 0, 359, 1, 0)
	_spin_range = _add_spin("Range (m)", 100, 50000, 100, 0)
	_spin_course = _add_spin("Course (°)", 0, 359, 1, 0)
	_spin_speed = _add_spin("Speed (kn)", 0, 40, 0.5, 0)
	_spin_bearing.value_changed.connect(func(v): trial.set_bearing(v))
	_spin_range.value_changed.connect(func(v): trial.set_range(v))
	_spin_course.value_changed.connect(func(v): trial.set_course(v))
	_spin_speed.value_changed.connect(func(v): trial.set_speed(v))

	_btn_enter = Button.new()
	_btn_enter.text = "✅ Enter Solution"
	_btn_enter.pressed.connect(_on_enter_solution)
	_panel.add_child(_btn_enter)

	# --- Dot Stack ---
	_lbl_dot = Label.new()
	_lbl_dot.text = "Dot Stack: —"
	_lbl_dot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_dot.custom_minimum_size = Vector2(0, 40)
	_panel.add_child(_lbl_dot)


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
	# 推进仿真（固定步长，按倍速累计）
	var acc: float = delta * _time_scale
	var dt: float = world.world["dt"]
	var steps: int = 0
	while acc >= dt and steps < 500:
		world.tick()
		acc -= dt
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
	_chart.tma_track = _compute_tma_track_points()
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
	_chart.queue_redraw()

	# 方位盘数据
	_bearing.own_course_deg = own.course_deg
	_bearing.lobs = _collect_lobs()
	var latest: Measurement = _latest_measurement()
	if latest != null:
		_bearing.latest_bearing_deg = latest.measured_bearing_deg
		_bearing.latest_color = _color_for_track("LATEST")
	else:
		_bearing.latest_bearing_deg = -1.0
	_bearing.queue_redraw()


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


func _collect_lobs() -> Array:
	var out: Array = []
	for t in tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var m: Measurement = t.latest_measurement()
		if m == null:
			continue
		(
			out
			. append(
				{
					"origin": Vector2(m.observer_east_m, m.observer_north_m),
					"bearing_deg": m.measured_bearing_deg,
					"color": _color_for_track(t.track_id),
					"id": t.track_id,
				}
			)
		)
	return out


## 用 Trial 解推算一段目标轨迹（前 120s 到后 180s）。
func _compute_tma_track_points() -> Array:
	if trial.range_m <= 0.0:
		return []
	var pts: Array = []
	var p0: Vector2 = Vector2(trial.estimated_position_east_m, trial.estimated_position_north_m)
	var v := Vector2(
		NavUtils.kn_to_ms(trial.speed_kn) * sin(deg_to_rad(trial.course_deg)),
		NavUtils.kn_to_ms(trial.speed_kn) * cos(deg_to_rad(trial.course_deg)),
	)
	for dt in range(-120, 180, 20):
		pts.append(p0 + v * float(dt))
	return pts


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


## 拟合 TMA：用首个 ACTIVE track 的全部测量做加权最小二乘。
## 结果写入 TrialSolution，并同步到 SpinBox / Dot Stack。
func _on_fit_tma() -> void:
	var best_track: Track = null
	for t in tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE and t.measurement_history.size() >= 4:
			best_track = t
			break
	if best_track == null:
		_update_status("Need at least 4 measurements to fit")
		return

	var meas: Array = []
	for m in best_track.measurement_history:
		meas.append(_meas_to_dict(m))

	var start: Dictionary = {}
	if trial.range_m > 0.0:
		var v := Vector2(
			NavUtils.kn_to_ms(trial.speed_kn) * sin(deg_to_rad(trial.course_deg)),
			NavUtils.kn_to_ms(trial.speed_kn) * cos(deg_to_rad(trial.course_deg)),
		)
		start = {
			"p0_e": trial.estimated_position_east_m,
			"p0_n": trial.estimated_position_north_m,
			"v_e_ms": v.x,
			"v_n_ms": v.y,
		}
	else:
		start = _rough_guess(meas)

	var r: Dictionary = TmaSolver.solve(meas, start)
	if not r.get("success", false):
		_update_status("TMA failed: " + str(r.get("error", "unknown")))
		return

	trial.from_solver(r)

	# Dot Stack 用全部测量
	var all_meas: Array = []
	for m in world.measurements:
		all_meas.append(_meas_to_dict(m))
	dot_stack.compute(all_meas, r["p0_e"], r["p0_n"], r["v_e_ms"], r["v_n_ms"], r["t0"])

	_update_status(
		(
			"TMA ✓ B%.0f° R%.0fm C%.0f° S%.1fkn RMS%.2f°"
			% [
				r["bearing_deg"],
				r["range_m"],
				r["course_deg"],
				r["speed_kn"],
				r["rms_residual_deg"],
			]
		)
	)


func _meas_to_dict(m: Measurement) -> Dictionary:
	return {
		"time": m.timestamp,
		"observer_e": m.observer_east_m,
		"observer_n": m.observer_north_m,
		"bearing": m.measured_bearing_deg,
		"sigma": m.bearing_sigma_deg,
	}


## 粗略初值：最新两条测量方位线最近点作为位置，速度 0。
func _rough_guess(meas: Array) -> Dictionary:
	if meas.size() < 2:
		return {}
	var m0: Dictionary = meas[meas.size() - 2]
	var m1: Dictionary = meas[meas.size() - 1]
	var o0 := Vector2(float(m0["observer_e"]), float(m0["observer_n"]))
	var o1 := Vector2(float(m1["observer_e"]), float(m1["observer_n"]))
	var b0: float = deg_to_rad(float(m0["bearing"]))
	var b1: float = deg_to_rad(float(m1["bearing"]))
	var d0 := Vector2(sin(b0), cos(b0))
	var d1 := Vector2(sin(b1), cos(b1))
	var near: Array = _closest_point(o0, d0, o1, d1)
	var p: Vector2 = (near[0] + near[1]) * 0.5
	return {"p0_e": p.x, "p0_n": p.y, "v_e_ms": 0.0, "v_n_ms": 0.0}


## 两条射线最近点（简化版，避免依赖 solver 私有函数）。
func _closest_point(pa: Vector2, da: Vector2, pb: Vector2, db: Vector2) -> Array:
	var r: Vector2 = pa - pb
	var a: float = da.dot(da)
	var e: float = db.dot(db)
	var f: float = db.dot(r)
	if a <= 1e-9 or e <= 1e-9:
		return [pa, pb]
	var c: float = da.dot(r)
	var b: float = da.dot(db)
	var denom: float = a * e - b * b
	var s: float = 0.0
	var t: float = 0.0
	if absf(denom) > 1e-9:
		s = (b * f - c * e) / denom
		t = (a * f - b * c) / denom
	return [pa + da * s, pb + db * t]


func _on_enter_solution() -> void:
	if trial.range_m <= 0.0:
		_update_status("Fit TMA first, then submit")
		return
	system_sol = trial.commit(world.sim_time)
	_update_status("System Solution submitted")


func _update_status(msg: String) -> void:
	if world != null:
		_lbl_status.text = (
			"Time %.0fs | Meas %d\n%s" % [world.sim_time, world.measurements.size(), msg]
		)
	else:
		_lbl_status.text = msg
