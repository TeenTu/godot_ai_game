class_name OwnPageBuilder
extends RefCounted
## own_page_builder.gd — 战术页末尾的"本艇"区装配（P1-B 从 main_ui 拆出控行数）。
##
## main_ui 是装配枢纽、已顶到 .gdlintrc 的 1200 行上限，凡"整块装配、只通过 ui
## 字段读写"的逻辑一律外移（与 UiChartData / ContactCard.install 同一模式）。
## 本文件只装配控件与接线、不持有业务状态：状态仍全部写在 ui 上（_lbl_status /
## _own_panel / _auto_panel / _chk_layers / _btn_show_truth）。
##
## 与 main_ui 无 class_name 互相引用：ui 参数是 Control，诊断区默认模式由调用方
## 以 diag_default 传入（避免 GDScript 循环依赖）。


## 装配本艇区：状态文本 + 自动化 + 机动/深度控制 + 镜头 + 图层 + 开发选项。
static func build(ui: Control, pg: VBoxContainer, diag_default: int) -> void:
	_own_maneuver_section(ui, pg)
	_camera_section(ui, pg)
	_layer_section(ui, pg, diag_default)
	ui._btn_show_truth = Button.new()
	ui._btn_show_truth.text = UiText.t("btn_show_truth")
	ui._btn_show_truth.toggle_mode = true
	ui._btn_show_truth.toggled.connect(ui._on_show_truth)
	pg.add_child(ui._btn_show_truth)


## 状态区（ACT/CMD 文本）+ 自动化面板（与主动声呐卡片共享唯一模式源）+ 机动簇。
static func _own_maneuver_section(ui: Control, pg: VBoxContainer) -> void:
	ui._lbl_status = Label.new()
	ui._lbl_status.text = ""
	ui._lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui._lbl_status.add_theme_font_size_override("font_size", 14)
	var sec_status := UiSection.make(UiText.t("sec_status"))
	UiSection.body(sec_status).add_child(ui._lbl_status)
	pg.add_child(sec_status)
	var auto_panel := AutomationPanelUI.new()
	# PG-01：自动化面板与主动声呐卡片共享唯一模式源（_auto_ctrl），
	# 卡片切模式 = 全局切模式，不再各自持一份状态（T21）。
	auto_panel.ctrl = ui._auto_ctrl
	auto_panel.bind(ui.tracker, ui._auto_refit_track, ui.world)
	ui._auto_panel = auto_panel
	var auto_sec := UiSection.make(UiText.t("sec_automation"))
	UiSection.body(auto_sec).add_child(auto_panel)
	pg.add_child(auto_sec)
	ui._own_panel = OwnManeuverPanel.new()
	pg.add_child(ui._own_panel)


## 镜头按钮（复位/自动取景）+ 全 LOB / 仅选中航迹开关。
static func _camera_section(ui: Control, pg: VBoxContainer) -> void:
	var cam_title := Label.new()
	cam_title.text = UiText.t("cam_view")
	cam_title.add_theme_font_size_override("font_size", 15)
	pg.add_child(cam_title)
	var row_cam := HFlowContainer.new()  # UI-01：窄侧栏自动换行
	row_cam.add_theme_constant_override("h_separation", 4)
	row_cam.add_theme_constant_override("v_separation", 4)
	pg.add_child(row_cam)
	var btn_reset := Button.new()
	btn_reset.text = UiText.t("btn_reset_view")
	btn_reset.pressed.connect(func(): ui._chart.reset_view())
	row_cam.add_child(btn_reset)
	var btn_frame := Button.new()
	btn_frame.text = UiText.t("btn_auto_frame")
	btn_frame.pressed.connect(func(): ui._chart.auto_frame())
	row_cam.add_child(btn_frame)
	var chk_all_lob := CheckButton.new()
	chk_all_lob.text = UiText.t("chk_all_lob")
	chk_all_lob.toggled.connect(func(on: bool): ui._chart.show_all_lobs = on)
	pg.add_child(chk_all_lob)
	# REQ-B3-03：Selected Track only / All Tracks 切换（默认突出当前 Track）。
	var chk_sel_only := CheckButton.new()
	chk_sel_only.text = UiText.t("chk_sel_only")
	chk_sel_only.toggled.connect(func(on: bool): ui._chart.show_selected_only = on)
	pg.add_child(chk_sel_only)


## 图层开关（含 BT 轴模式）+ 诊断区模式选择。
static func _layer_section(ui: Control, pg: VBoxContainer, diag_default: int) -> void:
	var lt := Label.new()
	lt.text = UiText.t("layers")
	lt.add_theme_font_size_override("font_size", 15)
	pg.add_child(lt)
	for key in ["lob", "sigma", "fit", "alt", "trial", "system", "truth", "threat"]:
		var cb := CheckButton.new()
		cb.text = UiText.t("legend_alt") if key == "alt" else UiText.t("legend_" + key)
		cb.button_pressed = bool(ui._chart.layers.get(key, true))
		cb.toggled.connect(ui._on_layer_toggle.bind(key))
		pg.add_child(cb)
		ui._chk_layers[key] = cb
	_add_axis_mode(ui, pg)
	var diag_lbl := Label.new()
	diag_lbl.text = UiText.t("diagnostics")
	diag_lbl.add_theme_font_size_override("font_size", 15)
	pg.add_child(diag_lbl)
	var diag_ob := UiContract.tame_option_button(OptionButton.new())
	diag_ob.add_item(UiText.t("diag_closed"))
	diag_ob.add_item(UiText.t("diag_bt"))
	diag_ob.add_item(UiText.t("diag_residual"))
	diag_ob.add_item(UiText.t("diag_split"))
	diag_ob.select(diag_default)
	diag_ob.item_selected.connect(ui._set_diag_mode)
	pg.add_child(diag_ob)


## BT 轴模式（本地/360°）；_bt_plot 在 _build_bottom 里才创建，故延迟读取。
static func _add_axis_mode(ui: Control, pg: VBoxContainer) -> void:
	var ob := UiContract.tame_option_button(OptionButton.new())
	ob.add_item(UiText.t("bt_local"))
	ob.add_item(UiText.t("bt_360"))
	ob.item_selected.connect(
		func(i: int):
			ui._bt_plot.overview_mode = i == 1
			ui._bt_plot.queue_redraw()
	)
	pg.add_child(ob)
