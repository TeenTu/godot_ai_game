class_name ContactChartOverlay
extends RefCounted
## contact_chart_overlay.gd — PG-06：普通接触的海图输出与减载。
##
## 每一条接触只画**一份**物体（PG-05 已在数据侧保证 TT 与普通航迹不重复建模；
## 这里再做一次 mirror 淘汰，防同一观测驱动多个视图时出现重叠假双目标）：
##   未选中 → 简洁标记 + 短 ID + 概率分类 + 更新时间；
##   选中   → 展开估计点、误差区、历史点列与运动向量。
##
## 纯绘制 + 纯决策：决策部分（declutter / label_lines）不依赖渲染，可无头断言。

## 选中标记的误差圈绘制上限（米），避免大误差圈糊满屏。
const MAX_SEL_SIGMA_M: float = 6000.0
## 历史点列上限（选中才画）。
const MAX_HISTORY_PTS: int = 32
const VECTOR_HORIZON_S: float = 60.0


## 减载决策：把标记分成"简洁"与"展开"两组，并淘汰 mirror 条目。
## 返回 {simple: Array, expanded: Array, dropped: int}。
static func declutter(markers: Array) -> Dictionary:
	var simple: Array = []
	var expanded: Array = []
	var dropped: int = 0
	for m in markers:
		var d: Dictionary = m
		if str(d.get("mirror_of", "")) != "":
			# 同一观测已由威胁图层（TT）绘制 → 不重复画物体。
			dropped += 1
			continue
		if bool(d.get("selected", false)):
			expanded.append(d)
		else:
			simple.append(d)
	return {"simple": simple, "expanded": expanded, "dropped": dropped}


## 标记的短 ID（海图上只用短 ID，完整 ID 在侧栏/卡片里）。
static func short_id(track_id: String) -> String:
	var s: String = track_id.strip_edges()
	if s.length() <= 5:
		return s
	return s.substr(s.length() - 5, 5)


## 标记的文案行：未选中 1 行（短 ID + 分类 + 更新時刻），选中展开全部字段。
##   marker: {track_id, class_label, updated_time, has_estimate, range_m,
##            range_sigma_m, bearing_deg, is_sector, course_deg, speed_kn, epochs}
static func label_lines(marker: Dictionary, now: float) -> Array:
	var sid: String = short_id(str(marker.get("track_id", "")))
	var cls: String = str(marker.get("class_label", ""))
	var age: float = maxf(now - float(marker.get("updated_time", now)), 0.0)
	var head: String = "%s %s" % [sid, cls] if cls != "" else sid
	if not bool(marker.get("selected", false)):
		return ["%s 更新 %s" % [head, ChartCameraOverlay.mmss(age)]]
	var out: Array = [head]
	out.append("更新 %s 前" % ChartCameraOverlay.mmss(age))
	if bool(marker.get("has_estimate", false)):
		out.append("观测 %.0f°" % float(marker.get("bearing_deg", 0.0)))
		if marker.has("range_m"):
			out.append(
				(
					"距离 %.2f 千米 ±%.0f 米"
					% [
						float(marker.get("range_m", 0.0)) / 1000.0,
						float(marker.get("range_sigma_m", 0.0))
					]
				)
			)
		if bool(marker.get("is_sector", false)):
			out.append("方位误差大：仅扇区")
	else:
		out.append("仅方位（无距离证据）")
	if bool(marker.get("has_motion", false)):
		out.append(
			(
				"运动 %.0f° / %.0f 节"
				% [float(marker.get("course_deg", 0.0)), float(marker.get("speed_kn", 0.0))]
			)
		)
	return out


## 绘制：未选中简洁标记，选中展开误差区/历史/运动向量。零 Truth。
static func draw(chart: ChartView, markers: Array, now: float) -> void:
	var groups: Dictionary = declutter(markers)
	for m in groups["simple"]:
		_simple(chart, m, now)
	for m in groups["expanded"]:
		_expanded(chart, m, now)


static func _simple(chart: ChartView, m: Dictionary, now: float) -> void:
	var col: Color = ChartView.COL_CONTACT
	var has_est: bool = bool(m.get("has_estimate", false))
	var at: Vector2 = _anchor(chart, m)
	_diamond(chart, at, col, 0.95)
	# 有估计点：小十字 + 方位短线（比误差区轻，未选中不糊屏）。
	if has_est:
		chart.draw_line(at + Vector2(-4, 0), at + Vector2(4, 0), col, 1.0)
		chart.draw_line(at + Vector2(0, -4), at + Vector2(0, 4), col, 1.0)
	var lines: Array = label_lines(m, now)
	chart._draw_label(at + Vector2(9, -6), str(lines[0]), col, 11)


static func _expanded(chart: ChartView, m: Dictionary, now: float) -> void:
	var col: Color = ChartView.COL_CONTACT_SEL
	var at: Vector2 = _anchor(chart, m)
	var scl: float = chart._scale_px()
	# 误差区（有估计才画；大误差截断，避免糊满屏）。
	if bool(m.get("has_estimate", false)):
		var sig: float = clampf(float(m.get("sigma_m", 0.0)), 0.0, MAX_SEL_SIGMA_M)
		if sig > 0.0:
			chart.draw_arc(at, sig * scl, 0.0, TAU, 64, Color(col.r, col.g, col.b, 0.7), 1.5)
		_diamond(chart, at, col, 1.0)
	# 历史点列（时间序）。
	var hist: Array = m.get("history", [])
	var n: int = hist.size()
	var start: int = maxi(n - MAX_HISTORY_PTS, 0)
	for i in range(start, n):
		var p: Vector2 = chart.world_to_screen(hist[i])
		chart.draw_circle(p, 1.6, Color(col.r, col.g, col.b, 0.55))
	# 运动向量。
	if bool(m.get("has_motion", false)):
		var spd_mps: float = NavUtils.kn_to_ms(float(m.get("speed_kn", 0.0)))
		var tip: Vector2 = (
			_anchor_world(m)
			+ (
				NavUtils.bearing_to_world_dir(float(m.get("course_deg", 0.0)))
				* spd_mps
				* VECTOR_HORIZON_S
			)
		)
		chart.draw_line(at, chart.world_to_screen(tip), Color(col.r, col.g, col.b, 0.95), 2.0)
		_diamond(chart, at, col, 1.0)
	var lines: Array = label_lines(m, now)
	var off: float = 0.0
	for s in lines:
		chart._draw_label(at + Vector2(11, 14 + off), str(s), Color(col.r, col.g, col.b, 0.95), 12)
		off += 15.0


static func _anchor(chart: ChartView, m: Dictionary) -> Vector2:
	return chart.world_to_screen(_anchor_world(m))


## 估计点优先；无估计 → 用"本艇位置 + 方位"上的示意点（不假装有距离）。
static func _anchor_world(m: Dictionary) -> Vector2:
	if bool(m.get("has_estimate", false)):
		return Vector2(float(m.get("east_m", 0.0)), float(m.get("north_m", 0.0)))
	var obs := Vector2(float(m.get("observer_east_m", 0.0)), float(m.get("observer_north_m", 0.0)))
	if bool(m.get("bearing_known", false)):
		return obs + NavUtils.bearing_to_world_dir(float(m.get("bearing_deg", 0.0))) * 1500.0
	return obs


static func _diamond(chart: ChartView, at: Vector2, col: Color, alpha: float) -> void:
	var pts := PackedVector2Array(
		[at + Vector2(0, -5), at + Vector2(5, 0), at + Vector2(0, 5), at + Vector2(-5, 0)]
	)
	chart.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(col.r, col.g, col.b, alpha), 1.5)
