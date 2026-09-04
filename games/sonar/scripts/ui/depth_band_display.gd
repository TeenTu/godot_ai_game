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


func _init() -> void:
	custom_minimum_size = Vector2(WIDTH_PX, 200)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func bind(w: World) -> void:
	_world = w


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
		[y_of.call(0.0), "SURF", Color(0.7, 0.9, 1.0)],
		[y_of.call(upper_hold), "UP", Color(0.6, 0.8, 0.6)],
		[y_of.call(lower_hold), "LOW", Color(0.6, 0.6, 0.9)],
		[y_of.call(z_max), "BOT", Color(0.8, 0.7, 0.5)],
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
