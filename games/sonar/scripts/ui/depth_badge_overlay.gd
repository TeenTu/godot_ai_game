class_name DepthBadgeOverlay
extends RefCounted
## depth_badge_overlay.gd — S1-11 §7.4：敌方深度概率的地图表达（ChartView 专用）。
##
## 视觉语义（严格区分"有证据"与"未知"，绝不画伪精确敌方深度点）：
##   选中的接触      → 沿最新 LOB 标注文字：可能上层 72% / 可能下层 61% /
##                     可能 80–140m（95%）/ 深度未知；
##   未选中的接触    → 只画一个小型层带符号（实心菱形=已知主导层；空心问号=未知）。
##
## 输入只允许 {origin, bearing_deg, text, selected, known, layer} —— 全部来自
## Track 自己的 LOB 与 DepthEstimator 摘要，绝不含 TruthEntity / target_id。

const SYMBOL_DIST_PX: float = 190.0
const COL_KNOWN := Color(0.98, 0.88, 0.45, 0.95)
const COL_UNKNOWN := Color(0.72, 0.78, 0.82, 0.85)
const COL_SEL := Color(0.99, 0.93, 0.62, 1.0)
## 主导层 → 单字短标（与深度条/预设同一套中文词）。
const LAYER_GLYPH := {
	"SURFACE_LIKELY": "面",
	"UPPER_LIKELY": "上",
	"LOWER_LIKELY": "下",
}


static func draw(chart: ChartView, badges: Array, _sim_now: float) -> void:
	if chart == null or badges.is_empty():
		return
	for b in badges:
		if not (b is Dictionary):
			continue
		var origin: Vector2 = b.get("origin", Vector2.ZERO)
		var bearing: float = float(b.get("bearing_deg", 0.0))
		var p: Vector2 = (
			chart.world_to_screen(origin) + NavUtils.bearing_to_screen_dir(bearing) * SYMBOL_DIST_PX
		)
		var selected: bool = bool(b.get("selected", false))
		var known: bool = bool(b.get("known", false))
		if selected:
			chart._draw_label(p, str(b.get("text", UiText.t("depth_band_unknown"))), COL_SEL, 12)
			continue
		# 未选中：小型符号（减载——不写字，只留一个双编码符号：形状 + 颜色）。
		if known:
			chart.draw_colored_polygon(
				PackedVector2Array(
					[
						p + Vector2(0.0, -5.0),
						p + Vector2(5.0, 0.0),
						p + Vector2(0.0, 5.0),
						p + Vector2(-5.0, 0.0)
					]
				),
				COL_KNOWN
			)
		else:
			chart.draw_arc(p, 4.5, 0.0, TAU, 16, COL_UNKNOWN, 1.0)
			chart._draw_label(p + Vector2(6.0, -3.0), "?", COL_UNKNOWN, 10)
