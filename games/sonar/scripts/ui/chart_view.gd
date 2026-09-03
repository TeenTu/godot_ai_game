class_name ChartView
extends Control
## chart_view.gd — 海图（俯视图），TMA 可视化重构版。
##
## 重点：信息减载 + 可辨认 + 相机交互。
##   - 相机：滚轮缩放 / 拖拽平移 / Reset View / Auto Frame（1~60 km）
##   - LOB 减载：默认最多 24 条代表性 LOB（最新 4 / 最旧 2 / 观测腿边界 /
##     均匀抽样），σ 扇区只画悬停或选中的测量；离群红虚线 + X 标记
##   - 拟合轨迹：白 3px + 橙外描边；时间刻度 ≤12 个（mm:ss，可点击联动）
##   - 备选解 A/B/C 编号 + 不同虚线模式；Trial 青菱形；System 紫双环
##   - 95% 置信椭圆（rank<4 / cond>1e4 / MULTIMODAL 时禁画）
##   - 图例 + 图层开关（layers 字典由 main_ui 的复选框驱动）
##
## 数据由 main_ui 在「新测量 / 新拟合 / 视图变化」时注入，不每帧重建。

signal tick_selected(time: float)

const PRED_HORIZON_S: float = 600.0
const BACK_HORIZON_S: float = 900.0
const HALF_LIFE_S: float = 600.0  # LOB 绝对半衰期（不按最老样本归一化）
const MAX_REP_LOBS: int = 24
const MAX_TICKS: int = 12
const MAX_ALTS: int = 3
const CHI2_95: float = 5.991  # 2 自由度 95% 分位（椭圆）

const ALT_COLORS: Array = [
	Color(0.55, 0.75, 1.0),
	Color(0.6, 0.9, 0.65),
	Color(0.85, 0.65, 1.0),
]
const ALT_DASH: Array = [10.0, 6.0, 3.0]  # A/B/C 虚线节距
const COL_BEST := Color(0.98, 0.55, 0.15)
const COL_TRIAL := Color(0.2, 0.95, 0.9)
const COL_SYSTEM := Color(0.75, 0.5, 1.0)
const COL_OUTLIER := Color(1.0, 0.25, 0.25)
const COL_OWN := Color(0.35, 0.7, 1.0)

var layers: Dictionary = {
	"lob": true,
	"sigma": true,
	"fit": true,
	"alt": true,
	"trial": true,
	"system": true,
	"truth": false,
}
var show_all_lobs: bool = false  # "All LOB History" 开关（默认关闭=代表性 24 条）
var show_truth: bool = false  # Show Truth 开关（与 layers.truth 同步）

# --- 相机 ---
var cam_center: Vector2 = Vector2.ZERO  # 相机中心（世界坐标 东/北 m）
var view_radius_m: float = 10000.0  # 可视半径（m），1~60 km

# --- 注入数据 ---
var own_pos: Vector2 = Vector2.ZERO
var own_track: Array = []
var own_course_deg: float = 0.0  # 本艇实际艏向（S1-01.4：本艇符号随实际艏向旋转）
# lob: [{origin, bearing_deg, color, id, track_id, time, sigma_deg, inlier}]
var lobs: Array = []
var leg_boundary_times: Array = []  # 观测腿首末测量时刻
var hover_time: float = -1.0  # BT 图悬停测量的时刻（-1 无）
var selected_time: float = -1.0  # 时间刻度点击选中的时刻（-1 无）
# meas_index: [{time, origin, bearing_deg, sigma_deg, inlier, track_id}]
var meas_index: Array = []
var trial_pos: Vector2 = Vector2.ZERO
var trial_active: bool = false
var trial_velocity: Vector2 = Vector2.ZERO
var system_pos: Vector2 = Vector2.ZERO
var system_active: bool = false
var truth_positions: Array = []  # [{pos, id}] 仅开发模式
# 假设: [{p_ref, v_ms, t_ref, weight, is_best, label, speed_kn, course_deg}]
var fit_hypotheses: Array = []
var fit_ticks: Array = []  # ≤12 个刻度时刻
var fit_track_id: String = ""
var fit_now_time: float = 0.0
# 位置协方差子矩阵（外推到 now 的 2x2）：[[PEE, PEN], [PEN, PNN]]
var fit_cov_pos: Array = []
var fit_status: String = ""
# S1-04C-REQ-03/06：选中 Track 最近一次有效测距证据（海图 range ring/带宽）。
# {center, range_m, sigma_m, bearing_deg, color, track_id}；空 = 不画。
var range_ring: Dictionary = {}
# 在水鱼雷：[{trail: [{e, n, t}], state: String}]（自身传感器/状态，非 Truth）
var torpedoes: Array = []

