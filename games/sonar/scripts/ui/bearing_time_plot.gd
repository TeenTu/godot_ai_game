class_name BearingTimePlot
extends Control
## bearing_time_plot.gd — Bearing-Time 图（重构版）。
##
##   - 高度 ≥240px；默认局部动态纵轴（按时间连续展开 + y_margin），
##     可切换 "360° Overview" 固定 0–360 全览
##   - 绘制顺序：先低透明度测量点，最上层画 3px 最优模型曲线
##   - 时间轴刻度 mm:ss、网格、本艇转向标记
##   - 悬停测量 → 发出 hover_changed(time)，由 main_ui 联动海图/残差图
##   - 离群点红色 X；误差棒 1.5px；测量点半径 3.5~4px

signal hover_changed(time: float)  # -1 = 离开

const PAD_L: float = 44.0
const PAD_R: float = 10.0
const PAD_T: float = 10.0
const PAD_B: float = 22.0
const BEST_WIDTH: float = 3.0

var overview_mode: bool = false  # false=局部动态纵轴, true=0..360 全览
var meas_points: Array = []  # [{time, bearing_deg, sigma_deg, color, inlier}]
var model_curves: Array = []  # [{points:[{time,bearing_deg}], color, best}]
var turn_times: Array = []
var t_min: float = 0.0
var t_max: float = 1.0
var track_id: String = ""

var _font: Font = null
var _hover_time: float = -1.0
# 展开后的绘制缓存：[{x, y, orig}]（orig={} 表示模型曲线点）
var _meas_unwrapped: Array = []
var _y_lo: float = 0.0
var _y_hi: float = 360.0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(0, 240)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_time_window(t0: float, t1: float) -> void:
	t_min = t0
	t_max = maxf(t1, t0 + 1.0)


func _plot_rect() -> Rect2:
	return Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R, size.y - PAD_T - PAD_B)


func _tx(t: float) -> float:
	var r := _plot_rect()
	var span: float = maxf(t_max - t_min, 1.0)
	return r.position.x + (t - t_min) / span * r.size.x


## 按当前模式把展开值映射到屏幕 y。
func _ty(val_unwrapped: float) -> float:
	var r := _plot_rect()
	if overview_mode:
		return r.position.y + (1.0 - NavUtils.wrap360(val_unwrapped) / 360.0) * r.size.y
	var span: float = maxf(_y_hi - _y_lo, 1.0)
	return r.position.y + (1.0 - (val_unwrapped - _y_lo) / span) * r.size.y


## 按时间连续展开（跨北处理）：
## unwrapped[i] = unwrapped[i-1] + wrap180(bearing[i] - unwrapped[i-1])
static func unwrap_series(points: Array, anchor: float = INF) -> Array:
	var out: Array = []
	var prev: float = 0.0
	var first: bool = true
	for p in points:
		var b: float = float(p["bearing_deg"])
		if first:
			var base: float = b if is_inf(anchor) else anchor + NavUtils.wrap180(b - anchor)
			out.append(base)
			prev = base
			first = false
		else:
			prev = prev + NavUtils.wrap180(b - prev)
			out.append(prev)
	return out


## 局部动态纵轴：由展开后的测量+模型确定 y 范围，
## y_margin = max(5 deg, 3 * max_sigma)。同时生成绘制缓存
## （overview 模式也生成缓存，_ty 内部对值做 wrap360）。
func _rebuild_axis() -> void:
	_meas_unwrapped = []
	if meas_points.is_empty():
		return
	var sorted: Array = meas_points.duplicate()
	sorted.sort_custom(func(a, b): return float(a["time"]) < float(b["time"]))
	var vals: Array = unwrap_series(sorted)
	var max_sig: float = 0.0
	for i in range(sorted.size()):
		var mp: Dictionary = sorted[i]
		max_sig = maxf(max_sig, float(mp.get("sigma_deg", 1.0)))
		_meas_unwrapped.append({"x": float(mp["time"]), "y": float(vals[i]), "orig": mp})
	for curve in model_curves:
		var pts: Array = curve.get("points", [])
		if pts.is_empty():
			continue
		var cv: Array = unwrap_series(pts, _model_anchor(pts))
		curve["_unwrapped"] = cv
		for i in range(pts.size()):
			_meas_unwrapped.append({"x": float(pts[i]["time"]), "y": float(cv[i]), "orig": {}})
	if overview_mode:
		return
	var lo: float = INF
	var hi: float = -INF
	for u in _meas_unwrapped:
		lo = minf(lo, float(u["y"]))
		hi = maxf(hi, float(u["y"]))
	var margin: float = maxf(5.0, 3.0 * max_sig)
	_y_lo = lo - margin
	_y_hi = hi + margin


