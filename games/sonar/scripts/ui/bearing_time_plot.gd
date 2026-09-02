class_name BearingTimePlot
extends Control
## bearing_time_plot.gd — Bearing-Time 图（需求文档第九节 2）。
##
## 横轴时间，纵轴方位（度）：
##   - 实测方位点 + 误差棒（按 track 着色）
##   - 最优解预测方位曲线（粗实线）
##   - 各备选解预测曲线（细虚线）
##   - 本艇转向时刻竖直标记
## 方位跨越 0/360 时按连续性展开（unwrap），不出现 359°→1° 的长直线。
##
## 数据由 main_ui 每帧注入，本组件只绘制。

const PAD_L: float = 34.0
const PAD_R: float = 8.0
const PAD_T: float = 8.0
const PAD_B: float = 16.0

var meas_points: Array = []  # [{time, bearing_deg, sigma_deg, color}]
var model_curves: Array = []  # [{points: [{time, bearing_deg}], color, width, best: bool}]
var turn_times: Array = []  # [float] 本艇转向时刻
var t_min: float = 0.0
var t_max: float = 1.0

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(0, 150)


func _plot_rect() -> Rect2:
	return Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R, size.y - PAD_T - PAD_B)


func _tx(t: float) -> float:
	var r := _plot_rect()
	var span: float = maxf(t_max - t_min, 1.0)
	return r.position.x + (t - t_min) / span * r.size.x


func _ty(brg_unwrapped: float) -> float:
	# 纵轴固定 0..360
	var r := _plot_rect()
	return r.position.y + (1.0 - brg_unwrapped / 360.0) * r.size.y


func set_time_window(t0: float, t1: float) -> void:
	t_min = t0
	t_max = maxf(t1, t0 + 1.0)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.06, 0.08, 1.0))
	var r := _plot_rect()
	# 边框与横向刻度线
	draw_rect(r, Color(0.2, 0.3, 0.35, 0.8), false, 1.0)
	for brg in [0.0, 90.0, 180.0, 270.0, 360.0]:
		var y: float = _ty(brg)
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(0.15, 0.25, 0.28, 0.4), 1.0)
		draw_string(
			_font,
			Vector2(2, y + 4),
			"%d°" % int(brg),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			Color(0.5, 0.7, 0.75, 0.8)
		)
	# 本艇转向竖直标记
	for tt in turn_times:
		var x: float = _tx(float(tt))
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(0.4, 0.7, 1.0, 0.5), 1.0)
	# 模型曲线（先画，让数据点在上层）
	for curve in model_curves:
		_draw_curve(curve)
	# 实测点 + 误差棒
	for p in meas_points:
		var x: float = _tx(float(p["time"]))
		var y: float = _ty(_unwrap_at(float(p["time"]), float(p["bearing_deg"])))
		var col: Color = p.get("color", Color(1.0, 0.85, 0.3))
		var sig: float = float(p.get("sigma_deg", 1.0))
		# 误差棒（±1σ，展开空间里直接加减）
		draw_line(
			Vector2(x, _ty(_unwrap_at(float(p["time"]), float(p["bearing_deg"])) + sig)),
			Vector2(x, _ty(_unwrap_at(float(p["time"]), float(p["bearing_deg"])) - sig)),
			Color(col.r, col.g, col.b, 0.5),
			1.0
		)
		draw_circle(Vector2(x, y), 2.5, col)


## 按时间顺序维护展开方位（避免 359→1 跳变）。
## 简化实现：以"距最新模型曲线最近分支"展开；无模型时按数据自身连续性展开。
func _unwrap_at(t: float, brg: float) -> float:
	var base: float = brg
	# 找最近的模型曲线值作为参考分支
	for curve in model_curves:
		var pts: Array = curve["points"]
		for p in pts:
			if absf(float(p["time"]) - t) < 1e-6:
				var m: float = NavUtils.wrap360(float(p["bearing_deg"]))
				base = m + NavUtils.wrap180(brg - m)
				return base
	# 无模型参考：数据自身在 _draw 中按顺序展开（这里退回 wrap360）
	return NavUtils.wrap360(brg)


func _draw_curve(curve: Dictionary) -> void:
	var pts: Array = curve["points"]
	if pts.size() < 2:
		return
	var col: Color = curve.get("color", Color(1.0, 0.5, 0.2))
	var width: float = 2.0 if bool(curve.get("best", false)) else 1.0
	var alpha: float = 0.95 if bool(curve.get("best", false)) else 0.45
	var prev: Vector2 = Vector2.ZERO
	var prev_valid: bool = false
	# 曲线本身按模型值展开（分支跟随前一点）
	var prev_val: float = 0.0
	var first: bool = true
	for p in pts:
		var t: float = float(p["time"])
		var b: float = float(p["bearing_deg"])
		var val: float = b
		if not first:
			val = prev_val + NavUtils.wrap180(b - prev_val)
		var s := Vector2(_tx(t), _ty(val))
		if prev_valid and absf(s.x - prev.x) < size.x:
			_draw_seg(prev, s, Color(col.r, col.g, col.b, alpha), width)
		prev = s
		prev_valid = true
		prev_val = val
		first = false


## 简易虚线段。
func _draw_seg(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	if width >= 2.0:
		draw_line(a, b, col, width)
		return
	# 细线 = 备选解 → 虚线
	var len: float = a.distance_to(b)
	if len < 1.0:
		return
	var dir: Vector2 = (b - a) / len
	var t: float = 0.0
	while t < len:
		var t2: float = minf(t + 4.0, len)
		draw_line(a + dir * t, a + dir * t2, col, 1.0)
		t += 7.0
