class_name TorpedoControlBar
extends PanelContainer
## torpedo_control_bar.gd — S1-11 §4.3：地图选中鱼雷的紧凑浮动栏。
##
## [TK01] [直航/捕获中/已锁定/短时丢失/重搜] [主动声呐：关/开] [重画航线]
## [深度：自动/上层/下层] [居中]
## 不再显示左转/右转 5°、授权自主、返回线导、接受最佳航迹、搜索图形、引信模式。
## 只读己方武器自身状态（合法）；命令经 WeaponMapControl → Torpedo 线控通道。

signal active_toggled(on: bool)
signal reroute_requested
signal depth_policy_changed(policy: String)
signal center_requested

const POLICIES: Array = ["AUTO", "UPPER", "LOWER"]

var torpedo_id: String = ""
var depth_policy: String = "AUTO"
var wire_connected: bool = true
var wire_reason: String = ""
var _active_on: bool = false

var _lbl_id: Label = null
var _lbl_state: Label = null
var _btn_active: Button = null
var _btn_reroute: Button = null
var _btn_depth: Button = null
var _btn_center: Button = null
var _lbl_reject: Label = null


func _init() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	_lbl_id = Label.new()
	_lbl_id.add_theme_font_size_override("font_size", 14)
	row.add_child(_lbl_id)
	_lbl_state = Label.new()
	_lbl_state.add_theme_font_size_override("font_size", 12)
	row.add_child(_lbl_state)
	_btn_active = _mk(row, "", func(): active_toggled.emit(not _active_on))
	_btn_reroute = _mk(row, UiText.t("bar_reroute"), func(): reroute_requested.emit())
	_btn_depth = _mk(row, "", _on_depth_pressed)
	_btn_center = _mk(row, UiText.t("bar_center"), func(): center_requested.emit())
	_lbl_reject = Label.new()
	_lbl_reject.add_theme_font_size_override("font_size", 11)
	_lbl_reject.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_lbl_reject)


func _on_depth_pressed() -> void:
	var i: int = POLICIES.find(depth_policy)
	depth_policy = POLICIES[(i + 1) % POLICIES.size()]
	depth_policy_changed.emit(depth_policy)


func _mk(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


## 刷新显示（每帧，由 WeaponMapControl 注入净化状态）。
func refresh(tid: String, state_cn: String, active_on: bool, wire_ok: bool, reject: String) -> void:
	torpedo_id = tid
	wire_connected = wire_ok
	wire_reason = reject
	_active_on = active_on
	_lbl_id.text = tid
	_lbl_state.text = state_cn
	_btn_active.text = UiText.t("bar_active_on") if not active_on else UiText.t("bar_active_off")
	_btn_depth.text = UiText.t("bar_depth") + UiText.depth_policy(depth_policy)
	_lbl_reject.text = reject
	var can_cmd: bool = wire_ok
	_btn_active.disabled = not can_cmd
	_btn_reroute.disabled = not can_cmd
	_btn_depth.disabled = not can_cmd
	_btn_active.tooltip_text = (
		UiText.t("iw_tx_tip") % UiText.wire("CONNECTED" if wire_ok else "BROKEN")
	)
	_btn_reroute.tooltip_text = (
		UiText.t("bar_reroute_tip") % UiText.wire("CONNECTED" if wire_ok else "BROKEN")
	)
