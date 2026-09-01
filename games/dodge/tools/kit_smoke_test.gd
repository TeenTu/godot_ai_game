extends SceneTree
## game_kit 共享套件冒烟测试（headless 可跑）。
##
## 覆盖新增/核心组件：
##   1. GameKitTouchButton 实例化 + 信号
##   2. GameKitFsm 状态注册与切换
##   3. GameKitVirtualJoystick 三种模式（FIXED/DYNAMIC/FOLLOWING）的认领与输出
##
## 说明：headless 无窗口时 Input.parse_input_event 不把 ScreenTouch 分发给节点的
## _input，故这里直接调用节点的 _input(event) 模拟事件分发（逻辑等价、环境无关）。
## 注意：SceneTree 脚本里信号回调用实例方法（成员变量计数），lambda 闭包计数会失效。

var _btn_pressed := 0
var _btn_released := 0


func _on_btn_pressed() -> void:
	_btn_pressed += 1


func _on_btn_released() -> void:
	_btn_released += 1


func _initialize() -> void:
	var root: Window = get_root()
	var all_ok := true

	# ---- 1. TouchButton ----
	var btn := GameKitTouchButton.new()
	btn.name = "Btn"
	btn.radius = 40.0
	btn.size = Vector2(80, 80)
	btn.position = Vector2(100, 100)
	root.add_child(btn)
	btn.pressed.connect(_on_btn_pressed)
	btn.released.connect(_on_btn_released)
	await process_frame
	_send_touch(btn, 0, true, Vector2(140, 140))
	await process_frame
	_send_touch(btn, 0, false, Vector2(140, 140))
	await process_frame
	var btn_ok: bool = _btn_pressed == 1 and _btn_released == 1
	print(
		"KIT touch_button ok=",
		btn_ok,
		" (pressed=",
		_btn_pressed,
		", released=",
		_btn_released,
		")"
	)
	all_ok = all_ok and btn_ok

	# ---- 2. Fsm ----
	var fsm := GameKitFsm.new()
	fsm.name = "Fsm"
	root.add_child(fsm)
	var idle := GameKitFsmState.new()
	idle.name = "idle"
	fsm.add_child(idle)
	var run := GameKitFsmState.new()
	run.name = "run"
	fsm.add_child(run)
	await process_frame
	await process_frame
	var fsm_ok: bool = fsm.current_state == idle
	idle.transition_to("run")
	await process_frame
	fsm_ok = fsm_ok and fsm.current_state == run
	print("KIT fsm ok=", fsm_ok, " (initial=", fsm.current_state.name, ")")
	all_ok = all_ok and fsm_ok

	# ---- 3. VirtualJoystick 三种模式 ----
	var modes: Array[GameKitVirtualJoystick.Mode] = [
		GameKitVirtualJoystick.Mode.FIXED,
		GameKitVirtualJoystick.Mode.DYNAMIC,
		GameKitVirtualJoystick.Mode.FOLLOWING,
	]
	for i in modes.size():
		var mode: GameKitVirtualJoystick.Mode = modes[i]
		var j := GameKitVirtualJoystick.new()
		j.name = "Joy%d" % i
		j.mode = mode
		j.base_radius = 80.0
		j.follow_slack = 60.0
		j.size = Vector2(200, 200)
		j.position = Vector2(300.0, 100.0 + i * 250.0)
		root.add_child(j)
		await process_frame
		# 在摇杆中心触点（DYNAMIC/FOLLOWING 认领附近点）。
		var center := j.position + j.size * 0.5
		_send_touch(j, 0, true, center)
		await process_frame
		var claimed: bool = j.is_pressed
		_send_touch(j, 0, false, center)
		await process_frame
		var released: bool = not j.is_pressed
		print("KIT joystick mode=", mode, " claim=", claimed, " release=", released)
		all_ok = all_ok and claimed and released

	print("KIT smoke result=" + ("PASS" if all_ok else "FAIL"))
	quit(0 if all_ok else 1)


## 构造触摸事件并直接喂给节点的 _input（headless 兼容模拟）。
func _send_touch(node: Node, index: int, pressed: bool, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = pos
	node.call("_input", ev)
