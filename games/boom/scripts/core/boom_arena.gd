class_name BoomArena
extends RefCounted
## M8 重构拆分：夜巡街巷 3D 场地构建器（从 main.gd 拆出控制行数门禁）。
## 全部静态、以传入父节点为根；视觉数值与拆分前逐字一致（冷靛夜景）。

const ARENA_WIDTH: float = 52.0
const ARENA_DEPTH: float = 76.0
const ARENA_HALF_X: float = 26.0
const ARENA_HALF_Z: float = 38.0


## 构建整块场地：湿石板地 + 环境/灯光 + 网格线 + 围栏 + 出口牌坊。
static func build(w: Node3D) -> void:
	_add_floor(w)
	_add_environment(w)
	_add_grid_accents(w)
	_add_court_rails(w)
	_add_exit_gate(w)
	_add_lights(w)


static func _add_floor(w: Node3D) -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(ARENA_WIDTH, ARENA_DEPTH)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color("d6e0ed")
	var floor_path := "res://assets/images/floors/wet_stone_tiles.png"
	if ResourceLoader.exists(floor_path):
		floor_mat.albedo_texture = load(floor_path) as Texture2D
		floor_mat.uv1_scale = Vector3(6.0, 10.0, 1.0)
	floor_mat.roughness = 0.95
	var floor := MeshInstance3D.new()
	floor.mesh = floor_mesh
	floor.material_override = floor_mat
	w.add_child(floor)


static func _add_environment(w: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("101827")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("8093b5")
	env.ambient_light_energy = 0.58
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	w.add_child(world_env)


static func _add_grid_accents(w: Node3D) -> void:
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color("526582")
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var thick := 0.035
	for x in range(-int(ARENA_HALF_X), int(ARENA_HALF_X) + 1, 4):
		_add_box(w, Vector3(float(x), 0.012, 0.0), Vector3(thick, 0.01, ARENA_DEPTH), line_mat)
	for z in range(-int(ARENA_HALF_Z), int(ARENA_HALF_Z) + 1, 4):
		_add_box(w, Vector3(0.0, 0.012, float(z)), Vector3(ARENA_WIDTH, 0.01, thick), line_mat)


static func _add_court_rails(w: Node3D) -> void:
	var rail_mat := _make_mat(Color("273754"), 0.72)
	var cap_mat := _make_mat(Color("bd8b52"), 0.55, Color("d99d56"))
	var hx := 10.0
	var hz := 27.0
	_add_box(w, Vector3(0.0, 0.32, -hz), Vector3(hx * 2.0 + 0.4, 0.64, 0.35), rail_mat)
	_add_box(w, Vector3(0.0, 0.32, hz), Vector3(hx * 2.0 + 0.4, 0.64, 0.35), rail_mat)
	_add_box(w, Vector3(-hx, 0.32, 0.0), Vector3(0.35, 0.64, hz * 2.0 + 0.4), rail_mat)
	_add_box(w, Vector3(hx, 0.32, 0.0), Vector3(0.35, 0.64, hz * 2.0 + 0.4), rail_mat)
	_add_box(w, Vector3(0.0, 0.67, -hz), Vector3(hx * 2.0 + 0.5, 0.10, 0.42), cap_mat)
	_add_box(w, Vector3(0.0, 0.67, hz), Vector3(hx * 2.0 + 0.5, 0.10, 0.42), cap_mat)
	_add_box(w, Vector3(-hx, 0.67, 0.0), Vector3(0.42, 0.10, hz * 2.0 + 0.5), cap_mat)
	_add_box(w, Vector3(hx, 0.67, 0.0), Vector3(0.42, 0.10, hz * 2.0 + 0.5), cap_mat)


static func _add_exit_gate(w: Node3D) -> void:
	var gold := _make_mat(Color("c28a4f"), 0.32, Color("c28a4f"))
	var cream := _make_mat(Color("d7c7a7"), 0.42)
	var gate_z := -26.65
	_add_box(w, Vector3(-1.25, 1.15, gate_z), Vector3(0.38, 2.3, 0.55), gold)
	_add_box(w, Vector3(1.25, 1.15, gate_z), Vector3(0.38, 2.3, 0.55), gold)
	_add_box(w, Vector3(0.0, 2.2, gate_z), Vector3(2.9, 0.38, 0.55), cream)
	_add_box(w, Vector3(0.0, 0.035, gate_z + 0.4), Vector3(2.2, 0.04, 1.0), gold)


static func _add_lights(w: Node3D) -> void:
	var key := DirectionalLight3D.new()
	key.light_color = Color("b7c7e6")
	key.light_energy = 0.78
	key.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 72.0
	w.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color("d39b69")
	fill.light_energy = 0.28
	fill.rotation_degrees = Vector3(-60.0, 130.0, 0.0)
	fill.shadow_enabled = false
	w.add_child(fill)


static func _make_mat(
	color: Color, roughness: float, emission: Color = Color.TRANSPARENT
) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	if emission.a > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = 0.45
	return mat


static func _add_box(w: Node3D, pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = mat
	m.position = pos
	w.add_child(m)
