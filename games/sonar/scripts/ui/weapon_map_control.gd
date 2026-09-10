class_name WeaponMapControl
extends Control
## weapon_map_control.gd — S1-11 Batch 4c/5：地图侧武器交互总控（从 main_ui 拆出）。
##
## 职责（§4.1–§4.5 / §6）：
##   - 发射前地图航线绘制（唯一发射方式 MAP_ROUTE）与「发射」触发；
##   - 在水鱼雷地图选择浮动栏（[TKxx][状态][主动][重画航线][深度][居中]）；
##   - 右键地图命令：向此处航行 / 继续添加航路点 / 在此处开启主动声呐 /
##     清除剩余航线；
##   - 主动开机标记（沿航线累计距离，随新航线重算）；
##   - 所有命令遵守导线/终局门控，拒绝时回传中文原因（绝不静默失败）。
##
## 信息边界：只持世界坐标与己方武器自身状态，绝不含 target_id / Truth。

signal status(msg: String)
signal route_state_changed

var ui = null  # SonarUI（读 selected_track_id / world / fire_exec / programmer）
var chart: ChartView = null
var world: World = null
var fire_exec: FireExecutor = null

var route_overlay: MapRouteOverlay = null
var bar: TorpedoControlBar = null

var selected_torpedo_id: String = ""
## 发射前航线上的开机点累计距离（m；<0 = 无）。
var prelaunch_trigger_offset_m: float = -1.0
## 在水重画时被编辑的鱼雷 id（空 = 正在画发射航线）。
var _reroute_tid: String = ""
var _reroute_base_distance_m: float = 0.0
var _reroute_prev_points: Array = []


func setup(p_ui, p_world: World, p_chart: ChartView, p_fire_exec: FireExecutor) -> void:
	ui = p_ui
	if p_world != null:
		world = p_world
	if p_chart != null:
		chart = p_chart
	if p_fire_exec != null:
		fire_exec = p_fire_exec
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if route_overlay != null:
		return
	route_overlay = MapRouteOverlay.new()
	route_overlay.chart = chart
	route_overlay.route_changed.connect(_on_route_changed)
	route_overlay.route_committed.connect(_on_route_committed)
	route_overlay.trigger_changed.connect(_on_trigger_changed)
	add_child(route_overlay)
	bar = TorpedoControlBar.new()
	bar.visible = false
	bar.active_toggled.connect(_on_bar_active)
	bar.reroute_requested.connect(_on_bar_reroute)
	bar.depth_policy_changed.connect(_on_bar_depth)
	bar.center_requested.connect(_on_bar_center)
	add_child(bar)


# ---------------------------------------------------------------- 发射航线
func begin_draw() -> void:
	if world == null:
		return
	if not world.is_mission_running():
		status.emit(UiText.reject("MISSION_ENDED"))
		return
	var own: RefCounted = world.world["own"]
	_reroute_tid = ""
	route_overlay.trigger_offset_m = -1.0
	route_overlay.begin(float(own.position_east_m), float(own.position_north_m), false)
	prelaunch_trigger_offset_m = -1.0
	status.emit(UiText.t("btn_route_draw"))
	route_state_changed.emit()


func cancel_draw() -> void:
	_reroute_tid = ""
	prelaunch_trigger_offset_m = -1.0
	if route_overlay != null:
		route_overlay.cancel()
	status.emit(UiText.t("evt_route_cleared"))
	route_state_changed.emit()


func undo_point() -> void:
	if route_overlay != null and route_overlay.undo_last():
		route_state_changed.emit()


func is_drawing() -> bool:
	return route_overlay != null and route_overlay.active


func is_route_ready() -> bool:
	return route_overlay != null and route_overlay.can_commit()


func route_snapshot() -> Array:
	return route_overlay.route_snapshot() if route_overlay != null else []


