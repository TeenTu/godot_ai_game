class_name DebugTruthOverlay
extends RefCounted
## debug_truth_overlay.gd — S109 §7.2 开发真值绘制层（ChartView 专用）。
##
## 纪律：
##   - 数据只能来自 TruthDebugProvider 快照（§2.1 调试链旁路）；
##   - 纯绘制、零内部状态：开关关闭后调用方不再注入条目 → 不残留任何真值
##     图元（AT-27）；
##   - 绘制结果不产生信号、不回流玩法层（AT-26 隔离由测试强制）。
##
## 文案暂为英文：Batch 7 全中文 + 字体 cmap CI 校验时统一翻译（避免先引入
## 未入子集字形导致 Web 豆腐块）。

const COL_SUB := Color(1.0, 0.25, 0.25, 0.9)
const COL_TORP_ENEMY := Color(1.0, 0.45, 0.1, 0.95)
const COL_TORP_FRIENDLY := Color(0.35, 0.9, 1.0, 0.95)
const COL_BEARING := Color(1.0, 0.4, 0.15, 0.35)
const WATERMARK: String = "开发真值 — 非玩家情报"


static func draw(chart: ChartView, entries: Array, own_pos: Vector2, font: Font) -> void:
	var own_s: Vector2 = chart.world_to_screen(own_pos)
	for e in entries:
		var s: Vector2 = chart.world_to_screen(e["pos"])
		if str(e.get("kind", "SUB")) == "TORPEDO":
			var col: Color = COL_TORP_ENEMY
			if str(e.get("side", "")) == "FRIENDLY":
				col = COL_TORP_FRIENDLY
			chart.draw_line(own_s, s, COL_BEARING, 1.0)
			_polygon(chart, s, float(e.get("course_deg", 0.0)), col)
			(
				chart
				. _draw_label(
					s + Vector2(9, -4),
					(
						"%s %s 真方位 %.0f° / %.1f km"
						% [
							str(e.get("debug_id", "?")),
							UiText.tp_state(str(e.get("state", ""))),
							float(e.get("bearing_from_own_deg", 0.0)),
							float(e.get("range_from_own_m", 0.0)) / 1000.0,
						]
					),
					col,
					13
				)
			)
		else:
			chart.draw_rect(Rect2(s - Vector2(6, 6), Vector2(12, 12)), COL_SUB)
			chart._draw_label(s + Vector2(9, -4), str(e.get("id", "?")), Color(1, 0.5, 0.5), 14)
	_draw_watermark(chart, font)


static func _polygon(chart: ChartView, at: Vector2, course_deg: float, col: Color) -> void:
	var out: PackedVector2Array = PackedVector2Array()
	for p in [Vector2(0, -8), Vector2(-6, 6), Vector2(6, 6)]:
		out.append(at + p.rotated(deg_to_rad(course_deg)))
	chart.draw_polygon(out, PackedColorArray([col]))


static func _draw_watermark(chart: ChartView, font: Font) -> void:
	if font == null:
		return
	var fs: int = 13
	var sz: Vector2 = font.get_string_size(WATERMARK, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var baseline: Vector2 = chart.size - Vector2(sz.x + 10.0, 12.0)
	chart.draw_rect(
		Rect2(baseline - Vector2(4, fs), Vector2(sz.x + 8.0, fs + 6.0)),
		Color(0.02, 0.05, 0.07, 0.75)
	)
	chart.draw_string(
		font, baseline, WATERMARK, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.75, 0.4, 0.9)
	)
