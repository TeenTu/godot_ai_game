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
	title.text = UiText.t("countermeasures")
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_lbl_state = Label.new()
	_lbl_state.add_theme_font_size_override("font_size", 12)
	add_child(_lbl_state)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var lbl_brg := Label.new()
	lbl_brg.text = UiText.t("brg_deg")
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
	_btn_mobile.text = UiText.t("btn_mobile")
	_btn_mobile.add_theme_font_size_override("font_size", 12)
	_btn_mobile.pressed.connect(func(): _launch(DecoyProgram.TYPE_MOBILE))
	row2.add_child(_btn_mobile)
	_btn_jammer = Button.new()
	_btn_jammer.text = UiText.t("btn_jammer")
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
			# P1-C DC-03：分离阶段显式标注（出管后仍有真实位移，不是零速漂浮）。
			var phase: String = ""
			if float(d.age_s) < float(d.separation_duration_s):
				phase = " 出管分离中 %.0fs" % maxf(float(d.separation_duration_s) - float(d.age_s), 0.0)
			(
				lines
				. append(
					(
						"%s %s 速度 %.1f/%.1f 节 深度 %.0f/%.0f 米 寿命 %.0f 秒%s"
						% [
							str(d.id),
							"干扰" if d.decoy_type == DecoyProgram.TYPE_JAMMER else "诱饵",
							float(d.speed_kn),
							float(d.commanded_speed_kn),
							float(d.depth_m),
							float(d.commanded_depth_m),
							life_left,
							phase,
						]
					)
				)
			)
		else:
			lines.append(
				(
					"%s 引信化 %.1fs"
					% [str(d.id), maxf(float(d.activation_delay_s) - float(d.age_s), 0.0)]
				)
			)
	# DC-07：待发 / 备用 / 装填剩余时间（与 CountermeasureSystem.ammo_summary 同源）。
	var ammo: Dictionary = cm.ammo_summary()
	var reload_txt: String = ""
	if bool(ammo["reloading"]):
		reload_txt = " | " + (UiText.t("cm_reload_fmt") % float(ammo["reload_left_s"]))
	var state: String = (
		"%s | %s | 冷却 %.0fs | 己方诱饵 %d"
		% [
			UiText.t("cm_ready_fmt") % int(ammo["ready"]),
			UiText.t("cm_spare_fmt") % int(ammo["spare"]),
			cd,
			lines.size(),
		]
	)
	state += reload_txt
	# REQ-UI-03 频带提示：JAMMER 配置的干扰频带（发射前即可见，本艇事实）。
	var jam: Dictionary = cm.profile_for(DecoyProgram.TYPE_JAMMER)
	if not jam.is_empty() and float(jam.get("band_max_hz", 0.0)) > 0.0:
		state += (
			"\n干扰器频段 %.0f–%.0f Hz"
			% [
				float(jam.get("band_min_hz", 800.0)),
				float(jam.get("band_max_hz", 1200.0)),
			]
		)
	if not lines.is_empty():
		state += "\n" + "\n".join(lines)
	_lbl_state.text = state


## P1-C DC-02/DC-05：程序构建统一走 DecoyLaunchBuilder（与地图右键菜单同一处），
## 本面板只提供"投放方向（真方位）"这一个主要方向设置。
func _launch(decoy_type: String) -> void:
	if _world == null:
		return
	var own: TruthEntity = _world.world.get("own", null)
	var prog: DecoyProgram = DecoyLaunchBuilder.build(
		_world.countermeasures, decoy_type, clampf(_spin_brg.value, 0.0, 359.9), own
	)
	var ok: bool = _world._launch_decoy(prog)
	if not ok:
		var reason: String = _world.last_decoy_reject_reason
		if reason == "":
			reason = str(UiText.t("decoy_unknown"))
		status.emit(UiText.t("decoy_reject") % UiText.reject(reason))
	else:
		status.emit(UiText.t("decoy_launch") % [UiText.decoy(decoy_type), prog.launch_bearing_deg])
