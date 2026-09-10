extends SceneTree
## 使用真实渲染器输出固定场景；不能以 --headless 运行截图模式。
## --script res://tools/visual_review.gd -- --capture-dir=<absolute directory>


func _initialize() -> void:
	call_deferred("_review")


func _review() -> void:
	var capture_dir := ""
	var capture_horde := false
	var capture_ui := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
		elif arg == "--horde":
			capture_horde = true
		elif arg == "--ui":
			capture_ui = true
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: BoomPlayer = scene.sim.player
	print(
		(
			"VISUAL_UI_GEOM select=%s background=%s"
			% [scene._select.size, scene._select.get_child(0).size]
		)
	)
	print(
		(
			"VISUAL_FIGHT_GEOM pos=%s size=%s scale=%s text=%s"
			% [
				scene._select._fight_btn.position,
				scene._select._fight_btn.size,
				scene._select._fight_btn.scale,
				"FIGHT",
			]
		)
	)
	scene.sim.set_physics_process(false)
	scene.set_physics_process(false)
	if capture_ui and not capture_dir.is_empty():
		assert(DisplayServer.get_name() != "headless", "Capture needs an actual renderer")
		DirAccess.make_dir_recursive_absolute(capture_dir)
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		var ui_path := capture_dir.path_join("m10_weapon_tree_ui.png")
		assert(root.get_texture().get_image().save_png(ui_path) == OK)
		print("VISUAL_CAPTURE " + ui_path)
		scene._select.set_selected("greatsword")
		await create_timer(0.2).timeout
		await RenderingServer.frame_post_draw
		var brush_ui_path := capture_dir.path_join("m10_brush_tree_ui.png")
		assert(root.get_texture().get_image().save_png(brush_ui_path) == OK)
		print("VISUAL_CAPTURE " + brush_ui_path)
		scene.queue_free()
		await process_frame
		quit()
		return
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
		if capture_horde:
			scene.sim.set_weapon("greatsword")
			for index in BoomGame.MAX_ALIVE_CAP:
				var ring: int = floori(float(index) / 12.0)
				var angle := TAU * float(index % 12) / 12.0 + float(ring) * 0.16
				var radius := 3.6 + float(ring) * 2.0
				var enemy: BoomJelly = scene.sim.spawn_enemy_at(
					Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
				)
				# sim 在定帧截图中停用，直接结束出生缩放，否则所有敌人保持 scale=0。
				enemy._spawn_ttl = 0.0
				enemy.scale = Vector3.ONE * enemy.base_scale
				if enemy._art != null:
					enemy._art.modulate.a = 1.0
			var started_usec := Time.get_ticks_usec()
			for _frame in 30:
				await process_frame
			var average_ms := float(Time.get_ticks_usec() - started_usec) / 30_000.0
			await RenderingServer.frame_post_draw
			var horde_path := capture_dir.path_join("horde_48.png")
			assert(root.get_texture().get_image().save_png(horde_path) == OK)
			print(
				(
					"HORDE_RENDER enemies=%d average_frame_ms=%.2f capture=%s"
					% [scene.sim.enemies.size(), average_ms, horde_path]
				)
			)
	scene.queue_free()
	await process_frame
	quit()
