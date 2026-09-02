class_name GameKitVirtualJoystick
extends Control
## 虚拟摇杆：原生多点触控支持，也能在桌面端配合「鼠标模拟触摸」调试。
##
## 用法：
##   1. 在场景里放一个本节点（建议锚定在屏幕角落，size 约 200x200）。
##   2. 任何脚本读取 joystick.output（Vector2，各分量 -1..1）驱动角色；
##      或设 use_input_actions=true，让摇杆直接把方向写成 Input Action，
##      这样角色逻辑可以统一用 is_action_pressed("move_left") 等处理键盘+摇杆。
##   3. 桌面端测试：项目设置 input_devices/pointing/emulate_touch_from_mouse=true。
##
## 设计参考 godot-demo-projects：
##   - mobile/multitouch_view（触摸事件处理）
##   - 3d/platformer 内置的 VirtualJoystick 插件（MarcoFazioRandom 版）——
##     吸收其 FIXED/DYNAMIC/FOLLOWING 三种模式和 input-actions 注入，但保持程序化绘制（零素材）。

signal joystick_moved(output: Vector2)
signal joystick_released

enum Mode { FIXED, DYNAMIC, FOLLOWING }

## FIXED：摇杆固定在原位；DYNAMIC：摇杆出现在手指落点；FOLLOWING：手指滑出后底座跟随。
@export var mode: Mode = Mode.FIXED
## 摇杆底座半径（像素）。节点 size 应约等于 2 * base_radius。
@export var base_radius: float = 90.0
## 摇杆帽半径（像素）。
@export var knob_radius: float = 36.0
## 手指滑出底座多远仍继续跟踪（像素），防止边缘抖动丢触点。
@export var follow_slack: float = 60.0
## 输出向量长度超过 dead_zone 才算有效输入（0..1）。
@export var dead_zone: float = 0.08
## 若 ≥ 0：触点 x 归一(相对 viewport 宽)超过该值则本摇杆不认领，
## 用于把屏幕右侧留给技能手势(仅设置方生效)。默认 -1 = 全屏可达(老行为)。
@export var exclude_right_x: float = -1.0
## 为 true 时，摇杆直接写入 Input Action（move_left/right/up/down），
## 游戏逻辑用 is_action_pressed 即可统一处理摇杆与键盘；输出 output 仍照常更新。
@export var use_input_actions: bool = false
@export var action_left: String = "move_left"
@export var action_right: String = "move_right"
@export var action_up: String = "move_up"
@export var action_down: String = "move_down"

## 当前输出（各分量 -1..1），未触摸时为 Vector2.ZERO。
var output: Vector2 = Vector2.ZERO
## 是否正被手指按住。
var is_pressed: bool = false

var _pointers: Dictionary = {}  # touch_index -> true（本摇杆控制的触点）
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
	if is_pressed:
		return
	if _in_excluded_right(pos):
		return
	# FIXED 模式要求点进底座才认；DYNAMIC/FOLLOWING 全屏任意位置认领。
	if mode == Mode.FIXED and not _in_base(pos):
		return
	if mode != Mode.FIXED and not _in_reach_anywhere(pos):
		return
	is_pressed = true
	_pointers[index] = true
	if mode != Mode.FIXED:
		# DYNAMIC/FOLLOWING：底座跟到手指落点。要把物理像素转 canvas 逻辑坐标后
		# 再换算成 Control 局部**绝对**位置（= 触点在屏幕上的实际位置），
		# 而不是用 _to_local_center() 返回的"相对当前底座"偏移——否则底座会画到别处/屏外。
		var canvas_local: Vector2 = get_canvas_transform().affine_inverse() * pos
		_base_center = canvas_local - get_global_rect().position
		_knob_pos = _base_center
	_update_output(_to_local_center(pos))


func _drag(index: int, pos: Vector2) -> void:
	if not _pointers.get(index, false):
		return
	var local := _to_local_center(pos)
	if mode == Mode.FOLLOWING and local.length() > base_radius + follow_slack:
		# 手指滑太远：底座跟着挪，让摇杆继续跟手。
		_base_center += local - local.limit_length(base_radius)
		local = _to_local_center(pos)
	_update_output(local)


