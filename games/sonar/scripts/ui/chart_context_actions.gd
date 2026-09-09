class_name ChartContextActions
extends RefCounted
## chart_context_actions.gd — S109 §9.3 右键菜单动作执行器。
##
## 只做三件事：相机居中、右栏分页跳转/预填、经既有命令门发命令——
## Ping → ActivePingController.request_ping()（UNAVAILABLE/冷却/在途检查）
## → world.issue_ping()（MISSION_ENDED 命令门）；切断导线 → Torpedo
## .cut_wire()（内部门控 + last_cmd_reject_reason）。菜单关闭不改视图与
## 选择；任何动作不绕过终局/联锁。"开始测距尺/查看证据历史"为占位条目
## （S109 未定义交互细则，本批仅提示）。

var _ui = null
var _chart: ChartView = null
var _pager: RightSidebarPager = null
var _menu: ChartContextMenu = null


func setup(ui, chart: ChartView, pager: RightSidebarPager) -> void:
	_ui = ui
	_chart = chart
	_pager = pager
	_menu = ChartContextMenu.new()
	chart.add_child(_menu)
	chart.context_requested.connect(_on_context)
	_menu.action_chosen.connect(_on_action)
	_menu.about_to_popup.connect(func(): chart.context_menu_open = true)
	_menu.popup_hide.connect(func(): chart.context_menu_open = false)


## 测试入口：直接触发一个已确认的动作（跳过菜单点击）。
func run_action(action: String, ctx: Dictionary) -> void:
	_on_action(action, ctx)


func _on_context(ctx: Dictionary) -> void:
	var gp: Vector2 = _chart.get_screen_transform() * (ctx["screen_position"] as Vector2)
	_menu.open_at(gp, ctx)


func _on_action(action: String, ctx: Dictionary) -> void:
	match action:
		"threat_view", "threat_set_active", "threat_evidence":
			_pager.select("tracks")
			_ui._update_status(UiText.t("threat_detail_hint"))
		"threat_center":
			_center_threat(str(ctx.get("hit_id", "")))
		"threat_goto_weapons":
			_pager.select("weapons")
		"threat_ping":
			_ui._on_ping_requested()
		"contact_select":
			_ui._on_contact_selected(str(ctx.get("hit_id", "")))
		"contact_mark_group":
			_ui.mark_flow.active_group_id = str(ctx.get("hit_id", ""))
			_ui._refresh_mark_panel()
			_ui._update_status(str(UiText.t("mark_group_set_to")) + str(ctx.get("hit_id", "")))
		"contact_goto_tma":
			_ui._on_contact_selected(str(ctx.get("hit_id", "")))
			_pager.select("tracks")
		"contact_fit":
			_ui._on_contact_selected(str(ctx.get("hit_id", "")))
			_ui._on_fit_tma()
		"contact_presite":
			_presite_fire(str(ctx.get("hit_id", "")))
		"contact_center":
			_chart.cam_center = ctx["world_position"]
			_chart.queue_redraw()
		"torpedo_select":
			_chart.selected_torpedo_id = str(ctx.get("hit_id", ""))
			_chart.torpedo_selected.emit(_chart.selected_torpedo_id)
			_chart.queue_redraw()
		"torpedo_wire":
			_pager.select("weapons")
		"torpedo_center":
			_center_torpedo(str(ctx.get("hit_id", "")))
		"torpedo_cut":
			_cut_wire(str(ctx.get("hit_id", "")))
		"empty_center":
			_chart.cam_center = ctx["world_position"]
			_chart.queue_redraw()
		"empty_ruler":
			_ui._update_status(UiText.t("ruler_placeholder"))
		"empty_frame":
			_chart.auto_frame()
		"empty_clear":
			_clear_selection()
		"empty_layers":
			_pager.select("own")


func _center_threat(tid: String) -> void:
	for s in _chart.threat_snapshots:
		if str(s.get("track_id", "")) == tid and s.get("draw_center_e_m") != null:
			_chart.cam_center = Vector2(float(s["draw_center_e_m"]), float(s["draw_center_n_m"]))
			_chart.queue_redraw()
			return


func _center_torpedo(tid: String) -> void:
	for tp in _chart.torpedoes:
		if str(tp.get("torpedo_id", "")) != tid:
			continue
		var pts: Array = tp.get("trail", [])
		if not pts.is_empty():
			_chart.cam_center = Vector2(float(pts[-1]["e"]), float(pts[-1]["n"]))
			_chart.queue_redraw()
			return


## §9.2：预填概略射击 = 选择接触 + 以玩家最近测得方位填 Trial + 切武器页。
## 绝不发射（AT-34）；发射仍须玩家在武器页显式操作并过 FireExecutor 联锁。
func _presite_fire(tid: String) -> void:
	_ui._on_contact_selected(tid)
	var t: Track = _ui.tracker.track_by_id(tid)
	var m: Measurement = t.latest_measurement() if t != null else null
	if m == null:
		_ui._update_status(UiText.t("presite_no_bearing"))
		return
	_ui.trial.set_bearing(m.measured_bearing_deg)
	_pager.select("weapons")
	_ui._update_status(str(UiText.t("presite_done")) + "（方位 %.0f°）" % m.measured_bearing_deg)


## §9.2 切断导线…（危险动作；确认流程在 ChartContextMenu 内完成）。
func _cut_wire(tid: String) -> void:
	if _ui.world == null or _ui.world.weapons == null:
		return
	for tp in _ui.world.weapons.torpedoes:
		if str(tp.torpedo_id) != tid:
			continue
		if tp.cut_wire():
			_ui._update_status(str(UiText.t("wire_cut_done")) + " " + tid)
		else:
			_ui._update_status(
				str(UiText.t("wire_cut_reject")) + UiText.reject(str(tp.last_cmd_reject_reason))
			)
		return


func _clear_selection() -> void:
	_ui.selected_track_id = ""
	_ui._refresh_fit_view()
	_ui._dirty = true
	_ui._rebuild_display_data()
	_ui._update_status(UiText.t("selection_cleared"))
