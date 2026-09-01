class_name Powerup
extends Node2D
## 护盾道具：AI 生成的贴图（共享 props_sheet 帧 3），缓慢下落，拾取后获得一次性护盾。

const FALL_SPEED: float = 130.0
const DESPAWN_Y: float = 1250.0
const RADIUS: float = 15.0
## 共享雪碧图（由 shared/assets 注入到 assets/_shared/items/）。
const PROPS_TEXTURE: String = "res://assets/_shared/items/props_sheet.png"
const FRAME: int = 128
const SHIELD_FRAME_INDEX: int = 3

var _tex: Texture2D = null


func _ready() -> void:
	_tex = load(PROPS_TEXTURE) as Texture2D
	queue_redraw()


func _process(delta: float) -> void:
	position.y += FALL_SPEED * delta
	if position.y > DESPAWN_Y:
		queue_free()
	queue_redraw()


func _draw() -> void:
	var pulse: float = sin(Time.get_ticks_msec() * 0.006) * 2.0
	# 呼吸光晕（程序化，贴图之外）。
	draw_circle(Vector2.ZERO, RADIUS + pulse, Color(0.2, 0.9, 0.55, 0.28))
	if _tex != null:
		var region := Rect2(Vector2(SHIELD_FRAME_INDEX * FRAME, 0.0), Vector2(FRAME, FRAME))
		var dst := Rect2(-RADIUS * 1.4, -RADIUS * 1.4, RADIUS * 2.8, RADIUS * 2.8)
		draw_texture_rect_region(_tex, dst, region)
	else:
		# 兜底：程序化十字徽章。
		draw_circle(Vector2.ZERO, RADIUS, Color(0.2, 0.9, 0.55, 0.9))
		draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 24, Color(1, 1, 1, 0.7), 2.0, true)
		draw_rect(Rect2(-3.5, -9, 7, 18), Color.WHITE)
		draw_rect(Rect2(-9, -3.5, 18, 7), Color.WHITE)
