class_name BoomCam
extends Camera3D
## 竖屏俯视角相机：固定俯角（略倾斜）跟随玩家 + 仿噪震屏。
## 朝向在 _init 里一次算好（无需每帧 look_at，规避 up 向量共线的奇异姿态）。
## 震屏按 trauma^2 衰减，用 sin 叠加代替纯随机抖动，帧间平滑不闪瞎。

const CAM_SIZE: float = 15.5
const CAM_OFFSET: Vector3 = Vector3(0.0, 12.8, 5.0)
const SMOOTH: float = 7.0
const TRAUMA_DECAY: float = 2.6
const MAX_SHAKE: float = 0.55

var trauma: float = 0.0
var shake_t: float = 0.0
var target: Node3D = null
var _pos_smooth: Vector3 = Vector3.ZERO


func _init() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	size = CAM_SIZE
	keep_aspect = Camera3D.KEEP_HEIGHT
	near = 0.3
	far = 160.0
	basis = Basis.looking_at(-CAM_OFFSET, Vector3.UP)


func _ready() -> void:
	_pos_smooth = _desired_pos()


func setup_follow(node: Node3D) -> void:
	target = node
	if _pos_smooth == Vector3.ZERO:
		_pos_smooth = _desired_pos()


## 供事件层加震：amount 0..1。
func add_trauma(amount: float) -> void:
	trauma = clampf(trauma + amount, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	shake_t += delta
	trauma = maxf(0.0, trauma - TRAUMA_DECAY * delta)
	var desired := _desired_pos()
	_pos_smooth = _pos_smooth.lerp(desired, 1.0 - exp(-SMOOTH * delta))
	var amp: float = trauma * trauma * MAX_SHAKE
	var ph := shake_t * 43.0
	var shake := Vector3(sin(ph * 1.37), sin(ph * 1.93) * 0.6, sin(ph * 0.87)) * amp
	global_position = _pos_smooth + shake


func _desired_pos() -> Vector3:
	var base := Vector3.ZERO
	if target != null:
		base = target.position
	return base + CAM_OFFSET
