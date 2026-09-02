class_name WeaponPanelUI
extends VBoxContainer
## weapon_panel.gd — 武器发射面板（阶段四，从 main_ui 拆出控制行数）。
##
## 信息链纪律：Fire 只用已提交的 SystemSolution（玩家火控解），绝不读 Truth。
## 本面板只负责「展示 + 触发」，fire_requested 交由 main_ui 用自身位置执行发射，
## 因此本面板不持有 Truth own、也不直接调用 weapons.fire。

signal fire_requested
signal status(msg: String)

const MAX_LOG: int = 5

var weapons: WeaponSystem = null
var chart: ChartView = null

var _btn_fire: Button = null
var _lbl_weapons: Label = null
var _weapon_log: Array = []
var _chart_dirty: Callable = Callable()


func _init() -> void:
	_build()


func _build() -> void:
	_btn_fire = Button.new()
	_btn_fire.text = "🚀 Fire Torpedo (System Solution)"
	_btn_fire.pressed.connect(func(): fire_requested.emit())
	_btn_fire.disabled = true
	add_child(_btn_fire)
	_lbl_weapons = Label.new()
	_lbl_weapons.text = "Tubes: -"
	_lbl_weapons.add_theme_font_size_override("font_size", 14)
	add_child(_lbl_weapons)


## 由 main_ui 装配后注入依赖并监听武器事件。
func bind(p_weapons: WeaponSystem, p_chart: ChartView, p_on_dirty: Callable) -> void:
	weapons = p_weapons
	chart = p_chart
	_chart_dirty = p_on_dirty
	if weapons != null:
		weapons.weapon_event.connect(_on_weapon_event)
	_refresh()


## 解被提交后启用 Fire；无解时禁用。
func set_solution_available(available: bool) -> void:
	if _btn_fire != null:
		_btn_fire.disabled = not available


func _on_weapon_event(tid: String, kind: String, detail: Dictionary) -> void:
	var txt: String = "%s %s" % [tid, kind]
	if kind == "HIT":
		txt = "💥 %s HIT %s" % [tid, str(detail.get("target_id", ""))]
		if _chart_dirty.is_valid():
			_chart_dirty.call()
	elif kind == "ACQUIRE":
		txt = "%s ACQUIRE @%.0fm" % [tid, float(detail.get("range_m", 0.0))]
	elif kind == "ENABLE":
		txt = "%s seeker ENABLED" % tid
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
	if not _weapon_log.is_empty():
		_lbl_weapons.text += "\n" + " | ".join(_weapon_log)
	if chart == null:
		return
	var chart_data: Array = []
	for tp in weapons.torpedoes:
		var state_name: String = "RUN"
		match tp.state:
			Torpedo.State.SEARCH:
				state_name = "SEARCH"
			Torpedo.State.PURSUIT:
				state_name = "PURSUIT"
		chart_data.append({"trail": tp.trail, "state": state_name})
	chart.torpedoes = chart_data
	chart.queue_redraw()
