class_name DepthBandDisplay
extends Control
## depth_band_display.gd — 侧边深度条（S1-07 §11.4，Commit 11）+ 深度操纵（UI-03）。
##
## 竖条自上而下：Surface / Upper hold / 温跃层带 / Lower hold / Bottom；
## 显示本艇、己方鱼雷、己方诱饵的实际（实心）与命令（空心）深度标记。
## 敌方深度只有经测量推断后才允许显示——本条绝不读敌方 Truth。
## 双编码（§11.5 上层要求）：形状（■艇 ▲鱼雷 ◆诱饵）+ 文字标签，不只靠颜色。
##
## UI-03 操纵约定：
##   - 纵向标尺点击/拖动 → 预览米数（拖动期在固定信息框里给数值，不遮标尺文字），
##     **松开才提交一次** command_depth()（经 OwnCommandGate → OwnManeuverPanel 统一门）；
##   - 深度 = 刻度上下界与局部 y 反算，再按艇体（min/max_depth_m）与场景（海面/海底）
##     实际限制钳制；
##   - 实际（实心 ■ + "实际"）、命令（空心 ○ + 虚线 + "命令"）、预览（虚线 + ◆ + "预览"）
##     三者分别显示、形状与中文文字同时区分；
##   - 命中区比标尺宽（"太窄时扩大命中区"）：整条左侧栏带（x ≤ 标尺右缘 + 24）都可拖；
##   - 敌方层带提示只是**半透明概率带**，不是可拖目标（拖动只映射到本艇深度刻度）；
##   - 右键 / Esc 取消未提交预览；终局（interactive=false）不启动拖动并清掉预览（T26）。

signal depth_commanded(depth_m: float)

const WIDTH_PX: float = 96.0
const TOP_PAD: float = 4.0
const VALUE_BOX_H: float = 20.0
const HIT_SLACK_X: float = 24.0
const COL_ACTUAL := Color(0.3, 0.8, 1.0)
const COL_PREVIEW := Color(1.0, 0.95, 0.4)

var preview_z: float = -1.0
var interactive: bool = true

var _world: World = null
var _tracker: Tracker = null
var _dragging: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(WIDTH_PX, 200)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP


func bind(w: World, tr: Tracker = null) -> void:
	_world = w
	if tr != null:
		_tracker = tr


func sync() -> void:
	if _world != null:
		queue_redraw()


## 预览是否活动（测试/仲裁用）。
func preview_active() -> bool:
	return preview_z >= 0.0 or _dragging


## 取消未提交预览：不写命令、不残留拖动状态。
func cancel_preview() -> void:
	if not preview_active():
		return
	preview_z = -1.0
	_dragging = false
	queue_redraw()


## 深度刻度（局部坐标映射）：与 _draw 共用，保证拖动的反算与显示一致。
func scale_info() -> Dictionary:
	var dm: RefCounted = null
	if _world != null:
		dm = _world.world.get("depth_model", null)
	var z_min: float = 0.0
	var z_max: float = 400.0
	var therm: float = 120.0
	var therm_half: float = 10.0
	var upper_hold: float = 70.0
	var lower_hold: float = 180.0
	if dm != null and bool(dm.get("enabled")):
		z_min = float(dm.get("surface_depth_m"))
		z_max = float(dm.get("bottom_depth_m"))
		therm = float(dm.get("thermocline_depth_m"))
		therm_half = float(dm.get("thermocline_thickness_m")) * 0.5
		upper_hold = float(dm.call("hold_depth_for_band", "UPPER"))
		lower_hold = float(dm.call("hold_depth_for_band", "LOWER"))
	var h: float = maxf(size.y - VALUE_BOX_H - 8.0, 20.0)
	return {
		"z_min": z_min,
		"z_max": z_max,
		"therm": therm,
		"therm_half": therm_half,
		"upper_hold": upper_hold,
		"lower_hold": lower_hold,
		"y0": TOP_PAD,
		"h": h,
	}


