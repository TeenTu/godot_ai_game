class_name OwnManeuverPanel
extends VBoxContainer
## own_maneuver_panel.gd — 本艇机动/深度控制簇（航向/航速/深度 + 层带按钮）。
##
## S1-02/G-05：UI 只写命令值（command_course/command_speed），实际状态按
## 转向率/加速度限速逼近。
## S1-07A §4.2：▲Upper / ▼Lower 按钮只写 commanded_depth_m（层 hold 深度），
## 实际深度按 Vz 限速逼近；显示 ACT→CMD + 换层 ETA + 当前层带。模型未启用
## （旧二维场景）时层按钮回退 70/180 默认、只显示纯数值。
##
## 信息链纪律：只读 own TruthEntity 的命令/实际状态（本艇自身状态合法），
## 不接触任何目标 Truth。world 由 main_ui 注入。

var _world: World = null
var _spin_course: SpinBox = null
var _spin_speed: SpinBox = null
var _spin_depth: SpinBox = null
var _lbl_cmd: Label = null
## UI-04：最后设定值（命令完成后保留显示，避免把内部 -1 哨兵当航向/深度展示）。
var _last_course: float = -1.0
var _last_depth: float = -1.0
var _last_speed: float = -1.0


func _init() -> void:
	_build()


func _build() -> void:
	var title := Label.new()
	title.text = UiText.t("own_maneuver")
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_spin_course = _add_spin(UiText.t("spin_own_course"), 0, 359, 1, 0)
	_spin_speed = _add_spin(UiText.t("spin_own_speed"), 0, 30, 0.5, 0)
	_spin_depth = _add_spin(UiText.t("spin_own_depth"), 0, 400, 1, 0)
	_lbl_cmd = Label.new()
	_lbl_cmd.add_theme_font_size_override("font_size", 13)
	_lbl_cmd.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # UI-01：ACT/CMD 长串只换行
	add_child(_lbl_cmd)
	_spin_course.value_changed.connect(_on_course)
	_spin_speed.value_changed.connect(_on_speed)
	_spin_depth.value_changed.connect(_on_depth)
	# S1-07A §4.2：层按钮只写 commanded_depth_m。
	var row_band := HBoxContainer.new()
	row_band.add_theme_constant_override("separation", 4)
	add_child(row_band)
	var b_up := Button.new()
	b_up.text = UiText.t("btn_upper")
	b_up.pressed.connect(_on_band.bind("UPPER"))
	row_band.add_child(b_up)
	var b_dn := Button.new()
	b_dn.text = UiText.t("btn_lower")
	b_dn.pressed.connect(_on_band.bind("LOWER"))
	row_band.add_child(b_dn)
	var row_turn := HFlowContainer.new()  # UI-01：窄侧栏自动换行
	row_turn.add_theme_constant_override("h_separation", 4)
	row_turn.add_theme_constant_override("v_separation", 4)
	add_child(row_turn)
	for cfg in [
		[UiText.t("btn_turn_left"), _on_turn_left],
		[UiText.t("btn_turn_right"), _on_turn_right],
		[UiText.t("btn_speed_up"), _on_speed_up],
		[UiText.t("btn_speed_down"), _on_slow_down]
	]:
		var b := Button.new()
		b.text = cfg[0] as String
		b.pressed.connect(cfg[1] as Callable)
		row_turn.add_child(b)


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
	add_child(box)
	return sp


## main_ui 场景装配后注入 world（本艇状态 + 温跃层模型）。
func bind_world(w: World) -> void:
	_world = w
	sync()


