class_name BoomHitNum
extends Node3D
## 飘字对象池（伤害数字 / 击杀得分）。
## 击杀、伤害瞬间在 3D 位置弹字：上浮 + 淡出，0.7s 后回收复用，全程零 instantiate。
## 在 _init 预建 POOL_SIZE 个 Label3D（与 BoomGame/BoomBullet 同模式），
## 无头逻辑测试可在不入树的情况下直接 spawn / 断言 active_count()。

const POOL_SIZE: int = 24
const RISE_TIME: float = 0.7
const RISE_HEIGHT: float = 1.3
const FONT_PX: int = 56
const PIXEL_SIZE: float = 0.008
const BASE_Y: float = 1.1

const COLOR_DAMAGE: Color = Color(1.0, 1.0, 1.0)
const COLOR_SCORE: Color = Color(1.0, 0.85, 0.35)

var _labels: Array = []  # 全部 Label3D（下标 = 池槽位）
var _tweens: Array = []  # 槽位当前 tween
var _free: Array[int] = []  # 空闲槽位
var _busy: Array[int] = []  # 使用中槽位（先入先出，供断言/超限挤出）


func _init() -> void:
	for i in POOL_SIZE:
		var l := Label3D.new()
		l.name = "HitNum%d" % i
		l.text = ""
		l.font_size = FONT_PX
		l.pixel_size = PIXEL_SIZE
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.modulate = Color(1.0, 1.0, 1.0, 0.0)
		l.visible = false
		add_child(l)
		_labels.append(l)
		_tweens.append(null)
		_free.append(i)


## 在 pos 弹一个飘字。color/scale_p 由调用方按普通白/击杀金/连击放大传入。
func spawn(pos: Vector3, text: String, color: Color = COLOR_DAMAGE, scale_p: float = 1.0) -> void:
	if _labels.is_empty():
		return
	var idx := _next_slot()
	var l := _labels[idx] as Label3D
	_kill_tween(idx)
	l.text = text
	l.modulate = Color(color.r, color.g, color.b, 1.0)
	l.scale = Vector3.ONE * maxf(0.5, scale_p)
	l.position = pos + Vector3(0.0, BASE_Y, 0.0)
	l.visible = true
	_busy.append(idx)
	var tw := create_tween()
	_tweens[idx] = tw
	tw.set_parallel(true)
	(
		tw
		. tween_property(l, "position:y", l.position.y + RISE_HEIGHT, RISE_TIME)
		. set_trans(Tween.TRANS_QUAD)
		. set_ease(Tween.EASE_OUT)
	)
	tw.tween_property(l, "modulate:a", 0.0, RISE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(
		Tween.EASE_IN
	)
	tw.chain().tween_callback(_recycle.bind(idx))


## 池满时挤出最老的槽位；否则取空闲槽位。
func _next_slot() -> int:
	if not _free.is_empty():
		return _free.pop_back()
	var oldest: int = _busy.pop_front()
	_kill_tween(oldest)
	return oldest


func _kill_tween(idx: int) -> void:
	var old := _tweens[idx] as Tween
	if old != null and old.is_valid():
		old.kill()
	_tweens[idx] = null


func _recycle(idx: int) -> void:
	var l := _labels[idx] as Label3D
	if l != null:
		l.visible = false
		l.modulate.a = 0.0
	_busy.erase(idx)
	_free.append(idx)
	_tweens[idx] = null


## 当前活跃飘字数（测试/断言用）。
func active_count() -> int:
	return _busy.size()


## 第一个活跃槽位（若有），供测试取池中实例。
func first_active() -> Label3D:
	if _busy.is_empty():
		return null
	return _labels[_busy[0]] as Label3D
