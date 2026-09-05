class_name CountermeasurePanel
extends VBoxContainer
## countermeasure_panel.gd — 诱饵/反制面板（S1-07 §8.5/§11.5，Commit 11）。
##
## 显示：类型支持 / 剩余装填 / 库存 / 冷却 / 活动诱饵（己方）；发射按钮
## （MOBILE / JAMMER，方位可调）。发射条件与拒绝原因由 CountermeasureSystem
## 权威判定（库存/冷却/程序合法性），本面板只展示结果。
##
## 信息链纪律：只列己方诱饵与发射器状态（本艇事实）；不接触任何目标 Truth。

signal status(msg: String)

var _world: World = null
var _lbl_state: Label = null
var _spin_brg: SpinBox = null
var _btn_mobile: Button = null
var _btn_jammer: Button = null


func _init() -> void:
	var title := Label.new()
	title.text = "Countermeasures"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_lbl_state = Label.new()
	_lbl_state.add_theme_font_size_override("font_size", 12)
	add_child(_lbl_state)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var lbl_brg := Label.new()
	lbl_brg.text = "Brg(°)"
	lbl_brg.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl_brg)
	_spin_brg = SpinBox.new()
	_spin_brg.min_value = 0.0
	_spin_brg.max_value = 359.0
	_spin_brg.step = 1.0
	_spin_brg.value = 90.0
	_spin_brg.custom_minimum_size = Vector2(80, 0)
	row.add_child(_spin_brg)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	add_child(row2)
	_btn_mobile = Button.new()
	_btn_mobile.text = "Launch MOBILE"
	_btn_mobile.add_theme_font_size_override("font_size", 12)
	_btn_mobile.pressed.connect(func(): _launch(DecoyProgram.TYPE_MOBILE))
	row2.add_child(_btn_mobile)
	_btn_jammer = Button.new()
	_btn_jammer.text = "Launch JAMMER"
	_btn_jammer.add_theme_font_size_override("font_size", 12)
	_btn_jammer.pressed.connect(func(): _launch(DecoyProgram.TYPE_JAMMER))
	row2.add_child(_btn_jammer)


func bind(w: World) -> void:
	_world = w


func sync() -> void:
	if _world == null or _world.countermeasures == null:
		return
	var cm: CountermeasureSystem = _world.countermeasures
	var own_types: Array = cm.supported_types
	var cd: float = cm.cooldown_left(_world.sim_time)
	# REQ-UI-03/REQ-CM-04：冷却参与 disabled；无弹/类型不支持各自禁用。
	var can_mobile: bool = (
		own_types.has(DecoyProgram.TYPE_MOBILE) and cm.ready_rounds > 0 and cd <= 0.0
	)
	var can_jammer: bool = (
		own_types.has(DecoyProgram.TYPE_JAMMER) and cm.ready_rounds > 0 and cd <= 0.0
	)
	_btn_mobile.disabled = not can_mobile
	_btn_jammer.disabled = not can_jammer
	# 己方诱饵状态：激活倒计时 / 实际与命令航速深度 / 剩余寿命（本艇事实）。
	var lines: Array = []
	for d in _world.decoys:
		if str(d.side) != "blue":
			continue
		if d.activated:
			var life_left: float = maxf(float(d.lifetime_s) - float(d.age_s), 0.0)
			(
				lines
				. append(
					(
						"%s %s spd %.1f/%.1fkn dep %.0f/%.0fm life %.0fs"
						% [
							str(d.id),
							"JAM" if d.decoy_type == DecoyProgram.TYPE_JAMMER else "MOB",
							float(d.speed_kn),
							float(d.commanded_speed_kn),
							float(d.depth_m),
							float(d.commanded_depth_m),
							life_left,
						]
					)
				)
			)
		else:
			lines.append(
				(
					"%s arming %.1fs"
					% [str(d.id), maxf(float(d.activation_delay_s) - float(d.age_s), 0.0)]
				)
			)
	var state: String = (
		"Rounds %d | Inv %d | CD %.0fs | Own decoys %d"
		% [cm.ready_rounds, cm.inventory, cd, lines.size()]
	)
	if not lines.is_empty():
		state += "\n" + "\n".join(lines)
	_lbl_state.text = state


func _launch(decoy_type: String) -> void:
	if _world == null:
		return
	var prog := DecoyProgram.new()
	prog.decoy_type = decoy_type
	prog.launch_bearing_deg = clampf(_spin_brg.value, 0.0, 359.9)
	prog.course_deg = prog.launch_bearing_deg
	prog.speed_kn = 8.0 if decoy_type == DecoyProgram.TYPE_MOBILE else 0.5
	prog.activation_delay_s = 2.0
	prog.lifetime_s = 120.0
	prog.initial_depth_band = _band_for_own()
	prog.commanded_depth_band = prog.initial_depth_band
	# REQ-CM-04：画像从配置读取（scenario own_ship.countermeasures.profiles），
	# UI 不再回调构造物理参数；无配置时用下列默认。
	var sig := AcousticProfile.new()
	var cfg: Dictionary = {}
	if _world.countermeasures != null:
		cfg = _world.countermeasures.profile_for(decoy_type)
	if not cfg.is_empty():
		sig.from_dict(cfg)
	else:
		sig.broadband_base_level_db = 165.0
		sig.tonal_lines = [
			{"freq_hz": 240.0, "level_db": 128.0},
			{"freq_hz": 480.0, "level_db": 122.0},
		]
		if decoy_type == DecoyProgram.TYPE_JAMMER:
			sig.broadband_base_level_db = 185.0
			sig.tonal_lines = [{"freq_hz": 900.0, "level_db": 150.0}]
	prog.signature = sig
	var ok: bool = _world._launch_decoy(prog)
	if not ok:
		var reason: String = _world.last_decoy_reject_reason
		if reason == "":
			reason = "unknown"
		status.emit("Decoy rejected: %s" % reason)
	else:
		status.emit("Decoy launched %s @%.0f°" % [decoy_type, prog.launch_bearing_deg])


func _band_for_own() -> String:
	var own: TruthEntity = _world.world["own"]
	return "LOWER" if own.depth_m >= 120.0 else "UPPER"
