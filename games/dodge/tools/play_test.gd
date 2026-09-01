extends SceneTree

## 太空闪避无头自检（用法：godot --headless --script res://tools/play_test.gd）。
##
## 依次验证四件事（全用确定性输入，不依赖随机运气）：
##   1. auto_move 钩子能驱动飞船移动
##   2. 计分随时间增长、陨石正常生成
##   3. 陨石撞上飞船会触发游戏结束
##   4. restart() 能干净地重开一局

const CHECK_MOVE_AT: int = 65
const CHECK_SCORE_AT: int = 150
const FORCE_HIT_AT: int = 160
const CHECK_HIT_AT: int = 190
const RESTART_AT: int = 200
const CHECK_RESTART_AT: int = 206
const REPORT_AT: int = 212

var _main: Node
var _steps: int = 0
var _x0: float = 0.0
var _move_ok: bool = false
var _score_ok: bool = false
var _hit_ok: bool = false
var _restart_ok: bool = false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	seed(20260902)


func _process(_delta: float) -> bool:
	_steps += 1

	if _steps == 5:
		_x0 = _main.player.position.x
		_main.auto_move = Vector2.RIGHT
	elif _steps == CHECK_MOVE_AT:
		_main.auto_move = Vector2.ZERO
		_move_ok = _main.player.position.x > _x0 + 100.0
	elif _steps == CHECK_SCORE_AT:
		_score_ok = _main.score > 0.5 and _main.asteroids_root.get_child_count() >= 1
	elif _steps == FORCE_HIT_AT:
		# 把一颗陨石精确放到飞船位置，下一帧必然判定碰撞。
		var rock: Node2D = _main._spawn_asteroid()
		rock.position = _main.player.position
	elif _steps == CHECK_HIT_AT:
		_hit_ok = _main.is_over
	elif _steps == RESTART_AT:
		_main.restart()
	elif _steps == CHECK_RESTART_AT:
		# 注意：restart 归零后 _process 又在累加 delta，所以分数断言用 < 0.5 而非 == 0。
		_restart_ok = (
			not _main.is_over and _main.score < 0.5 and _main.asteroids_root.get_child_count() == 0
		)
	elif _steps >= REPORT_AT:
		_report()
		return true
	return false


func _report() -> void:
	print("PLAY_TEST steps=", _steps)
	print("PLAY_TEST move_works=", _move_ok, " score_works=", _score_ok)
	print("PLAY_TEST hit_works=", _hit_ok, " restart_works=", _restart_ok)
	var all_ok := _move_ok and _score_ok and _hit_ok and _restart_ok
	print("PLAY_TEST result=", "PASS" if all_ok else "FAIL")
