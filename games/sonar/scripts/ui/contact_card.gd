class_name ContactCard
extends VBoxContainer
## contact_card.gd — S1-11 D-17 / AT-63 / AT-64：普通接触卡。
##
## 常用操作层只保留四个直接动作：
##   查看 / 优先跟踪 / 主动确认 / 设为攻击目标。
## Mark 改绑、原始回波、残差、分支假设与完整审计一律进入"详情"折叠区（默认收起），
## 不得挤占常用侧栏（见 demo §3.9 / D-16）。
##
## 卡片只读玩家 Track 表示（分类概率/来源/证据数），不含任何真值。

signal view_requested(track_id: String)
signal track_requested(track_id: String)
signal confirm_requested(track_id: String)
signal target_requested(track_id: String)

const ACTION_IDS: Array = ["view", "track", "confirm", "target"]
const ACTION_KEYS: Dictionary = {
	"view": "contact_action_view",
	"track": "contact_action_track",
	"confirm": "contact_action_confirm",
	"target": "contact_action_target",
}

var action_row: HFlowContainer = null  # UI-01：空间不足自动换行（不撑宽侧栏）
var detail_toggle: Button = null
var detail_box: VBoxContainer = null
var ui: Control = null  # 主 UI（选中态/状态回调）

var _btns: Dictionary = {}
var _lbl: Label = null
var _detail_lbl: Label = null


## 在主 UI 战术页安装卡片（一行装配，避免撑爆枢纽行数）。
static func install(parent: Node, ui_ref: Control) -> ContactCard:
	var card := ContactCard.new()
	card.ui = ui_ref
	parent.add_child(card)
	return card


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_lbl = Label.new()
	_lbl.text = UiText.t("contact_no_selection")
	_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_lbl)
	action_row = HFlowContainer.new()
	action_row.add_theme_constant_override("h_separation", 4)
	action_row.add_theme_constant_override("v_separation", 4)
	add_child(action_row)
	for aid in ACTION_IDS:
		var b := Button.new()
		b.text = UiText.t(str(ACTION_KEYS[aid]))
		b.pressed.connect(_on_action.bind(str(aid)))
		action_row.add_child(b)
		_btns[aid] = b
	detail_toggle = Button.new()
	detail_toggle.text = UiText.t("contact_details")
	detail_toggle.toggle_mode = true
	detail_toggle.toggled.connect(func(on: bool): detail_box.visible = on)
	add_child(detail_toggle)
	detail_box = VBoxContainer.new()
	detail_box.visible = false
	add_child(detail_box)
	_detail_lbl = Label.new()
	_detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_box.add_child(_detail_lbl)
	set_process(true)
	sync()


## 常用层动作按钮数量（AT-63：恰好四个）。
func action_button_count() -> int:
	return _btns.size()


func action_button(aid: String) -> Button:
	return _btns.get(aid, null)


func details_visible() -> bool:
	return detail_box != null and detail_box.visible


## 卡片标题文本（含分类标签，AT-60）。
func title_text() -> String:
	return _lbl.text if _lbl != null else ""


## 详情抽屉里的高级控件文本（AT-64：改绑/原始回波/残差/分支假设/审计）。
func detail_control_names() -> Array:
	var out: Array = []
	if detail_box == null:
		return out
	for c in detail_box.get_children():
		out.append(str(c.name))
	return out


func _process(_delta: float) -> void:
	sync()


## 按当前选中接触刷新标题与动作可用性（无选中时禁用动作）。
func sync() -> void:
	if ui == null or _lbl == null:
		return
	var tid: String = str(ui.selected_track_id)
	var has: bool = tid != ""
	if not has:
		_lbl.text = UiText.t("contact_no_selection")
		_detail_lbl.text = ""
	else:
		var t: Track = ui.tracker.track_by_id(tid)
		_lbl.text = "%s · %s" % [tid, _track_summary(t)]
		_detail_lbl.text = _detail_summary(t)
	for aid in _btns.keys():
		(_btns[aid] as Button).disabled = not has
	if not has and detail_toggle != null:
		detail_toggle.button_pressed = false
		detail_box.visible = false
	detail_toggle.visible = has


func _track_summary(t: Track) -> String:
	if t == null:
		return UiText.t("contact_no_selection")
	var parts: Array = [t.classification_label()]
	var src: String = t.mark_source_summary()
	if src != "":
		parts.append(src)
	return " · ".join(parts)


func _detail_summary(t: Track) -> String:
	if t == null:
		return ""
	var a: Dictionary = t.classification_assessment
	var ev: String = str(a.get("evidence_summary", "证据不足"))
	return "分类依据：%s | 证据数 %d" % [ev, t.evidence_count()]


func _on_action(aid: String) -> void:
	var tid: String = str(ui.selected_track_id) if ui != null else ""
	if tid == "":
		return
	match aid:
		"view":
			view_requested.emit(tid)
			ui._on_contact_selected(tid)
		"track":
			track_requested.emit(tid)
			ui._update_status("已优先跟踪 " + tid)
		"confirm":
			confirm_requested.emit(tid)
			ui._update_status("已主动确认 " + tid)
		"target":
			target_requested.emit(tid)
			ui._on_contact_selected(tid)
			ui._update_status("已设为攻击目标 " + tid)