## 每帧同步：数字框显示**有效命令值**（有命令显示命令，否则显示实际），实际值在
## _lbl_cmd 里另外展示（UI-04）。内部 LineEdit 持有焦点时绝不被同步覆盖（T25）。
func sync() -> void:
	if _world == null:
		return
	var own: TruthEntity = _world.world["own"]
	_set_spin(
		_spin_course, own.commanded_course_deg if own.has_course_command() else own.course_deg
	)
	_set_spin(_spin_speed, own.commanded_speed_kn if own.has_speed_command() else own.speed_kn)
	_set_spin(_spin_depth, own.commanded_depth_m if own.has_depth_command() else own.depth_m)
	if _lbl_cmd == null:
		return
	var txt: String = UiText.t("own_act_fmt") % [own.course_deg, own.speed_kn]
	if own.has_course_command():
		var err: float = absf(NavUtils.wrap180(own.commanded_course_deg - own.course_deg))
		var rate: float = maxf(own.turn_rate_deg_s, TruthEntity.DEFAULT_TURN_RATE_DEG_S)
		txt += UiText.t("own_cmd_course_fmt") % [own.commanded_course_deg, err / rate]
	if own.has_speed_command():
		var dv: float = absf(own.commanded_speed_kn - own.speed_kn)
		var acc: float = maxf(own.acceleration_kn_s, TruthEntity.DEFAULT_ACCEL_KN_S)
		txt += UiText.t("own_cmd_speed_fmt") % [own.commanded_speed_kn, dv / acc]
	# S1-07A：深度 ACT→CMD + 换层 ETA + 层带（模型未启用则纯数值）。
	txt += UiText.t("own_depth_fmt") % own.depth_m
	if own.has_depth_command():
		var dz: float = absf(own.commanded_depth_m - own.depth_m)
		txt += (
			UiText.t("own_depth_cmd_fmt")
			% [own.commanded_depth_m, dz / maxf(own.max_vertical_speed_m_s, 0.5)]
		)
	# UI-04：转向命令完成后保留最后设定显示（不回落成哨兵值，也不假装还在转）。
	if not own.has_course_command() and _last_course >= 0.0:
		txt += UiText.t("own_last_cmd_fmt") % [_last_course, maxf(_last_depth, 0.0)]
	var dm: RefCounted = _depth_model()
	if dm != null:
		txt += " %s" % UiText.depth_preset((dm as DepthLayerModel).band_name(own.depth_m))
	_lbl_cmd.text = txt


## UI-04/T25：SpinBox 的焦点在**内部 LineEdit** 上，Control.has_focus() 对它无效
## ——直接用 has_focus() 判断会漏，每帧同步就会把玩家正在输入的内容冲掉。
func _set_spin(sp: SpinBox, v: float) -> void:
	if sp == null:
		return
	var le: LineEdit = sp.get_line_edit()
	if le != null and le.has_focus():
		return
	sp.set_value_no_signal(v)


## UI-04 统一命令入口：图形（罗盘/深度条）、数字框、±按钮、层带预设全走这里。
## 返回是否真的写入命令（供"预览取消不写命令""终局拒绝新命令"断言）。
func command_course(deg: float) -> bool:
	if not _commands_ok():
		return false
	var v: float = NavUtils.wrap360(deg)
	_last_course = v
	_set_spin(_spin_course, v)
	_own().command_course(v)
	sync()
	return true


func command_depth(depth_m: float) -> bool:
	if not _commands_ok():
		return false
	var v: float = maxf(depth_m, 0.0)
	_last_depth = v
	_set_spin(_spin_depth, v)
	_own().command_depth(v)
	sync()
	return true


func command_speed(kn: float) -> bool:
	if not _commands_ok():
		return false
	var v: float = maxf(kn, 0.0)
	_last_speed = v
	_set_spin(_spin_speed, v)
	_own().command_speed(v)
	sync()
	return true


## 最后设定值（UI-04 展示用；-1 = 从未设定）。
func last_command() -> Dictionary:
	return {"course": _last_course, "depth": _last_depth, "speed": _last_speed}


func _on_course(deg: float) -> void:
	command_course(deg)


func _on_speed(kn: float) -> void:
	command_speed(kn)


func _on_depth(v: float) -> void:
	command_depth(v)


## S1-07A：层按钮 → hold 深度 → 只写 commanded_depth_m（同一入口）。
func _on_band(band: String) -> void:
	if _spin_depth == null:
		return
	var dm: RefCounted = _depth_model()
	var hold: float = 70.0 if band == "UPPER" else 180.0
	if dm != null:
		hold = float((dm as DepthLayerModel).hold_depth_for_band(band))
	command_depth(hold)


func _on_turn_left() -> void:
	_change_course(-5.0)


func _on_turn_right() -> void:
	_change_course(5.0)


func _on_speed_up() -> void:
	_change_speed(2.0)


func _on_slow_down() -> void:
	_change_speed(-2.0)


func _change_course(delta_deg: float) -> void:
	if _spin_course == null:
		return
	command_course(NavUtils.wrap360(_spin_course.value + delta_deg))


func _change_speed(delta_kn: float) -> void:
	if _spin_speed == null:
		return
	command_speed(clampf(_spin_speed.value + delta_kn, 0.0, 30.0))


func _own() -> TruthEntity:
	return _world.world["own"] if _world != null else null


## REQ-B5-05：任务终局后拒绝一切本艇机动命令。
func _commands_ok() -> bool:
	return _world != null and _world.is_mission_running()


## 取场景温跃层模型（未启用返回 null；层按钮回退 70/180 默认）。
func _depth_model() -> RefCounted:
	if _world == null:
		return null
	var dm: RefCounted = _world.world.get("depth_model", null)
	if dm != null and not (dm as DepthLayerModel).enabled:
		return null
	return dm