## 模型曲线展开锚点：取时间上最近的测量方位，保证与测量同一分支。
func _model_anchor(pts: Array) -> float:
	if meas_points.is_empty() or pts.is_empty():
		return INF
	var t0: float = float(pts[0]["time"])
	var best_b: float = float(pts[0]["bearing_deg"])
	var best_d: float = INF
	for mp in meas_points:
		var d: float = absf(float(mp["time"]) - t0)
		if d < best_d:
			best_d = d
			best_b = float(mp["bearing_deg"])
	return best_b


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	_rebuild_axis()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.06, 0.08, 1.0))
	var r := _plot_rect()
	draw_rect(r, Color(0.2, 0.3, 0.35, 0.8), false, 1.0)
	_draw_y_axis(r)
	_draw_time_axis(r)
	for tt in turn_times:
		var x: float = _tx(float(tt))
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(0.4, 0.7, 1.0, 0.45), 1.5)
	# 1) 低透明度测量点（模型曲线画在其上层）
	for u in _meas_unwrapped:
		var mp: Dictionary = u["orig"]
		if mp.is_empty():
			continue
		var x: float = _tx(float(u["x"]))
		var y: float = _ty(float(u["y"]))
		var col: Color = mp.get("color", Color(1.0, 0.85, 0.3))
		var sig: float = maxf(float(mp.get("sigma_deg", 1.0)), 0.1)
		var inlier: bool = bool(mp.get("inlier", true))
		if inlier:
			draw_line(
				Vector2(x, _ty(float(u["y"]) + sig)),
				Vector2(x, _ty(float(u["y"]) - sig)),
				Color(col.r, col.g, col.b, 0.4),
				1.5
			)
			draw_circle(Vector2(x, y), 3.5, Color(col.r, col.g, col.b, 0.45))
		else:
			_draw_x(Vector2(x, y), Color(1.0, 0.25, 0.25, 0.9))
	# 2) 备选虚线在下，最优 3px 置顶
	for curve in model_curves:
		if not bool(curve.get("best", false)):
			_draw_curve(curve, false)
	for curve in model_curves:
		if bool(curve.get("best", false)):
			_draw_curve(curve, true)
	_draw_hover()


func _draw_y_axis(r: Rect2) -> void:
	if overview_mode:
		for brg in [0.0, 90.0, 180.0, 270.0, 360.0]:
			var y: float = _ty(brg)
			draw_line(
				Vector2(r.position.x, y), Vector2(r.end.x, y), Color(0.15, 0.25, 0.28, 0.4), 1.0
			)
			draw_string(
				_font,
				Vector2(2, y + 5),
				"%d°" % int(brg),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				14,
				Color(0.5, 0.7, 0.75, 0.9)
			)
	else:
		var step: float = _axis_step(_y_hi - _y_lo)
		var v: float = ceilf(_y_lo / step) * step
		while v <= _y_hi:
			var y2: float = _ty(v)
			draw_line(
				Vector2(r.position.x, y2), Vector2(r.end.x, y2), Color(0.15, 0.25, 0.28, 0.4), 1.0
			)
			draw_string(
				_font,
				Vector2(2, y2 + 5),
				"%.0f°" % v,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				14,
				Color(0.5, 0.7, 0.75, 0.9)
			)
			v += step


func _axis_step(span: float) -> float:
	var target: float = span / 5.0
	for s in [1.0, 2.0, 5.0, 10.0, 20.0, 45.0, 90.0]:
		if target <= s:
			return s
	return 90.0


