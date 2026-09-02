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
##   [skills]  M2 技能逻辑（BoomGame.cast_* 直接驱动，不走手势）：
##             1. fan：cast_fan_shot 返回 5 且子弹池活跃数 +5；命中可击杀单敌
##             2. chain：三敌各在跳跃范围内 -> enemy_damaged 触发 3 次（链 3 跳）
##             3. nuke：6m 内 AOE BULLET_DMG*4 致死 + 触发顿帧；范围外不受
##   [skillcd] BoomSkillSystem 冷却：CD 中连发只触发 1 次，CD 归零可再触发
##   [m3-logic] M3 纯逻辑：击杀播报阈值(2/3/5→DOUBLE/TRIPLE/RAMPAGE)、结算星级(2/4/6 波)
##   [m3-settle] M3 结算状态机：game over → 0.3x 慢镜头 → 恢复 1.0x 启动结算序列
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
		_test_art_and_props()
		_test_wave_advance()
		_test_skills()
		_test_skill_system_cd()
		_test_m3_logic()
		_test_m3_settlement()
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
	_check(_main.get("skill_sys") != null, "skill_sys 技能系统已注入")
	_check(_main.get("skill_fx") != null, "skill_fx 技能特效已注入")
	var btns: Dictionary = _main.get("skill_btns")
	_check(btns.size() == 3, "技能 HUD 3 个圆形按钮已构建 (n=%d)" % btns.size())
	_check(_main.get("waypoints") != null, "waypoint 边缘标记层已构建")
	_check(_main.get("_combo_label") != null, "击杀播报大字 Label 已构建")
	if not has_sim:
		return
	var sim := _main.get("sim") as BoomGame
	_check(sim.player != null, "sim.player 存在")
	_check(sim.player.hp == sim.player.max_hp, "开局满血 hp=5")
	_check(sim.wave == 1, "初始波次 1")
	var st: Dictionary = _main.call("_test_hook_get_state")
	_check(st.has("score") and st.has("wave") and st.has("hp"), "test_hook state 键完整")
	for asset_path in [
		"res://assets/images/characters/bubble_captain.png",
		"res://assets/images/characters/jelly_scout.png",
		"res://assets/images/characters/water_gunner.png",
		"res://assets/images/floors/carnival_tiles.png",
		"res://assets/images/icons/skill_nuke.png",
	]:
		_check(ResourceLoader.exists(asset_path), "美术资源可加载: %s" % asset_path)


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


# ------------------------------------------------------------------ 美术资源 / 可破坏物


func _test_art_and_props() -> void:
	print("[art-props]")
	var g := _new_game()
	_check(g.props.size() == 3, "场景创建 3 个可破坏物")
	var prop := g.props[0] as BoomProp
	_check(prop != null and not prop.broken, "可破坏物初始可见")
	if prop != null:
		_check(not prop.take_damage(), "木箱首次命中不立即破碎")
		_check(prop.take_damage(), "木箱第二次命中破碎")
		g.call("_finalize_prop", prop)
		_check(g.coins == 1, "破坏物奖励金币 +1")
	g.free()


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


# ------------------------------------------------------------------ M2 技能（BoomGame 层）


func _test_skills() -> void:
	print("[skills]")
	# 3 个独立游戏实例，避免击杀/顿帧串扰，保证各自断言干净。
	_test_fan_hit()
	_test_chain_hits()
	_test_nuke_aoe()


func _test_fan_hit() -> void:
	var g := _new_game()
	g.player.invuln_left = 10.0
	# 正前方放一个敌人，扇形中线对准它。
	var jelly := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	var before: int = _active_bullets(g)
	var n: int = g.cast_fan_shot()
	_check(n == BoomGame.FAN_COUNT, "fan 发射 %d 发 (返回 %d)" % [BoomGame.FAN_COUNT, n])
	_check(_active_bullets(g) == before + BoomGame.FAN_COUNT, "fan 后活跃子弹 +%d" % BoomGame.FAN_COUNT)
	# 让扇形子弹飞行命中单敌（3HP，多发齐中应致死）。
	var guard := 0
	while guard < MAX_FRAMES and not jelly.is_dead():
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
	_check(jelly.is_dead(), "fan 扇形 5 发命中单敌致死")


func _test_chain_hits() -> void:
	var g := _new_game()
	g.player.invuln_left = 10.0
	# 三个敌人彼此链式分布在跳跃范围内（8m 内），首跳从最近敌人起。
	var a := g.spawn_enemy_at(Vector3(0.0, 0.0, -3.0))
	var b := g.spawn_enemy_at(Vector3(0.0, 0.0, -3.0 - 4.0))
	var c := g.spawn_enemy_at(Vector3(0.0, 0.0, -3.0 - 8.0))
	# a 距玩家最近(-3)，a->b 4m，b->c 4m，均在链程内。
	# GDScript lambda 对局部 int 按值捕获，必须用容器(Array)承载计数才能回写。
	var dmg_box: Array = [0]
	g.enemy_damaged.connect(func(_pos: Vector3, _dir: Vector3) -> void: dmg_box[0] += 1)
	var chain_hits: Array = g.cast_chain_arc()
	var damaged: int = dmg_box[0]
	# 每跳至少造成 1 伤害：三次伤害跳各触发一次 damaged。
	_check(damaged == 3, "chain 命中 3 个不同敌人 (damaged=%d)" % damaged)
	_check(not a.is_dead() and not b.is_dead() and not c.is_dead(), "chain 三敌未被秒杀（各受少量伤害）")
	# P1-2：命中即返回（含存活者）——main.gd 依赖它为存活目标画电弧/提示。
	_check(chain_hits.size() == 3, "chain 返回命中数组含存活者 (hits=%d)" % chain_hits.size())