var _font: Font = null
var _dragging: bool = false
var _drag_from: Vector2 = Vector2.ZERO
var _cam_at_press: Vector2 = Vector2.ZERO
var _tick_screens: Array = []  # 绘制期缓存 [{pos, time}] 供点击命中
var _label_boxes: Array = []  # 绘制期缓存 Rect2，标签防重叠


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP


# ------------------------------------------------------------------
#  相机
# ------------------------------------------------------------------


func _scale_px() -> float:
	return minf(size.x, size.y) / (2.0 * maxf(view_radius_m, 1.0))


func world_to_screen(w: Vector2) -> Vector2:
	var d: Vector2 = w - cam_center
	return Vector2(size.x * 0.5 + d.x * _scale_px(), size.y * 0.5 - d.y * _scale_px())


func screen_to_world(s: Vector2) -> Vector2:
	var d: Vector2 = (s - Vector2(size.x * 0.5, size.y * 0.5)) / _scale_px()
	return cam_center + Vector2(d.x, -d.y)


func set_view(center: Vector2, radius_m: float) -> void:
	cam_center = center
	view_radius_m = clampf(radius_m, 500.0, 60000.0)
	queue_redraw()


func reset_view() -> void:
	set_view(own_pos, 10000.0)


## Auto Frame：包含本艇航迹 / LOB 原点 / 最优解 / 备选解 / 95% 椭圆。
func auto_frame() -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in own_track:
		lo = lo.min(p)
		hi = hi.max(p)
	for lob in _representative_lobs():
		lo = lo.min(lob["origin"])
		hi = hi.max(lob["origin"])
	for hyp in fit_hypotheses:
		var now_p: Vector2 = _hyp_now_pos(hyp)
		lo = lo.min(now_p)
		hi = hi.max(now_p)
		var back: Vector2 = _hyp_now_pos(hyp) - (hyp["v_ms"] as Vector2) * BACK_HORIZON_S
		lo = lo.min(back)
		hi = hi.max(back)
	for p in _ellipse_extent():
		lo = lo.min(p)
		hi = hi.max(p)
	if lo.x > hi.x:
		set_view(own_pos, 10000.0)
		return
	var c := (lo + hi) * 0.5
	var radius: float = maxf((hi - lo).length() * 0.6, 1000.0)
	set_view(c, radius * 1.15)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.15)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_from = mb.position
				_cam_at_press = cam_center
			else:
				_dragging = false
				if mb.position.distance_to(_drag_from) < 4.0:
					_on_click(mb.position)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			var d: Vector2 = (mm.position - _drag_from) / _scale_px()
			cam_center = _cam_at_press - Vector2(d.x, -d.y)
			queue_redraw()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var w_before := screen_to_world(screen_pos)
	view_radius_m = clampf(view_radius_m * factor, 500.0, 60000.0)
	var w_after := screen_to_world(screen_pos)
	cam_center += w_before - w_after
	queue_redraw()


func _on_click(pos: Vector2) -> void:
	for tick in _tick_screens:
		if (tick["pos"] as Vector2).distance_to(pos) <= 10.0:
			selected_time = float(tick["time"])
			tick_selected.emit(selected_time)
			queue_redraw()
			return


# ------------------------------------------------------------------
#  绘制
# ------------------------------------------------------------------


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	_tick_screens = []
	_label_boxes = []
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.08, 0.10, 1.0))
	_draw_grid()
	_draw_own_track()
	_draw_range_ring()
	if bool(layers.get("lob", true)):
		_draw_lobs()
	if bool(layers.get("fit", true)):
		_draw_fit_tracks()
	if bool(layers.get("trial", true)):
		_draw_trial()
	if bool(layers.get("system", true)):
		_draw_system()
	if bool(layers.get("truth", false)):
		_draw_truth()
	_draw_torpedoes()
	_draw_hover_link()
	_draw_camera_overlays()


