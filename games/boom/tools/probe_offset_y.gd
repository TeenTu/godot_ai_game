extends SceneTree
## 探针：实证 AnimatedSprite3D.offset 的 y 方向（正 offset.y 向上还是向下）。
## 输出 OFFSETPROBE 两行：marker 屏幕像素行。


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(256, 256)
	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 6.0
	cam.position = Vector3(0, 1.0, 5.0)
	world.add_child(cam)
	cam.current = true
	var sprite := AnimatedSprite3D.new()
	var sf := SpriteFrames.new()
	sf.add_animation("a")
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var tex := ImageTexture.create_from_image(img)
	sf.add_frame("a", tex)
	sprite.sprite_frames = sf
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.pixel_size = 0.0076
	sprite.position = Vector3(0, 1.0, 0)
	world.add_child(sprite)
	sprite.play("a")
	sprite.pause()
	# 基准帧
	await process_frame
	await RenderingServer.frame_post_draw
	var base := root.get_texture().get_image()
	# offset.y = +200px → 世界 +1.52u（若 offset 单位为像素且 y 向上）
	sprite.offset = Vector2(0, 200)
	await process_frame
	await RenderingServer.frame_post_draw
	var moved := root.get_texture().get_image()
	var base_rows := _solid_rows(base)
	var moved_rows := _solid_rows(moved)
	print("OFFSETPROBE base_rows=", base_rows, " moved_rows=", moved_rows)
	print("OFFSETPROBE y_direction=", "UP" if moved_rows.x < base_rows.x else "DOWN")
	quit(0)


func _solid_rows(img: Image) -> Vector2i:
	var first := -1
	var last := -1
	for y in img.get_height():
		for x in range(0, img.get_width(), 2):
			var p := img.get_pixel(x, y)
			if p.r > 0.9 and p.g > 0.9 and p.b > 0.9:
				if first < 0:
					first = y
				last = y
				break
	return Vector2i(first, last)
