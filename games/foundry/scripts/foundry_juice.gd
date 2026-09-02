class_name FoundryJuice
extends RefCounted
## 买量风手感包装（v2.6）：震屏 / 撒花粒子，纯静态工具，无状态


## 屏幕震动：抖动 root 的 position 并归零（root 通常是主界面 Control）
static func shake(root: Control, intensity := 8.0, dur := 0.4) -> void:
	var origin: Vector2 = root.position
	var steps := 6
	var tw := root.create_tween()
	for i in steps:
		var k := 1.0 - float(i) / float(steps)
		var off := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * intensity * k
		tw.tween_property(root, "position", origin + off, dur / float(steps))
	tw.tween_property(root, "position", origin, dur / float(steps))


## 撒花：从 center 向下抛撒彩色小方块，落幕后自毁
static func confetti(parent: Control, center: Vector2, count := 36) -> void:
	var colors: Array[Color] = [
		Color("#FFB84D"),
		Color("#FFD700"),
		Color("#7ED957"),
		Color("#FF6B6B"),
		Color("#6BCBFF"),
		Color("#FFFFFF"),
	]
	for i in count:
		var r := ColorRect.new()
		r.color = colors[i % colors.size()]
		r.size = Vector2(10, 10)
		r.position = center + Vector2(randf_range(-60, 60), randf_range(-30, 10))
		r.rotation = randf_range(0.0, TAU)
		r.z_index = 300
		parent.add_child(r)
		var target := r.position + Vector2(randf_range(-180, 180), randf_range(260, 440))
		var tw := parent.create_tween()
		tw.set_parallel(true)
		(
			tw
			. tween_property(r, "position", target, randf_range(0.9, 1.5))
			. set_trans(Tween.TRANS_QUAD)
			. set_ease(Tween.EASE_IN)
		)
		tw.tween_property(r, "rotation", r.rotation + randf_range(-7.0, 7.0), 1.4)
		tw.chain().tween_callback(r.queue_free)


## 按钮弹跳：以中心为轴快速缩放一下
static func pop(btn: Control, amount := 1.1) -> void:
	btn.pivot_offset = btn.size / 2.0
	var tw := btn.create_tween()
	tw.tween_property(btn, "scale", Vector2.ONE * amount, 0.08)
	tw.tween_property(btn, "scale", Vector2.ONE, 0.14)
