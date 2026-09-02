class_name WaypointLayer
extends Control
## M3 目标指示（design_boom.md §7.3）：离屏最近敌人 → unproject 投影 →
## 吸附屏幕边缘的箭头 + 距离数字。Control 纯绘制，不占 3D 视口性能。

const MARGIN: float = 46.0
const MAX_MARKERS: int = 2

var cam: Camera3D = null
var game: BoomGame = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if cam == null or game == null:
		return
	var view := get_viewport_rect().size
	var ranked: Array = []
	for e in game.enemies:
		var jelly := e as BoomJelly
		if jelly == null or jelly.is_dead() or jelly.hp <= 0:
			continue
		ranked.append([game.player.position.distance_to(jelly.position), jelly])
	ranked.sort_custom(func(a: Variant, b: Variant) -> bool: return a[0] < b[0])
	var font := get_theme_default_font()
	var count: int = mini(MAX_MARKERS, ranked.size())
	for i in count:
		var jelly := ranked[i][1] as BoomJelly
		var wp: Vector3 = jelly.position + Vector3(0.0, 0.6, 0.0)
		if cam.is_position_behind(wp):
			continue
		# unproject 结果是窗口像素坐标，转回 720×1280 设计空间。
		var sp: Vector2 = (
			get_viewport().get_canvas_transform().affine_inverse() * cam.unproject_position(wp)
		)
		if (
			sp.x >= MARGIN
			and sp.x <= view.x - MARGIN
			and sp.y >= MARGIN
			and sp.y <= view.y - MARGIN
		):
			continue
		var center := view * 0.5
		var dir := sp - center
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		# 沿方向射线求与内缩矩形边的最小交点（边缘吸附）。
		var s := INF
		if dir.x > 0.0:
			s = minf(s, (center.x - MARGIN) / dir.x)
		if dir.x < 0.0:
			s = minf(s, (MARGIN - center.x) / dir.x)
		if dir.y > 0.0:
			s = minf(s, (center.y - MARGIN) / dir.y)
		if dir.y < 0.0:
			s = minf(s, (MARGIN - center.y) / dir.y)
		if s == INF or s < 0.0:
			continue
		var edge := center + dir * s
		var col := Color(0.55, 0.9, 0.5, 0.9)
		var ang := dir.angle()
		var pts := PackedVector2Array(
			[
				Vector2(16.0, 0.0),
				Vector2(-9.0, 9.0),
				Vector2(-9.0, -9.0),
			]
		)
		var world_pts := PackedVector2Array()
		for p in pts:
			world_pts.append(edge + (p as Vector2).rotated(ang))
		draw_colored_polygon(world_pts, col)
		# 距离数字（米）画在箭头内侧。
		if font != null:
			var dist_text := "%dm" % int(ranked[i][0])
			var fs := 18
			var ts := font.get_string_size(dist_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			var tp := edge - dir * 30.0 - Vector2(ts.x * 0.5, -ts.y * 0.35)
			draw_string(font, tp, dist_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8))
