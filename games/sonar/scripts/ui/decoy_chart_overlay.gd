class_name DecoyChartOverlay
extends RefCounted
## decoy_chart_overlay.gd — P1-C DC-04：己方诱饵图层的海图绘制（纯绘制 + 纯文案）。
##
##   图标位置走与本艇/鱼雷/航线**同一个** chart.world_to_screen（平移/缩放/改窗口
##   完全一致）；选中才展开轨迹（轨迹是世界坐标，与视图无关）。
##   有遥测 → 标"实测"；无遥测 → 标"程序估计"并计龄；绝不把估计冒充实测。
##   已退出活动图层的历史条目：只画暗淡轨迹 + 小点并标"已过期"，不参与命中。

const COL_DECOY := Color(0.45, 1.0, 0.75)
const COL_DECOY_SEL := Color(1.0, 0.95, 0.55)
const COL_JAMMER := Color(1.0, 0.7, 0.35)
const COL_HISTORY := Color(0.55, 0.6, 0.65)
const ICON_R: float = 5.0
const MAX_TRAIL_PTS: int = 64
const HISTORY_ALPHA: float = 0.35


## 图标文案。未选中 1 行（短 ID + 类型 + 状态 + 实测/程序估计 + 计龄）；
## 选中展开方向/速度/剩余寿命/深度（全部来自 DTO，不读 Truth）。
static func label_lines(row: Dictionary, now: float) -> Array:
	var sid: String = ContactChartOverlay.short_id(str(row.get("id", "")))
	var tname: String = UiText.decoy(str(row.get("type", "")))
	var st: String = UiText.decoy_state(str(row.get("state", "")))
	var measured: bool = bool(row.get("measured", true))
	# 计龄 = 距最近一次遥测/估计更新的时间（now - updated_time），不是诱饵自身寿命年龄。
	var age_s: float = maxf(now - float(row.get("updated_time", now)), 0.0)
	var src: String = (
		UiText.t("decoy_src_measured") if measured else UiText.t("decoy_src_estimated")
	)
	var head: String = "%s %s" % [sid, tname]
	var age_txt: String = ChartCameraOverlay.mmss(age_s)
	if not bool(row.get("selected", false)):
		return ["%s %s %s %s" % [head, st, src, age_txt]]
	var out: Array = [head]
	out.append("%s · %s · 计龄 %s" % [st, src, age_txt])
	out.append(
		"方向 %.0f° / %.1f 节" % [float(row.get("course_deg", 0.0)), float(row.get("speed_kn", 0.0))]
	)
	var life: float = float(row.get("lifetime_s", 0.0))
	if life > 0.0:
		out.append("剩余寿命 %.0f 秒" % maxf(life - float(row.get("age_s", 0.0)), 0.0))
	if row.has("depth"):
		out.append("深度 %.0f 米" % float(row.get("depth", 0.0)))
	return out


## 绘制活动图层（含选中展开轨迹）+ 历史图层（暗淡、不可选中）。
static func draw(chart: ChartView, layer: DecoyMapLayer, now: float) -> void:
	if layer == null:
		return
	_draw_history(chart, layer)
	for r in layer.active:
		_draw_row(chart, r as Dictionary, now)


static func _draw_history(chart: ChartView, layer: DecoyMapLayer) -> void:
	var col := Color(COL_HISTORY.r, COL_HISTORY.g, COL_HISTORY.b, HISTORY_ALPHA)
	for id in layer.history.keys():
		var rec: Dictionary = layer.history[id]
		var tr: Array = layer.tracks.get(str(id), [])
		var start: int = maxi(tr.size() - MAX_TRAIL_PTS, 0)
		for i in range(start, tr.size()):
			chart.draw_circle(chart.world_to_screen(tr[i]), 1.4, col)
		var at := world_of(rec)
		if tr.is_empty():
			chart.draw_circle(chart.world_to_screen(at), 1.8, col)


static func _draw_row(chart: ChartView, row: Dictionary, now: float) -> void:
	var sel: bool = bool(row.get("selected", false))
	var col: Color = (
		COL_DECOY_SEL
		if sel
		else (COL_JAMMER if str(row.get("type", "")) == DecoyProgram.TYPE_JAMMER else COL_DECOY)
	)
	var at := chart.world_to_screen(world_of(row))
	# 选中：展开世界坐标轨迹（与视图无关，改窗口/缩放不改变轨迹本身）。
	if sel:
		var tr: Array = row.get("trail", [])
		var start: int = maxi(tr.size() - MAX_TRAIL_PTS, 0)
		var prev: Vector2 = Vector2.ZERO
		for i in range(start, tr.size()):
			var s: Vector2 = chart.world_to_screen(tr[i])
			if i > start:
				chart.draw_line(prev, s, Color(col.r, col.g, col.b, 0.5), 1.2)
			prev = s
	# 图标：菱形 + 方向短线（方向来自诱饵实际航向，不是本艇航向）。
	_diamond(chart, at, col, 1.0)
	var dir := NavUtils.bearing_to_screen_dir(float(row.get("course_deg", 0.0)))
	chart.draw_line(at, at + dir * (ICON_R + 7.0), Color(col.r, col.g, col.b, 0.9), 1.5)
	if not bool(row.get("measured", true)):
		# 程序估计：额外的空心圈，视觉上不冒充实测图标。
		chart.draw_arc(at, ICON_R + 3.0, 0.0, TAU, 18, Color(col.r, col.g, col.b, 0.6), 1.0)
	if sel:
		chart.draw_arc(at, ICON_R + 7.0, 0.0, TAU, 22, Color(1, 1, 1, 0.85), 1.6)
	var lines: Array = label_lines(row, now)
	var off: float = 0.0
	for s in lines:
		chart._draw_label(
			at + Vector2(ICON_R + 6.0, -6.0 + off), str(s), col, 11 if not sel else 12
		)
		off += 15.0


static func world_of(row: Dictionary) -> Vector2:
	return Vector2(float(row.get("e", 0.0)), float(row.get("n", 0.0)))


static func _diamond(chart: ChartView, at: Vector2, col: Color, alpha: float) -> void:
	var pts := PackedVector2Array(
		[
			at + Vector2(0, -ICON_R),
			at + Vector2(ICON_R, 0),
			at + Vector2(0, ICON_R),
			at + Vector2(-ICON_R, 0),
		]
	)
	chart.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(col.r, col.g, col.b, alpha), 1.5)
