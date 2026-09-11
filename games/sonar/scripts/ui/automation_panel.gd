class_name AutomationPanelUI
extends VBoxContainer
## automation_panel.gd — S1-05 最小自动化控制 UI（REQ-AU-01/04）。
##
## 面板持有 AutomationController 并自驱动（_process 内按 auto_interval_s
## 调 update）：模式 OptionButton（MANUAL/ASSISTED/FULL_AUTO）+ ROE 开关
## （auto_fire/auto_decoy）+ 槽位/最近命令状态行。
## FULL_AUTO 的 REFIT 动作经 refit_requested 交主 UI 执行；ASSISTED 提案
## 仅显示待 Apply（去重：同一证据只提示一次）。
##
## PG-01：`ctrl` 是**唯一**模式源，由 main_ui 注入并与主动声呐卡片共享
## （卡片切模式 / Take Control 也会改这里；本面板只显示，不另存状态）。

signal refit_requested(track_id: String)

const AUTO_INTERVAL_S: float = 2.0

var ctrl: AutomationController = AutomationController.new()
var tracker: Tracker = null
var main_ref: Control = null  # 主 UI 引用（执行 REFIT 回调）
## S1-11 Batch 2：ASSIST 值班链运行器与数据源（世界测量流）。
var assist: AssistRuntime = null
var world_ref: World = null

var _sim_now: float = 0.0
var _accum: float = 0.0
var _pending_proposals: Array = []
var _mode_opt: OptionButton = null
var _chk_fire: CheckButton = null
var _chk_decoy: CheckButton = null
var _lbl_state: Label = null


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	if assist == null:
		assist = AssistRuntime.new(tracker)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	var lbl := Label.new()
	lbl.text = UiText.t("lbl_auto")
	row.add_child(lbl)
	_mode_opt = OptionButton.new()
	for m in AutomationController.MODE_NAMES:
		_mode_opt.add_item(UiText.mode(str(m)))
	_mode_opt.select(ctrl.mode)  # S1-11 D-11：默认 ASSISTED
	_mode_opt.item_selected.connect(_on_mode)
	row.add_child(_mode_opt)
	_chk_fire = _mk_roe("auto_fire")
	_chk_decoy = _mk_roe("auto_decoy")
	_lbl_state = Label.new()
	_lbl_state.text = UiText.t("slots_fmt") % [0, "—"]
	_lbl_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_state.custom_minimum_size = Vector2(0, 0)
	add_child(_lbl_state)


## 绑定数据源与执行回调（主 UI 在装配时调用一次）。
func bind(tracker_ref: Tracker, refit_cb: Callable, world_src: World = null) -> void:
	tracker = tracker_ref
	world_ref = world_src
	if assist == null:
		assist = AssistRuntime.new(tracker_ref)
	elif assist.chain != null:
		assist.chain.tracker = tracker_ref
	if refit_cb.is_valid():
		refit_requested.connect(func(tid: String): refit_cb.call(tid))


func _process(delta: float) -> void:
	if tracker == null:
		return
	_accum += delta
	if _accum < AUTO_INTERVAL_S:
		return
	_accum = 0.0
	var now: float = world_ref.sim_time if world_ref != null else _sim_now
	# S1-11 Batch 2：ASSIST 值班链（自动 Mark/关联/分类/增量 Fit）。
	if assist != null and world_ref != null:
		assist.consume_passive(world_ref.measurements, ctrl.mode, now)
		assist.classify_tracks(tracker.all_tracks(), now)
		if ctrl.mode == AutomationController.Mode.ASSISTED:
			for tid in assist.refit_requests(tracker.all_tracks()):
				refit_requested.emit(str(tid))
				assist.mark_fitted(tracker.track_by_id(str(tid)))
	var r: Dictionary = ctrl.update(now, tracker.all_tracks())
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
	c.text = UiText.roe(key)
	c.button_pressed = bool(ctrl.roe.get(key, false))
	c.toggled.connect(func(on: bool): ctrl.set_roe(key, on, _sim_now))
	add_child(c)
	return c


func _refresh_state() -> void:
	# PG-01/T21：模式下拉与唯一模式源同步（主动声呐卡片切模式也会反映到这里）。
	if _mode_opt != null and _mode_opt.selected != ctrl.mode:
		_mode_opt.select(ctrl.mode)
	var last: String = "—"
	if not ctrl.command_log.is_empty():
		var e: Dictionary = ctrl.command_log[ctrl.command_log.size() - 1]
		last = "%s %s" % [UiText.event(str(e.get("kind", ""))), str(e.get("detail", ""))]
	var txt: String = UiText.t("slots_fmt") % [ctrl.slots.size(), last]
	if not _pending_proposals.is_empty():
		var ids: Array = []
		for p in _pending_proposals:
			ids.append(str(p.get("track_id", "")))
		txt += " | " + str(UiText.t("apply_prompt_2")) + ",".join(ids)
	_lbl_state.text = txt