## 深度 → 局部 y。
static func depth_to_y(info: Dictionary, z: float) -> float:
	var z_min: float = float(info["z_min"])
	var z_max: float = float(info["z_max"])
	var h: float = float(info["h"])
	return float(info["y0"]) + (clampf(z, z_min, z_max) - z_min) / maxf(z_max - z_min, 1.0) * h


## 局部 y → 深度（再按艇体 + 场景实际限制钳制）。
func depth_at_y(y: float) -> float:
	var info: Dictionary = scale_info()
	var z_min: float = float(info["z_min"])
	var z_max: float = float(info["z_max"])
	var h: float = float(info["h"])
	var frac: float = (clampf(y, float(info["y0"]), float(info["y0"]) + h) - float(info["y0"])) / h
	var z: float = z_min + frac * (z_max - z_min)
	var lo: float = z_min
	var hi: float = z_max
	var own: TruthEntity = _own()
	if own != null:  # 艇体实际限制优先于刻度
		lo = maxf(lo, own.min_depth_m)
		hi = minf(hi, own.max_depth_m)
	return clampf(z, minf(lo, hi), maxf(lo, hi))


func _own() -> TruthEntity:
	return _world.world["own"] if _world != null else null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _dragging:
		_update_preview((event as InputEventMouseMotion).position)
		accept_event()


func _unhandled_key_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo or k.keycode != KEY_ESCAPE:
		return
	if not preview_active():
		return
	cancel_preview()
	get_viewport().set_input_as_handled()


