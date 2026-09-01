extends SceneTree

## 无头自检。
##
## 第一阶段做确定性验证：把两颗葡萄叠在一起，必须合成出一颗樱桃。
## 第二阶段跑一局随机对局，主要用来抓崩溃和物理爆炸（不做分数断言，
## 因为随机丢水果的成局质量不稳定，拿来当断言会变成 flaky 测试）。
##
## 用法：godot --headless --script res://tools/play_test.gd

const MAX_STEPS: int = 6000
const DROP_INTERVAL: int = 30
const MAX_DROPS: int = 70
const MERGE_CHECK_AT: int = 120

var _main: Node
var _steps: int = 0
var _drops: int = 0
var _merge_ok: bool = false
var _checked: bool = false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	# 固定随机种子，让每一次跑出来的日志可复现
	seed(20260901)


func _process(_delta: float) -> bool:
	_steps += 1
	if not _checked:
		if _steps == 5:
			_main._spawn_fruit(0, Vector2(352.0, 600.0))
			_main._spawn_fruit(0, Vector2(374.0, 600.0))
		if _steps == MERGE_CHECK_AT:
			_merge_ok = _count_level(1) >= 1 and _main.score >= 1
			_checked = true
		return false

	if not _main.is_over and _drops < MAX_DROPS and _steps % DROP_INTERVAL == 0:
		_main.pointer_x = randf_range(90.0, 630.0)
		_main._drop_held()
		_drops += 1

	if _main.is_over or _steps >= MAX_STEPS:
		_report()
		return true
	return false


func _count_level(level: int) -> int:
	var n: int = 0
	for child in _main.fruits_root.get_children():
		var f := child as Fruit
		if f != null and not f.is_held and f.level == level:
			n += 1
	return n


func _report() -> void:
	var counts := {}
	var total: int = 0
	for child in _main.fruits_root.get_children():
		var f := child as Fruit
		if f == null or f.is_held:
			continue
		counts[f.level] = counts.get(f.level, 0) + 1
		total += 1
	print("PLAY_TEST steps=", _steps, " drops=", _drops, " score=", _main.score)
	print("PLAY_TEST over=", _main.is_over, " alive=", total, " levels=", counts)
	print("PLAY_TEST merge_works=", _merge_ok)
	print("PLAY_TEST result=", "PASS" if _merge_ok else "FAIL")
