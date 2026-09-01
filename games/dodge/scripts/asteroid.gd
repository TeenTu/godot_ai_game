class_name Asteroid
extends Node2D
## 陨石：AI 生成的贴图（共享 props_sheet 帧 0-2 随机），下落 + 自旋，出屏自毁。
## near_miss_done：擦身奖励一次性标记（由主控读写）。

const FALL_SPEED_BASE: float = 300.0
const DESPAWN_Y: float = 1250.0
## 共享雪碧图（由 shared/assets 注入到 assets/_shared/items/）。
const PROPS_TEXTURE: String = "res://assets/_shared/items/props_sheet.png"
const FRAME: int = 128  # 每帧 128x128

var radius: float = 26.0
var fall_speed: float = 300.0
var near_miss_done: bool = false
var _rot_speed: float = 1.0
var _frame_index: int = 0
var _tex: Texture2D = null
var _verts: PackedVector2Array = PackedVector2Array()
var _shade: Color = Color(0.55, 0.55, 0.62)


func setup(rng: RandomNumberGenerator, score: float) -> void:
	radius = rng.randf_range(18.0, 38.0)
	fall_speed = FALL_SPEED_BASE + score * 12.0 + rng.randf_range(-40.0, 80.0)
	_rot_speed = rng.randf_range(-2.2, 2.2)
	_frame_index = rng.randi_range(0, 2)  # props_sheet 帧 0-2 是三种陨石
	_tex = load(PROPS_TEXTURE) as Texture2D
	if _tex == null:
		# 兜底：程序化随机多边形。
		var n := rng.randi_range(7, 9)
		for i in n:
			var angle: float = TAU * float(i) / float(n)
			var r: float = radius * rng.randf_range(0.72, 1.12)
			_verts.append(Vector2.from_angle(angle) * r)
		var tone := rng.randf_range(0.45, 0.65)
		_shade = Color(tone, tone, tone + 0.06)
	queue_redraw()


func _process(delta: float) -> void:
	position.y += fall_speed * delta
	rotation += _rot_speed * delta
	if position.y > DESPAWN_Y:
		queue_free()
	queue_redraw()


func _draw() -> void:
	if _tex != null:
		var region := Rect2(Vector2(_frame_index * FRAME, 0.0), Vector2(FRAME, FRAME))
		# 绘制尺寸 ≈ 直径 * 1.15（留描边余量），自旋跟随节点 rotation。
		var dst := Rect2(-radius * 1.15, -radius * 1.15, radius * 2.3, radius * 2.3)
		draw_texture_rect_region(_tex, dst, region)
	elif not _verts.is_empty():
		draw_colored_polygon(_verts, _shade)
		draw_arc(Vector2.ZERO, radius * 0.94, 0, TAU, 24, Color(1, 1, 1, 0.14), 2.0, true)
	else:
		draw_circle(Vector2.ZERO, radius, _shade)
