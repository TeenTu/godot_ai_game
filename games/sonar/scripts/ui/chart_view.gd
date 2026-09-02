class_name ChartView
extends Control
## chart_view.gd — 海图（俯视图）。阶段三 TMA 重构版。
##
## 数据源由外部（main_ui）每帧注入，本组件只负责绘制：
##   - 本艇位置（蓝三角）与历史航迹
##   - 历史 LOB：从各自测量时刻的本艇位置发出，越旧透明度越低，
##     带 ±2σ 方位不确定扇区，离群测量虚线（需求文档第九节 1）
##   - 自动拟合目标轨迹：完整运动线 + 时间刻度（每个刻度落在对应
##     测量时刻的 LOB 上——判断 TMA 正确与否的最直接可视化）
##   - 备选解：细虚线，不同低饱和度颜色
##   - 当前位置不确定区域（单峰可观测解才显示，禁止多峰画小椭圆）
##   - 外推预测位置与不确定区（随外推时间扩大）
##   - Show Truth 时叠加真实目标位置（红色方块，仅 Developer Debug）
##
## 坐标映射：以本艇当前位置为中心，固定视野半径 view_radius_m。

const TICK_RADIUS_PX: float = 3.5
const PRED_HORIZON_S: float = 600.0  # 外推预测时长
const BACK_HORIZON_S: float = 900.0  # 轨迹向后回溯时长

# 备选解低饱和度调色板
const ALT_COLORS: Array = [
	Color(0.55, 0.65, 0.85),
	Color(0.6, 0.8, 0.65),
	Color(0.75, 0.65, 0.85),
	Color(0.8, 0.7, 0.55),
]

var view_radius_m: float = 10000.0  # 视野半径（米），本艇居中

# 注入数据（每帧由 main_ui 更新）
var own_pos: Vector2 = Vector2.ZERO  # 本艇当前位置（世界坐标，东/北）
var own_track: Array = []  # 本艇历史位置点（世界坐标）
# LOB: [{origin: Vector2, bearing_deg: float, color: Color, id: String,
#        age_s: float, sigma_deg: float, inlier: bool}]
var lobs: Array = []
var trial_pos: Vector2 = Vector2.ZERO  # Trial Solution 目标符号位置
var trial_active: bool = false
var trial_velocity: Vector2 = Vector2.ZERO  # Trial Solution 速度向量（米/秒）
var system_pos: Vector2 = Vector2.ZERO  # System Solution 目标符号位置
var system_active: bool = false
var truth_positions: Array = []  # [{pos: Vector2, id: String}] 调试用
var show_truth: bool = false

# --- 自动拟合结果（TmaFitResult 注入） ---
# hypotheses: [{p_ref: Vector2, v_ms: Vector2, t_ref: float, weight: float,
#               is_best: bool, speed_kn: float, course_deg: float}]
var fit_hypotheses: Array = []
var fit_meas_times: Array = []  # [float] 用于画轨迹时间刻度
var fit_pos_unc_m: float = -1.0  # <0 表示无可信不确定度
var fit_now_time: float = 0.0  # 当前仿真时间（外推用）
var fit_stale_s: float = 0.0

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


## 世界坐标 → 屏幕坐标（本艇居中）。
func world_to_screen(w: Vector2) -> Vector2:
	var scale: float = minf(size.x, size.y) / (2.0 * view_radius_m)
	var d: Vector2 = w - own_pos
	return Vector2(size.x * 0.5 + d.x * scale, size.y * 0.5 - d.y * scale)


## 屏幕坐标 → 世界坐标（供鼠标点击反算，TMA 尺用）。
func screen_to_world(s: Vector2) -> Vector2:
	var scale: float = minf(size.x, size.y) / (2.0 * view_radius_m)
	var d: Vector2 = (s - Vector2(size.x * 0.5, size.y * 0.5)) / scale
	return own_pos + Vector2(d.x, -d.y)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	# 背景
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.08, 0.10, 1.0))
	# 网格（每 2000m 一格）
	var grid_m: float = 2000.0
	var scale: float = minf(size.x, size.y) / (2.0 * view_radius_m)
	var grid_px: float = grid_m * scale
	if grid_px >= 10.0:
		var col := Color(0.15, 0.25, 0.28, 0.35)
		var x: float = fmod(size.x * 0.5, grid_px)
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), col, 1.0)
			x += grid_px
		var y: float = fmod(size.y * 0.5, grid_px)
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), col, 1.0)
			y += grid_px

	_draw_own_track()
	_draw_lobs()
	_draw_fit_tracks()
	_draw_symbols()
	if show_truth:
		_draw_truth()


