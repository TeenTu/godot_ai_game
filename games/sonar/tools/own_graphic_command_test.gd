extends SceneTree
## own_graphic_command_test.gd — P1-B UI-02/03/04：图形操纵与统一命令仲裁（T23..T26）。
##
## 运行：godot --headless --path games/sonar --script res://tools/own_graphic_command_test.gd
## 必须输出 "OWN_GRAPHIC_COMMAND_TEST result=PASS"。
##
## T23 罗盘：四象限（上=北 0°、右=东 90°、下=南 180°、左=西 270°）、359°→1° 跨 0°、
##     中心死区不参与操纵、拖动期不改实际 course、拖出控件后释放仍提交一次、
##     Esc/右键取消不写命令、不夺接触选择；
## T24 深度条：顶部/底部/温跃层/上下层带映射与场景海底深度一致、按艇体与场景限制
##     钳制、实际深度受垂速限制、预览与命令/实际三态分离；
## T25 数字框：内部 LineEdit 持焦时不被 sync 覆盖（Control.has_focus() 判不出来）、
##     图形与数字双向同步；
## T26 终局：罗盘/深度条/面板/地图投放全部拒绝新命令。
##
## 输入驱动分两层：widget 数学用直接 _gui_input（确定性），另有一条真实事件链用例
## 走 root.push_input(ev, true)（拖动出控件 + 释放；Viewport mouse_focus 捕获）——
## 只调内部函数抓不到"事件链断掉"那类 bug。
## **in_local_coords 必须为 true**：headless 根视口带 content-scale，按屏幕坐标投递
## 会被再变换一次，点击落到视口外（一个控件都收不到 = 假绿）。与
## chart_context_menu_test 同一约定。
## headless --script 不自动调 _process：显式 ui._process()；布局需 await 帧。

const EPS: float = 0.5


func _init() -> void:
	await _run()


func _run() -> void:
	var fails: Array = []
	var ui: Control = await _mk_ui()
	_t23_compass_quadrants(fails, ui)
	_t23_compass_wrap_and_deadzone(fails, ui)
	await _t23_compass_drag_contracts(fails, ui)
	_t24_depth_mapping(fails, ui)
	await _t24_depth_commit_and_vz(fails, ui)
	await _t24_preview_lifecycle(fails, ui)
	await _t25_number_input(fails, ui)
	await _t26_after_end(fails, ui)  # 终局不可逆 → 放最后
	ui.queue_free()
	await process_frame
	_finish(fails)


func _mk_ui(w: int = 1280, h: int = 720) -> Control:
	root.size = Vector2i(w, h)
	await process_frame
	await process_frame
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	ui._process(0.01)
	await process_frame
	return ui


# ==================================================================== T23 罗盘
## 上=北(0°) / 右=东(90°) / 下=南(180°) / 左=西(270°)：屏幕语义，不引用实现公式。
func _t23_compass_quadrants(fails: Array, ui: Control) -> void:
	var b: BearingDisplay = ui._bearing
	var own: TruthEntity = ui.world.world["own"]
	var c: Vector2 = b.size * 0.5
	var d: float = 40.0
	var cases: Array = [
		[Vector2(0, -d), 0.0, "up=N"],
		[Vector2(d, 0), 90.0, "right=E"],
		[Vector2(0, d), 180.0, "down=S"],
		[Vector2(-d, 0), 270.0, "left=W"],
	]
	for cfg in cases:
		var before: float = float(own.commanded_course_deg)
		_press(b, c + (cfg[0] as Vector2))
		_release(b, c + (cfg[0] as Vector2))
		_assert_close(
			fails, "T23 quadrant %s" % cfg[2], float(own.commanded_course_deg), float(cfg[1]), EPS
		)
		_assert_bool(
			fails,
			"T23 quadrant %s changed cmd" % cfg[2],
			float(own.commanded_course_deg) != before or before < 0.0,
			true
		)
	# 拖动不改实际 course（只有命令变；实际由转向率逼近）。
	_assert_close(fails, "T23 drag keeps actual course", float(own.course_deg), 0.0, EPS)
	# 不夺接触选择：环带按下不改变当前选中接触。
	ui.selected_track_id = ""
	_press(b, c + Vector2(0, -d))
	_release(b, c + Vector2(0, -d))
	_assert_bool(fails, "T23 ring press keeps selection", ui.selected_track_id == "", true)