## §4.1：地图浮动栏「发射」——无有效航线时禁用并给中文原因。
func try_fire() -> Dictionary:
	if world == null or world.weapons == null or fire_exec == null:
		return {"ok": false, "reason": "NO_WEAPONS"}
	if not is_route_ready():
		status.emit(UiText.t("evt_fire_reject") + "：" + UiText.t("evt_route_needed"))
		return {"ok": false, "reason": "NO_ROUTE"}
	var prog: LaunchProgrammer = fire_exec.programmer
	if prog != null:
		prog.route_points = route_snapshot()
		prog.active_enable_mode = (
			WeaponProgram.ActiveEnableMode.DISTANCE if prelaunch_trigger_offset_m >= 0.0 else -1
		)
		if prelaunch_trigger_offset_m >= 0.0:
			prog.active_enable_value = prelaunch_trigger_offset_m
	var res: Dictionary = fire_exec.execute(world.weapons, world, "MAP_ROUTE", ui.selected_track_id)
	if not bool(res.get("ok", false)):
		status.emit(UiText.t("evt_fire_reject") + "：" + UiText.reject(str(res.get("reason", "?"))))
		return res
	var tp: Torpedo = res["tp"]
	if tp == null:
		status.emit(UiText.t("evt_fire_reject") + " — 无已装管或参数非法")
		return res
	status.emit("%s（%s / 地图航线）" % [UiText.t("evt_torpedo_away"), tp.torpedo_id])
	route_overlay.cancel()
	prelaunch_trigger_offset_m = -1.0
	route_state_changed.emit()
	return res


## 结束绘制（双击 / Enter / 右键「完成航线」）：
##   - 在线重画 → 原子提交新剩余航路；
##   - 发射航线 → 冻结当前航路，等待「发射」。
func finish_draw() -> void:
	if _reroute_tid != "":
		commit_reroute()
		return
	if route_overlay != null and route_overlay.active and route_overlay.can_commit():
		route_overlay.commit()
		status.emit(UiText.t("evt_route_committed"))


func _on_route_committed(_pts: Array) -> void:
	if _reroute_tid != "":
		commit_reroute()


# ---------------------------------------------------------------- 在水鱼雷
func set_selected_torpedo(tid: String) -> void:
	selected_torpedo_id = tid
	if bar != null:
		bar.visible = tid != "" and world != null and _torpedo(tid) != null
	if tid == "" and _reroute_tid != "":
		cancel_reroute()


func _torpedo(tid: String) -> Torpedo:
	if world == null or world.weapons == null or tid == "":
		return null
	for tp in world.weapons.torpedoes:
		if str(tp.torpedo_id) == tid:
			return tp
	return null


## §4.4：在线重画剩余航线（导线门控；LOCKED_ATTACK 禁止；LOST_REACQUIRE→TRANSIT）。
func begin_reroute(tid: String) -> bool:
	var tp: Torpedo = _torpedo(tid)
	if tp == null:
		status.emit(UiText.t("wire_cut_reject") + UiText.reject("INVALID STATE"))
		return false
	if not tp.wire_link.accepts_commands() or not tp._wire_accepts_command():
		status.emit(UiText.t("reroute_reject") + UiText.wire(tp.wire_state_name()))
		return false
	if tp.mission_state == Torpedo.MissionState.LOCKED_ATTACK:
		status.emit(UiText.t("reroute_reject") + UiText.t("reroute_locked"))
		return false
	_prepare_reroute(tp)
	return true


func _prepare_reroute(tp: Torpedo) -> void:
	_reroute_tid = str(tp.torpedo_id)
	_reroute_base_distance_m = float(tp.traveled_m)
	_reroute_prev_points = tp.remaining_route_points()
	route_overlay.begin(float(tp.pos_east_m), float(tp.pos_north_m), true)
	if tp.has_active_trigger_point():
		route_overlay.set_trigger_offset(
			maxf(tp.active_trigger_distance_m - _reroute_base_distance_m, 0.0)
		)
	status.emit(UiText.t("reroute_hint") + str(tp.torpedo_id))
	route_state_changed.emit()


func cancel_reroute() -> void:
	if _reroute_tid == "":
		return
	var tp: Torpedo = _torpedo(_reroute_tid)
	if tp != null:
		route_overlay.set_route_preview(
			_reroute_prev_points if not _reroute_prev_points.is_empty() else []
		)
	route_overlay.cancel()
	_reroute_tid = ""
	status.emit(UiText.t("reroute_cancelled"))
	route_state_changed.emit()


