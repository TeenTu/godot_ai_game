class_name GameKitFsm
extends Node
## 通用层级状态机（Finite State Machine）。
##
## 用法：
##   1. 场景里放一个本节点（GameKitFsm），下面挂若干个 GameKitFsmState 子节点。
##   2. 设 start_state 指定初始状态；不设则默认用第一个子状态。
##   3. 每个子状态 override enter/exit/update/handle_input，需要切换时
##      emit finished.emit("state_name") 或调用 transition_to()。
##   4. 状态机 active 时会把 _physics_process 与 _unhandled_input 委托给当前状态。
##
## 设计来源：godot-demo-projects/2d/finite_state_machine（state_machine.gd），
## 改造为 game_kit 命名（GameKitFsm / GameKitFsmState），接口保持一致。

signal state_changed(current_state: Node)

## 初始状态（相对本节点的 NodePath）；留空则用第一个子状态。
@export var start_state: NodePath

var states_map: Dictionary = {}
var states_stack: Array = []
var current_state: Node = null
var _active: bool = false


func register_state(state: GameKitFsmState) -> void:
	states_map[state.name] = state
	if not state.finished.is_connected(Callable(self, "_change_state")):
		state.finished.connect(_change_state)
	if not _active and current_state == null:
		# 第一个注册的状态作为默认初始态。
		_initialize(state)


func _initialize(initial_state: Node) -> void:
	_active = true
	set_physics_process(true)
	set_process_input(true)
	states_stack.push_front(initial_state)
	current_state = states_stack[0]
	current_state.enter()
	state_changed.emit(current_state)


func set_active(value: bool) -> void:
	_active = value
	set_physics_process(value)
	set_process_input(value)
	if not _active:
		states_stack = []
		current_state = null


func _unhandled_input(input_event: InputEvent) -> void:
	if _active and current_state != null:
		current_state.handle_input(input_event)


func _physics_process(delta: float) -> void:
	if _active and current_state != null:
		current_state.update(delta)


func _change_state(state_name: String) -> void:
	if not _active or current_state == null:
		return
	current_state.exit()

	if state_name == "previous":
		states_stack.pop_front()
	elif states_map.has(state_name):
		states_stack[0] = states_map[state_name]
	else:
		push_warning("GameKitFsm: unknown state '%s'" % state_name)
		return

	current_state = states_stack[0]
	current_state.enter()
	state_changed.emit(current_state)