func _draw_own_track() -> void:
	# 本艇历史轨迹（淡蓝细线）
	if own_track.size() >= 2:
		var pts: PackedVector2Array = []
		for p in own_track:
			pts.append(world_to_screen(p))
		draw_polyline(pts, Color(0.35, 0.6, 0.95, 0.5), 1.5)
	# 本艇三角符号
	var s: Vector2 = world_to_screen(own_pos)
	var tri := PackedVector2Array([s + Vector2(0, -10), s + Vector2(7, 6), s + Vector2(-7, 6)])
	draw_colored_polygon(tri, Color(0.3, 0.7, 1.0, 1.0))
	draw_string(
		_font,
		s + Vector2(8, -8),
		"OWN",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		Color(0.6, 0.85, 1.0, 0.9)
	)


func _draw_lobs() -> void:
	# 找最大 age 用于透明度衰减
	var age_max: float = 1.0
	for lob in lobs:
		age_max = maxf(age_max, float(lob.get("age_s", 0.0)))
	for lob in lobs:
		var origin: Vector2 = world_to_screen(lob["origin"])
		var bearing: float = lob["bearing_deg"]
		var col: Color = lob.get("color", Color(1.0, 0.85, 0.3, 0.6))
		# 越旧越透明
		var age: float = float(lob.get("age_s", 0.0))
		var alpha: float = clampf(1.0 - 0.7 * (age / age_max), 0.25, 1.0)
		var inlier: bool = bool(lob.get("inlier", true))
		var brad: float = deg_to_rad(bearing)
		var dir := Vector2(sin(brad), cos(brad))
		var end_w: Vector2 = lob["origin"] + dir * view_radius_m * 1.2
		var end_s: Vector2 = world_to_screen(end_w)
		if inlier:
			draw_line(origin, end_s, Color(col.r, col.g, col.b, alpha * 0.75), 1.0)
		else:
			# 被排除的离群测量 → 虚线
			_draw_dashed(origin, end_s, Color(col.r, col.g, col.b, alpha * 0.5), 1.0)
		# ±2σ 方位不确定扇区（半透明）
		var sig: float = float(lob.get("sigma_deg", 1.0))
		var wedge_len: float = minf(view_radius_m, 6000.0)
		var seg_len: float = 2500.0
		var a0: float = deg_to_rad(bearing - 2.0 * sig)
		var a1: float = deg_to_rad(bearing + 2.0 * sig)
		var wedge := PackedVector2Array(
			[
				origin,
				world_to_screen(lob["origin"] + Vector2(sin(a0), cos(a0)) * seg_len),
				world_to_screen(lob["origin"] + Vector2(sin(brad), cos(brad)) * wedge_len),
				world_to_screen(lob["origin"] + Vector2(sin(a1), cos(a1)) * seg_len),
			]
		)
		draw_colored_polygon(wedge, Color(col.r, col.g, col.b, 0.05))
		# 测量时刻本艇位置点
		draw_circle(origin, 2.0, Color(col.r, col.g, col.b, alpha))
		# 标注接触编号（只标最新一条）
		var id: String = lob.get("id", "")
		if id != "" and age < 1.0:
			var mid: Vector2 = (origin + end_s) * 0.5
			draw_string(_font, mid + Vector2(4, -4), id, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


func _draw_dashed(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var len: float = a.distance_to(b)
	if len < 1.0:
		return
	var dir: Vector2 = (b - a) / len
	var t: float = 0.0
	while t < len:
		var t2: float = minf(t + 5.0, len)
		draw_line(a + dir * t, a + dir * t2, col, width)
		t += 9.0


## 拟合轨迹：完整运动线 + 时间刻度（刻度必须落在对应 LOB 上）。
func _draw_fit_tracks() -> void:
	if fit_hypotheses.is_empty():
		return
	var t_ref: float = float(fit_hypotheses[0].get("t_ref", fit_now_time))
	var alt_idx: int = 0
	for hyp in fit_hypotheses:
		var is_best: bool = bool(hyp.get("is_best", false))
		var col: Color = (
			Color(0.95, 0.45, 0.15) if is_best else ALT_COLORS[alt_idx % ALT_COLORS.size()]
		)
		if not is_best:
			alt_idx += 1
		var p_ref := hyp["p_ref"] as Vector2
		var v := hyp["v_ms"] as Vector2
		# 轨迹线：从 t_ref - BACK 到 now + PRED
		var pts: PackedVector2Array = []
		var t0: float = t_ref - BACK_HORIZON_S
		var t1: float = fit_now_time + PRED_HORIZON_S
		var step: float = 30.0
		var tt: float = t0
		while tt <= t1:
			pts.append(world_to_screen(p_ref + v * (tt - t_ref)))
			tt += step
		if is_best:
			draw_polyline(pts, col, 2.2)
		else:
			_draw_dashed_polyline(pts, Color(col.r, col.g, col.b, 0.6))
		# 时间刻度：每个测量时刻一个刻度点（应落在对应 LOB 上）
		if is_best:
			for mt in fit_meas_times:
				var pos: Vector2 = world_to_screen(p_ref + v * (float(mt) - t_ref))
				draw_circle(pos, TICK_RADIUS_PX, Color(1.0, 1.0, 1.0, 0.95))
				draw_arc(pos, TICK_RADIUS_PX + 1.5, 0, TAU, 16, col, 1.5)
		# 外推当前位置 + 不确定区域（仅最优解）
		if is_best:
			var now_pos: Vector2 = p_ref + v * (fit_now_time - t_ref)
			var now_s: Vector2 = world_to_screen(now_pos)
			draw_circle(now_s, 4.5, col)
			if fit_pos_unc_m > 0.0:
				var unc_px: float = fit_pos_unc_m * minf(size.x, size.y) / (2.0 * view_radius_m)
				if unc_px > 2.0:
					draw_arc(now_s, unc_px, 0, TAU, 48, Color(col.r, col.g, col.b, 0.55), 1.2)
					draw_arc(now_s, unc_px * 2.0, 0, TAU, 48, Color(col.r, col.g, col.b, 0.25), 1.0)
				# 预测位置（+PRED_HORIZON）与不确定区扩大
				var pred_pos: Vector2 = world_to_screen(now_pos + v * PRED_HORIZON_S)
				draw_arc(pred_pos, 4.0, 0, TAU, 20, Color(col.r, col.g, col.b, 0.6), 1.2)
				draw_line(now_s, pred_pos, Color(col.r, col.g, col.b, 0.3), 1.0)
			var unc_m: float = maxf(fit_pos_unc_m, 0.0)
			var label := "FIT %.0fm" % p_ref.distance_to(own_pos)
			if fit_pos_unc_m >= 0.0:
				label += "±%.0f" % unc_m
			draw_string(
				_font,
				now_s + Vector2(8, 4),
				label,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				11,
				Color(col.r, col.g, col.b, 0.9)
			)
		else:
			# 备选解标注
			var alt_pos: Vector2 = world_to_screen(p_ref + v * (fit_now_time - t_ref))
			draw_circle(alt_pos, 3.0, Color(col.r, col.g, col.b, 0.8))
			draw_string(
				_font,
				alt_pos + Vector2(6, -6),
				(
					"alt %.0fkg %.0fkn"
					% [float(hyp.get("weight", 0.0)) * 100.0, float(hyp.get("speed_kn", 0.0))]
				),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				10,
				Color(col.r, col.g, col.b, 0.8)
			)


func _draw_dashed_polyline(pts: PackedVector2Array, col: Color) -> void:
	for i in range(pts.size() - 1):
		_draw_dashed(pts[i], pts[i + 1], col, 1.0)


func _draw_symbols() -> void:
	if trial_active:
		var s: Vector2 = world_to_screen(trial_pos)
		draw_circle(s, 5.0, Color(0.4, 1.0, 0.7, 0.95))
		draw_string(
			_font,
			s + Vector2(8, 4),
			"TRIAL",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			11,
			Color(0.5, 1.0, 0.8, 0.9)
		)
		# 速度向量箭头（按 trial 航向/航速画 60s 预测位移）
		if trial_velocity.length() > 0.01:
			var end_w: Vector2 = trial_pos + trial_velocity * 60.0
			var end_s: Vector2 = world_to_screen(end_w)
			draw_line(s, end_s, Color(0.4, 1.0, 0.7, 0.7), 2.0)
			# 箭头头
			var dir: Vector2 = (end_s - s).normalized()
			if dir.length() > 0.01:
				var perp: Vector2 = Vector2(-dir.y, dir.x) * 5.0
				var head: PackedVector2Array = [
					end_s, end_s - dir * 10.0 + perp, end_s - dir * 10.0 - perp
				]
				draw_colored_polygon(head, Color(0.4, 1.0, 0.7, 0.8))
	if system_active:
		var s2: Vector2 = world_to_screen(system_pos)
		draw_arc(s2, 8.0, 0, TAU, 24, Color(1.0, 1.0, 0.3, 0.95), 2.0)
		draw_string(
			_font,
			s2 + Vector2(10, 4),
			"SYSTEM",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			11,
			Color(1.0, 1.0, 0.5, 0.9)
		)


func _draw_truth() -> void:
	for t in truth_positions:
		var s: Vector2 = world_to_screen(t["pos"])
		var r := Rect2(s - Vector2(5, 5), Vector2(10, 10))
		draw_rect(r, Color(1.0, 0.25, 0.25, 0.9))
		draw_string(
			_font,
			s + Vector2(8, -2),
			t.get("id", "?"),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			11,
			Color(1.0, 0.5, 0.5, 0.9)
		)
