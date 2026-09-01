class_name GameKitTouchButton
extends Control
## 触屏按钮：原生多点触控响应（InputEventScreenTouch），程序化绘制（零素材）。
##
## 相比 Godot 内置的 TouchScreenButton，本类用纯 Control + _draw 绘制圆形/圆角按钮，
## 不依赖贴图，且支持按住时长等便捷属性。用法：放进 UI，连接 pressed 信号。
##
## 设计参考 godot-demo-projects：3d/platformer 的 touch_screen_ui 用 TouchScreenButton
## 做 jump/shoot 按键；本类把同样的理念做成零素材的 Control 版本。

signal pressed
signal released

## 按钮半径（像素）。节点 size 应约等于 2 * radius。
@export var radius: float = 42.0
## 按住时的填充色；松开恢复为半透明描边风格。
@export var fill_color: Color = Color(1, 1, 1, 0.18)
## 描边色。
@export var stroke_color: Color = Color(1, 1, 1, 0.45)
## 可选的文字（如 "重开"）。
@export var label: String = ""
## 可选的字体（不设置则用 Godot 默认字体，中文字符可能缺字形，建议游戏自带字体子集）。
@export var label_font: Font = null

## 是否正被按住。
var is_pressed: bool = false

var _touch_index: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _touch_index == -1 and _in_circle(event.position):
			_touch_index = event.index
			_set_pressed(true)
			get_viewport().set_input_as_handled()
		elif not event.pressed and event.index == _touch_index:
			_touch_index = -1
			_set_pressed(false)
			get_viewport().set_input_as_handled()


func _in_circle(screen_pos: Vector2) -> bool:
	var center: Vector2 = get_global_rect().get_center()
	var local := screen_pos - center
	return local.length_squared() <= radius * radius


func _set_pressed(value: bool) -> void:
	is_pressed = value
	queue_redraw()
	if value:
		pressed.emit()
	else:
		released.emit()


func _draw() -> void:
	var center := size * 0.5
	if is_pressed:
		draw_circle(center, radius, fill_color)
	draw_arc(center, radius, 0, TAU, 48, stroke_color, 2.5, true)
	if label != "":
		var f := label_font if label_font != null else ThemeDB.fallback_font
		var fs: int = ThemeDB.fallback_font_size
		draw_string(
			f,
			center - Vector2(0, fs * 0.4),
			label,
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			fs,
			Color(1, 1, 1, 0.9)
		)
