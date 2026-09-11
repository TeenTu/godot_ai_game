class_name OwnCommandGate
extends RefCounted
## own_command_gate.gd — UI-04：统一命令仲裁（图形 / 数字 / 快捷键同一入口）。
##
## 单一入口：罗盘外圈（UI-02）与深度条（UI-03）的提交信号只走 OwnManeuverPanel
## 的 command_course() / command_depth()——与数字框、±/转向按钮、层带预设是**同一个**
## 入口，任务终局门与范围钳制都在那一处，图形与数字因此天然双向同步（T25）。
##
## 预览生命周期统一：切页 / 暂停 / 终局 → cancel_previews()。取消预览**不写命令**、
## 不残留拖动状态；终局还通过 interactive=false 让两个控件拒绝启动新拖动（T26）。
##
## 本类只做仲裁与数据回灌，不持有世界状态、不写任何命令值。

var panel: OwnManeuverPanel = null
var bearing: BearingDisplay = null
var depth_bar: DepthBandDisplay = null
var pager: RightSidebarPager = null
var world: World = null

var _cancel_reason: String = ""


## 装配：接线两个图形控件 + 分页器切页清理。world 可为 null（装配期先接线）。
func install(
	w: World, p: OwnManeuverPanel, b: BearingDisplay, d: DepthBandDisplay, pg: RightSidebarPager
) -> void:
	world = w
	panel = p
	bearing = b
	depth_bar = d
	pager = pg
	if b != null:
		b.course_commanded.connect(_on_course_commanded)
		b.tooltip_text = UiText.t("own_graphic_hint")
	if d != null:
		d.depth_commanded.connect(_on_depth_commanded)
		d.tooltip_text = UiText.t("own_graphic_hint")
	if pg != null:
		pg.page_switched.connect(_on_page_switched)


## 取消未提交预览（不写命令）；reason 仅用于审计/测试断言。
func cancel_previews(reason: String = "") -> void:
	_cancel_reason = reason
	if bearing != null:
		bearing.cancel_preview()
	if depth_bar != null:
		depth_bar.cancel_preview()


func cancel_reason() -> String:
	return _cancel_reason


func preview_active() -> bool:
	var b: bool = bearing != null and bearing.preview_active()
	var d: bool = depth_bar != null and depth_bar.preview_active()
	return b or d


## 每帧：本艇实际/命令/最大转向率 → 罗盘；并按任务状态开关图形操纵。
func sync() -> void:
	if world == null:
		return
	var own: TruthEntity = world.world.get("own", null)
	if own == null:
		return
	var running: bool = world.is_mission_running()
	_sync_bearing(own, running)
	if depth_bar != null:
		depth_bar.interactive = running
		if not running:
			depth_bar.cancel_preview()  # 终局清理（无预览时为空操作）


func _sync_bearing(own: TruthEntity, running: bool) -> void:
	if bearing == null:
		return
	var rate: float = maxf(own.turn_rate_deg_s, TruthEntity.DEFAULT_TURN_RATE_DEG_S)
	bearing.interactive = running
	bearing.turn_rate_deg_s = rate
	if own.has_course_command():
		bearing.cmd_course_deg = float(own.commanded_course_deg)
		bearing.cmd_eta_s = (
			absf(NavUtils.wrap180(own.commanded_course_deg - own.course_deg)) / rate
		)
	else:
		bearing.cmd_course_deg = -1.0
		bearing.cmd_eta_s = -1.0
	if not running:
		bearing.cancel_preview()
	bearing.queue_redraw()


func _on_course_commanded(deg: float) -> void:
	if panel != null:
		panel.command_course(deg)


func _on_depth_commanded(z: float) -> void:
	if panel != null:
		panel.command_depth(z)


func _on_page_switched(_page_id: String) -> void:
	cancel_previews("page")
