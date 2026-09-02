extends SceneTree

## B-Boom 无头自检（CI 门禁用）。
##
##   [smoke]   主场景实例化 + _ready 后关键系统挂载（sim/cam/joystick/fx/hitnum/audio）
##   [logic]   BoomGame 直接驱动（不加载场景，手动 step 虚拟帧）：
##             1. 玩家受控：上推摇杆 z 位移、松手停住
##             2. 自动开火：放置敌人后产生子弹
##             3. 命中致死：3 点血被泡泡打到死、击杀计数/分数变化
##             4. 波次推进：清空当前波后 wave 增长、获得清波奖励
##   [hitnum]  BoomHitNum 飘字池：击杀信号触发 spawn 后池中活跃实例可取
##
## 用法：godot --headless --path games/boom --script res://tools/play_test.gd

const DT: float = 1.0 / 60.0
const MAX_FRAMES: int = 1200

var _failures := 0
var _step := 0
var _smoke_done := false
var _logic_done := false
var _main: Node


func _initialize() -> void:
	seed(20260902)
	var ps := load("res://scenes/main.tscn") as PackedScene
	if ps == null:
		_check(false, "加载 scenes/main.tscn")
		_finish()
		return
	_main = ps.instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_step += 1
	if not _smoke_done and _step >= 4:
		_smoke_done = true
		_test_smoke()
	if _smoke_done and not _logic_done:
		_logic_done = true
		seed(20260902)
		_test_player_moves()
		_test_auto_fire_kill()
		_test_hitnum()
		_test_wave_advance()
		_finish()
	return false


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: ", msg)
	else:
		_failures += 1
		print("  FAIL: ", msg)


func _finish() -> void:
	if _failures == 0:
		print("PLAY_TEST result=PASS")
		quit(0)
	else:
		print("PLAY_TEST result=FAIL failures=", _failures)
		quit(1)


# ------------------------------------------------------------------ smoke


func _test_smoke() -> void:
	print("[smoke]")
	_check(_main != null, "主场景实例化成功")
	if _main == null:
		return
	_check(_main.get_child_count() > 0, "Main _ready 后含子节点")
	_check(_main.has_method("_test_hook_get_state"), "实现 _test_hook_get_state")
	var has_sim: bool = _main.get("sim") != null
	var has_cam: bool = _main.get("cam") != null
	var has_joy: bool = _main.get("joystick") != null
	var has_fx: bool = _main.get("fx") != null
	_check(has_sim, "sim 已构建")
	_check(has_cam, "cam 已构建")
	_check(has_joy, "joystick 已构建")
	_check(has_fx, "fx 已构建")
	_check(_main.get("hitnum") != null, "hitnum 飘字模块已注入")
	if not has_sim:
		return
	var sim := _main.get("sim") as BoomGame
	_check(sim.player != null, "sim.player 存在")
	_check(sim.player.hp == sim.player.max_hp, "开局满血 hp=5")
	_check(sim.wave == 1, "初始波次 1")
	var st: Dictionary = _main.call("_test_hook_get_state")
	_check(st.has("score") and st.has("wave") and st.has("hp"), "test_hook state 键完整")


# ------------------------------------------------------------------ 玩家移动


func _new_game() -> BoomGame:
	var g := BoomGame.new()
	g.auto_spawn = false
	return g


func _test_player_moves() -> void:
	print("[player-move]")
	var g := _new_game()
	g.input_move = Vector2(0.0, -1.0)
	var start_z: float = g.player.position.z
	_run(g, 45)
	var moved: float = start_z - g.player.position.z
	_check(moved > 1.5, "推摇杆向上移动 z 位移 %.2f" % moved)

	g.input_move = Vector2.ZERO
	var frozen := g.player.position
	_run(g, 30)
	_check(g.player.position.distance_to(frozen) < 0.02, "松手后玩家停下")


# ------------------------------------------------------------------ 开火/击杀


func _test_auto_fire_kill() -> void:
	print("[auto-fire-kill]")
	var g := _new_game()
	# 全程无敌：只测输出与击杀，不被反杀干扰。
	g.player.invuln_left = 10.0
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	var saw_bullet := false
	var fired := false
	var guard := 0
	while guard < MAX_FRAMES:
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
		if not saw_bullet and _active_bullets(g) > 0:
			saw_bullet = true
			fired = true
		if jelly.is_dead():
			break
	_check(fired, "开枪后子弹产生")
	_check(jelly.is_dead(), "敌人被击杀至死")
	_check(jelly.hp <= 0, "敌人 hp 归零")
	if fired and jelly.is_dead():
		_check(g.enemies.is_empty(), "死亡敌人已移出列表")
		_check(g.kills == 1, "击杀计数 = 1")
		_check(g.score >= BoomGame.KILL_SCORE, "分数 >= 击杀分")
		_check(g.combo == 1, "首杀 combo = 1")


# ------------------------------------------------------------------ 飘字池


func _test_hitnum() -> void:
	print("[hitnum]")
	var g := _new_game()
	g.player.invuln_left = 10.0
	var hn := BoomHitNum.new()
	# 模拟 main.gd 注入路径：击杀信号 → 模块 spawn。
	g.enemy_died.connect(func(pos: Vector3) -> void: hn.spawn(pos, "+10", BoomHitNum.COLOR_SCORE))
	root.add_child(hn)
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	var guard := 0
	while guard < MAX_FRAMES and not jelly.is_dead():
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
	_check(jelly.is_dead(), "飘字测试敌人被击杀")
	_check(hn.active_count() > 0, "击杀后飘字对象池含活跃实例")
	var lbl: Label3D = hn.first_active()
	_check(lbl != null and lbl.text != "", "可取得活跃飘字实例且带文本")
	root.remove_child(hn)
	hn.free()


# ------------------------------------------------------------------ 波次


func _test_wave_advance() -> void:
	print("[wave-advance]")
	var g := _new_game()
	g.player.invuln_left = 10.0
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.5))
	g.force_wave_spawned_done()
	var guard := 0
	while guard < MAX_FRAMES and g.wave == 1:
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
		if jelly.is_dead():
			# 刷新新波可能会重新刷怪，测试只关心波次推进本身。
			pass
	_check(g.wave == 2, "清空首波后 wave 推进到 2")
	_check(g.score >= 10, "击杀 + 清波奖励后分数累积 (score=%d)" % g.score)


# ------------------------------------------------------------------ helpers


func _active_bullets(g: BoomGame) -> int:
	var n := 0
	for b in g.bullets:
		if (b as BoomBullet).active:
			n += 1
	return n


func _run(g: BoomGame, frames: int) -> void:
	for i in frames:
		g.step(DT)
