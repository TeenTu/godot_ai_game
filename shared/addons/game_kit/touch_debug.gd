class_name GameKitTouchDebug
extends Control
## 多点触控调试覆盖层：每个触点画一个圆点和序号，验证真机触控是否正常。
##
## 用法：加到场景最上层（自动铺满、不拦截输入），真机运行即可看到触点。
## 实现参考 godot-demo-projects/mobile/multitouch_view 的 touch_helper.gd。

const COLORS: Array[Color] = [
	Color(0.95, 0.30, 0.30),
	Color(0.30, 0.75, 0.95),
	Color(0.95, 0.80, 0.30),
	Color(0.45, 0.90, 0.45),
	Color(0.80, 0.50, 0.95),
	Color(0.95, 0.55, 0.25),
]

var _pointers: Dictionary = {}  # touch_index -> 当前位置（屏幕坐标）
var _font: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_pointers[event.index] = event.position
		else:
			_pointers.erase(event.index)
		queue_redraw()
	elif event is InputEventScreenDrag:
		_pointers[event.index] = event.position
		queue_redraw()


func _draw() -> void:
	var i := 0
	for index: int in _pointers:
		var pos: Vector2 = _pointers[index]
		var color := COLORS[i % COLORS.size()]
		draw_circle(pos, 36.0, Color(color, 0.25))
		draw_arc(pos, 36.0, 0, TAU, 32, color, 2.0, true)
		if _font:
			draw_string(
				_font, pos + Vector2(-6, 8), str(index), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, color
			)
		i += 1
