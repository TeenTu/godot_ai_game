class_name ResidualPlot
extends Control
## residual_plot.gd — 残差图（Dot Stack 的可视化升级版）。
##
##   - 横轴时间；纵轴可切换 deg / sigma（点击图内切换）
##   - 绘制 e_i = wrap180(z_i - θ̂_i)；0 线突出；±1σ/±2σ/±3σ 区域带
##   - 离群点红色 X；底部统计：RMS / bias / max / used / rejected
##   - 悬停联动：hover_changed(time) 与 Bearing-Time 图一致

signal hover_changed(time: float)  # -1 = 离开

const PAD_L: float = 44.0
const PAD_R: float = 10.0
const PAD_T: float = 8.0
const PAD_B: float = 20.0

var residuals: Array = []  # [{time, residual_deg, normalized, inlier}]
var sigma_ref_deg: float = 1.0  # ±Nσ 带的参考 σ（被使用测量的平均 σ）
var t_min: float = 0.0
var t_max: float = 1.0
var use_sigma: bool = false  # false=deg, true=sigma
var track_id: String = ""
var highlight_time: float = -1.0

var _font: Font = null
var _hover_time: float = -1.0
var _y_span: float = 10.0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(0, 150)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_time_window(t0: float, t1: float) -> void:
	t_min = t0
	t_max = maxf(t1, t0 + 1.0)


func _plot_rect() -> Rect2:
	return Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R, size.y - PAD_T - PAD_B)


func _val(r: Dictionary) -> float:
	return float(r["normalized"]) if use_sigma else float(r["residual_deg"])


func _band_val(n_sigma: float) -> float:
	return n_sigma if use_sigma else n_sigma * sigma_ref_deg


func _ty(v: float) -> float:
	var pr := _plot_rect()
	return pr.position.y + (1.0 - (v + _y_span) / (2.0 * _y_span)) * pr.size.y


func _tx(t: float) -> float:
	var pr := _plot_rect()
	var span: float = maxf(t_max - t_min, 1.0)
	return pr.position.x + (t - t_min) / span * pr.size.x


func _compute_span() -> float:
	var m: float = _band_val(3.2)
	for r in residuals:
		m = maxf(m, absf(_val(r)) * 1.15)
	return maxf(m, 1.0)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	_y_span = _compute_span()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.06, 0.08, 1.0))
	var pr := _plot_rect()
	draw_rect(pr, Color(0.2, 0.3, 0.35, 0.8), false, 1.0)
	# ±1/2/3σ 区域带
	var bands: Array = [
		[3.0, Color(1.0, 0.3, 0.3, 0.05)],
		[2.0, Color(1.0, 0.8, 0.3, 0.06)],
		[1.0, Color(0.4, 1.0, 0.5, 0.08)],
	]
	for b in bands:
		var n: float = float(b[0])
		var y1: float = _ty(_band_val(n))
		var y2: float = _ty(_band_val(-n))
		draw_rect(Rect2(Vector2(pr.position.x, y1), Vector2(pr.size.x, y2 - y1)), b[1] as Color)
		draw_line(
			Vector2(pr.position.x, y1), Vector2(pr.end.x, y1), Color(0.5, 0.7, 0.75, 0.35), 1.0
		)
		draw_line(
			Vector2(pr.position.x, y2), Vector2(pr.end.x, y2), Color(0.5, 0.7, 0.75, 0.35), 1.0
		)
		draw_string(
			_font,
			Vector2(2, y1 + 5),
			_band_label(n),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(0.5, 0.7, 0.75, 0.9)
		)
	# 0 线（突出）
	draw_line(
		Vector2(pr.position.x, _ty(0.0)), Vector2(pr.end.x, _ty(0.0)), Color(1, 1, 1, 0.8), 2.0
	)
	# 转向竖线已由 BT 图承担；这里画高亮时刻
	if highlight_time >= 0.0:
		var xh: float = _tx(highlight_time)
		draw_line(Vector2(xh, pr.position.y), Vector2(xh, pr.end.y), Color(1, 1, 1, 0.5), 1.5)
	# 残差点
	for r in residuals:
		var x: float = _tx(float(r["time"]))
		var y: float = _ty(_val(r))
		var inlier: bool = bool(r.get("inlier", true))
		if inlier:
			draw_circle(Vector2(x, y), 3.5, Color(0.5, 0.85, 1.0, 0.85))
		else:
			draw_line(
				Vector2(x - 4, y - 4), Vector2(x + 4, y + 4), Color(1.0, 0.25, 0.25, 0.95), 2.0
			)
			draw_line(
				Vector2(x - 4, y + 4), Vector2(x + 4, y - 4), Color(1.0, 0.25, 0.25, 0.95), 2.0
			)
	_draw_stats(pr)
	if _hover_time >= 0.0:
		var xh2: float = _tx(_hover_time)
		draw_line(Vector2(xh2, pr.position.y), Vector2(xh2, pr.end.y), Color(1, 1, 1, 0.5), 1.5)


func _band_label(n: float) -> String:
	if use_sigma:
		return "%+d" % int(n)
	return "%+.1f°" % [n * sigma_ref_deg]


func _draw_stats(pr: Rect2) -> void:
	var used: Array = []
	for r in residuals:
		if bool(r.get("inlier", true)):
			used.append(r)
	if used.is_empty():
		draw_string(
			_font,
			Vector2(pr.position.x + 6, pr.position.y + 16),
			"no residuals (fit first)  |  click: deg/sigma",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(0.6, 0.7, 0.75, 0.9)
		)
		return
	var sq: float = 0.0
	var sm: float = 0.0
	var mx: float = 0.0
	for r in used:
		var v: float = float(r["residual_deg"])
		sq += v * v
		sm += v
		mx = maxf(mx, absf(v))
	var n: float = float(used.size())
	var rms: float = sqrt(sq / n)
	var bias: float = sm / n
	var rej: int = residuals.size() - used.size()
	var txt := (
		"RMS %.2f°  bias %+.2f°  max %.2f°  used %d  rej %d  [track %s]  click: deg/sigma"
		% [
			rms,
			bias,
			mx,
			used.size(),
			rej,
			track_id,
		]
	)
	draw_rect(
		Rect2(Vector2(pr.position.x + 4, pr.position.y + 2), Vector2(560, 20)),
		Color(0.02, 0.05, 0.07, 0.75)
	)
	draw_string(
		_font,
		Vector2(pr.position.x + 8, pr.position.y + 18),
		txt,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(0.85, 0.95, 1.0, 0.95)
	)


# ------------------------------------------------------------------
#  交互
# ------------------------------------------------------------------


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			use_sigma = not use_sigma
			queue_redraw()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var t: float = _nearest_time(mm.position)
		if absf(t - _hover_time) > 1e-6:
			_hover_time = t
			hover_changed.emit(t)
			queue_redraw()


func _nearest_time(pos: Vector2) -> float:
	var best_t: float = -1.0
	var best_d: float = 14.0
	for r in residuals:
		var p := Vector2(_tx(float(r["time"])), _ty(_val(r)))
		var d: float = p.distance_to(pos)
		if d < best_d:
			best_d = d
			best_t = float(r["time"])
	return best_t


func set_highlight(t: float) -> void:
	if absf(t - highlight_time) > 1e-6:
		highlight_time = t
		queue_redraw()


func mouse_exited_notify() -> void:
	if _hover_time != -1.0:
		_hover_time = -1.0
		hover_changed.emit(-1.0)
		queue_redraw()
