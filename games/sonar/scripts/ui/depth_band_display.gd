class_name DepthBandDisplay
extends Control
## depth_band_display.gd — 侧边深度条（S1-07 §11.4，Commit 11）。
##
## 竖条自上而下：Surface / Upper hold / 温跃层带 / Lower hold / Bottom；
## 显示本艇、己方鱼雷、己方诱饵的实际（实心）与命令（空心）深度标记。
## 敌方深度只有经测量推断后才允许显示——本条绝不读敌方 Truth。
## 双编码（§11.5 上层要求）：形状（■艇 ▲鱼雷 ◆诱饵）+ 文字标签，不只靠颜色。

const WIDTH_PX: float = 96.0

var _world: World = null
var _tracker: Tracker = null


func _init() -> void:
	custom_minimum_size = Vector2(WIDTH_PX, 200)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func bind(w: World, tr: Tracker = null) -> void:
	_world = w
	if tr != null:
		_tracker = tr


func sync() -> void:
	if _world != null:
		queue_redraw()


func _draw() -> void:
	if _world == null:
		return
	var dm: RefCounted = _world.world.get("depth_model", null)
	var z_min: float = 0.0
	var z_max: float = 400.0
	var upper_hold: float = 70.0
	var lower_hold: float = 180.0
	var therm: float = 120.0
	var therm_half: float = 10.0
	if dm != null and bool(dm.get("enabled")):
		z_min = float(dm.get("surface_depth_m"))
		z_max = float(dm.get("bottom_depth_m"))
		therm = float(dm.get("thermocline_depth_m"))
		therm_half = float(dm.get("thermocline_thickness_m")) * 0.5
		upper_hold = float(dm.call("hold_depth_for_band", "UPPER"))
		lower_hold = float(dm.call("hold_depth_for_band", "LOWER"))
	var h: float = size.y - 8.0
	var x0: float = 30.0
	var bar_w: float = 14.0
	var y_of: Callable = func(z: float) -> float:
		return 4.0 + (clampf(z, z_min, z_max) - z_min) / maxf(z_max - z_min, 1.0) * h
	# 背景竖条 + 层带（文字 + 线型双编码，不只靠颜色）。
	draw_rect(Rect2(x0, 4.0, bar_w, h), Color(0.05, 0.15, 0.2, 0.9))
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
	draw_string(f, Vector2(x0 - 28.0, y + 4.0), kind, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, col)