func _handle_button(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		if preview_active():
			cancel_preview()
			accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		if not interactive or not _in_hit_area(mb.position):
			return
		_dragging = true
		_update_preview(mb.position)
		accept_event()
		return
	if not _dragging:
		return
	_dragging = false
	var z: float = preview_z
	preview_z = -1.0
	queue_redraw()
	accept_event()
	if z >= 0.0 and interactive:
		depth_commanded.emit(z)


## 命中区：标尺所在左侧带（比标尺宽——深度条太窄时仍好按），纵向铺满。
func _in_hit_area(pos: Vector2) -> bool:
	return pos.x <= WIDTH_PX * 0.5 + HIT_SLACK_X and pos.y >= 0.0 and pos.y <= size.y - VALUE_BOX_H


func _update_preview(pos: Vector2) -> void:
	preview_z = depth_at_y(pos.y)
	queue_redraw()


func _draw() -> void:
	if _world == null:
		return
	var info: Dictionary = scale_info()
	var z_min: float = float(info["z_min"])
	var z_max: float = float(info["z_max"])
	var therm: float = float(info["therm"])
	var therm_half: float = float(info["therm_half"])
	var upper_hold: float = float(info["upper_hold"])
	var lower_hold: float = float(info["lower_hold"])
	var h: float = float(info["h"])
	var x0: float = 30.0
	var bar_w: float = 14.0
	var y_of: Callable = func(z: float) -> float: return depth_to_y(info, z)
	# 背景竖条 + 层带（文字 + 线型双编码，不只靠颜色）。
	draw_rect(Rect2(x0, 4.0, bar_w, h), Color(0.05, 0.15, 0.2, 0.9))
	# 命中区提示（拖动可用范围；不遮标尺文字）。
	draw_rect(Rect2(0.0, 4.0, WIDTH_PX * 0.5 + HIT_SLACK_X, h), Color(0.3, 0.6, 0.7, 0.04))
	var y_th0: float = y_of.call(therm - therm_half)
	var y_th1: float = y_of.call(therm + therm_half)
	draw_rect(Rect2(x0, y_th0, bar_w, y_th1 - y_th0), Color(0.5, 0.3, 0.0, 0.85))
	var f := get_theme_default_font()
	for cfg in [
		[y_of.call(0.0), str(UiText.t("band_surf")), Color(0.7, 0.9, 1.0)],
		[y_of.call(upper_hold), str(UiText.t("band_up")), Color(0.6, 0.8, 0.6)],
		[y_of.call(lower_hold), str(UiText.t("band_low")), Color(0.6, 0.6, 0.9)],
		[y_of.call(z_max), str(UiText.t("band_bot")), Color(0.8, 0.7, 0.5)],
	]:
		draw_line(Vector2(x0 - 4.0, cfg[0]), Vector2(x0 + bar_w + 4.0, cfg[0]), cfg[2], 1.0)
		draw_string(
			f,
			Vector2(x0 + bar_w + 6.0, cfg[0] + 4.0),
			str(cfg[1]),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			cfg[2]
		)
	# 实体标记：实心=actual，空心=commanded。
	_mark(
		x0,
		bar_w,
		y_of,
		float(_world.world["own"].depth_m),
		_commanded(_world.world["own"]),
		"OWN",
		Color(0.3, 0.8, 1.0),
		Rect2(0, 0, 0, 0)
	)
	if _world.weapons != null:
		for tp in _world.weapons.torpedoes:
			_mark(
				x0,
				bar_w,
				y_of,
				float(tp.actual_depth_m),
				float(tp.commanded_depth_m),
				"TK",
				Color(1.0, 0.45, 0.25),
				Rect2(0, 0, 0, 0)
			)
	for d in _world.decoys:
		if str(d.side) == "blue":
			_mark(
				x0,
				bar_w,
				y_of,
				float(d.depth_m),
				float(d.commanded_depth_m),
				"DCY",
				Color(0.9, 0.9, 0.3),
				Rect2(0, 0, 0, 0)
			)
	_draw_enemy_depth_bands(x0, bar_w, y_of, upper_hold, lower_hold)
	_draw_preview(x0, bar_w, h, y_of, f)


## UI-03：预览（虚线 + ◆ + 固定信息框数值）。信息框固定在底部，绝不被指针遮住
## 标尺文字，也不与任何实际/命令标记混形。
func _draw_preview(x0: float, bar_w: float, h: float, y_of: Callable, f: Font) -> void:
	var box_y: float = 4.0 + h + 4.0
	var own: TruthEntity = _own()
	var txt: String = ""
	if preview_z >= 0.0:
		txt = UiText.t("depth_preview_fmt") % preview_z
	elif _dragging:
		txt = str(UiText.t("depth_tag_preview"))
	elif own != null:
		txt = UiText.t("depth_preview_idle_fmt") % float(own.depth_m)
	if preview_z >= 0.0:
		var y: float = y_of.call(preview_z)
		var cx: float = x0 + bar_w * 0.5
		draw_dashed_line(
			Vector2(x0 - 20.0, y), Vector2(x0 + bar_w + 16.0, y), COL_PREVIEW, 2.0, 4.0
		)
		draw_colored_polygon(
			PackedVector2Array(
				[
					Vector2(cx, y - 5.0),
					Vector2(cx + 5.0, y),
					Vector2(cx, y + 5.0),
					Vector2(cx - 5.0, y)
				]
			),
			COL_PREVIEW
		)
	draw_string(
		f,
		Vector2(2.0, box_y + 13.0),
		txt,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		10,
		COL_PREVIEW if preview_z >= 0.0 else Color(0.6, 0.75, 0.8)
	)


## S1-11 §7.4/AT-27..33：敌方深度只画**半透明概率带**——绝不画伪精确深度点。
## 无合法证据（置信度 < 0.55）一律不画（显式"深度未知"，不默认上层、不用 0m）。
func _draw_enemy_depth_bands(
	x0: float, bar_w: float, y_of: Callable, upper_hold: float, lower_hold: float
) -> void:
	if _tracker == null:
		return
	var f := get_theme_default_font()
	var rows: int = 0
	for t in _tracker.all_tracks():
		if t == null or t.depth_estimator == null:
			continue
		var s: Dictionary = t.depth_estimate_summary()
		var conf: float = float(s.get("confidence", 0.0))
		if conf < 0.55:
			continue  # AT-27：无证据/低置信 → 深度未知（不画）
		var dom: String = str(s.get("dominant", "UNKNOWN"))
		var z: float = _band_depth(dom, upper_hold, lower_hold)
		if z < 0.0:
			continue
		var p: float = clampf(float(s.get("probability", 0.0)), 0.0, 1.0)
		var y: float = y_of.call(z)
		# 半透明概率带（透明度 ∝ 概率；宽度覆盖整条深度刻度）。
		draw_rect(
			Rect2(x0 - 22.0, y - 7.0, bar_w + 30.0, 14.0), Color(0.95, 0.8, 0.25, 0.10 + 0.28 * p)
		)
		draw_line(
			Vector2(x0 - 22.0, y), Vector2(x0 + bar_w + 8.0, y), Color(0.95, 0.85, 0.4, 0.55), 1.0
		)
		draw_string(
			f,
			Vector2(x0 - 22.0, y - 10.0),
			UiText.depth_band_summary(s),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			Color(0.98, 0.9, 0.6)
		)
		rows += 1
		if rows >= 3:
			break  # 减载：深度条最多展开 3 条敌方深度带


## 主导层 → 该层代表深度（SURFACE=-1 表示"近水面"画在 0m 处）。
func _band_depth(dom: String, upper_hold: float, lower_hold: float) -> float:
	match dom:
		"SURFACE_LIKELY":
			return 0.0
		"UPPER_LIKELY":
			return upper_hold
		"LOWER_LIKELY":
			return lower_hold
	return -1.0


func _commanded(e: RefCounted) -> float:
	return float(e.commanded_depth_m)


## 一个深度标记：■(艇)/▲(鱼雷)/◆(诱饵) 由 kind 首字符形状区分 + 文字。
func _mark(
	x0: float,
	bar_w: float,
	y_of: Callable,
	z: float,
	z_cmd: float,
	kind: String,
	col: Color,
	_unused: Rect2
) -> void:
	var y: float = y_of.call(z)
	var cx: float = x0 + bar_w * 0.5
	var f := get_theme_default_font()
	var shape: String = "sq" if kind == "OWN" else ("tri" if kind == "TK" else "dia")
	if kind == "OWN":
		draw_string(
			f,
			Vector2(x0 - 28.0, y - 8.0),
			UiText.t("depth_tag_actual"),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			9,
			col
		)
	match shape:
		"sq":
			draw_rect(Rect2(cx - 4.0, y - 3.0, 8.0, 6.0), col)
		"tri":
			draw_colored_polygon(
				PackedVector2Array(
					[Vector2(cx, y - 4.0), Vector2(cx - 4.0, y + 3.0), Vector2(cx + 4.0, y + 3.0)]
				),
				col
			)
		_:
			draw_colored_polygon(
				PackedVector2Array(
					[
						Vector2(cx, y - 4.0),
						Vector2(cx + 4.0, y),
						Vector2(cx, y + 4.0),
						Vector2(cx - 4.0, y)
					]
				),
				col
			)
	# 命令深度（空心圈 + 虚线指示）。
	if z_cmd >= 0.0 and absf(z_cmd - z) > 1.0:
		var yc: float = y_of.call(z_cmd)
		draw_arc(Vector2(cx, yc), 4.0, 0.0, TAU, 12, Color(col.r, col.g, col.b, 0.8), 1.0)
		draw_dashed_line(
			Vector2(cx + 5.0, yc),
			Vector2(cx + bar_w, yc),
			Color(col.r, col.g, col.b, 0.4),
			1.0,
			3.0
		)
		if kind == "OWN":
			draw_string(
				f,
				Vector2(x0 - 28.0, yc - 8.0),
				UiText.t("depth_tag_cmd"),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				Color(col.r, col.g, col.b, 0.9)
			)
	draw_string(f, Vector2(x0 - 28.0, y + 12.0), kind, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, col)