## 359°→1° 跨 0° + 中心死区（死区内按下/拖动都不产生命令、不产生预览）。
func _t23_compass_wrap_and_deadzone(fails: Array, ui: Control) -> void:
	var b: BearingDisplay = ui._bearing
	var own: TruthEntity = ui.world.world["own"]
	var c: Vector2 = b.size * 0.5
	var d: float = 40.0
	for deg in [359.0, 1.0, 180.0]:
		var dir: Vector2 = Vector2(sin(deg_to_rad(deg)), -cos(deg_to_rad(deg))) * d
		_press(b, c + dir)
		_release(b, c + dir)
		_assert_close(fails, "T23 wrap %.0f°" % deg, float(own.commanded_course_deg), deg, EPS)
	# 死区内按下：既不预览也不提交。
	_press(b, c)
	_assert_bool(fails, "T23 deadzone no preview", b.preview_active(), false)
	_release(b, c)
	_assert_bool(
		fails,
		"T23 deadzone no command",
		is_equal_approx(float(own.commanded_course_deg), 180.0),
		true
	)
	# 拖动经过死区：保持上一个角度（不乱跳），释放仍按最后有效角度提交。
	_press(b, c + Vector2(d, 0))
	_move(b, c)  # 进入死区 → 角度不更新
	_move(b, c + Vector2(0, -d))  # 回到环带北向
	_release(b, c)
	_assert_close(fails, "T23 drag through deadzone", float(own.commanded_course_deg), 0.0, EPS)


## 真实事件链：press 在控件内 → 拖出控件（仍在窗口内）→ 释放，必须提交一次。
## 另外验证 Esc/右键取消不写命令，且纯取消不产生命令（与"预览"状态分离）。
func _t23_compass_drag_contracts(fails: Array, ui: Control) -> void:
	var b: BearingDisplay = ui._bearing
	var own: TruthEntity = ui.world.world["own"]
	var c: Vector2 = b.size * 0.5
	var d: float = 40.0
	# --- 真实链（root.push_input）：按下 → 拖到海图上（控件外）→ 释放 ---
	var global_c: Vector2 = b.global_position + c
	var inside: Vector2 = global_c + Vector2(d, 0)
	var outside: Vector2 = global_c + Vector2(d + 260.0, 0)  # 明显在罗盘外
	_push_button(inside, true)
	_assert_bool(fails, "T23 chain preview started", b.preview_active(), true)
	_push_motion(outside)
	_push_button(outside, false)
	_assert_bool(fails, "T23 chain released outside", b.preview_active(), false)
	_assert_close(
		fails, "T23 chain committed outside release", float(own.commanded_course_deg), 90.0, EPS
	)
	# --- Esc 取消：预览清掉、命令不写 ---
	var keep: float = float(own.commanded_course_deg)
	_press(b, c + Vector2(0, -d))
	_assert_bool(fails, "T23 esc preview active", b.preview_active(), true)
	_push_key(ui, KEY_ESCAPE)
	_assert_bool(fails, "T23 esc clears preview", b.preview_active(), false)
	_assert_close(fails, "T23 esc writes nothing", float(own.commanded_course_deg), keep, EPS)
	_release(b, c + Vector2(0, -d))
	_assert_close(fails, "T23 esc cleared release", float(own.commanded_course_deg), keep, EPS)
	# --- 无预览时不吃 Esc（不能顺带挡住地图/航线层的 Esc）---
	_push_key(ui, KEY_ESCAPE)
	_assert_bool(fails, "T23 idle esc not consumed", root.is_input_handled(), false)
	# --- 右键取消 ---
	_press(b, c + Vector2(0, -d))
	_right_click(b, c + Vector2(0, -d))
	_assert_bool(fails, "T23 right cancels preview", b.preview_active(), false)
	_assert_close(fails, "T23 right writes nothing", float(own.commanded_course_deg), keep, EPS)
	await process_frame


