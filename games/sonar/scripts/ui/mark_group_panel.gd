class_name MarkGroupPanel
extends VBoxContainer
## mark_group_panel.gd — REQ-0908 Batch 1：显式 Mark 组选择控件（REQ-B1-01）
## 与 Mark 编辑（REQ-B1-05 最小集：Remove / Reassign-Apply / Undo + 审计）。
##
##   Add Mark to:  [ (auto) | M01 | M02 | ... ]  [+ New Group]
##   Association:  [ LOCKED | SUGGEST | AUTO ]
##   [Apply suggestion] [Remove Last Mark] [Undo]
##
## 编辑操作直接走 MarkFlow（flow），结果经 operation_result 信号交 main_ui
## 统一应用（修订同步/置脏/刷新），面板不自持 Track 状态。

signal association_changed(mode: String)
signal active_group_changed(group_id: String)
signal operation_result(res: Dictionary)

var flow: MarkFlow = null
var selected_provider: Callable = Callable()  # () -> String（选中 Contact）

var association_mode: String = "LOCKED"
var active_group_id: String = ""

var _opt_group: OptionButton = null
var _opt_assoc: OptionButton = null
var _btn_apply: Button = null
var _lbl_suggest: Label = null
var _lbl_audit: Label = null


func _init() -> void:
	add_theme_font_size_override("font_size", 12)

	var row1 := HBoxContainer.new()
	var lbl1 := Label.new()
	lbl1.text = UiText.t("add_mark_to")
	lbl1.add_theme_font_size_override("font_size", 12)
	row1.add_child(lbl1)
	_opt_group = OptionButton.new()
	_opt_group.add_item(UiText.t("auto_pick"))
	_opt_group.item_selected.connect(_on_group_selected)
	row1.add_child(_opt_group)
	var btn_new := Button.new()
	btn_new.text = UiText.t("btn_new_group")
	btn_new.add_theme_font_size_override("font_size", 12)
	btn_new.pressed.connect(_on_new_group)
	row1.add_child(btn_new)
	add_child(row1)

	var row2 := HBoxContainer.new()
	var lbl2 := Label.new()
	lbl2.text = UiText.t("assoc_label")
	lbl2.add_theme_font_size_override("font_size", 12)
	row2.add_child(lbl2)
	_opt_assoc = OptionButton.new()
	for m in ["LOCKED", "SUGGEST", "AUTO"]:
		_opt_assoc.add_item(UiText.assoc(m))
	_opt_assoc.select(0)
	_opt_assoc.item_selected.connect(_on_assoc_selected)
	row2.add_child(_opt_assoc)
	add_child(row2)

	var row3 := HBoxContainer.new()
	_btn_apply = Button.new()
	_btn_apply.text = UiText.t("btn_apply_suggest")
	_btn_apply.add_theme_font_size_override("font_size", 12)
	_btn_apply.disabled = true
	_btn_apply.pressed.connect(_on_apply)
	row3.add_child(_btn_apply)
	var btn_rm := Button.new()
	btn_rm.text = UiText.t("btn_remove_last")
	btn_rm.add_theme_font_size_override("font_size", 12)
	btn_rm.pressed.connect(_on_remove)
	row3.add_child(btn_rm)
	var btn_undo := Button.new()
	btn_undo.text = UiText.t("btn_undo")
	btn_undo.add_theme_font_size_override("font_size", 12)
	btn_undo.pressed.connect(_on_undo)
	row3.add_child(btn_undo)
	add_child(row3)

	_lbl_suggest = Label.new()
	_lbl_suggest.text = ""
	_lbl_suggest.add_theme_font_size_override("font_size", 12)
	_lbl_suggest.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_suggest)
	_lbl_audit = Label.new()
	_lbl_audit.text = ""
	_lbl_audit.add_theme_font_size_override("font_size", 11)
	_lbl_audit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_audit)


func _on_group_selected(i: int) -> void:
	active_group_id = "" if i == 0 else _opt_group.get_item_text(i)
	active_group_changed.emit(active_group_id)


func _on_assoc_selected(i: int) -> void:
	association_mode = ["LOCKED", "SUGGEST", "AUTO"][i]
	association_changed.emit(association_mode)


func _on_new_group() -> void:
	if flow == null:
		return
	var res: Dictionary = flow.new_group()
	var ag: String = str(res.get("active_group", ""))
	if ag != "":
		active_group_id = ag
	operation_result.emit(res)


func _on_apply() -> void:
	if flow == null or active_group_id == "":
		return
	operation_result.emit(flow.apply_suggestion(active_group_id))


func _on_remove() -> void:
	if flow == null:
		return
	var tid: String = active_group_id
	if tid == "" and selected_provider.is_valid():
		tid = str(selected_provider.call())
	operation_result.emit(flow.remove_last_mark(tid))


func _on_undo() -> void:
	if flow == null:
		return
	operation_result.emit(flow.undo_last_edit())


## 用当前 Track 列表刷新组下拉（保持现选中项；组消失回落 auto）。
func set_groups(track_ids: Array) -> void:
	var cur: String = active_group_id
	_opt_group.clear()
	_opt_group.add_item(UiText.t("auto_pick"))
	for tid in track_ids:
		_opt_group.add_item(str(tid))
	var idx: int = 0
	if cur != "":
		for i in range(1, _opt_group.get_item_count()):
			if _opt_group.get_item_text(i) == cur:
				idx = i
				break
	_opt_group.select(idx)


func show_suggestion(tid: String) -> void:
	_lbl_suggest.text = (str(UiText.t("suggestion_fmt")) % tid) if tid != "" else ""
	_btn_apply.disabled = tid == ""


func set_audit(line: String) -> void:
	_lbl_audit.text = line
