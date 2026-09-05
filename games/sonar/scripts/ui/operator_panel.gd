class_name OperatorPanel
extends VBoxContainer
## operator_panel.gd — Sonar Operator Layer 面板。
##
## 包含：阵列切换（BOW/FLANK/TOWED）、Autocrew 开关（默认关）、
## Broadband 方位-时间瀑布、Narrowband/LOFAR 频率-时间瀑布、
## DEMON 包络谱瀑布、概率分类与 DEMON 测速标签。
##
## 数据流：main_ui 调 set_operator(op) 并在 op 有新行时调 refresh()；
## 玩家点击 BB 瀑布 → mark_requested(bearing_deg) 信号 → main_ui 建 Mark。

signal mark_requested(bearing_deg: float, as_true: bool, row: Dictionary)
signal array_changed(array_id: String)
signal autocrew_toggled(on: bool)
signal towed_deploy_requested
signal towed_retract_requested
signal towed_hold_requested
signal towed_length_commanded(frac: float)  # 0..1 × max_tow_length_m（S1-03）
signal ping_requested  # S1-04：玩家按下主动声呐 Ping
signal active_return_selected(return_index: int)  # S1-04C：点 Latest Returns 行
signal active_undo_requested  # S1-04C：撤销最近一次自动关联（改绑/Reject）
signal active_fit_mode_requested(mode: String)  # S1-04C-REQ-02：TMA 拟合模式
signal active_take_control_requested  # S1-04C-REQ-02：Take Control（→MANUAL）
signal active_apply_requested  # S1-04C-REQ-02：ASSISTED 应用 range 到 Trial

const MAX_ROWS_SHOWN: int = 80

var wf_bb: WaterfallView = null
var wf_nb: WaterfallView = null
var wf_demon: WaterfallView = null
var _lbl_bb_mode: Label = null  # 标注当前 BB 瀑布显示基准（RELATIVE / TRUE STABILIZED）
var _lbl_nb_band: Label = null  # REQ-09：窄带频段标注
var _sonar: OperatorSonar = null  # REQ-09：refresh 时缓存引用（频段切换用）

var _autocrew: CheckBox = null
var _lbl_class: Label = null
var _lbl_demon: Label = null
var _arr_opt: OptionButton = null  # 阵列选择（无拖曳硬件时禁用 TOWED 项，S1-03）
var _tow_ctl: VBoxContainer = null  # TOWED 长度命令区（S1-03）
var _btn_tow_deploy: Button = null
var _btn_tow_retract: Button = null
var _btn_tow_hold: Button = null
var _len_slider: HSlider = null
var _lbl_tow: Label = null  # TOWED 状态/阵航向/长度显示
var _active_card: ActiveSonarCard = null  # 主动声呐结构化卡片（S1-04C-REQ-01）
var _last_row_count: int = -1
var _last_wf_seq: int = -1  # P1-10：封顶后 size 恒定，按单调序号判定刷新
var _last_array_id: String = ""  # S1-03B：切阵列时即使行数相同也强制刷新瀑布