## 提交在线重画（原子替换剩余航路）。
func commit_reroute() -> bool:
	var tp: Torpedo = _torpedo(_reroute_tid)
	if tp == null or not route_overlay.can_commit():
		cancel_reroute()
		return false
	var pts: Array = route_overlay.route_snapshot()
	var future: Array = pts.slice(1)
	var state := TorpedoRouteState.new()
	var pos := Vector2(float(tp.pos_east_m), float(tp.pos_north_m))
	if not state.replace_from(pos, future):
		status.emit(UiText.t("reroute_reject") + UiText.t("reroute_invalid"))
		cancel_reroute()
		return false
	if not tp.update_route(state):
		status.emit(UiText.t("reroute_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))
		cancel_reroute()
		return false
	if route_overlay.has_trigger():
		tp.command_active_trigger_distance(
			_reroute_base_distance_m + route_overlay.trigger_offset_m
		)
	status.emit(UiText.t("reroute_done") + str(tp.torpedo_id))
	route_overlay.cancel()
	_reroute_tid = ""
	route_state_changed.emit()
	return true


# ---------------------------------------------------------------- 右键地图命令
func map_goto_point(world_pos: Vector2) -> void:
	var tp: Torpedo = _torpedo(selected_torpedo_id)
	if tp == null:
		return
	if not tp.wire_link.accepts_commands() or not tp._wire_accepts_command():
		status.emit(UiText.t("map_cmd_reject") + UiText.wire(tp.wire_state_name()))
		return
	if tp.mission_state == Torpedo.MissionState.LOCKED_ATTACK:
		status.emit(UiText.t("map_cmd_reject") + UiText.t("reroute_locked"))
		return
	var state := TorpedoRouteState.new()
	if not state.replace_from(Vector2(float(tp.pos_east_m), float(tp.pos_north_m)), [world_pos]):
		status.emit(UiText.t("map_cmd_reject") + UiText.t("reroute_invalid"))
		return
	if tp.update_route(state):
		status.emit(UiText.t("map_goto_done") % [str(tp.torpedo_id)])
	else:
		status.emit(UiText.t("map_cmd_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))


func map_append_waypoint(world_pos: Vector2) -> void:
	var tp: Torpedo = _torpedo(selected_torpedo_id)
	if tp == null:
		return
	if not tp.wire_link.accepts_commands() or not tp._wire_accepts_command():
		status.emit(UiText.t("map_cmd_reject") + UiText.wire(tp.wire_state_name()))
		return
	if tp.mission_state == Torpedo.MissionState.LOCKED_ATTACK:
		status.emit(UiText.t("map_cmd_reject") + UiText.t("reroute_locked"))
		return
	var future: Array = tp.remaining_route_points()
	if future.size() >= TorpedoRouteState.MAX_FUTURE_POINTS + 1:
		status.emit(UiText.t("map_cmd_reject") + UiText.t("route_full"))
		return
	future.append(world_pos)
	var state := TorpedoRouteState.new()
	if state.replace_from(Vector2(float(tp.pos_east_m), float(tp.pos_north_m)), future):
		if tp.update_route(state):
			status.emit(UiText.t("map_waypoint_done") % [str(tp.torpedo_id)])
			return
	status.emit(UiText.t("map_cmd_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))


func map_active_at(world_pos: Vector2) -> void:
	var tp: Torpedo = _torpedo(selected_torpedo_id)
	if tp == null:
		return
	if not tp.wire_link.accepts_commands() or not tp._wire_accepts_command():
		status.emit(UiText.t("map_cmd_reject") + UiText.wire(tp.wire_state_name()))
		return
	var dist: float = tp.remaining_route_distance_to(world_pos)
	var abs_dist: float = float(tp.traveled_m) + dist
	if tp.command_active_trigger_distance(abs_dist):
		status.emit(UiText.t("map_active_at_done") % [str(tp.torpedo_id), _fmt_m(abs_dist)])
	else:
		status.emit(UiText.t("map_cmd_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))


func map_clear_remaining_route() -> void:
	var tp: Torpedo = _torpedo(selected_torpedo_id)
	if tp == null:
		return
	if not tp.wire_link.accepts_commands() or not tp._wire_accepts_command():
		status.emit(UiText.t("map_cmd_reject") + UiText.wire(tp.wire_state_name()))
		return
	if tp.clear_route():
		status.emit(UiText.t("map_route_cleared") % [str(tp.torpedo_id)])
	else:
		status.emit(UiText.t("map_cmd_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))


func toggle_active(tid: String) -> void:
	var tp: Torpedo = _torpedo(tid)
	if tp == null:
		return
	_apply_active(tid, tp, int(tp.active_tx_state) == Torpedo.ActiveTxState.OFF)


func _apply_active(tid: String, tp: Torpedo, on: bool) -> void:
	if tp.set_active_tx(on):
		status.emit(UiText.t("map_active_done") % [tid, UiText.t("on") if on else UiText.t("off")])
	else:
		status.emit(UiText.t("map_cmd_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))


func center(tid: String) -> void:
	var tp: Torpedo = _torpedo(tid)
	if tp == null or chart == null:
		return
	chart.cam_center = Vector2(float(tp.pos_east_m), float(tp.pos_north_m))
	chart.queue_redraw()


func set_depth_policy(tid: String, policy: String) -> void:
	var tp: Torpedo = _torpedo(tid)
	if tp == null:
		return
	if tp.command_depth_policy(policy):
		status.emit(UiText.t("map_depth_done") % [tid, UiText.depth_policy(policy)])
	else:
		status.emit(UiText.t("map_cmd_reject") + UiText.reject(str(tp.last_cmd_reject_reason)))


# ---------------------------------------------------------------- 每帧刷新
func refresh() -> void:
	if bar == null or chart == null:
		return
	_sync_selection()
	if not bar.visible:
		return
	var tp: Torpedo = _torpedo(selected_torpedo_id)
	if tp == null:
		bar.visible = false
		return
	var connected: bool = tp.wire_link.accepts_commands() and tp._wire_accepts_command()
	var reject: String = ""
	if not connected:
		reject = UiText.t("wire_cmd_disabled") % UiText.wire(tp.wire_state_name())
	elif tp.mission_state == Torpedo.MissionState.LOCKED_ATTACK:
		reject = UiText.t("reroute_locked")
	bar.depth_policy = tp.depth_policy()
	bar.refresh(
		str(tp.torpedo_id),
		UiText.tp_state(tp.mission_state_name()),
		int(tp.active_tx_state) != Torpedo.ActiveTxState.OFF,
		connected,
		reject
	)
	var head: Vector2 = chart.world_to_screen(Vector2(float(tp.pos_east_m), float(tp.pos_north_m)))
	# AT-43：用内容最小尺寸（而非可能滞后一帧的 size）钳制，保证浮动栏
	# 始终留在海图内、绝不压到右栏告警条。
	var bsz: Vector2 = bar.get_combined_minimum_size()
	bar.size = bsz
	bar.position = Vector2(
		clampf(head.x + 14.0, 4.0, maxf(chart.size.x - bsz.x - 4.0, 4.0)),
		clampf(head.y - bsz.y - 12.0, 4.0, maxf(chart.size.y - bsz.y - 4.0, 4.0))
	)


## 选中 id 与武器集合对齐（鱼雷消失时清选择）。
func _sync_selection() -> void:
	if selected_torpedo_id == "":
		return
	if _torpedo(selected_torpedo_id) == null:
		selected_torpedo_id = ""
		bar.visible = false
		if chart != null:
			chart.selected_torpedo_id = ""


# ---------------------------------------------------------------- 内部信号
func _on_route_changed() -> void:
	route_state_changed.emit()


func _on_trigger_changed(offset_m: float) -> void:
	if _reroute_tid == "":
		prelaunch_trigger_offset_m = offset_m
	route_state_changed.emit()


func _on_bar_active(on: bool) -> void:
	var tp: Torpedo = _torpedo(selected_torpedo_id)
	if tp == null:
		return
	_apply_active(selected_torpedo_id, tp, on)


func _on_bar_reroute() -> void:
	begin_reroute(selected_torpedo_id)


func _on_bar_depth(policy: String) -> void:
	set_depth_policy(selected_torpedo_id, policy)


func _on_bar_center() -> void:
	center(selected_torpedo_id)


func _fmt_m(m: float) -> String:
	return "%.0f 米" % m