# ==================================================================== T24 深度条
## 刻度映射：顶部=海面、底部=海底、温跃层带中心=温跃层深度、上下 hold 线。
func _t24_depth_mapping(fails: Array, ui: Control) -> void:
	var bar: DepthBandDisplay = ui._depth_bar
	var info: Dictionary = bar.scale_info()
	var y0: float = float(info["y0"])
	var h: float = float(info["h"])
	_assert_close(fails, "T24 top maps surface", bar.depth_at_y(y0), 0.0, 1.0)
	_assert_close(fails, "T24 bottom maps seabed", bar.depth_at_y(y0 + h), 400.0, 1.0)
	_assert_close(
		fails,
		"T24 thermocline maps",
		bar.depth_at_y(DepthBandDisplay.depth_to_y(info, 120.0)),
		120.0,
		2.0
	)
	_assert_close(
		fails,
		"T24 upper hold maps",
		bar.depth_at_y(DepthBandDisplay.depth_to_y(info, 70.0)),
		70.0,
		2.0
	)
	_assert_close(
		fails,
		"T24 lower hold maps",
		bar.depth_at_y(DepthBandDisplay.depth_to_y(info, 180.0)),
		180.0,
		2.0
	)
	# 不同场景海底（浅海 250 米）：同一条标尺按新海底重映射，并按艇体限制钳制。
	var dm: RefCounted = ui.world.world.get("depth_model", null)
	dm.bottom_depth_m = 250.0
	var info2: Dictionary = bar.scale_info()
	_assert_close(
		fails,
		"T24 other seabed maps",
		bar.depth_at_y(float(info2["y0"]) + float(info2["h"])),
		250.0,
		1.0
	)
	_assert_bool(fails, "T24 seabed clamped by scene", bar.depth_at_y(9999.0) <= 250.0 + EPS, true)


## 提交 → 命令深度；实际深度按垂速逼近（不瞬移）；预览与命令/实际三态分离。
func _t24_depth_commit_and_vz(fails: Array, ui: Control) -> void:
	var bar: DepthBandDisplay = ui._depth_bar
	var panel: OwnManeuverPanel = ui._own_panel
	var own: TruthEntity = ui.world.world["own"]
	var info: Dictionary = bar.scale_info()
	var y_target: float = DepthBandDisplay.depth_to_y(info, 200.0)
	_press(bar, Vector2(20.0, y_target))
	_assert_bool(fails, "T24 preview active", bar.preview_active(), true)
	_assert_close(fails, "T24 preview value", bar.preview_z, 200.0, 3.0)
	# 预览期间不写命令（拖动只预览）。
	_assert_bool(fails, "T24 preview writes nothing", own.has_depth_command(), false)
	_assert_bool(fails, "T24 preview keeps actual", is_equal_approx(float(own.depth_m), 50.0), true)
	_release(bar, Vector2(20.0, y_target))
	_assert_bool(fails, "T24 preview cleared on release", bar.preview_active(), false)
	_assert_close(fails, "T24 commit writes command", float(own.commanded_depth_m), 200.0, 3.0)
	_assert_close(fails, "T24 number box shows command", float(panel._spin_depth.value), 200.0, 3.0)
	# 实际深度受垂速限制：一步之内不可能到 200 米。
	ui.world.run_steps(1)
	var step: float = float(ui.world.world["dt"])
	var max_dz: float = own.max_vertical_speed_m_s * step + 1.0
	_assert_bool(fails, "T24 actual limited by vz", absf(float(own.depth_m) - 50.0) <= max_dz, true)
	ui.world.run_steps(60)
	_assert_bool(
		fails,
		"T24 actual approaches command",
		float(own.depth_m) > 50.0 and float(own.depth_m) <= 200.0 + 1.0,
		true
	)
	# Esc 取消：不写命令、不残留预览。
	var keep: float = float(own.commanded_depth_m)
	_press(bar, Vector2(20.0, DepthBandDisplay.depth_to_y(bar.scale_info(), 320.0)))
	_push_key(ui, KEY_ESCAPE)
	_assert_bool(fails, "T24 esc clears preview", bar.preview_active(), false)
	_release(bar, Vector2(20.0, 100.0))
	_assert_close(fails, "T24 esc writes nothing", float(own.commanded_depth_m), keep, EPS)
	await process_frame


