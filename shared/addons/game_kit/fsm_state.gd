class_name GameKitFsmState
extends Node
## 状态机的一个状态节点。挂到 GameKitFsm 的 children 下即被注册。
##
## 子类 override 这些虚函数：
##   enter() / exit()          进入与离开状态
##   update(delta)             每物理帧（需状态机 active）
##   handle_input(event)       未处理输入
##   _on_animation_finished()  动画结束回调
##
## 想切到别的状态，直接 emit finished.emit(state_name)；传 "previous" 回退到上一个。
## 设计来源：godot-demo-projects/2d/finite_state_machine（state.gd）。

signal finished(next_state_name: String)

var state_machine: GameKitFsm = null


func _ready() -> void:
	# 延迟到父节点树就绪后再注册到状态机，确保兄弟节点都已挂好。
	call_deferred("_register")


func _register() -> void:
	var sm := get_parent()
	if sm is GameKitFsm:
		state_machine = sm
		sm.register_state(self)


func enter() -> void:
	pass


func exit() -> void:
	pass


func update(_delta: float) -> void:
	pass


func handle_input(_event: InputEvent) -> void:
	pass


func _on_animation_finished(_anim_name: String) -> void:
	pass


## 便捷切换：等价于 emit finished.emit(state_name)。
func transition_to(state_name: String) -> void:
	finished.emit(state_name)