func _draw_time_axis(r: Rect2) -> void:
	var span: float = maxf(t_max - t_min, 1.0)
	var step_t: float = 600.0
	for s in [15.0, 30.0, 60.0, 120.0, 300.0, 600.0]:
		if span / s <= 10.0:
			step_t = s
			break
	var tt: float = ceilf(t_min / step_t) * step_t
	while tt <= t_max:
		var x: float = _tx(tt)
		draw_line(Vector2(x, r.end.y), Vector2(x, r.end.y + 4.0), Color(0.5, 0.7, 0.75, 0.7), 1.0)
		draw_string(
			_font,
			Vector2(x - 16.0, size.y - 6.0),
			_mmss(tt),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(0.5, 0.7, 0.75, 0.9)
		)
		tt += step_t
	if track_id != "":
		draw_string(
			_font,
			Vector2(r.end.x - 100.0, r.position.y + 16.0),
			"track " + track_id,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(0.7, 0.85, 0.9, 0.9)
		)


func _draw_curve(curve: Dictionary, is_best: bool) -> void:
	var pts: Array = curve.get("points", [])
	if pts.size() < 2:
		return
	var col: Color = curve.get("color", Color(1.0, 0.5, 0.2))
	var uw: Array = curve.get("_unwrapped", [])
	if uw.size() != pts.size():
		uw = unwrap_series(pts)
	var width: float = BEST_WIDTH if is_best else 1.5
	var alpha: float = 0.95 if is_best else 0.4
	var plot_h: float = _plot_rect().size.y
	var prev := Vector2.ZERO
	var has_prev: bool = false
	for i in range(pts.size()):
		var s := Vector2(_tx(float(pts[i]["time"])), _ty(float(uw[i])))
		# overview 模式下分支跳跃（跨北）断开，不画长直线
		var jump: bool = has_prev and overview_mode and absf(s.y - prev.y) > plot_h * 0.4
		if has_prev and not jump:
			if is_best:
				draw_line(prev, s, Color(col.r, col.g, col.b, alpha), width)
			else:
				_draw_dashed(prev, s, Color(col.r, col.g, col.b, alpha), width)
		prev = s
		has_prev = true


func _draw_dashed(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var seg: float = a.distance_to(b)
	if seg < 1.0:
		return
	var dir: Vector2 = (b - a) / seg
	var t: float = 0.0
	while t < seg:
		var t2: float = minf(t + 4.0, seg)
		draw_line(a + dir * t, a + dir * t2, col, width)
		t += 8.0


func _draw_x(pos: Vector2, col: Color) -> void:
	draw_line(pos + Vector2(-4, -4), pos + Vector2(4, 4), col, 2.0)
	draw_line(pos + Vector2(-4, 4), pos + Vector2(4, -4), col, 2.0)


func _draw_hover() -> void:
	if _hover_time < 0.0:
		return
	var x: float = _tx(_hover_time)
	var r := _plot_rect()
	draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.5), 1.5)


func _mmss(t: float) -> String:
	var s: int = int(maxf(t, 0.0))
	return "%02d:%02d" % [s / 60, s % 60]


# ------------------------------------------------------------------
#  悬停交互
# ------------------------------------------------------------------


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var t: float = _nearest_meas_time(mm.position)
		if absf(t - _hover_time) > 1e-6:
			_hover_time = t
			hover_changed.emit(t)
			queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _hover_time != -1.0:
			_hover_time = -1.0
			hover_changed.emit(-1.0)
			queue_redraw()


func _nearest_meas_time(pos: Vector2) -> float:
	var best_t: float = -1.0
	var best_d: float = 14.0
	for u in _meas_unwrapped:
		var mp: Dictionary = u["orig"]
		if mp.is_empty():
			continue
		var p := Vector2(_tx(float(u["x"])), _ty(float(u["y"])))
		var d: float = p.distance_to(pos)
		if d < best_d:
			best_d = d
			best_t = float(u["x"])
	return best_t


func mouse_exited_notify() -> void:
	if _hover_time != -1.0:
		_hover_time = -1.0
		hover_changed.emit(-1.0)
		queue_redraw()