func _draw_grid() -> void:
	var step_m: float = _nice_step(view_radius_m)
	var sp: float = step_m * _scale_px()
	if sp < 8.0:
		return
	var col := Color(0.15, 0.25, 0.28, 0.35)
	var origin := world_to_screen(Vector2.ZERO)
	var x: float = fposmod(origin.x, sp)
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
		x += sp
	var y: float = fposmod(origin.y, sp)
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
		y += sp
	# 网格标注（左下第一格处标单位）
	draw_string(
		_font,
		Vector2(6, size.y - 6),
		_dist_label(step_m),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(0.4, 0.6, 0.65, 0.8)
	)


func _nice_step(radius_m: float) -> float:
	var target: float = radius_m / 4.0
	var mag: float = pow(10.0, floor(log(maxf(target, 1.0)) / log(10.0)))
	for m in [1.0, 2.0, 5.0, 10.0]:
		if target <= m * mag:
			return m * mag
	return 10.0 * mag


func _dist_label(m: float) -> String:
	return "%.0f km" % [m / 1000.0] if m >= 1000.0 else "%.0f m" % m


## 本艇符号：随实际艏向旋转的三角 + 艏向线（S1-01.4：不再固定朝上）。
func _draw_own_track() -> void:
	if own_track.size() >= 2:
		var pts: PackedVector2Array = []
		for p in own_track:
			pts.append(world_to_screen(p))
		draw_polyline(pts, Color(COL_OWN.r, COL_OWN.g, COL_OWN.b, 0.5), 2.0)
	var s: Vector2 = world_to_screen(own_pos)
	# 屏幕坐标系 y 向下：世界北(+N)对应屏幕 -y
	var rad: float = own_course_deg * PI / 180.0
	var fwd := Vector2(sin(rad), -cos(rad))
	var side := Vector2(-fwd.y, fwd.x)
	var tip: Vector2 = s + fwd * 12.0
	var left: Vector2 = s - fwd * 7.0 - side * 7.0
	var right: Vector2 = s - fwd * 7.0 + side * 7.0
	# 艏向线（明显伸出三角之外）+ 艉部缺口（三角尾部不闭合）
	draw_line(s, s + fwd * 22.0, Color(COL_OWN.r, COL_OWN.g, COL_OWN.b, 0.9), 1.5)
	draw_colored_polygon(PackedVector2Array([tip, right, s - fwd * 3.0, left]), COL_OWN)
	_draw_label(s + Vector2(10, -10), "OWN", COL_OWN)


## 主动测距证据环（REQ-03/06）：以测量时刻观测位置为心、measured_range 为
## 半径画 ring，±σ 为半透明带宽；沿测量方位画径向短线把证据锚到该接触，
## 颜色 = Track 色（同色高亮）。过期/无测距由调用方传空 dict 禁用。
func _draw_range_ring() -> void:
	if range_ring.is_empty():
		return
	var c: Vector2 = range_ring["center"] as Vector2
	var r_m: float = float(range_ring["range_m"])
	var s_m: float = maxf(float(range_ring.get("sigma_m", 0.0)), 0.0)
	var col: Color = range_ring.get("color", COL_BEST) as Color
	var cs: Vector2 = world_to_screen(c)
	var scl: float = _scale_px()
	var r_px: float = r_m * scl
	var band_px: float = 2.0 * s_m * scl
	if band_px >= 2.0:
		draw_arc(cs, r_px, 0.0, TAU, 128, Color(col.r, col.g, col.b, 0.16), band_px)
	draw_arc(cs, r_px, 0.0, TAU, 128, Color(col.r, col.g, col.b, 0.95), 1.5)
	var brad: float = deg_to_rad(float(range_ring.get("bearing_deg", 0.0)))
	var dirv := Vector2(sin(brad), -cos(brad))  # 屏幕 y 向下
	draw_line(cs, cs + dirv * r_px, Color(col.r, col.g, col.b, 0.9), 1.0)
	var lp: Vector2 = cs + dirv * r_px
	var lab: String = "R %.1fkm ±%.0fm" % [r_m / 1000.0, s_m]
	_draw_label(lp + Vector2(6, -4), lab, Color(col.r, col.g, col.b, 0.95), 12)


# ------------------------------------------------------------------
#  LOB 减载绘制
# ------------------------------------------------------------------


