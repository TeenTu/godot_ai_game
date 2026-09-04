class_name WeaponPanelUI
extends VBoxContainer
## weapon_panel.gd — 武器发射面板（阶段四，从 main_ui 拆出控制行数）。
##
## 信息链纪律：Fire 请求交由 main_ui 执行——有 SystemSolution 走 SOLUTION；
## 无解但有选中接触走 BEARING_ONLY；否则 MANUAL（沿本艇艏向）。本面板不持有
## Truth own、不直接调用 weapons.fire，只负责「展示 + 触发 + 模式提示」。

signal fire_requested
signal status(msg: String)

const MAX_LOG: int = 5

var weapons: WeaponSystem = null
var chart: ChartView = null
var now_time: float = 0.0  # 由 main_ui 每帧注入（脉冲动画/龄期衰减用）

var _btn_fire: Button = null
var _lbl_fire_hint: Label = null
var _lbl_weapons: Label = null
var _weapon_log: Array = []
var _chart_dirty: Callable = Callable()


func _init() -> void:
	_build()


func _build() -> void:
	_btn_fire = Button.new()
	_btn_fire.text = "🚀 Fire Torpedo"
	_btn_fire.pressed.connect(func(): fire_requested.emit())
	_btn_fire.disabled = true
	add_child(_btn_fire)
	_lbl_fire_hint = Label.new()
	_lbl_fire_hint.text = ""
	_lbl_fire_hint.add_theme_font_size_override("font_size", 12)
	_lbl_fire_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_fire_hint)
	_lbl_weapons = Label.new()
	_lbl_weapons.text = "Tubes: -"
	_lbl_weapons.add_theme_font_size_override("font_size", 14)
	_lbl_weapons.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # P1-03.2
	add_child(_lbl_weapons)


## 由 main_ui 装配后注入依赖并监听武器事件。
func bind(p_weapons: WeaponSystem, p_chart: ChartView, p_on_dirty: Callable) -> void:
	weapons = p_weapons
	chart = p_chart
	_chart_dirty = p_on_dirty
	if weapons != null:
		weapons.weapon_event.connect(_on_weapon_event)
	_refresh()


## 发射上下文提示（S1-07 §5.2）：SOLUTION / BEARING_ONLY / MANUAL + 风险说明。
## Fire 可用性不依赖解，只依赖有装填管（_refresh 内判定）。
func set_fire_context(text: String) -> void:
	if _lbl_fire_hint != null:
		_lbl_fire_hint.text = text


func _on_weapon_event(tid: String, kind: String, detail: Dictionary) -> void:
	# P1-03.6：文案映射与真实事件名一致（SEEKER_PHASE / TRACK_ACCEPTED /
	# WIRE_CUT / ACTIVE_TX_ON/OFF / DETONATION / FUZE_ARMED / ECHO_RECEIVED /
	# LISTEN_COMPLETE_NO_RETURN / AUTONOMY_AUTHORIZED ...），删除已失效的
	# ACQUIRE/ENABLE 特判。UI-07/08：绝不显示 target_id，绝不即时
	# CONFIRMED KILL（爆炸证据走 AlertPanel）。
	var txt: String = ""
	match kind:
		"DETONATION":
			txt = (
				"💥 %s DETONATION (min pass %.0fm)"
				% [tid, float(detail.get("min_distance_m", -1.0))]
			)
		"SEEKER_PHASE":
			txt = "%s seeker %s" % [tid, str(detail.get("state", ""))]
		"TRACK_ACCEPTED":
			txt = "%s track #%s accepted (ASSISTED)" % [tid, str(detail.get("track_id", "?"))]
		"ACTIVE_TX_PING":
			txt = "%s ping %s sent" % [tid, str(detail.get("ping_id", ""))]
		"ECHO_RECEIVED":
			txt = "%s echo received" % tid
		"LISTEN_COMPLETE_NO_RETURN":
			txt = "%s listen complete — no return" % tid
		"FUZE_ARMED":
			txt = "%s fuze ARMED (%.0fm run)" % [tid, float(detail.get("traveled_m", 0.0))]
		_:
			txt = "%s %s" % [tid, kind]
	_weapon_log.push_front(txt)
	if _weapon_log.size() > MAX_LOG:
		_weapon_log.pop_back()
	_refresh()


## 每帧轻刷新：管数 / 在水鱼雷 / 海图鱼雷轨迹。
func refresh() -> void:
	_refresh()


func _refresh() -> void:
	if weapons == null or _lbl_weapons == null:
		return
	_lbl_weapons.text = (
		"Tubes: %d/%d loaded  In-water: %d"
		% [weapons.loaded_count(), weapons.tubes.size(), weapons.torpedoes.size()]
	)
	if _btn_fire != null:
		# Commit 3：随时可发射 = 有装填管（无解也允许 MANUAL/BEARING_ONLY）。
		_btn_fire.disabled = weapons.loaded_count() == 0
	if not _weapon_log.is_empty():
		# P1-03.2：一行一事件（不用长 " | " 拼接），配合 autowrap 不撑宽侧栏。
		_lbl_weapons.text += "\n" + "\n".join(_weapon_log)
	if chart == null:
		return
	var chart_data: Array = []
	for tp in weapons.torpedoes:
		# S1-07 §11.3（Commit 11）：海图叠加——轨迹/任务状态 + 线导连线 +
		# 搜索扇区/Seeker FOV + 选中航迹方位（全部来自己方武器状态与净化摘要）。
		# 评审 P0-10/P1-02：扇区由 SeekerBeamState 单一真源驱动（物理门与
		# 绘制同参数）；地图用真实 torpedo_id（绝不用数组序号）；主动脉冲由
		# tx_state 驱动（不由 ATTACK/TERMINAL 猜测）；±σ 用航迹真实方差。
		var beam: Dictionary = SeekerBeamState.new_from(tp).to_dict()
		var entry := {
			"trail": tp.trail,
			"state": tp.mission_state_name(),
			"torpedo_id": str(tp.torpedo_id),
			"course_deg": tp.course_deg,
			"wire_state": tp.wire_state_name(),
			"tx_state": tp.active_tx_state_name(),
			"beam": beam,
			"search_center_deg": beam["search_center_true_deg"],
			"search_half_deg": beam["search_half_angle_deg"],
			"fov_half_deg": beam["passive_half_angle_deg"],
			"track_bearing_deg": -1.0,
			"track_sigma_deg": 0.0,
		}
		if tp._seeker != null:
			var sel: SeekerTrack = tp._seeker.selected_track()
			if sel != null:
				entry["track_bearing_deg"] = sel.bearing_estimate_deg
				entry["track_sigma_deg"] = sqrt(maxf(sel.bearing_var_deg2, 0.0))
		chart_data.append(entry)
	chart.torpedoes = chart_data
	chart.now_time = now_time
	chart.queue_redraw()
