class_name MarkGroupPanel
extends VBoxContainer
## mark_group_panel.gd — Mark 组选择控件（MK-01：**纯视图**，只渲染快照）。
##
## 本面板**不再自持** active_group_id / association_mode：这两项的业务状态唯一
## 存放在 MarkFlow。旧实现各存一份，导致地图右键「设为当前 Mark 组」改了
## MarkFlow 后，面板下一次 set_groups() 又用自己那份旧值覆盖回去（刷新不完整
## 同步），玩家看到的锁定组和真实写入组可以长期不一致。
##
## 布局：
##   当前查看：M02
##   手动落点写入：M01（锁定）              [＋ 新建组]
##   [（自动）| M01 | M02 ...]  关联方式：[锁定|建议|自动]
##   [应用建议] [移入当前组] [移除最近] [撤销]
##   建议：建议关联到 M0x
##   待处理落点：…（[归入当前组] [新建组]）
##   审计行

signal mode_change_requested(mode: String)
signal group_change_requested(group_id: String)
signal operation_result(res: Dictionary)

const ASSOC_ORDER: Array = ["LOCKED", "SUGGEST", "AUTO"]

var flow: MarkFlow = null
var selected_provider: Callable = Callable()  # () -> String（选中 Contact）

var _lbl_view: Label = null
var _lbl_write: Label = null
var _lbl_pending: Label = null
var _btn_move: Button = null
var _btn_pending_attach: Button = null
var _btn_pending_new: Button = null
var _opt_group: OptionButton = null
var _opt_assoc: OptionButton = null
var _btn_apply: Button = null
var _lbl_suggest: Label = null
var _lbl_audit: Label = null


func _init() -> void:
	add_theme_font_size_override("font_size", 12)

	# MK-01：两个独立信息，明确区分"看"与"写"。
	_lbl_view = _mk_label(12)
	add_child(_lbl_view)
	var row0 := HBoxContainer.new()
	_lbl_write = _mk_label(12)
	_lbl_write.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row0.add_child(_lbl_write)
	var btn_new := Button.new()
	btn_new.text = UiText.t("btn_new_group")
	btn_new.add_theme_font_size_override("font_size", 12)
	btn_new.pressed.connect(_on_new_group)
	row0.add_child(btn_new)
	add_child(row0)

	var row1 := HBoxContainer.new()
	var lbl1 := _mk_label(12)
	lbl1.text = UiText.t("add_mark_to")
	row1.add_child(lbl1)
	_opt_group = OptionButton.new()
	_opt_group.add_item(UiText.t("auto_pick"))
	_opt_group.item_selected.connect(_on_group_selected)
	row1.add_child(_opt_group)
	add_child(row1)

	var row2 := HBoxContainer.new()
	var lbl2 := _mk_label(12)
	lbl2.text = UiText.t("assoc_label")
	row2.add_child(lbl2)
	_opt_assoc = OptionButton.new()
	for m in ASSOC_ORDER:
		_opt_assoc.add_item(UiText.assoc(m))
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
	_btn_move = Button.new()
	_btn_move.text = UiText.t("btn_move_to_group")
	_btn_move.add_theme_font_size_override("font_size", 12)
	_btn_move.disabled = true
	_btn_move.pressed.connect(_on_move_to_group)
	row3.add_child(_btn_move)
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

	_lbl_suggest = _mk_label(12)
	add_child(_lbl_suggest)

	# MK-05：目的组失效时的待处理落点恢复入口。
	_lbl_pending = _mk_label(12)
	add_child(_lbl_pending)
	var row4 := HBoxContainer.new()
	_btn_pending_attach = Button.new()
	_btn_pending_attach.text = UiText.t("btn_attach_pending")
	_btn_pending_attach.add_theme_font_size_override("font_size", 12)
	_btn_pending_attach.pressed.connect(_on_attach_pending)
	row4.add_child(_btn_pending_attach)
	_btn_pending_new = Button.new()
	_btn_pending_new.text = UiText.t("btn_new_group_from_pending")
	_btn_pending_new.add_theme_font_size_override("font_size", 12)
	_btn_pending_new.pressed.connect(_on_new_group_from_pending)
	row4.add_child(_btn_pending_new)
	add_child(row4)

	_lbl_audit = Label.new()
	_lbl_audit.text = ""
	_lbl_audit.add_theme_font_size_override("font_size", 11)
	_lbl_audit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl_audit)


func _mk_label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# ---------------------------------------------------------------- 交互
func _on_group_selected(i: int) -> void:
	group_change_requested.emit(_group_id_at(i))