## 预览生命周期（UI-04）：切页 / 暂停按同一规则清掉未提交预览，**不写命令**。
func _t24_preview_lifecycle(fails: Array, ui: Control) -> void:
	var bar: DepthBandDisplay = ui._depth_bar
	var bearing: BearingDisplay = ui._bearing
	var own: TruthEntity = ui.world.world["own"]
	var keep_course: float = float(own.commanded_course_deg)
	var keep_depth: float = float(own.commanded_depth_m)
	var y_target: float = DepthBandDisplay.depth_to_y(bar.scale_info(), 300.0)
	# --- 切页：深度条预览被清掉，释放不提交 ---
	_press(bar, Vector2(20.0, y_target))
	_assert_bool(fails, "T24 switch preview active", bar.preview_active(), true)
	var other: String = "tactics" if ui._pager.current_page() == "sonar" else "sonar"
	ui._pager.select(other)
	_assert_bool(fails, "T24 switch clears preview", bar.preview_active(), false)
	_assert_bool(fails, "T24 switch gate reason", ui._cmd_gate.cancel_reason() == "page", true)
	_release(bar, Vector2(20.0, y_target))
	_assert_close(fails, "T24 switch writes nothing", float(own.commanded_depth_m), keep_depth, EPS)
	# --- 暂停：罗盘预览被清掉，释放不提交；恢复后仍可操作 ---
	var c: Vector2 = bearing.size * 0.5
	_press(bearing, c + Vector2(40.0, 0.0))
	_assert_bool(fails, "T24 pause preview active", bearing.preview_active(), true)
	ui._on_pause()
	_assert_bool(fails, "T24 pause clears preview", bearing.preview_active(), false)
	_assert_bool(fails, "T24 pause gate reason", ui._cmd_gate.cancel_reason() == "pause", true)
	_release(bearing, c + Vector2(40.0, 0.0))
	_assert_close(
		fails, "T24 pause writes nothing", float(own.commanded_course_deg), keep_course, EPS
	)
	ui._on_pause()  # 恢复运行（后续用例照常推进）
	_assert_bool(fails, "T24 pause resumed", ui.world.is_mission_running(), true)
	await process_frame


# ==================================================================== T25 数字框
## 内部 LineEdit 持焦时不得被每帧 sync 覆盖；图形与数字双向同步。
func _t25_number_input(fails: Array, ui: Control) -> void:
	var panel: OwnManeuverPanel = ui._own_panel
	var bearing: BearingDisplay = ui._bearing
	var own: TruthEntity = ui.world.world["own"]
	var spin: SpinBox = panel._spin_course
	var le: LineEdit = spin.get_line_edit()
	le.grab_focus()
	_assert_bool(fails, "T25 line edit holds focus", le.has_focus(), true)
	# 焦点在内部 LineEdit 上时，Control.has_focus() 判不出来（旧实现因此会覆盖输入）。
	_assert_bool(fails, "T25 spin has_focus blind", spin.has_focus(), false)
	spin.set_value_no_signal(123.0)
	own.course_deg = 11.0
	own.commanded_course_deg = 77.0
	panel.sync()
	_assert_close(fails, "T25 focused input not overwritten", float(spin.value), 123.0, EPS)
	le.release_focus()
	panel.sync()
	_assert_close(fails, "T25 unfocused follows command", float(spin.value), 77.0, EPS)
	# 图形 → 数字：罗盘提交后数字框与命令同步。
	var b: BearingDisplay = bearing
	var c: Vector2 = b.size * 0.5
	_press(b, c + Vector2(0, -40.0))
	_release(b, c + Vector2(0, -40.0))
	_assert_close(fails, "T25 graphic writes command", float(own.commanded_course_deg), 0.0, EPS)
	_assert_close(fails, "T25 graphic syncs number", float(spin.value), 0.0, EPS)
	# 数字 → 图形：输入框改值后，仲裁每帧把命令回灌到罗盘虚线。
	spin.value = 45.0  # 真实路径：value_changed → panel.command_course
	ui._cmd_gate.sync()
	_assert_close(fails, "T25 number writes command", float(own.commanded_course_deg), 45.0, EPS)
	_assert_close(fails, "T25 number syncs compass", float(bearing.cmd_course_deg), 45.0, EPS)
	# 清掉命令，避免影响后续用例。
	own.commanded_course_deg = -1.0
	await process_frame


