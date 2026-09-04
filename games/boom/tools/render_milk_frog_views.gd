extends SceneTree
## 只读评审工具：在统一正交镜头和灯光下输出当前奶蛙模型的正/侧/背三视图。

const MODEL_SCENE := "res://scenes/player/milk_frog_3d.tscn"
const OUTPUT_DIR := "res://assets/review/milk_frog_model"
const VIEW_SIZE := Vector2i(640, 640)


func _initialize() -> void:
	call_deferred("_render_views")


func _render_views() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var packed_model := load(MODEL_SCENE) as PackedScene
	if packed_model == null:
		push_error("Unable to load %s" % MODEL_SCENE)
		quit(1)
		return

	var viewport := SubViewport.new()
	viewport.size = VIEW_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)

	var world_root := Node3D.new()
	viewport.add_child(world_root)
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#F4EFE7")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#FFF3D9")
	environment.ambient_light_energy = 0.34
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment_node.environment = environment
	world_root.add_child(environment_node)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-38.0, -28.0, 0.0)
	key_light.light_color = Color("#FFF0CF")
	key_light.light_energy = 0.78
	key_light.shadow_enabled = true
	world_root.add_child(key_light)
	var fill_light := DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(25.0, 145.0, 0.0)
	fill_light.light_color = Color("#D9E8FF")
	fill_light.light_energy = 0.22
	world_root.add_child(fill_light)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.45
	camera.position = Vector3(0.0, 0.88, 4.0)
	camera.look_at_from_position(camera.position, Vector3(0.0, 0.88, 0.0), Vector3.UP)
	world_root.add_child(camera)
	camera.current = true

	var model := packed_model.instantiate() as Node3D
	world_root.add_child(model)
	var views := {
		"front": 0.0,
		"three_quarter": -22.0,
		"side": -90.0,
		"back": 180.0,
	}
	for view_name: String in views:
		model.rotation_degrees.y = float(views[view_name])
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var output_path := "%s/milk_frog_%s.png" % [OUTPUT_DIR, view_name]
		var error := image.save_png(ProjectSettings.globalize_path(output_path))
		if error != OK:
			push_error("Failed to save %s: %s" % [output_path, error_string(error)])
			quit(1)
			return
		print("RENDERED ", output_path)
	quit()