## 代表性 LOB 选择：最新 4 + 最旧 2 + 观测腿边界 + 均匀抽样，总数 ≤24。
func _representative_lobs() -> Array:
	if show_all_lobs or lobs.size() <= MAX_REP_LOBS:
		return lobs
	var sorted: Array = lobs.duplicate()
	sorted.sort_custom(func(a, b): return float(a["time"]) < float(b["time"]))
	var chosen: Array = []
	var used := {}
	for i in range(minf(4, sorted.size())):
		chosen.append(sorted[i])
		used[i] = true
	for i in range(maxf(sorted.size() - 2, 0), sorted.size()):
		if not used.has(i):
			chosen.append(sorted[i])
			used[i] = true
	for bt in leg_boundary_times:
		var idx: int = _nearest_idx(sorted, float(bt))
		if not used.has(idx):
			chosen.append(sorted[idx])
			used[idx] = true
	var extra: int = MAX_REP_LOBS - chosen.size()
	if extra > 0 and sorted.size() > chosen.size():
		var pool: Array = []
		for i in range(sorted.size()):
			if not used.has(i):
				pool.append(i)
		var stride: float = float(pool.size()) / float(extra + 1)
		for k in range(extra):
			chosen.append(sorted[int(pool[int((k + 1) * stride)])])
	return chosen


func _nearest_idx(sorted: Array, t: float) -> int:
	var best_i: int = 0
	var best_d: float = INF
	for i in range(sorted.size()):
		var d: float = absf(float(sorted[i]["time"]) - t)
		if d < best_d:
			best_d = d
			best_i = i
	return best_i


func _lob_alpha(lob: Dictionary, is_latest: bool, is_sel: bool) -> float:
	if is_sel:
		return 1.0
	if is_latest:
		return 0.95
	var age: float = float(lob.get("time", 0.0))
	var age_s: float = maxf(fit_now_time - age, 0.0) if fit_now_time > 0.0 else 0.0
	# 绝对半衰期衰减，夹在 0.25~0.5
	return clampf(pow(0.5, age_s / HALF_LIFE_S) * 0.5, 0.25, 0.5)


func _draw_lobs() -> void:
	var reps: Array = _representative_lobs()
	var t_latest: float = -INF
	for lob in reps:
		t_latest = maxf(t_latest, float(lob["time"]))
	# 矢量线：LOB 是射线，屏幕空间延伸到海图边界，缩放不改变线型。
	var ray_len_px: float = size.length() * 1.5
	for lob in reps:
		var t: float = float(lob["time"])
		var is_latest: bool = t >= t_latest
		var is_sel: bool = t == selected_time or t == hover_time
		var inlier: bool = bool(lob.get("inlier", true))
		var mirror: bool = bool(lob.get("mirror", false))
		var col: Color = lob.get("color", Color(1.0, 0.85, 0.3))
		var origin_s := world_to_screen(lob["origin"])
		var brad: float = deg_to_rad(float(lob["bearing_deg"]))
		var dir_px := Vector2(sin(brad), -cos(brad))  # 屏幕 y 向下
		var end_s: Vector2 = origin_s + dir_px * ray_len_px
		if not inlier:
			_draw_dashed(origin_s, end_s, COL_OUTLIER, 1.5)
			_draw_x(origin_s, COL_OUTLIER)
		elif mirror:
			# S1-03B：拖曳阵 A/B 镜像支 → 细虚线 + 半透明，绝不做成同等级普通
			# 实线；歧义性只以弱化候选呈现（选中时再标 LR AMBIGUOUS）。
			_draw_dashed(origin_s, end_s, Color(col.r, col.g, col.b, 0.32), 1.0)
		elif is_sel or is_latest:
			draw_line(
				origin_s, end_s, Color(col.r, col.g, col.b, _lob_alpha(lob, is_latest, is_sel)), 2.5
			)
		else:
			draw_line(
				origin_s, end_s, Color(col.r, col.g, col.b, _lob_alpha(lob, false, false)), 1.0
			)
		# σ 扇区：仅悬停 / 选中测量（图例开关 sigma 控制）；镜像支不画同等级扇区
		if bool(layers.get("sigma", true)) and is_sel and not mirror:
			_draw_sigma_wedge(lob, col)
		draw_circle(
			origin_s,
			2.5 if not mirror else 1.8,
			Color(col.r, col.g, col.b, 0.9 if not mirror else 0.45),
		)
	# 选中 LOB 附加高亮圈；镜像支补 "LR AMBIGUOUS" 标注
	if selected_time >= 0.0 or hover_time >= 0.0:
		for lob in reps:
			if float(lob["time"]) in [selected_time, hover_time]:
				draw_arc(world_to_screen(lob["origin"]), 7.0, 0, TAU, 20, Color(1, 1, 1, 0.8), 2.0)
				if bool(lob.get("mirror", false)):
					var brad2: float = deg_to_rad(float(lob["bearing_deg"]))
					var dir2 := Vector2(sin(brad2), -cos(brad2))
					var lp2: Vector2 = world_to_screen(lob["origin"]) + dir2 * ray_len_px * 0.3
					_draw_label(lp2 + Vector2(6, 0), "LR AMBIGUOUS", Color(1.0, 0.9, 0.5, 0.9), 11)