func _init() -> void:
	var row := HBoxContainer.new()
	var arr_lbl := Label.new()
	arr_lbl.text = "Array:"
	arr_lbl.add_theme_font_size_override("font_size", 14)
	row.add_child(arr_lbl)
	var arr_opt := OptionButton.new()
	for aid in OperatorSonar.ARRAY_DEFS:
		arr_opt.add_item(aid)
	arr_opt.item_selected.connect(func(i: int): array_changed.emit(arr_opt.get_item_text(i)))
	_arr_opt = arr_opt
	row.add_child(arr_opt)
	_autocrew = CheckBox.new()
	_autocrew.text = "Autocrew (off)"
	_autocrew.button_pressed = false  # 默认关闭自动 Mark/建 Track
	_autocrew.add_theme_font_size_override("font_size", 14)
	_autocrew.toggled.connect(
		func(on: bool):
			_autocrew.text = "Autocrew (on)" if on else "Autocrew (off)"
			autocrew_toggled.emit(on)
	)
	row.add_child(_autocrew)
	add_child(row)

	# TOWED 拖曳阵（S1-03 可控长度）：STREAM/HOLD/RETRIEVE + 长度滑条 + 预设。
	# 选择 TOWED 显示不再自动触发布放；按钮不可用时显示原因。
	_tow_ctl = VBoxContainer.new()
	_tow_ctl.add_theme_constant_override("separation", 2)
	add_child(_tow_ctl)
	var tow_btns := HBoxContainer.new()
	tow_btns.add_theme_constant_override("separation", 4)
	_tow_ctl.add_child(tow_btns)
	_btn_tow_deploy = Button.new()
	_btn_tow_deploy.text = "Stream"
	_btn_tow_deploy.pressed.connect(func(): towed_deploy_requested.emit())
	tow_btns.add_child(_btn_tow_deploy)
	_btn_tow_hold = Button.new()
	_btn_tow_hold.text = "Hold"
	_btn_tow_hold.pressed.connect(func(): towed_hold_requested.emit())
	tow_btns.add_child(_btn_tow_hold)
	_btn_tow_retract = Button.new()
	_btn_tow_retract.text = "Retrieve"
	_btn_tow_retract.pressed.connect(func(): towed_retract_requested.emit())
	tow_btns.add_child(_btn_tow_retract)
	_len_slider = HSlider.new()
	_len_slider.min_value = 0.0
	_len_slider.max_value = 1.0
	_len_slider.step = 0.05
	_len_slider.custom_minimum_size = Vector2(0, 16)
	# 拖动只预览，松开才提交命令（S1-08：提交前可见，不瞬发）
	_len_slider.drag_ended.connect(
		func(changed: bool):
			if changed:
				towed_length_commanded.emit(_len_slider.value)
	)
	_tow_ctl.add_child(_len_slider)
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 4)
	_tow_ctl.add_child(preset_row)
	for frac in [0.25, 0.5, 0.75, 1.0]:
		var pb := Button.new()
		pb.text = "%d%%" % int(frac * 100.0)
		pb.add_theme_font_size_override("font_size", 11)
		pb.pressed.connect(
			func():
				_len_slider.set_value_no_signal(frac)
				towed_length_commanded.emit(frac)
		)
		preset_row.add_child(pb)
	_lbl_tow = Label.new()
	_lbl_tow.text = "Towed: STOWED"
	_lbl_tow.add_theme_font_size_override("font_size", 12)
	_lbl_tow.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tow_ctl.add_child(_lbl_tow)

	# 主动声呐结构化卡片（S1-04C-REQ-01）：State Badge + PING + 固定参数 +
	# Latest Returns 逐行列表 + TMA Link。替代旧的"按钮+自动换行长字符串"。
	_active_card = ActiveSonarCard.new()
	add_child(_active_card)
	_active_card.ping_requested.connect(func(): ping_requested.emit())
	_active_card.return_selected.connect(func(i: int): active_return_selected.emit(i))
	_active_card.undo_requested.connect(func(): active_undo_requested.emit())
	_active_card.fit_mode_requested.connect(func(m: String): active_fit_mode_requested.emit(m))
	_active_card.take_control_requested.connect(func(): active_take_control_requested.emit())
	_active_card.apply_requested.connect(func(): active_apply_requested.emit())
	_active_card.set_data(
		{
			"state": "UNAVAILABLE",
			"cooldown": 0.0,
			"params": {},
			"returns": [],
			"tma": {},
			"undo_enabled": false
		}
	)

	# BB 瀑布显示基准切换：RELATIVE(默认,艇艏=0°) / TRUE STABILIZED(真北稳定)
	var bb_mode_row := HBoxContainer.new()
	bb_mode_row.add_theme_constant_override("separation", 4)
	add_child(bb_mode_row)
	_lbl_bb_mode = Label.new()
	_lbl_bb_mode.text = "RELATIVE (bow=0°)"
	_lbl_bb_mode.add_theme_font_size_override("font_size", 12)
	bb_mode_row.add_child(_lbl_bb_mode)
	var bb_mode_opt := OptionButton.new()
	bb_mode_opt.add_item("RELATIVE")
	bb_mode_opt.add_item("TRUE STABILIZED")
	bb_mode_opt.select(0)
	bb_mode_opt.item_selected.connect(
		func(i: int):
			var mode: String = "rel" if i == 0 else "true"
			wf_bb.set_bearing_mode(mode)
			_lbl_bb_mode.text = "RELATIVE (bow=0°)" if i == 0 else "TRUE STABILIZED (north-up)"
	)
	bb_mode_row.add_child(bb_mode_opt)

	wf_bb = WaterfallView.new()
	wf_bb.axis_mode = "bearing"
	wf_bb.x_min = -180.0
	wf_bb.x_max = 180.0
	wf_bb.custom_minimum_size = Vector2(0, 100)
	wf_bb.mark_requested.connect(
		func(x: float, _t: float, row: Dictionary):
			mark_requested.emit(x, wf_bb.bearing_mode == "true", row)
	)
	add_child(wf_bb)

	add_child(_mk_label("Narrowband / LOFAR (freq-time)"))
	# REQ-09/验收11：窄带频段切换（0-500 / 500-3000 / 8000-16000 Hz）。
	var nb_band_row := HBoxContainer.new()
	nb_band_row.add_theme_constant_override("separation", 6)
	add_child(nb_band_row)
	_lbl_nb_band = Label.new()
	_lbl_nb_band.text = "NB band: 0-500 Hz"
	_lbl_nb_band.add_theme_font_size_override("font_size", 12)
	nb_band_row.add_child(_lbl_nb_band)
	var nb_band_opt := OptionButton.new()
	nb_band_opt.add_item("0-500 Hz")
	nb_band_opt.add_item("500-3000 Hz")
	nb_band_opt.add_item("8000-16000 Hz")
	nb_band_opt.select(0)
	nb_band_opt.item_selected.connect(
		func(i: int):
			var preset: String = ["LOW", "MID", "HIGH"][i]
			if _sonar != null and _sonar.set_nb_band(preset):
				var band: Vector2 = OperatorSonar.NB_BANDS[preset]
				wf_nb.x_min = band.x
				wf_nb.x_max = band.y
				_lbl_nb_band.text = "NB band: %d-%d Hz" % [int(band.x), int(band.y)]
	)
	nb_band_row.add_child(nb_band_opt)
	wf_nb = WaterfallView.new()
	wf_nb.axis_mode = "freq"
	wf_nb.x_min = 0.0
	wf_nb.x_max = 500.0
	wf_nb.custom_minimum_size = Vector2(0, 100)
	add_child(wf_nb)

	add_child(_mk_label("DEMON envelope (blade harmonics)"))
	wf_demon = WaterfallView.new()
	wf_demon.axis_mode = "envelope"
	wf_demon.x_min = 0.0
	wf_demon.x_max = 32.0
	wf_demon.custom_minimum_size = Vector2(0, 100)
	add_child(wf_demon)

	_lbl_class = _mk_label("Classification: -")
	add_child(_lbl_class)
	_lbl_demon = _mk_label("DEMON: -")
	add_child(_lbl_demon)