func _release(index: int) -> void:
	if not _pointers.get(index, false):
		return
	_pointers.erase(index)
	_set_output(Vector2.ZERO)
	is_pressed = false
	_base_center = size * 0.5
	_knob_pos = _base_center
	queue_redraw()
	joystick_released.emit()


func _to_local_center(screen_pos: Vector2) -> Vector2:
	# 把 screen/物理坐标先经 canvas 逆变换回 canvas 逻辑坐标（720×1280 设计空间），
	# 再减 joystick 的 canvas-局部 global rect 与 _base_center，得到 Control 局部偏移。
	# Godot 4 Web 在 canvas_items stretch 下，_input 事件 position 可能是物理像素，
	# 必须 inverse canvas transform；否则 DYNAMIC 跟手会算到屏外、底座飞出。
	var canvas_local: Vector2 = get_canvas_transform().affine_inverse() * screen_pos
	return canvas_local - (get_global_rect().position + _base_center)


## 触点是否落在底座圆内（FIXED 模式认领用）。
func _in_base(screen_pos: Vector2) -> bool:
	var local := _to_local_center(screen_pos)
	return local.length_squared() <= base_radius * base_radius


## DYNAMIC/FOLLOWING 的"全屏可达"判：落点在 viewport 内即允许认领
## （slack 用 base_radius 保证触点离 joystick 当前中心不太远，避免误触）。
func _in_reach_anywhere(screen_pos: Vector2) -> bool:
	var canvas_local: Vector2 = get_canvas_transform().affine_inverse() * screen_pos
	return get_viewport_rect().has_point(canvas_local)


## 是否落在"排除给技能手势"的右侧区(触点 x 归一 > exclude_right_x)。
func _in_excluded_right(screen_pos: Vector2) -> bool:
	if exclude_right_x < 0.0:
		return false
	var canvas_local: Vector2 = get_canvas_transform().affine_inverse() * screen_pos
	var vp_w: float = get_viewport_rect().size.x
	return canvas_local.x > vp_w * exclude_right_x


func _update_output(local: Vector2) -> void:
	var clamped := local.limit_length(base_radius)
	_knob_pos = _base_center + clamped
	var raw := clamped / base_radius
	_set_output(Vector2.ZERO if raw.length() < dead_zone else raw)
	queue_redraw()
	joystick_moved.emit(output)


## 供测试钩子 / 调试：把底座与摇杆帽的画布坐标归一成 0..1（相对 viewport），
## 便于 vision-e2e 用 hook 数值断言底座/帽没有飞出屏幕。
func get_debug_geom() -> Dictionary:
	var vp: Vector2 = get_viewport_rect().size
	var canvas_base: Vector2 = get_global_rect().position + _base_center
	var canvas_knob: Vector2 = get_global_rect().position + _knob_pos
	return {
		"pressed": is_pressed,
		"base_x": canvas_base.x / vp.x,
		"base_y": canvas_base.y / vp.y,
		"knob_x": canvas_knob.x / vp.x,
		"knob_y": canvas_knob.y / vp.y,
	}


func _set_output(value: Vector2) -> void:
	output = value
	if not use_input_actions:
		return
	_apply_action(action_left, -value.x)
	_apply_action(action_right, value.x)
	_apply_action(action_up, -value.y)
	_apply_action(action_down, value.y)


func _apply_action(action: String, strength: float) -> void:
	if strength > 0.0 and not Input.is_action_pressed(action):
		Input.action_press(action, strength)
	elif strength <= 0.0 and Input.is_action_pressed(action):
		Input.action_release(action)


func _draw() -> void:
	# 底座：半透明圆环，视觉上不抢戏。
	draw_circle(_base_center, base_radius, Color(1, 1, 1, 0.10))
	draw_arc(_base_center, base_radius, 0, TAU, 48, Color(1, 1, 1, 0.35), 2.0, true)
	# 摇杆帽。
	draw_circle(_knob_pos, knob_radius, Color(1, 1, 1, 0.55))
	draw_arc(_knob_pos, knob_radius, 0, TAU, 32, Color(1, 1, 1, 0.8), 1.5, true)