func _test_nuke_aoe() -> void:
	var g := _new_game()
	g.player.invuln_left = 10.0
	# 范围内敌（玩家原点，4m < 6m）应被 4 伤害一击秒；范围外(8m)不受。
	var inside := g.spawn_enemy_at(Vector3(4.0, 0.0, 0.0))
	var outside := g.spawn_enemy_at(Vector3(8.0, 0.0, 0.0))
	var dmg_before: float = g._freeze_left
	var hits: Array = g.cast_aoe_nuke()
	_check(hits.size() == 1, "nuke 命中 1 个范围内敌 (hits=%d)" % hits.size())
	_check(inside.is_dead(), "nuke 范围内敌被 4 伤秒杀")
	_check(g.kills == 1, "nuke 击杀计数 +1")
	_check(outside.is_dead() == false, "nuke 范围外敌未受伤害")
	_check(g._freeze_left >= 0.14 and g._freeze_left > dmg_before, "nuke 命中触发 0.14s 顿帧")


# ------------------------------------------------------------------ BoomSkillSystem 冷却


func _test_skill_system_cd() -> void:
	print("[skillcd]")
	var g := _new_game()
	var sys := BoomSkillSystem.new()
	sys.game = g
	g.add_child(sys)
	# GDScript lambda 按值捕获局部 int；用容器承载计数才能跨信号累加。
	var fired_box: Array = [0]
	sys.skill_fired.connect(func(_id: String, _r: Variant) -> void: fired_box[0] += 1)
	# 就绪态第一次 tap 应触发 fan。
	sys.handle_tap()
	var fired_count: int = fired_box[0]
	_check(fired_count == 1, "就绪态 tap 触发 fan 1 次")
	var st: Dictionary = sys.get_state()
	_check(st["fan"] > 0.0, "fan 施放后进入 CD (cooldown_left=%.2f)" % st["fan"])
	# 冷却中连发不触发（fan CD 3s 未到）。
	sys.handle_tap()
	fired_count = fired_box[0]
	_check(fired_count == 1, "CD 中 tap 不重复触发 fan")
	# 其它技能独立不受 fan CD 影响。
	sys.handle_swipe_left()
	sys.handle_swipe_right()
	fired_count = fired_box[0]
	_check(fired_count == 3, "chain/nuke 就绪，另两技能仍可触发 (fired=%d)" % fired_count)
	# 越过 fan CD 后即可再次触发。
	sys.tick(BoomSkillSystem.FAN_COOLDOWN + 0.1)
	var st2: Dictionary = sys.get_state()
	_check(st2["fan"] <= 0.0, "tick 越过 CD 后 fan 冷却归零 (%.2f)" % st2["fan"])
	sys.handle_tap()
	fired_count = fired_box[0]
	_check(fired_count == 4, "CD 归零后 tap 再触发 fan (fired=%d)" % fired_count)
	g.remove_child(sys)
	sys.free()


# ------------------------------------------------------------------ M3 纯逻辑 + 结算状态机


func _test_m3_logic() -> void:
	print("[m3-logic]")
	_check(BoomGame.announce_for_combo(0) == "", "combo 0 不播报")
	_check(BoomGame.announce_for_combo(1) == "", "combo 1 不播报")
	_check(BoomGame.announce_for_combo(2) == "DOUBLE", "combo 2 → DOUBLE")
	_check(BoomGame.announce_for_combo(3) == "TRIPLE", "combo 3 → TRIPLE")
	_check(BoomGame.announce_for_combo(4) == "TRIPLE", "combo 4 维持 TRIPLE 档")
	_check(BoomGame.announce_for_combo(5) == "RAMPAGE", "combo 5 → RAMPAGE")
	_check(BoomGame.announce_for_combo(9) == "RAMPAGE", "combo 9 → RAMPAGE")
	_check(BoomGame.result_stars(1) == 0, "wave 1 → 0 星")
	_check(BoomGame.result_stars(2) == 1, "wave 2 → 1 星")
	_check(BoomGame.result_stars(4) == 2, "wave 4 → 2 星")
	_check(BoomGame.result_stars(6) == 3, "wave 6 → 3 星")
	_check(BoomGame.result_stars(10) == 3, "wave 10 → 封顶 3 星")


func _test_m3_settlement() -> void:
	print("[m3-settle]")
	var panel: Control = _main.get("_over_panel")
	_check(panel != null, "结算面板已构建")
	if panel == null:
		return
	_check(not panel.visible, "开局结算面板隐藏")
	_main.call("_on_game_over", 88)
	_check(panel.visible, "game over 后结算面板显示")
	_check(is_equal_approx(Engine.time_scale, 0.3), "最后一击进入 0.3x 慢镜头")
	var stars: Array = _main.get("_result_stars")
	_check(stars.size() == 3, "结算星级 3 颗已构建")
	# 直接推进状态机（避免无头环境下 tween 墙钟时序抖动）：
	# 慢镜头结束 → time_scale 恢复 → 结算序列已启动。
	_main.call("_end_slowmo")
	_check(is_equal_approx(Engine.time_scale, 1.0), "慢镜头恢复 1.0x")
	_check(int(_main.get("_slowmo_until_ms")) == 0, "慢镜头计时已清零（序列已启动）")


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
