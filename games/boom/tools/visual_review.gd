extends SceneTree
## 使用真实渲染器输出固定场景；不能以 --headless 运行截图模式。
## --script res://tools/visual_review.gd -- --capture-dir=<absolute directory>


func _initialize() -> void:
	call_deferred("_review")


func _review() -> void:
	var capture_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: BoomPlayer = scene.sim.player
	scene.sim.set_physics_process(false)
	scene.set_physics_process(false)
	scene._select.hide()
	player.set_move(Vector2.RIGHT)
	player.physics_update(0.0, 26.0, 38.0)
	var anim: AnimatedSprite3D = player.get_node("PlayerAnim2D")
	anim.set_frame_and_progress(3, 0.4)
	player.set_move(Vector2(0.70, 0.71))
	assert(player.facing_anim == "right", "Diagonal noise must retain facing")
	player.set_move(Vector2.UP)
	player.physics_update(0.0, 26.0, 38.0)
	assert(anim.animation == "move_up", "Deliberate turn must switch facing")
	assert(anim.frame == 3, "Direction change must preserve step phase")
	assert(is_equal_approx(anim.frame_progress, 0.4), "Step progress must survive turn")
	var floor_found := false
	for child in scene.world.get_children():
		if child is MeshInstance3D and child.mesh is PlaneMesh:
			floor_found = true
			assert(child.basis.y.dot(Vector3.UP) > 0.99, "Floor must face upward")
	assert(floor_found, "Review scene must contain a floor")
	print("VISUAL_LOGIC result=PASS")
	if not capture_dir.is_empty():
		assert(DisplayServer.get_name() != "headless", "Capture needs an actual renderer")
		DirAccess.make_dir_recursive_absolute(capture_dir)
		for direction in [Vector2.DOWN, Vector2.RIGHT, Vector2.UP, Vector2.LEFT]:
			player.set_move(direction)
			player.physics_update(0.0, 26.0, 38.0)
			await create_timer(0.25).timeout
			# 模拟被冻结时仍需同步一次，确保截图身体/武器属于同一时刻。
			player.physics_update(0.0, 26.0, 38.0)
			await RenderingServer.frame_post_draw
			var path := capture_dir.path_join("move_" + player.facing_anim + ".png")
			assert(root.get_texture().get_image().save_png(path) == OK)
			print("VISUAL_CAPTURE " + path)
	scene.queue_free()
	await process_frame
	quit()