## MK-01：业务 ID 存在 item metadata 里，**禁止**用显示文本反推。
func _group_id_at(i: int) -> String:
	if i <= 0:
		return ""
	var md: Variant = _opt_group.get_item_metadata(i)
	return str(md) if md != null else ""


func _on_assoc_selected(i: int) -> void:
	mode_change_requested.emit(str(ASSOC_ORDER[i]))


func _on_apply() -> void:
	if flow == null:
		return
	operation_result.emit(flow.apply_pending_suggestion())


## MK-03：把最近点击的那条既有证据显式改绑到锁定目的组。
func _on_move_to_group() -> void:
	if flow == null:
		return
	operation_result.emit(flow.move_last_clicked_to_lock())


func _on_remove() -> void:
	if flow == null:
		return
	var tid: String = _locked_id()
	if tid == "" and selected_provider.is_valid():
		tid = str(selected_provider.call())
	operation_result.emit(flow.remove_last_mark(tid))


func _on_undo() -> void:
	if flow == null:
		return
	operation_result.emit(flow.undo_last_edit())


func _on_new_group() -> void:
	if flow == null:
		return
	operation_result.emit(flow.new_group())


func _on_attach_pending() -> void:
	if flow == null:
		return
	var tid: String = _locked_id()
	if tid == "":
		return
	operation_result.emit(flow.attach_pending(tid))


func _on_new_group_from_pending() -> void:
	if flow == null:
		return
	operation_result.emit(flow.new_group_from_pending())


func _locked_id() -> String:
	return flow.active_group_id if flow != null else ""


# ---------------------------------------------------------------- 渲染
## 用当前 Track 列表刷新组下拉。选中项 = MarkFlow 的当前目的组（唯一状态源）。
func set_groups(track_ids: Array) -> void:
	var cur: String = _locked_id()
	_opt_group.clear()
	_opt_group.add_item(UiText.t("auto_pick"))
	_opt_group.set_item_metadata(0, "")
	for tid in track_ids:
		_opt_group.add_item(str(tid))
		_opt_group.set_item_metadata(_opt_group.get_item_count() - 1, str(tid))
	var idx: int = 0
	for i in range(1, _opt_group.get_item_count()):
		if _group_id_at(i) == cur and cur != "":
			idx = i
			break
	_opt_group.select(idx)
	_refresh_snapshot()


## MK-01：快照渲染（当前查看 / 手动落点写入 / 模式 / 建议 / 待处理）。
func _refresh_snapshot() -> void:
	if flow == null:
		return
	var view_id: String = str(selected_provider.call()) if selected_provider.is_valid() else ""
	var snap: Dictionary = flow.status_snapshot(view_id)
	var vid: String = str(snap["view_id"])
	_lbl_view.text = UiText.t("mark_view_fmt") % (vid if vid != "" else UiText.t("none_value"))
	var wid: String = str(snap["write_id"])
	if wid == "":
		_lbl_write.text = UiText.t("mark_write_auto")
	else:
		_lbl_write.text = (
			UiText.t("mark_write_lock_fmt") % wid
			if bool(snap["locked"])
			else UiText.t("mark_write_fmt") % wid
		)
	var mode_idx: int = ASSOC_ORDER.find(str(snap["mode"]))
	_opt_assoc.select(mode_idx if mode_idx >= 0 else 0)
	var sug: String = str(snap["suggestion"])
	_lbl_suggest.text = (str(UiText.t("suggestion_fmt")) % sug) if sug != "" else ""
	_btn_apply.disabled = sug == ""
	_btn_move.disabled = not (
		wid != "" and flow.last_clicked_owner_id() != "" and flow.last_clicked_owner_id() != wid
	)
	_btn_pending_attach.disabled = not bool(snap["pending"]) or wid == ""
	_btn_pending_new.disabled = not bool(snap["pending"])
	_lbl_pending.text = (
		(str(UiText.t("mark_pending_fmt")) % flow.pending_bearing())
		if bool(snap["pending"])
		else ""
	)


func show_suggestion(tid: String) -> void:
	# 兼容旧调用方；真实渲染走 _refresh_snapshot()。
	var text: String = (str(UiText.t("suggestion_fmt")) % tid) if tid != "" else ""
	_lbl_suggest.text = text
	_btn_apply.disabled = tid == ""


## MK-03：外部（如 main_ui 应用点击结果后）刷新"移入当前组"可用性。
func refresh_actions() -> void:
	_refresh_snapshot()


func set_audit(line: String) -> void:
	_lbl_audit.text = line
