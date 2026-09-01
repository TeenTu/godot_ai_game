class_name GameKitSafeArea
extends Control
## 多端屏幕适配：把安全区（刘海/挖孔/圆角/手势条）之外的边距应用到自己身上。
##
## 用法：作为全屏容器的父节点（锚点自动设为 Full Rect），所有 UI 放它下面，
## 即可自动避开手机刘海与手势条；桌面/网页端没有安全区时边距为 0。
## 窗口尺寸或屏幕旋转变化时自动重算。

var _insets: Rect2 = Rect2()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_safe_area()
	# 窗口尺寸变化 / 设备旋转时重算。
	get_viewport().size_changed.connect(_apply_safe_area)


func _apply_safe_area() -> void:
	var window := get_window()
	if window == null:
		return
	var window_size := Vector2(window.size)
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		return
	# 安全区是屏幕坐标；换算成相对本窗口的偏移。
	var safe := DisplayServer.get_display_safe_area()
	var inset_left := maxf(safe.position.x - window.position.x, 0.0)
	var inset_top := maxf(safe.position.y - window.position.y, 0.0)
	var inset_right := maxf(window.position.x + window_size.x - safe.end.x, 0.0)
	var inset_bottom := maxf(window.position.y + window_size.y - safe.end.y, 0.0)

	# 本节点锚点为 Full Rect，用 offsets 把内容挤进安全区。
	offset_left = inset_left
	offset_top = inset_top
	offset_right = -inset_right
	offset_bottom = -inset_bottom
	_insets = Rect2(Vector2(inset_left, inset_top), Vector2(inset_right, inset_bottom))


## 返回当前安全区内边距（left/top 与 right/bottom 取绝对值前的原始偏移）。
func get_insets() -> Rect2:
	return _insets
