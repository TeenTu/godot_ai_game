extends SceneTree

## 太空闪避无头自检 v2（用法：godot --headless --script res://tools/play_test.gd）。
##
## 依次验证六件事（全用确定性输入，不依赖随机运气）：
##   1. auto_move 钩子能驱动飞船移动
##   2. 计分随时间增长、陨石正常生成
##   3. 护盾道具拾取生效
##   4. 有护盾时被撞只碎盾不结束
##   5. 陨石贴身飞过触发擦身奖励
##   6. restart() 能干净地重开一局
##
## 第 140 帧起清场并停用随机生成（_spawn_cd=99999），后续阶段完全确定性。

const MOVE_START: int = 5
const CHECK_MOVE_AT: int = 65
const CLEAR_AT: int = 140
const CHECK_SCORE_AT: int = 150
const POWERUP_AT: int = 155
const CHECK_SHIELD_AT: int = 165
const SHIELD_HIT_AT: int = 172
const CHECK_SHIELD_USED_AT: int = 180
const NEAR_MISS_AT: int = 185
const CHECK_NEAR_MISS_AT: int = 200
const RESTART_AT: int = 205
const CHECK_RESTART_AT: int = 211
const REPORT_AT: int = 216

var _main: Node
var _steps: int = 0
var _x0: float = 0.0
var _move_ok: bool = false
var _score_ok: bool = false
var _shield_ok: bool = false
var _shield_use_ok: bool = false
var _near_ok: bool = false
var _restart_ok: bool = false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	seed(20260902)


func _process(_delta: float) -> bool:
	_steps += 1

	if _steps == MOVE_START:
		_x0 = _main.player.position.x
		_main.auto_move = Vector2.RIGHT
	elif _steps == CHECK_MOVE_AT:
		_main.auto_move = Vector2.ZERO
		_move_ok = _main.player.position.x > _x0 + 100.0
	elif _steps == CLEAR_AT:
		# 清场 + 关闭随机生成，保证后续阶段确定性。
		for child in _main.asteroids_root.get_children():
			child.queue_free()
		_main._spawn_cd = 99999.0
		_main._spawn_asteroid()  # 计分断言需要场上至少一颗陨石
	elif _steps == CHECK_SCORE_AT:
		_score_ok = _main.score > 0.5 and _main.asteroids_root.get_child_count() >= 1
	elif _steps == POWERUP_AT:
		# 护盾道具精确放到飞船位置，必然拾取。
		var p: Node2D = _main._spawn_powerup()
		p.position = _main.player.position
	elif _steps == CHECK_SHIELD_AT:
		_shield_ok = _main.player.shielded
	elif _steps == SHIELD_HIT_AT:
		var rock: Node2D = _main._spawn_asteroid()
		rock.position = _main.player.position
	elif _steps == CHECK_SHIELD_USED_AT:
		_shield_use_ok = not _main.is_over and not _main.player.shielded
	elif _steps == NEAR_MISS_AT:
		# 横向偏移 62px：超出最大撞击距离（38+22=60），落在擦身范围内。
		var rock2: Node2D = _main._spawn_asteroid()
		rock2.position = _main.player.position + Vector2(62.0, 0.0)
	elif _steps == CHECK_NEAR_MISS_AT:
		_near_ok = _main.near_miss_count >= 1
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
	print("PLAY_TEST move=", _move_ok, " score=", _score_ok, " shield=", _shield_ok)
	print(
		"PLAY_TEST shield_use=", _shield_use_ok, " near_miss=", _near_ok, " restart=", _restart_ok
	)
	var all_ok := (
		_move_ok and _score_ok and _shield_ok and _shield_use_ok and _near_ok and _restart_ok
	)
	print("PLAY_TEST result=", "PASS" if all_ok else "FAIL")