func _draw_sigma_wedge(lob: Dictionary, col: Color) -> void:
	var brad: float = deg_to_rad(float(lob["bearing_deg"]))
	var sig: float = float(lob.get("sigma_deg", 1.0))
	var wedge_len: float = view_radius_m * 0.7
	var a0: float = deg_to_rad(float(lob["bearing_deg"]) - 2.0 * sig)
	var a1: float = deg_to_rad(float(lob["bearing_deg"]) + 2.0 * sig)
	var wedge := PackedVector2Array(
		[
			world_to_screen(lob["origin"]),
			world_to_screen(lob["origin"] + Vector2(sin(a0), cos(a0)) * wedge_len * 0.35),
			world_to_screen(lob["origin"] + Vector2(sin(brad), cos(brad)) * wedge_len),
			world_to_screen(lob["origin"] + Vector2(sin(a1), cos(a1)) * wedge_len * 0.35),
		]
	)
	draw_colored_polygon(wedge, Color(col.r, col.g, col.b, 0.10))


func _draw_dashed(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var seg: float = a.distance_to(b)
	if seg < 1.0:
		return
	var dir: Vector2 = (b - a) / seg
	var t: float = 0.0
	while t < seg:
		var t2: float = minf(t + 5.0, seg)
		draw_line(a + dir * t, a + dir * t2, col, width)
		t += 9.0


func _draw_dashed_pattern(a: Vector2, b: Vector2, col: Color, width: float, pat: float) -> void:
	var seg: float = a.distance_to(b)
	if seg < 1.0:
		return
	var dir: Vector2 = (b - a) / seg
	var t: float = 0.0
	while t < seg:
		var t2: float = minf(t + pat * 0.6, seg)
		draw_line(a + dir * t, a + dir * t2, col, width)
		t += pat


func _draw_x(pos: Vector2, col: Color) -> void:
	draw_line(pos + Vector2(-5, -5), pos + Vector2(5, 5), col, 2.0)
	draw_line(pos + Vector2(-5, 5), pos + Vector2(5, -5), col, 2.0)


# ------------------------------------------------------------------
#  拟合轨迹
# ------------------------------------------------------------------


func _hyp_now_pos(hyp: Dictionary) -> Vector2:
	var v := hyp["v_ms"] as Vector2
	return (hyp["p_ref"] as Vector2) + v * (fit_now_time - float(hyp["t_ref"]))


func _draw_fit_tracks() -> void:
	if fit_hypotheses.is_empty() or fit_status == "NO_FIT":
		return
	var t_ref: float = float(fit_hypotheses[0].get("t_ref", fit_now_time))
	var alt_i: int = 0
	for hyp in fit_hypotheses:
		if bool(hyp.get("is_best", false)):
			_draw_best_track(hyp, t_ref)
		elif bool(layers.get("alt", true)) and alt_i < MAX_ALTS:
			_draw_alt_track(hyp, t_ref, alt_i)
			alt_i += 1


func _draw_best_track(hyp: Dictionary, t_ref: float) -> void:
	var v := hyp["v_ms"] as Vector2
	var p_ref := hyp["p_ref"] as Vector2
	var pts: PackedVector2Array = []
	var tt: float = t_ref - BACK_HORIZON_S
	while tt <= fit_now_time + PRED_HORIZON_S:
		pts.append(world_to_screen(p_ref + v * (tt - t_ref)))
		tt += 30.0
	# 橙色外描边（更宽）再叠白色主线
	draw_polyline(pts, Color(COL_BEST.r, COL_BEST.g, COL_BEST.b, 0.85), 5.0)
	draw_polyline(pts, Color(1, 1, 1, 0.95), 3.0)
	_draw_fit_ticks(p_ref, v, t_ref)
	_draw_best_end(p_ref, v, t_ref)


func _draw_fit_ticks(p_ref: Vector2, v: Vector2, t_ref: float) -> void:
	for mt in fit_ticks:
		var pos: Vector2 = world_to_screen(p_ref + v * (float(mt) - t_ref))
		var is_sel: bool = float(mt) == selected_time
		var r: float = 5.5 if is_sel else 4.0
		draw_circle(pos, r, Color(1, 1, 1, 0.95))
		draw_arc(pos, r + 1.5, 0, TAU, 16, COL_BEST, 2.0)
		var lbl := _mmss(float(mt))
		_draw_label(pos + Vector2(8, -8), lbl, Color(1, 1, 1, 0.9))
		_tick_screens.append({"pos": pos, "time": float(mt)})


func _draw_best_end(p_ref: Vector2, v: Vector2, t_ref: float) -> void:
	var now_pos: Vector2 = p_ref + v * (fit_now_time - t_ref)
	var now_s := world_to_screen(now_pos)
	draw_circle(now_s, 5.0, COL_BEST)
	_draw_cov_ellipse(now_s)
	# 外推预测虚线
	var pred_s := world_to_screen(now_pos + v * PRED_HORIZON_S)
	_draw_dashed(now_s, pred_s, Color(COL_BEST.r, COL_BEST.g, COL_BEST.b, 0.4), 1.5)
	var lbl := "FIT %s" % _dist_label(own_pos.distance_to(now_pos))
	_draw_label(now_s + Vector2(9, 4), lbl, COL_BEST, 16)


## 95% 置信椭圆（fit_cov_pos 2x2）；数据不足时不画。
func _draw_cov_ellipse(now_s: Vector2) -> void:
	if fit_cov_pos.size() != 2 or (fit_cov_pos[0] as Array).size() != 2:
		return
	var pee: float = float(fit_cov_pos[0][0])
	var pen: float = float(fit_cov_pos[0][1])
	var pnn: float = float(fit_cov_pos[1][1])
	if pee <= 0.0 or pnn <= 0.0:
		return
	var tr: float = pee + pnn
	var det: float = pee * pnn - pen * pen
	if det <= 0.0:
		return
	var disc: float = maxf(tr * tr * 0.25 - det, 0.0)
	var l1: float = tr * 0.5 + sqrt(disc)
	var l2: float = maxf(tr * 0.5 - sqrt(disc), 1e-9)
	var theta: float = 0.5 * atan2(2.0 * pen, pee - pnn)
	var a: float = sqrt(CHI2_95 * l1) * _scale_px()
	var b: float = sqrt(CHI2_95 * l2) * _scale_px()
	if maxf(a, b) < 2.0:
		return
	var pts := PackedVector2Array()
	for i in range(49):
		var ang: float = TAU * float(i) / 48.0
		var local := Vector2(cos(ang) * a, sin(ang) * b)
		var rot := Vector2(
			local.x * cos(theta) - local.y * sin(theta), local.x * sin(theta) + local.y * cos(theta)
		)
		# 屏幕坐标 y 向下、北为 -y：翻转 y 分量保持椭圆方位正确
		pts.append(now_s + Vector2(rot.x, -rot.y))
	draw_polyline(pts, Color(COL_BEST.r, COL_BEST.g, COL_BEST.b, 0.7), 2.0)
	draw_polyline(pts, Color(COL_BEST.r, COL_BEST.g, COL_BEST.b, 0.12), 2.0, true)


func _draw_alt_track(hyp: Dictionary, t_ref: float, idx: int) -> void:
	var v := hyp["v_ms"] as Vector2
	var p_ref := hyp["p_ref"] as Vector2
	var col: Color = ALT_COLORS[idx % ALT_COLORS.size()]
	var pat: float = ALT_DASH[idx % ALT_DASH.size()]
	var pts := PackedVector2Array()
	var tt: float = t_ref - BACK_HORIZON_S
	while tt <= fit_now_time + PRED_HORIZON_S:
		pts.append(world_to_screen(p_ref + v * (tt - t_ref)))
		tt += 30.0
	for i in range(pts.size() - 1):
		_draw_dashed_pattern(pts[i], pts[i + 1], Color(col.r, col.g, col.b, 0.7), 1.5, pat)
	var alt_pos := world_to_screen(_hyp_now_pos(hyp))
	var lbl: String = (
		"%s w=%.2f %.0fkn"
		% [
			str(hyp.get("label", "?")),
			float(hyp.get("weight", 0.0)),
			float(hyp.get("speed_kn", 0.0)),
		]
	)
	_draw_label(alt_pos + Vector2(7, -7), lbl, col, 14)
	draw_circle(alt_pos, 4.0, Color(col.r, col.g, col.b, 0.9))


# ------------------------------------------------------------------
#  Trial / System / Truth / 悬停联动 / 覆盖层
# ------------------------------------------------------------------


func _draw_trial() -> void:
	if not trial_active:
		return
	var s := world_to_screen(trial_pos)
	# 青色菱形
	var d := PackedVector2Array(
		[s + Vector2(0, -9), s + Vector2(9, 0), s + Vector2(0, 9), s + Vector2(-9, 0)]
	)
	draw_colored_polygon(d, Color(COL_TRIAL.r, COL_TRIAL.g, COL_TRIAL.b, 0.95))
	if trial_velocity.length() > 0.01:
		var end_s := world_to_screen(trial_pos + trial_velocity * 60.0)
		draw_line(s, end_s, Color(COL_TRIAL.r, COL_TRIAL.g, COL_TRIAL.b, 0.7), 2.0)
	_draw_label(s + Vector2(10, 4), "TRIAL", COL_TRIAL, 16)


func _draw_system() -> void:
	if not system_active:
		return
	var s := world_to_screen(system_pos)
	# 紫色双环
	draw_arc(s, 8.0, 0, TAU, 24, COL_SYSTEM, 2.0)
	draw_arc(s, 13.0, 0, TAU, 24, COL_SYSTEM, 2.0)
	_draw_label(s + Vector2(15, 4), "SYSTEM", COL_SYSTEM, 16)


func _draw_truth() -> void:
	for t in truth_positions:
		var s := world_to_screen(t["pos"])
		draw_rect(Rect2(s - Vector2(6, 6), Vector2(12, 12)), Color(1.0, 0.25, 0.25, 0.9))
		_draw_label(s + Vector2(9, -4), str(t.get("id", "?")), Color(1, 0.5, 0.5), 14)


## 悬停联动：高亮 o_i（本艇位置）、LOB、p_i（拟合目标位置），显示数值。
func _draw_hover_link() -> void:
	var t: float = hover_time if hover_time >= 0.0 else selected_time
	if t < 0.0 or fit_hypotheses.is_empty() or fit_status == "NO_FIT":
		return
	var best: Dictionary = {}
	for hyp in fit_hypotheses:
		if bool(hyp.get("is_best", false)):
			best = hyp
			break
	if best.is_empty():
		return
	var m: Dictionary = _meas_at(t)
	if m.is_empty():
		return
	var o := m["origin"] as Vector2
	var p_i: Vector2 = _hyp_at_time(best, t)
	var o_s := world_to_screen(o)
	var p_s := world_to_screen(p_i)
	draw_arc(o_s, 9.0, 0, TAU, 20, Color(1, 1, 1, 0.9), 2.0)
	draw_arc(p_s, 7.0, 0, TAU, 20, Color(COL_BEST.r, COL_BEST.g, COL_BEST.b, 0.95), 2.0)
	draw_line(o_s, p_s, Color(1, 1, 1, 0.35), 1.5)
	# 数值面板：z_i / θ̂_i / e_i / e_i/σ_i
	var z: float = float(m["bearing_deg"])
	var sig: float = maxf(float(m["sigma_deg"]), 0.1)
	var dp: Vector2 = p_i - o
	var th: float = rad_to_deg(atan2(dp.x, dp.y))
	var e: float = NavUtils.wrap180(z - th)
	var txt := (
		"t=%s  z=%.1f  pred=%.1f\ne=%.2f°  e/sig=%.1f"
		% [
			_mmss(t),
			z,
			th,
			e,
			e / sig,
		]
	)
	_draw_label(Vector2(10, 24), txt, Color(1, 1, 1, 0.95), 14)


func _hyp_at_time(hyp: Dictionary, t: float) -> Vector2:
	var v := hyp["v_ms"] as Vector2
	return (hyp["p_ref"] as Vector2) + v * (t - float(hyp["t_ref"]))


func _meas_at(t: float) -> Dictionary:
	for m in meas_index:
		if absf(float(m["time"]) - t) < 1e-6:
			return m
	return {}


func _ellipse_extent() -> Array:
	if fit_cov_pos.size() != 2 or fit_hypotheses.is_empty():
		return []
	var best: Dictionary = {}
	for hyp in fit_hypotheses:
		if bool(hyp.get("is_best", false)):
			best = hyp
	var pee: float = float(fit_cov_pos[0][0])
	var pnn: float = float(fit_cov_pos[1][1])
	if pee <= 0.0 or best.is_empty():
		return []
	var r: float = sqrt(CHI2_95 * maxf(pee, pnn)) * 1.2
	var c := _hyp_now_pos(best)
	return [c + Vector2(r, r), c - Vector2(r, r)]


## 带半透明底板的标签（4px padding），自动错位避免相互覆盖。
func _draw_torpedoes() -> void:
	for i in range(torpedoes.size()):
		var tp: Dictionary = torpedoes[i]
		var col := Color(1.0, 0.3, 0.2)
		if str(tp.get("state", "")) == "PURSUIT":
			col = Color(1.0, 0.6, 0.1)
		var pts: Array = tp.get("trail", [])
		var prev: Vector2 = Vector2.ZERO
		for j in range(pts.size()):
			var p := Vector2(float(pts[j]["e"]), float(pts[j]["n"]))
			var s := world_to_screen(p)
			if j > 0:
				draw_line(prev, s, Color(col.r, col.g, col.b, 0.55), 1.5)
			prev = s
		if not pts.is_empty():
			var head := world_to_screen(Vector2(float(pts[-1]["e"]), float(pts[-1]["n"])))
			draw_circle(head, 3.5, col)
			_draw_label(
				head + Vector2(6.0, -6.0), "TK%d %s" % [i + 1, str(tp.get("state", ""))], col, 12
			)


func _draw_label(pos: Vector2, text: String, col: Color, font_px: int = 14) -> void:
	var fs: int = maxi(font_px, 14)
	var w: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var rect := Rect2(pos - Vector2(4, fs), Vector2(w + 8.0, fs + 6.0))
	for b in _label_boxes:
		if (b as Rect2).intersects(rect):
			rect.position.y += (b as Rect2).size.y + 2.0
	_label_boxes.append(rect)
	draw_rect(rect, Color(0.02, 0.05, 0.07, 0.75))
	draw_string(
		_font, rect.position + Vector2(4, fs - 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col
	)


func _draw_camera_overlays() -> void:
	# 比例尺（左下）
	var bar_m: float = _nice_step(view_radius_m / 3.0)
	var bar_px: float = bar_m * _scale_px()
	var y: float = size.y - 22.0
	draw_line(Vector2(10, y), Vector2(10 + bar_px, y), Color(1, 1, 1, 0.85), 2.5)
	draw_line(Vector2(10, y - 4), Vector2(10, y + 4), Color(1, 1, 1, 0.85), 2.0)
	draw_line(Vector2(10 + bar_px, y - 4), Vector2(10 + bar_px, y + 4), Color(1, 1, 1, 0.85), 2.0)
	draw_string(
		_font,
		Vector2(12, y - 8),
		_dist_label(bar_m),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(1, 1, 1, 0.9)
	)
	# 北向标记（右上）：箭头 + N
	var nc := Vector2(size.x - 24.0, 30.0)
	draw_line(nc, nc + Vector2(0, 22), Color(1, 1, 1, 0.8), 2.0)
	var head := PackedVector2Array([nc + Vector2(0, -8), nc + Vector2(5, 2), nc + Vector2(-5, 2)])
	draw_colored_polygon(head, Color(1, 1, 1, 0.9))
	draw_string(
		_font, nc + Vector2(-4, 36), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.9)
	)
	# 图例（右下）
	var lg := Vector2(size.x - 190.0, size.y - 92.0)
	var items := [
		["Best Fit", COL_BEST],
		["Alt A/B/C", ALT_COLORS[0]],
		["Trial", COL_TRIAL],
		["System", COL_SYSTEM],
		["Outlier", COL_OUTLIER],
	]
	var ly: float = lg.y
	for it in items:
		draw_line(Vector2(lg.x, ly + 5.0), Vector2(lg.x + 22.0, ly + 5.0), it[1] as Color, 2.5)
		draw_string(
			_font,
			Vector2(lg.x + 28.0, ly + 9.0),
			it[0] as String,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(1, 1, 1, 0.85)
		)
		ly += 18.0


func _mmss(t: float) -> String:
	var s: int = int(maxf(t, 0.0))
	return "%02d:%02d" % [s / 60, s % 60]
