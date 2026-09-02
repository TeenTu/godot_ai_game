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

signal mark_requested(bearing_deg: float, as_true: bool)
signal array_changed(array_id: String)
signal autocrew_toggled(on: bool)

const MAX_ROWS_SHOWN: int = 80

var wf_bb: WaterfallView = null
var wf_nb: WaterfallView = null
var wf_demon: WaterfallView = null
var _lbl_bb_mode: Label = null  # 标注当前 BB 瀑布显示基准（RELATIVE / TRUE STABILIZED）

var _autocrew: CheckBox = null
var _lbl_class: Label = null
var _lbl_demon: Label = null
var _last_row_count: int = -1


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
		func(x: float, _t: float): mark_requested.emit(x, wf_bb.bearing_mode == "true")
	)
	add_child(wf_bb)

	add_child(_mk_label("Narrowband / LOFAR (freq-time)"))
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


## Operator 有新瀑布行时调用（只在行数变化时重建 UI 数据）。
func refresh(op: OperatorSonar) -> void:
	var n: int = op.bb_rows.size()
	if n == _last_row_count:
		return
	_last_row_count = n
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
