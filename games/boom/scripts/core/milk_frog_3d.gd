class_name MilkFrog3D
extends Node3D
## 原生 3D 奶蛙：全部由低面数 MeshInstance3D 组成，不依赖平面角色贴图。
## +Z 为正脸方向，父节点旋转时会真实展示侧面和背面。

var _visual_root: Node3D
var _left_foot: MeshInstance3D
var _right_foot: MeshInstance3D
var _materials: Array[StandardMaterial3D] = []
var _time: float = 0.0
var _foot_rest_y: float = -0.22


func _init() -> void:
	_build_model()


func _build_model() -> void:
	_visual_root = Node3D.new()
	_visual_root.name = "VisualRoot"
	add_child(_visual_root)

	_visual_root.rotation.x = deg_to_rad(-4.0)
	var body_yellow := _make_material(Color.WHITE, 0.92)
	var yellow := _make_material(Color("#DFA43A"), 0.92)
	var belly := _make_material(Color("#DDBD82"), 0.94)
	var eye_green := _make_material(Color("#7D9854"), 0.82)
	var pupil := _make_material(Color("#15130F"), 0.55)
	var hand := _make_material(Color("#493A2B"), 0.92)
	var mouth := _make_material(Color("#4A281B"), 0.9)

	# 原版轮廓是连续的后仰梨形体块，而不是头、身体两个球的拼接。
	_make_organic_body(body_yellow)
	_make_sphere("Belly", Vector3(0.01, 0.94, 0.60), Vector3(0.82, 0.76, 0.055), belly)

	# 眼睛贴在脸上并保持轻微不对称；原版没有青蛙式凸眼球。
	_make_sphere("EyeLeft", Vector3(-0.225, 1.77, 0.31), Vector3(0.175, 0.185, 0.065), eye_green)
	_make_sphere("EyeRight", Vector3(0.17, 1.81, 0.315), Vector3(0.19, 0.195, 0.065), eye_green)
	_make_sphere("PupilLeft", Vector3(-0.225, 1.77, 0.349), Vector3(0.08, 0.09, 0.03), pupil)
	_make_sphere("PupilRight", Vector3(0.17, 1.81, 0.354), Vector3(0.088, 0.098, 0.03), pupil)

	# 极简平嘴，贴近原始表情，不增加笑脸或牙齿。
	var mouth_mesh := CylinderMesh.new()
	mouth_mesh.top_radius = 0.014
	mouth_mesh.bottom_radius = 0.014
	mouth_mesh.height = 0.245
	mouth_mesh.radial_segments = 12
	var mouth_node := _make_mesh("Mouth", mouth_mesh, mouth)
	mouth_node.position = Vector3(-0.035, 1.57, 0.425)
	mouth_node.rotation_degrees = Vector3(90.0, 0.0, 84.0)

	# 左臂下垂后折回托腮，手掌与手指独立建模，避免原先的棕色块遮脸。
	_make_limb(
		"LeftUpperArm", Vector3(-0.49, 1.33, -0.01), Vector3(-0.64, 0.70, 0.29), 0.17, yellow
	)
	_make_limb("LeftForearm", Vector3(-0.64, 0.70, 0.29), Vector3(-0.34, 1.28, 0.48), 0.145, yellow)
	_make_sphere("ThinkingPalm", Vector3(-0.26, 1.39, 0.54), Vector3(0.22, 0.24, 0.11), hand)
	_make_limb("ThinkingIndex", Vector3(-0.25, 1.44, 0.60), Vector3(-0.11, 1.51, 0.60), 0.032, hand)
	_make_limb(
		"ThinkingMiddle", Vector3(-0.27, 1.39, 0.605), Vector3(-0.12, 1.43, 0.61), 0.033, hand
	)
	_make_limb(
		"ThinkingThumb", Vector3(-0.26, 1.34, 0.60), Vector3(-0.13, 1.30, 0.595), 0.035, hand
	)

	# 右臂横压腹部，手指在正面形成原版接近人手的轮廓。
	_make_limb("RightUpperArm", Vector3(0.50, 1.29, -0.02), Vector3(0.59, 0.73, 0.31), 0.15, yellow)
	_make_limb("RightForearm", Vector3(0.59, 0.73, 0.31), Vector3(0.23, 0.66, 0.51), 0.13, yellow)
	_make_sphere("BellyPalm", Vector3(0.16, 0.65, 0.59), Vector3(0.22, 0.18, 0.105), hand)
	for finger_index: int in range(4):
		var finger_y := 0.705 - float(finger_index) * 0.045
		_make_limb(
			"BellyFinger%d" % finger_index,
			Vector3(0.15, finger_y, 0.645),
			Vector3(-0.01, finger_y - 0.025, 0.65),
			0.027,
			hand
		)

	# 全身参考中的腿细长、脚掌宽扁，并在身体后方带有短尾巴。
	_make_limb("LegLeft", Vector3(-0.27, 0.35, -0.02), Vector3(-0.30, -0.12, 0.01), 0.125, yellow)
	_make_limb("LegRight", Vector3(0.27, 0.35, -0.02), Vector3(0.31, -0.12, 0.01), 0.125, yellow)
	_left_foot = _make_sphere(
		"FootLeft", Vector3(-0.31, _foot_rest_y, 0.14), Vector3(0.38, 0.13, 0.49), hand
	)
	_right_foot = _make_sphere(
		"FootRight", Vector3(0.32, _foot_rest_y, 0.14), Vector3(0.38, 0.13, 0.49), hand
	)
	for toe_index: int in range(3):
		var toe_offset := (float(toe_index) - 1.0) * 0.065
		_make_limb(
			"LeftToe%d" % toe_index,
			Vector3(-0.31 + toe_offset * 0.45, -0.20, 0.30),
			Vector3(-0.31 + toe_offset, -0.21, 0.42),
			0.025,
			hand
		)
		_make_limb(
			"RightToe%d" % toe_index,
			Vector3(0.32 + toe_offset * 0.45, -0.20, 0.30),
			Vector3(0.32 + toe_offset, -0.21, 0.42),
			0.025,
			hand
		)
	_make_limb("Tail", Vector3(0.43, 0.49, -0.40), Vector3(0.62, 0.38, -0.48), 0.09, yellow)


