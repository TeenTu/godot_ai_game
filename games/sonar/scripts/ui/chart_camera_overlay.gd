class_name ChartCameraOverlay
extends RefCounted
## chart_camera_overlay.gd — 海图的**相机固定装饰层**（与目标数据无关）：
## 网格、比例尺、北向标记、图例。
##
## 从 ChartView 拆出（行数治理）：纯绘制、零状态，只读 chart 的公开视觉参数
## （view_radius_m / size / _scale_px() / world_to_screen()）。图层开关与减载
## 逻辑不在这里——这里只画"看地图的人需要的参照物"。


## 网格（世界坐标对齐，间距取 1/2/5 档）。
static func draw_grid(chart: ChartView) -> void:
	var step_m: float = nice_step(chart.view_radius_m)
	var sp: float = step_m * chart._scale_px()
	if sp < 8.0:
		return
	var col := Color(0.15, 0.25, 0.28, 0.35)
	var origin := chart.world_to_screen(Vector2.ZERO)
	var x: float = fposmod(origin.x, sp)
	while x < chart.size.x:
		chart.draw_line(Vector2(x, 0), Vector2(x, chart.size.y), col, 1.0)
		x += sp
	var y: float = fposmod(origin.y, sp)
	while y < chart.size.y:
		chart.draw_line(Vector2(0, y), Vector2(chart.size.x, y), col, 1.0)
		y += sp
	# 网格标注（左下第一格处标单位）
	chart.draw_string(
		chart._font,
		Vector2(6, chart.size.y - 6),
		dist_label(step_m),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(0.4, 0.6, 0.65, 0.8)
	)


## 比例尺 / 北向标记 / 图例（右上右下左下三处固定角标）。
static func draw_camera_overlays(chart: ChartView) -> void:
	# 比例尺（左下）
	var bar_m: float = nice_step(chart.view_radius_m / 3.0)
	var bar_px: float = bar_m * chart._scale_px()
	var y: float = chart.size.y - 22.0
	var white := Color(1, 1, 1, 0.85)
	chart.draw_line(Vector2(10, y), Vector2(10 + bar_px, y), white, 2.5)
	chart.draw_line(Vector2(10, y - 4), Vector2(10, y + 4), white, 2.0)
	chart.draw_line(Vector2(10 + bar_px, y - 4), Vector2(10 + bar_px, y + 4), white, 2.0)
	chart.draw_string(
		chart._font,
		Vector2(12, y - 8),
		dist_label(bar_m),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(1, 1, 1, 0.9)
	)
	# 北向标记（右上）：箭头 + N
	var nc := Vector2(chart.size.x - 24.0, 30.0)
	chart.draw_line(nc, nc + Vector2(0, 22), Color(1, 1, 1, 0.8), 2.0)
	var head := PackedVector2Array([nc + Vector2(0, -8), nc + Vector2(5, 2), nc + Vector2(-5, 2)])
	chart.draw_colored_polygon(head, Color(1, 1, 1, 0.9))
	chart.draw_string(
		chart._font,
		nc + Vector2(-4, 36),
		"N",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(1, 1, 1, 0.9)
	)
	# 图例（右下）——含 REQ-B3-02 威胁图层图例。
	var lg := Vector2(chart.size.x - 190.0, chart.size.y - 92.0)
	var items := [
		[UiText.t("legend_launch"), ChartView.COL_THREAT_LAUNCH],
		[UiText.t("legend_noise"), ChartView.COL_THREAT_NOISE],
		[UiText.t("legend_ping"), ChartView.COL_THREAT_PING],
		[UiText.t("legend_return"), ChartView.COL_THREAT_PING],
		[UiText.t("legend_contact"), ChartView.COL_CONTACT],
		[UiText.t("legend_contact_sel"), ChartView.COL_CONTACT_SEL],
		[UiText.t("legend_best"), ChartView.COL_BEST],
		[UiText.t("legend_alt"), ChartView.ALT_COLORS[0]],
		[UiText.t("legend_trial"), ChartView.COL_TRIAL],
		[UiText.t("legend_system"), ChartView.COL_TRIAL],
		[UiText.t("legend_outlier"), ChartView.COL_OUTLIER],
	]
	var ly: float = lg.y - 6.0 * 18.0  # 威胁 + 接触图例占额外 6 行
	for it in items:
		chart.draw_line(
			Vector2(lg.x, ly + 5.0), Vector2(lg.x + 22.0, ly + 5.0), it[1] as Color, 2.5
		)
		chart.draw_string(
			chart._font,
			Vector2(lg.x + 28.0, ly + 9.0),
			it[0] as String,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(1, 1, 1, 0.85)
		)
		ly += 18.0


## 网格/比例尺步长：1/2/5 × 10^n 档位（按可视半径挑一个合适的量级）。
static func nice_step(radius_m: float) -> float:
	var target: float = radius_m / 4.0
	var mag: float = pow(10.0, floor(log(maxf(target, 1.0)) / log(10.0)))
	for m in [1.0, 2.0, 5.0, 10.0]:
		if target <= m * mag:
			return m * mag
	return 10.0 * mag


static func dist_label(m: float) -> String:
	if m >= 1000.0:
		return "%.0f 千米" % (m / 1000.0)
	return "%.0f 米" % m


static func mmss(t: float) -> String:
	var s: int = int(maxf(t, 0.0))
	return "%02d:%02d" % [s / 60, s % 60]