# ==================================================================== T26 终局
## 终局后：罗盘/深度条拒绝启动拖动、面板与地图投放拒绝新命令。
func _t26_after_end(fails: Array, ui: Control) -> void:
	var bearing: BearingDisplay = ui._bearing
	var bar: DepthBandDisplay = ui._depth_bar
	var panel: OwnManeuverPanel = ui._own_panel
	var own: TruthEntity = ui.world.world["own"]
	var c: Vector2 = bearing.size * 0.5
	var keep_course: float = float(own.commanded_course_deg)
	var keep_depth: float = float(own.commanded_depth_m)
	ui.world.end_mission(ui.world.MissionState.PLAYER_DEFEATED, "TEST_END")
	ui._cmd_gate.sync()
	_assert_bool(fails, "T26 mission ended", ui.world.is_mission_running(), false)
	_assert_bool(fails, "T26 compass refuses", bearing.interactive, false)
	_assert_bool(fails, "T26 depth bar refuses", bar.interactive, false)
	# 罗盘：按下不预览、释放不提交
	_press(bearing, c + Vector2(0, -40.0))
	_assert_bool(fails, "T26 compass no preview", bearing.preview_active(), false)
	_release(bearing, c + Vector2(0, -40.0))
	_assert_close(
		fails, "T26 compass no command", float(own.commanded_course_deg), keep_course, EPS
	)
	# 深度条：同上
	var y_target: float = DepthBandDisplay.depth_to_y(bar.scale_info(), 300.0)
	_press(bar, Vector2(20.0, y_target))
	_assert_bool(fails, "T26 depth no preview", bar.preview_active(), false)
	_release(bar, Vector2(20.0, y_target))
	_assert_close(fails, "T26 depth no command", float(own.commanded_depth_m), keep_depth, EPS)
	# 面板（数字/按钮/快捷键共用入口）拒绝
	_assert_bool(fails, "T26 panel course refused", panel.command_course(90.0), false)
	_assert_bool(fails, "T26 panel depth refused", panel.command_depth(120.0), false)
	_assert_bool(fails, "T26 panel speed refused", panel.command_speed(12.0), false)
	# 地图投放（诱饵/干扰器同一 _launch_decoy 门）拒绝
	var prog: DecoyProgram = DecoyProgram.new()
	prog.decoy_type = "MOBILE"
	prog.launch_bearing_deg = 90.0
	prog.commanded_depth_band = "UPPER"
	_assert_bool(fails, "T26 map launch refused", ui.world._launch_decoy(prog), false)
	_assert_bool(
		fails,
		"T26 map launch reason",
		str(ui.world.last_decoy_reject_reason) == "MISSION_ENDED",
		true
	)
	await process_frame


# ==================================================================== 输入构造
func _press(ctrl: Control, pos: Vector2) -> void:
	ctrl._gui_input(_mb(pos, true, MOUSE_BUTTON_LEFT))


func _release(ctrl: Control, pos: Vector2) -> void:
	ctrl._gui_input(_mb(pos, false, MOUSE_BUTTON_LEFT))


func _right_click(ctrl: Control, pos: Vector2) -> void:
	ctrl._gui_input(_mb(pos, true, MOUSE_BUTTON_RIGHT))


func _move(ctrl: Control, pos: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	ctrl._gui_input(mm)


func _mb(pos: Vector2, pressed: bool, button: int) -> InputEventMouseButton:
	var mb := InputEventMouseButton.new()
	mb.button_index = button
	mb.pressed = pressed
	mb.position = pos
	return mb


## 真实事件链（视口本地坐标 = 窗口坐标，main_ui 是 root 的直接子节点）。
## in_local_coords=true：见文件头——否则 headless 的 content-scale 会把点变换到视口外。
func _push_button(local_pos: Vector2, pressed: bool) -> void:
	var mb := _mb(local_pos, pressed, MOUSE_BUTTON_LEFT)
	mb.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(mb, true)


func _push_motion(local_pos: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = local_pos
	mm.global_position = local_pos
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(mm, true)


## 真实键事件：与生产同一条链（GUI 阶段 → input → unhandled_key → unhandled）。
func _push_key(ui: Control, code: int) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	ui.get_viewport().push_input(k, true)


# ==================================================================== 断言
func _assert_bool(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if bool(got) != bool(want):
		fails.append("%s (got=%s want=%s)" % [name, str(got), str(want)])


func _assert_close(fails: Array, name: String, got: float, want: float, eps: float) -> void:
	if absf(got - want) > eps:
		fails.append("%s (got=%.3f want=%.3f±%.3f)" % [name, got, want, eps])


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("OWN_GRAPHIC_COMMAND_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("TEST FAIL: " + str(f))
		print("OWN_GRAPHIC_COMMAND_TEST result=FAIL (%d)" % fails.size())
		quit(1)