func animate_model(delta: float, motion: float, hit_flash: float) -> void:
	_time += delta * lerpf(3.2, 7.8, clampf(motion, 0.0, 1.0))
	var breath := sin(_time) * 0.025
	_visual_root.scale = Vector3(1.0 + breath, 1.0 - breath * 0.7, 1.0 + breath)
	_visual_root.rotation.z = sin(_time * 0.5) * 0.018
	if motion > 0.05:
		_left_foot.position.y = _foot_rest_y + maxf(0.0, sin(_time)) * 0.055
		_right_foot.position.y = _foot_rest_y + maxf(0.0, -sin(_time)) * 0.055
	else:
		_left_foot.position.y = lerpf(_left_foot.position.y, _foot_rest_y, delta * 10.0)
		_right_foot.position.y = lerpf(_right_foot.position.y, _foot_rest_y, delta * 10.0)
	for material in _materials:
		material.emission_enabled = hit_flash > 0.01
		material.emission_energy_multiplier = hit_flash * 1.5


func _make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.0
	material.emission_enabled = false
	material.emission = color.lightened(0.15)
	_materials.append(material)
	return material


func _make_organic_body(material: StandardMaterial3D) -> MeshInstance3D:
	var heights := PackedFloat32Array(
		[
			0.12,
			0.20,
			0.32,
			0.46,
			0.62,
			0.80,
			0.98,
			1.16,
			1.34,
			1.50,
			1.64,
			1.76,
			1.86,
			1.94,
			2.00,
			2.04,
			2.06
		]
	)
	var x_radii := PackedFloat32Array(
		[
			0.14,
			0.26,
			0.40,
			0.52,
			0.61,
			0.67,
			0.70,
			0.69,
			0.65,
			0.60,
			0.54,
			0.47,
			0.39,
			0.30,
			0.20,
			0.11,
			0.03
		]
	)
	var z_radii := PackedFloat32Array(
		[
			0.11,
			0.18,
			0.28,
			0.36,
			0.43,
			0.48,
			0.51,
			0.53,
			0.52,
			0.49,
			0.45,
			0.40,
			0.35,
			0.28,
			0.18,
			0.09,
			0.025
		]
	)
	var z_centers := PackedFloat32Array(
		[
			-0.05,
			-0.04,
			-0.02,
			0.01,
			0.03,
			0.04,
			0.04,
			0.02,
			-0.01,
			-0.04,
			-0.08,
			-0.11,
			-0.13,
			-0.14,
			-0.15,
			-0.15,
			-0.15
		]
	)
	var surface_tool := SurfaceTool.new()
	var segments: int = 36
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring_index: int in range(heights.size()):
		for segment_index: int in range(segments):
			var angle := TAU * float(segment_index) / float(segments)
			var vertex := Vector3(
				x_radii[ring_index] * cos(angle),
				heights[ring_index],
				z_centers[ring_index] + z_radii[ring_index] * sin(angle)
			)
			var front_amount := clampf((sin(angle) + 1.0) * 0.5, 0.0, 1.0)
			var height_amount := heights[ring_index] / heights[heights.size() - 1]
			var body_color := Color("#D99732").lerp(Color("#F0C34D"), 0.38 + height_amount * 0.28)
			body_color = body_color.lerp(Color("#F1BD48"), front_amount * 0.10)
			surface_tool.set_color(body_color)
			surface_tool.set_uv(Vector2(float(segment_index) / float(segments), height_amount))
			surface_tool.add_vertex(vertex)
	for ring_index: int in range(heights.size() - 1):
		for segment_index: int in range(segments):
			var next_segment: int = (segment_index + 1) % segments
			var lower: int = ring_index * segments + segment_index
			var lower_next: int = ring_index * segments + next_segment
			var upper: int = (ring_index + 1) * segments + segment_index
			var upper_next: int = (ring_index + 1) * segments + next_segment
			surface_tool.add_index(lower)
			surface_tool.add_index(upper_next)
			surface_tool.add_index(upper)
			surface_tool.add_index(lower)
			surface_tool.add_index(lower_next)
			surface_tool.add_index(upper_next)
	surface_tool.generate_normals()
	material.vertex_color_use_as_albedo = true
	var node := _make_mesh("Body", surface_tool.commit(), material)
	return node


func _make_sphere(
	name_value: String, local_position: Vector3, local_scale: Vector3, material: Material
) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 28
	sphere.rings = 16
	var node := _make_mesh(name_value, sphere, material)
	node.position = local_position
	node.scale = local_scale
	return node


func _make_limb(
	name_value: String, from: Vector3, to: Vector3, limb_radius: float, material: Material
) -> MeshInstance3D:
	var direction := to - from
	var capsule := CapsuleMesh.new()
	capsule.radius = limb_radius
	capsule.height = direction.length() + limb_radius * 2.0
	capsule.radial_segments = 20
	capsule.rings = 8
	var node := _make_mesh(name_value, capsule, material)
	node.position = (from + to) * 0.5
	node.basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
	return node


func _make_mesh(name_value: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name_value
	node.mesh = mesh
	node.material_override = material
	_visual_root.add_child(node)
	return node
