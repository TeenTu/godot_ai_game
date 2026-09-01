extends SceneTree

## 无头自检：模拟真人一直往里丢水果，看到底能不能合成、会不会正常判负。
## 用法：godot --headless --script res://tools/play_test.gd

const MAX_STEPS: int = 6000
const DROP_INTERVAL: int = 30
const MAX_DROPS: int = 70

var _main: Node
var _steps: int = 0
var _drops: int = 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_steps += 1
	if not _main.is_over and _drops < MAX_DROPS and _steps % DROP_INTERVAL == 0:
		_main.pointer_x = randf_range(90.0, 630.0)
		_main._drop_held()
		_drops += 1
	if _main.is_over or _steps >= MAX_STEPS:
		_report()
		return true
	return false


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
	var ok: bool = _main.score >= 10 and _drops >= 10
	print("PLAY_TEST result=", "PASS" if ok else "FAIL")