func _mk_label(txt: String) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 12)
	return l


## 设置拖曳硬件可用性（S1-03）：未安装硬件时禁用 TOWED 选项，不得提供
## "跟艇+满可用"的虚构回退。
func set_towed_available(avail: bool) -> void:
	if _arr_opt == null:
		return
	for i in range(_arr_opt.item_count):
		if _arr_opt.get_item_text(i) == "TOWED":
			_arr_opt.set_item_disabled(i, not avail)
	if not avail and _lbl_tow != null:
		_lbl_tow.text = "Towed: not installed"


## 主 UI 设置 TOWED 状态显示文本（含 ACT→CMD 长度/阵航向/可用度）。
## active=true 表示当前选中 TOWED 阵列，显示长度命令区；否则隐藏。
func set_towed_status(text: String, active: bool) -> void:
	if _lbl_tow == null:
		return
	_lbl_tow.text = text
	if _tow_ctl != null:
		_tow_ctl.visible = active


## 按拖曳阵状态启用/禁用命令按钮并标注原因（S1-03/S1-08）。
func update_towed_controls(t: TowedArray) -> void:
	if _btn_tow_deploy == null or t == null:
		return
	_btn_tow_deploy.disabled = t.actual_tow_length_m >= t.max_tow_length_m - 1e-6
	_btn_tow_deploy.tooltip_text = (
		"" if not _btn_tow_deploy.disabled else "Already at full length"
	)
	_btn_tow_retract.disabled = t.actual_tow_length_m <= 1e-6
	_btn_tow_retract.tooltip_text = ("" if not _btn_tow_retract.disabled else "Already stowed")
	_btn_tow_hold.disabled = (
		t.state == TowedArray.State.HOLD_PARTIAL or t.state == TowedArray.State.STOWED
	)
	_btn_tow_hold.tooltip_text = ("" if not _btn_tow_hold.disabled else "Already holding")
	if _len_slider != null and not _len_slider.has_focus():
		if t.max_tow_length_m > 0.0:
			_len_slider.set_value_no_signal(t.commanded_tow_length_m / t.max_tow_length_m)


