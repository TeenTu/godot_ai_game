class_name ThreatChartOverlay
extends RefCounted
## threat_chart_overlay.gd — S109 §4.5 威胁估计的海图表达（ChartView 专用）。
##
## 输入只允许 ThreatTrackManager.ui_snapshots() 的净化 DTO（§2.3 禁止字段
## 由快照构造保证）；纯绘制、零状态。
##
## 视觉语义（§4.5）：
##   已收敛   → 鱼雷估计符号（按估计航向）+ 95% 误差椭圆 + 60s 速度向量；
##   未收敛   → 概率走廊（大 95% 椭圆）+ 中心小十字，无精确符号、无速度向量；
##   RANGE_AIDED → 融合后短时高亮（不永久 Truth 风格）；
##   COASTING → 降低透明度 + "COAST" 标签（椭圆自然随协方差扩大）；
##   LOST     → 保留 LOST_HOLD_S 秒后不再绘制（移出主要视图）。

const COL_EST := Color(1.0, 0.32, 0.28)
const COL_ELLIPSE := Color(1.0, 0.45, 0.4, 0.85)
const COL_VECTOR := Color(1.0, 0.6, 0.5, 0.9)
const LOST_HOLD_S: float = 180.0
const AIDED_HIGHLIGHT_S: float = 10.0
const VECTOR_HORIZON_S: float = 60.0


static func draw(chart: ChartView, snaps: Array, sim_now: float) -> void:
	for s in snaps:
		var st: String = str(s.get("state", ""))
		var age: float = sim_now - float(s.get("last_update_time", sim_now))
		if st == "LOST" and age > LOST_HOLD_S:
			continue
		var alpha: float = 0.8
		if st == "COASTING":
			alpha = 0.45
		elif st == "LOST":
			alpha = 0.3
		elif st == "RANGE_AIDED" and age < AIDED_HIGHLIGHT_S:
			alpha = 1.0
		var cen_e: Variant = s.get("draw_center_e_m")
		var cen_n: Variant = s.get("draw_center_n_m")
		if cen_e == null or cen_n == null:
			continue
		var center := Vector2(float(cen_e), float(cen_n))
		_ellipse(
			chart,
			center,
			float(s["ellipse_a_m"]),
			float(s["ellipse_b_m"]),
			float(s.get("ellipse_angle_deg", 0.0)),
			alpha
		)
		if bool(s.get("converged", false)):
			_symbol(chart, center, float(s.get("course_est_deg", 0.0)), alpha)
			_vector(chart, s, center, alpha)
		else:
			_cross(chart, center, alpha)
		var lab: String = "%s %s" % [str(s.get("track_id", "?")), st]
		if s.get("range_est_m") != null:
			lab += " 距%.0f±%.0f 米" % [float(s["range_est_m"]), float(s.get("range_sigma_m", 0.0))]
		if st == "COASTING":
			lab += " 外推"
		chart._draw_label(
			chart.world_to_screen(center) + Vector2(11, 14),
			lab,
			Color(COL_EST.r, COL_EST.g, COL_EST.b, alpha),
			13
		)


static func _ellipse(
	chart: ChartView, center: Vector2, a_m: float, b_m: float, angle_deg: float, alpha: float
) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	var rot: float = deg_to_rad(angle_deg)
	for i in range(33):
		var th: float = TAU * float(i) / 32.0
		var lx: float = a_m * cos(th)
		var ly: float = b_m * sin(th)
		var w: Vector2 = center + Vector2(lx, ly).rotated(rot)
		pts.append(chart.world_to_screen(w))
	chart.draw_polyline(pts, Color(COL_ELLIPSE.r, COL_ELLIPSE.g, COL_ELLIPSE.b, alpha), 1.5)


static func _symbol(chart: ChartView, center: Vector2, course_deg: float, alpha: float) -> void:
	var at: Vector2 = chart.world_to_screen(center)
	var pts: PackedVector2Array = PackedVector2Array()
	for p in [Vector2(0, -7), Vector2(-5, 5), Vector2(5, 5)]:
		pts.append(at + p.rotated(deg_to_rad(course_deg)))
	chart.draw_polygon(pts, PackedColorArray([Color(COL_EST.r, COL_EST.g, COL_EST.b, alpha)]))


static func _vector(chart: ChartView, s: Dictionary, center: Vector2, alpha: float) -> void:
	if s.get("speed_est_kn") == null or s.get("course_est_deg") == null:
		return
	var spd_mps: float = float(s["speed_est_kn"]) / 1.94384
	var tip: Vector2 = (
		center
		+ (
			Vector2(
				sin(deg_to_rad(float(s["course_est_deg"]))),
				cos(deg_to_rad(float(s["course_est_deg"])))
			)
			* spd_mps
			* VECTOR_HORIZON_S
		)
	)
	chart.draw_line(
		chart.world_to_screen(center),
		chart.world_to_screen(tip),
		Color(COL_VECTOR.r, COL_VECTOR.g, COL_VECTOR.b, alpha),
		2.0
	)


static func _cross(chart: ChartView, center: Vector2, alpha: float) -> void:
	var at: Vector2 = chart.world_to_screen(center)
	var col := Color(COL_ELLIPSE.r, COL_ELLIPSE.g, COL_ELLIPSE.b, alpha)
	chart.draw_line(at + Vector2(-5, 0), at + Vector2(5, 0), col, 1.5)
	chart.draw_line(at + Vector2(0, -5), at + Vector2(0, 5), col, 1.5)
