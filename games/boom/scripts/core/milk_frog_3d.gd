class_name MilkFrog3D
extends Node3D
## 原生 3D 奶蛙：全部由低面数 MeshInstance3D 组成，不依赖平面角色贴图。
## +Z 为正脸方向，父节点旋转时会真实展示侧面和背面。

var _visual_root: Node3D
var _left_foot: MeshInstance3D
var _right_foot: MeshInstance3D
var _materials: Array[StandardMaterial3D] = []
var _time: float = 0.0


func _init() -> void:
	_build_model()


func _build_model() -> void:
	_visual_root = Node3D.new()
	_visual_root.name = "VisualRoot"
	add_child(_visual_root)

	_visual_root.rotation.x = deg_to_rad(-12.0)
	var yellow := _make_material(Color("#DFAE2F"), 0.68, Color("#4B270F"))
	var yellow_light := _make_material(Color("#F2C84B"), 0.62, Color("#5A2F12"))
	var belly := _make_material(Color("#F6DEB0"), 0.72, Color("#6D4B2C"))
	var eye_green := _make_material(Color("#81A95A"), 0.48, Color("#1F351A"))
	var pupil := _make_material(Color("#17140F"), 0.35, Color("#050403"))
	var hand := _make_material(Color("#584A31"), 0.76, Color("#21170C"))
	var mouth := _make_material(Color("#4B2818"), 0.84, Color("#170A06"))

	# 大头与身体使用同材质相交，远看保持奶蛙连续的软团剪影。
	_make_sphere("Body", Vector3(0.0, 0.68, 0.0), Vector3(1.16, 1.28, 0.86), yellow)
	_make_sphere("Head", Vector3(-0.02, 1.18, 0.02), Vector3(1.24, 0.94, 0.91), yellow_light)
	_make_sphere("Belly", Vector3(0.02, 0.55, 0.405), Vector3(0.72, 0.72, 0.10), belly)

	# 原版不对称凸眼：眼白即绿色眼球，正面为深色圆瞳。
	_make_sphere("EyeLeft", Vector3(-0.255, 1.39, 0.405), Vector3(0.31, 0.31, 0.20), eye_green)
	_make_sphere("EyeRight", Vector3(0.235, 1.43, 0.425), Vector3(0.34, 0.34, 0.21), eye_green)
	_make_sphere("PupilLeft", Vector3(-0.255, 1.39, 0.505), Vector3(0.145, 0.15, 0.07), pupil)
	_make_sphere("PupilRight", Vector3(0.235, 1.43, 0.532), Vector3(0.16, 0.17, 0.07), pupil)

	# 极简平嘴，贴近原始表情，不增加笑脸或牙齿。
	var mouth_mesh := CylinderMesh.new()
	mouth_mesh.top_radius = 0.022
	mouth_mesh.bottom_radius = 0.022
	mouth_mesh.height = 0.31
	mouth_mesh.radial_segments = 8
	var mouth_node := _make_mesh("Mouth", mouth_mesh, mouth)
	mouth_node.position = Vector3(-0.01, 1.18, 0.505)
	mouth_node.rotation_degrees = Vector3(90.0, 0.0, 83.0)

	# 左臂托腮、右臂横在肚前，保留最有辨识度的经典姿势。
	_make_limb("LeftUpperArm", Vector3(-0.47, 0.72, 0.07), Vector3(-0.29, 1.02, 0.38), 0.14, yellow)
	_make_limb("LeftForearm", Vector3(-0.29, 1.00, 0.39), Vector3(-0.16, 1.16, 0.48), 0.125, hand)
	_make_sphere("ThinkingHand", Vector3(-0.12, 1.16, 0.50), Vector3(0.27, 0.22, 0.16), hand)
	_make_limb("RightUpperArm", Vector3(0.48, 0.72, 0.06), Vector3(0.27, 0.47, 0.37), 0.145, yellow)
	_make_limb("RightForearm", Vector3(0.28, 0.47, 0.38), Vector3(0.04, 0.46, 0.47), 0.13, hand)
	_make_sphere("BellyHand", Vector3(-0.01, 0.46, 0.49), Vector3(0.27, 0.18, 0.14), hand)

	# 小脚让模型在俯视战场中有落地感，颜色沿用深色手掌。
	_left_foot = _make_sphere(
		"FootLeft", Vector3(-0.31, 0.12, 0.09), Vector3(0.39, 0.18, 0.44), hand
	)
	_right_foot = _make_sphere(
		"FootRight", Vector3(0.31, 0.12, 0.09), Vector3(0.39, 0.18, 0.44), hand
	)


func animate_model(delta: float, motion: float, hit_flash: float) -> void:
	_time += delta * lerpf(3.2, 7.8, clampf(motion, 0.0, 1.0))
	var breath := sin(_time) * 0.025
	_visual_root.scale = Vector3(1.0 + breath, 1.0 - breath * 0.7, 1.0 + breath)
	_visual_root.rotation.z = sin(_time * 0.5) * 0.018
	if motion > 0.05:
		_left_foot.position.y = 0.12 + maxf(0.0, sin(_time)) * 0.055
		_right_foot.position.y = 0.12 + maxf(0.0, -sin(_time)) * 0.055
	else:
		_left_foot.position.y = lerpf(_left_foot.position.y, 0.12, delta * 10.0)
		_right_foot.position.y = lerpf(_right_foot.position.y, 0.12, delta * 10.0)
	for material in _materials:
		material.emission_energy_multiplier = 0.08 + hit_flash * 1.8


func _make_material(color: Color, roughness: float, emission: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.0
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = 0.08
	_materials.append(material)
	return material


func _make_sphere(
	name_value: String, local_position: Vector3, local_scale: Vector3, material: Material
) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 18
	sphere.rings = 10
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
	capsule.radial_segments = 12
	capsule.rings = 5
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
