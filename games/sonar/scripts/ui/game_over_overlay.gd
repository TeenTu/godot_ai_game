class_name GameOverOverlay
extends Control
## game_over_overlay.gd — REQ-B5-04：任务终局覆盖层。
##
## world.mission_ended 后显示 MISSION FAILED / 原因 / 任务时间，并提供
## 「Restart Same Seed」（经 UiContract 启动覆写重建同局面）与
## 「Main Menu」。全屏 STOP 鼠标过滤锁定底层面板；命令层另有统一
## 命令门（world.command_reject_reason）双保险。

signal restart_requested
signal menu_requested

var _lbl_reason: Label = null
var _lbl_time: Label = null
var _scenario: String = ""
var _seed_val: int = -1


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP  # 终局后锁定底层全部面板
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.02, 0.02, 0.86)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(560, 0)
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var title := Label.new()
	title.text = UiText.t("mission_failed")
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(0.95, 0.25, 0.2))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_lbl_reason = Label.new()
	_lbl_reason.add_theme_font_size_override("font_size", 20)
	_lbl_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_lbl_reason)
	_lbl_time = Label.new()
	_lbl_time.add_theme_font_size_override("font_size", 16)
	_lbl_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_lbl_time)
	box.add_child(_mk_btn(UiText.t("btn_restart_seed"), _on_restart))
	box.add_child(_mk_btn(UiText.t("btn_main_menu"), func() -> void: menu_requested.emit()))


## 显示终局结果（reason 映射为玩家可读文本；不泄露任何 Truth 信息）。
func show_result(result: Dictionary, scenario: String, seed_val: int) -> void:
	_scenario = scenario
	_seed_val = seed_val
	var reason: String = str(result.get("reason", ""))
	_lbl_reason.text = UiText.mission(reason) if reason != "" else ""
	var t: float = float(result.get("time", 0.0))
	_lbl_time.text = "%s %02d:%02d" % [UiText.t("mission_time"), int(t) / 60, int(t) % 60]
	visible = true


func _mk_btn(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.pressed.connect(on_pressed)
	return b


## 同 seed 重玩：写启动覆写后重建 SonarUI（deferred，避免回调中 free 自身）。
func _on_restart() -> void:
	UiContract.set_startup_override(_scenario, _seed_val)
	if _seed_val >= 0:
		UiContract.record_last_seed(_seed_val)
	restart_requested.emit()