## 刷新主动声呐卡（S1-04C-REQ-01）：结构化固定布局，由 ActivePingController
## 组装完整数据后调用（state/cooldown/params/returns/tma/undo）。state 由
## World 权威给出：UNAVAILABLE/READY/LISTENING/RETURN/NO_RETURN（PingSession
## 状态机）+ 派生 TRANSMITTING/COOLDOWN 徽标。UNAVAILABLE=平台未配主动阵硬禁
## （REQ-20，绝不静默缺省）。ISSUE-06：不显示"还有 Xs 回波到达"等 Truth 推导
## 信息——只显示硬件状态与冷却（二者均为本艇事实）。
func set_active_sonar(data: Dictionary) -> void:
	if _active_card == null:
		return
	_active_card.set_data(data)


## Operator 有新瀑布行时调用（只在行数变化时重建 UI 数据）。
## S1-03B：阵列切换后即使行数相同也强制重建——各阵列缓冲独立，必须立即
## 只显示当前阵列自己的历史（拖曳阵双峰不得残留到 BOW/FLANK 视图）。
func refresh(op: OperatorSonar) -> void:
	_sonar = op
	var aid: String = op.active_array_id
	var force: bool = aid != _last_array_id
	_last_array_id = aid
	var n: int = op.bb_rows.size()
	if n == _last_row_count and op.waterfall_seq == _last_wf_seq and not force:
		return
	_last_row_count = n
	_last_wf_seq = op.waterfall_seq
	wf_bb.set_rows(op.bb_rows.slice(maxi(0, n - MAX_ROWS_SHOWN)))
	wf_nb.set_rows(op.nb_rows.slice(maxi(0, n - MAX_ROWS_SHOWN)))
	wf_demon.set_rows(op.demon_rows.slice(maxi(0, n - MAX_ROWS_SHOWN)))
	# 游标联动：DEMON 谐波标记到 NB 频率轴
	var mks: Array = []
	var de: Dictionary = op.demon_estimate
	if not de.is_empty() and int(de.get("blades", 0)) > 0:
		var br: float = float(de["rpm_hz"]) * float(de["blades"])
		for k in range(1, 6):
			if br * k <= 500.0:
				mks.append({"x": br * k, "color": Color(0.2, 1.0, 0.9, 0.5)})
	wf_nb.markers = mks
	if not de.is_empty():
		_lbl_demon.text = (
			"DEMON: shaft %.2f±%.2f Hz  blades %s  speed %.1f±%.1f kn"
			% [
				float(de["rpm_hz"]),
				float(de["rpm_sigma_hz"]),
				str(de["blades"]) if int(de["blades"]) > 0 else "?",
				float(de["speed_kn"]),
				float(de["speed_sigma_kn"]),
			]
		)
	if not op.classification.is_empty():
		var best: String = str(op.classification.get("best", "-"))
		var bp: float = float(op.classification.get(best, 0.0))
		_lbl_class.text = "Classification: %s (%.0f%%)" % [best, bp * 100.0]


func autocrew_on() -> bool:
	return _autocrew.button_pressed
