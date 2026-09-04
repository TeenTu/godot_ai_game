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


func _init() -> void:
	_build()


func _build() -> void:
	var title := Label.new()
	title.text = "Own Ship Maneuver"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_spin_course = _add_spin("Own Course (°)", 0, 359, 1, 0)
	_spin_speed = _add_spin("Own Speed (kn)", 0, 30, 0.5, 0)
	_spin_depth = _add_spin("Own Depth (m)", 0, 400, 1, 0)
	_lbl_cmd = Label.new()
	_lbl_cmd.add_theme_font_size_override("font_size", 13)
	add_child(_lbl_cmd)
	_spin_course.value_changed.connect(_on_course)
	_spin_speed.value_changed.connect(_on_speed)
	_spin_depth.value_changed.connect(_on_depth)
	# S1-07A §4.2：层按钮只写 commanded_depth_m。
	var row_band := HBoxContainer.new()
	row_band.add_theme_constant_override("separation", 4)
	add_child(row_band)
	var b_up := Button.new()
	b_up.text = "▲ Upper"
	b_up.pressed.connect(_on_band.bind("UPPER"))
	row_band.add_child(b_up)
	var b_dn := Button.new()
	b_dn.text = "▼ Lower"
	b_dn.pressed.connect(_on_band.bind("LOWER"))
	row_band.add_child(b_dn)
	var row_turn := HBoxContainer.new()
	row_turn.add_theme_constant_override("separation", 4)
	add_child(row_turn)
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


## 每帧同步：命令旋钮跟随实际值（无焦点时）；ACT→CMD 状态文本。
func sync() -> void:
	if _world == null:
		return
	var own: TruthEntity = _world.world["own"]
	if _spin_course != null and not _spin_course.has_focus():
		_spin_course.set_value_no_signal(own.course_deg)
	if _spin_speed != null and not _spin_speed.has_focus():
		_spin_speed.set_value_no_signal(own.speed_kn)
	if _spin_depth != null and not _spin_depth.has_focus():
		_spin_depth.set_value_no_signal(own.depth_m)
	if _lbl_cmd == null:
		return
	var txt: String = "ACT %.0f° %.1fkn" % [own.course_deg, own.speed_kn]
	if own.has_course_command():
		var err: float = absf(NavUtils.wrap180(own.commanded_course_deg - own.course_deg))
		var rate: float = maxf(own.turn_rate_deg_s, TruthEntity.DEFAULT_TURN_RATE_DEG_S)
		txt += " → CMD %.0f° (%.0fs)" % [own.commanded_course_deg, err / rate]
	if own.has_speed_command():
		var dv: float = absf(own.commanded_speed_kn - own.speed_kn)
		var acc: float = maxf(own.acceleration_kn_s, TruthEntity.DEFAULT_ACCEL_KN_S)
		txt += " → CMD %.1fkn (%.0fs)" % [own.commanded_speed_kn, dv / acc]
	# S1-07A：深度 ACT→CMD + 换层 ETA + 层带（模型未启用则纯数值）。
	txt += " | D %.0fm" % own.depth_m
	if own.has_depth_command():
		var dz: float = absf(own.commanded_depth_m - own.depth_m)
		txt += (
			"→%.0fm (ETA %.0fs)"
			% [own.commanded_depth_m, dz / maxf(own.max_vertical_speed_m_s, 0.5)]
		)
	var dm: RefCounted = _depth_model()
	if dm != null:
		txt += " %s" % (dm as DepthLayerModel).band_name(own.depth_m)
	_lbl_cmd.text = txt


func _on_course(deg: float) -> void:
	_own().command_course(NavUtils.wrap360(deg))


func _on_speed(kn: float) -> void:
	_own().command_speed(maxf(kn, 0.0))


func _on_depth(v: float) -> void:
	_own().command_depth(maxf(v, 0.0))


## S1-07A：层按钮 → hold 深度 → 只写 commanded_depth_m。
func _on_band(band: String) -> void:
	if _spin_depth == null:
		return
	var dm: RefCounted = _depth_model()
	var hold: float = 70.0 if band == "UPPER" else 180.0
	if dm != null:
		hold = float((dm as DepthLayerModel).hold_depth_for_band(band))
	_spin_depth.set_value_no_signal(hold)
	_own().command_depth(hold)


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
	var new_deg: float = NavUtils.wrap360(_spin_course.value + delta_deg)
	_spin_course.set_value_no_signal(new_deg)
	_own().command_course(new_deg)


func _change_speed(delta_kn: float) -> void:
	if _spin_speed == null:
		return
	var new_kn: float = clampf(_spin_speed.value + delta_kn, 0.0, 30.0)
	_spin_speed.set_value_no_signal(new_kn)
	_own().command_speed(new_kn)


func _own() -> TruthEntity:
	return _world.world["own"] if _world != null else null


## 取场景温跃层模型（未启用返回 null；层按钮回退 70/180 默认）。
func _depth_model() -> RefCounted:
	if _world == null:
		return null
	var dm: RefCounted = _world.world.get("depth_model", null)
	if dm != null and not (dm as DepthLayerModel).enabled:
		return null
	return dm
