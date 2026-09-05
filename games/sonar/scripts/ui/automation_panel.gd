class_name AutomationPanelUI
extends VBoxContainer
## automation_panel.gd — S1-05 最小自动化控制 UI（REQ-AU-01/04）。
##
## 面板持有 AutomationController 并自驱动（_process 内按 auto_interval_s
## 调 update）：模式 OptionButton（MANUAL/ASSISTED/FULL_AUTO）+ ROE 开关
## （auto_fire/auto_decoy）+ 槽位/最近命令状态行。
## FULL_AUTO 的 REFIT 动作经 refit_requested 交主 UI 执行；ASSISTED 提案
## 仅显示待 Apply（去重：同一证据只提示一次）。

signal refit_requested(track_id: String)

const AUTO_INTERVAL_S: float = 2.0

var ctrl: AutomationController = AutomationController.new()
var tracker: Tracker = null
var main_ref: Control = null  # 主 UI 引用（执行 REFIT 回调）

var _sim_now: float = 0.0
var _accum: float = 0.0
var _pending_proposals: Array = []
var _mode_opt: OptionButton = null
var _chk_fire: CheckButton = null
var _chk_decoy: CheckButton = null
var _lbl_state: Label = null


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	var lbl := Label.new()
	lbl.text = "AUTO"
	row.add_child(lbl)
	_mode_opt = OptionButton.new()
	for m in AutomationController.MODE_NAMES:
		_mode_opt.add_item(str(m))
	_mode_opt.select(AutomationController.MODE_MANUAL)
	_mode_opt.item_selected.connect(_on_mode)
	row.add_child(_mode_opt)
	_chk_fire = _mk_roe("auto_fire")
	_chk_decoy = _mk_roe("auto_decoy")
	_lbl_state = Label.new()
	_lbl_state.text = "slots 0 | —"
	_lbl_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_state.custom_minimum_size = Vector2(0, 0)
	add_child(_lbl_state)


## 绑定数据源与执行回调（主 UI 在装配时调用一次）。
func bind(tracker_ref: Tracker, refit_cb: Callable) -> void:
	tracker = tracker_ref
	if refit_cb.is_valid():
		refit_requested.connect(func(tid: String): refit_cb.call(tid))


func _process(delta: float) -> void:
	if tracker == null:
		return
	_accum += delta
	if _accum < AUTO_INTERVAL_S:
		return
	_accum = 0.0
	var r: Dictionary = ctrl.update(_sim_now, tracker.all_tracks())
	_pending_proposals = r.get("proposals", [])
	for a in r.get("actions", []):
		if str(a.get("action", "")) == "REFIT":
			refit_requested.emit(str(a.get("track_id", "")))
	_refresh_state()


func _on_mode(index: int) -> void:
	ctrl.set_mode(index, _sim_now)
	_refresh_state()


func _mk_roe(key: String) -> CheckButton:
	var c := CheckButton.new()
	c.text = key
	c.button_pressed = bool(ctrl.roe.get(key, false))
	c.toggled.connect(func(on: bool): ctrl.set_roe(key, on, _sim_now))
	add_child(c)
	return c


func _refresh_state() -> void:
	var last: String = "—"
	if not ctrl.command_log.is_empty():
		var e: Dictionary = ctrl.command_log[ctrl.command_log.size() - 1]
		last = "%s %s" % [str(e.get("kind", "")), str(e.get("detail", ""))]
	var txt: String = "slots %d | %s" % [ctrl.slots.size(), last]
	if not _pending_proposals.is_empty():
		var ids: Array = []
		for p in _pending_proposals:
			ids.append(str(p.get("track_id", "")))
		txt += " | Apply? " + ",".join(ids)
	_lbl_state.text = txt
