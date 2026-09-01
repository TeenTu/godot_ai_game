class_name GameKitVirtualJoystick
extends Control
## 虚拟摇杆：原生多点触控支持，也能在桌面端配合「鼠标模拟触摸」调试。
##
## 用法：
##   1. 在场景里放一个本节点（建议锚定在屏幕角落，size 约 200x200）。
##   2. 任何脚本读取 joystick.output（Vector2，各分量 -1..1）驱动角色。
##   3. 桌面端测试：项目设置 input_devices/pointing/emulate_touch_from_mouse=true。
##
## 实现参考 godot-demo-projects：mobile/multitouch_view（触摸事件处理）
## 与 3d/platformer 内置的 VirtualJoystick 插件（思路）。

signal joystick_moved(output: Vector2)
signal joystick_released

## 摇杆底座半径（像素）。节点 size 应约等于 2 * base_radius。
@export var base_radius: float = 90.0
## 摇杆帽半径（像素）。
@export var knob_radius: float = 36.0
## 手指滑出底座多远仍继续跟踪（像素），防止边缘抖动丢触点。
@export var follow_slack: float = 60.0
## 输出向量长度超过 dead_zone 才算有效输入（0..1）。
@export var dead_zone: float = 0.08

## 当前输出（各分量 -1..1），未触摸时为 Vector2.ZERO。
var output: Vector2 = Vector2.ZERO

var _pointers: Dictionary = {}  # touch_index -> 是否为控制该摇杆的手指
var _base_center: Vector2 = Vector2.ZERO
var _knob_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base_center = size * 0.5
	_knob_pos = _base_center


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_try_claim(event.index, event.position)
		else:
			_release(event.index)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)


func _try_claim(index: int, pos: Vector2) -> void:
	# 已被别的手指控制时忽略新手指（单手指摇杆）。
	for claimed in _pointers.values():
		if claimed:
			return
	var local := _to_local_center(pos)
	if local.length() <= base_radius + follow_slack:
		_pointers[index] = true
		_update_output(local)


func _drag(index: int, pos: Vector2) -> void:
	if not _pointers.get(index, false):
		return
	_update_output(_to_local_center(pos))


func _release(index: int) -> void:
	if not _pointers.get(index, false):
		return
	_pointers.erase(index)
	output = Vector2.ZERO
	_knob_pos = _base_center
	queue_redraw()
	joystick_released.emit()


func _to_local_center(screen_pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * screen_pos - _base_center


func _update_output(local: Vector2) -> Vector2:
	var clamped := local.limit_length(base_radius)
	_knob_pos = _base_center + clamped
	var raw := clamped / base_radius
	output = Vector2.ZERO if raw.length() < dead_zone else raw
	queue_redraw()
	joystick_moved.emit(output)
	return output


func _draw() -> void:
	# 底座：半透明圆环，视觉上不抢戏。
	draw_circle(_base_center, base_radius, Color(1, 1, 1, 0.10))
	draw_arc(_base_center, base_radius, 0, TAU, 48, Color(1, 1, 1, 0.35), 2.0, true)
	# 摇杆帽。
	draw_circle(_knob_pos, knob_radius, Color(1, 1, 1, 0.55))
	draw_arc(_knob_pos, knob_radius, 0, TAU, 32, Color(1, 1, 1, 0.8), 1.5, true)
