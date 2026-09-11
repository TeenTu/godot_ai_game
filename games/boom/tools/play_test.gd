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
##   [skill-float] §4.2 技能飘字：文案/颜色/字号映射（嘭!/链!/轰!）+ fan 命中飘字入池
##   [skillcd] BoomSkillSystem 冷却：CD 中连发只触发 1 次，CD 归零可再触发
##   [m3-logic] M3 纯逻辑：击杀播报阈值(2/3/5→DOUBLE/TRIPLE/RAMPAGE)、结算星级(2/4/6 波)
##   [m3-settle] M3 结算状态机：game over → 0.3x 慢镜头 → 恢复 1.0x 启动结算序列
##   [m4-wave]  M4 波次系统（design_m4_waves.md §7）：
##              1. 怪海配额边界 W1/4/5/9/10/封顶 96
##              2. 间歇阶梯 2.5/2.0/1.5/1.0 + 清波后 step(2.4) 不换波、越 2.5s 换波
##              3. 属性阶梯 W1/W5/W10 HP 30/40/50、W10 速度 1.7×1.1、W40 封顶 1.3×30=80
##              4. 精英标记 W5 最后一只/W4 否；精英 HP120/radius 0.84/速度 ×0.85
##              5. 精英死亡金币雨 8×5=40 逐枚入账；波奖励查表 + 台阶 ×2
##              6. 同屏 48 封顶、批量刷新、四帧分离轮转；auto_spawn=false 回归
##   [m5-weapon] M5 武器系统（design_m5_weapons.md §3/§4/§6）：
##              1. 注册表 BoomWeapons：两把武器、默认恒为泡泡、未知 id 回退
##              2. set_weapon 注入机体数值：大剑 HP 5→7、移速 ×0.85、形态 sword
##              3. 判笔重剑：0.32/0.08/0.36 节奏、150°×2.9m、最多 12 敌、独立墨迹层
##              4. 无目标不空挥：近战待机保持 NONE，不消耗挥斩
##              5. 选武器 UX（main 层）：选单默认泡泡、确认后开战/隐藏选单/
##                 max_hp 血条上限重建 7
##   [m7-assets] 夜巡灯使帧条素材存在性（无武器身体动作条 + 暂存 weapon 图标，
##              ResourceLoader.exists 走 .import remap）
##   [m7-stats]  M7 属性系统已被 M8 重构（design_m8_attributes.md）→ 节点见 [m8-*] 分册
##   [m7-exp]    M7 经验升级（§4）：曲线边界 5/9、跨级信号、满级封顶、
##              击杀 +1 xp / 精英 +6 xp（M8 §11.2）/ 升级产属性点
##   [m7-tree]   M7R 每武器技能树（§5）：全池 9 定义、双武器树 6 槽序列、跨树过滤、
##              树内顺序价 60/120/200/300/420、跨局存档解锁扣币、装备上限 3、
##              槽位手势重映射、ring 12 发 / twin 2 发 / heal 回复、跨局保留
##   [m7-passive] M7R 武器专属被动（§5.1）：rapid 射速 ×0.8 / titan 弧斩 +1、
##              被动不进施放管线、whirl 旋风斩命中与封顶
##   [m7-save]   M7R 跨局存档（§8）：默认结构、roundtrip（写→清内存→读一致）、
##              对局金币即时入档、restart 保留、结算落盘
##   [m7-tree-ui] M7R 选单技能配置区（§5.5）：按当前武器切换 6 行、跨树技能不可见、
##              价格标注、行点击解锁/勾选
##   [m10-font] M10 §9 Web CJK 字体：ui_theme.tres/default_font = 中文字集，
##              全部可见文案（技能/描述/分支/首领/升级卡/稀有奖励）字形齐备
##   [m8-*]      M8 属性/战斗数值/升级卡/属性面板分册 → tools/play_test_m8.gd
##
## 用法：godot --headless --path games/boom --script res://tools/play_test.gd

const DT: float = 1.0 / 60.0
const MAX_FRAMES: int = 1200

var _failures := 0
var _step := 0
var _smoke_done := false
var _logic_done := false
var _main: Node
## M7/M7R 测试分册（tools/play_test_m7.gd，控制本文件行数门禁）。
var _m7_tests: RefCounted
## M8 测试分册（tools/play_test_m8.gd，控制本文件行数门禁）。
var _m8_tests: RefCounted
## M11 首领战与奖励测试分册。
var _m11_tests: RefCounted
## M12 技能完成度与触发链测试分册。
var _m12_tests: RefCounted


func _initialize() -> void:
	seed(20260902)
	BoomSave._path = "user://boom_headless_test_save.json"
	# 主场景构建前先清测试档，避免本机试玩解锁状态污染默认主动槽断言。
	BoomSave.test_reset()
	_m7_tests = preload("res://tools/play_test_m7.gd").new(self)
	_m8_tests = preload("res://tools/play_test_m8.gd").new(self)
	_m11_tests = preload("res://tools/play_test_m11.gd").new(self)
	_m12_tests = preload("res://tools/play_test_m12.gd").new(self)
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
		_test_skill_float_text()
		_test_skill_system_cd()
		_test_m3_logic()
		_test_m3_settlement()
		_test_m4_waves()
		_test_m5_weapons()
		_m7_tests.run_all()
		_m8_tests.run_all()
		_m11_tests.run_all()
		_m12_tests.run_all()
		_failures += preload("res://tools/play_test_m13.gd").new().run(self)
		_test_ui_font()
		_finish()
	return false


## [m10-font] Web 无系统 CJK 回退（DESIGN_M10 §9）：内嵌中文字集覆盖全部可见
## 文案，且顶层 Control 主题确实继承到该字体——否则线上中文全变豆腐块。
## 覆盖范围：12 技能名 + 12 描述 + 技能飘字 + 连击播报 + 手势提示 + 圆心缩写
## + 2 分支标题 + 首领名 + 升级卡 + 稀有奖励 + HUD 内联提示。
func _test_ui_font() -> void:
	print("[m10-font]")
	var theme := load("res://assets/fonts/ui_theme.tres") as Theme
	var font := load("res://assets/fonts/ui_subset.ttf") as FontFile
	_check(theme != null and font != null, "ui_theme.tres / ui_subset.ttf 均可加载")
	if theme == null or font == null:
		return
	_check(theme.default_font == font, "主题 default_font 指向中文字集字体")
	# 运行时取值链：Control.theme → default_font（Label 无自备字体时用的就是它）。
	var probe := Control.new()
	probe.theme = theme
	_check(probe.get_theme_default_font() == font, "控件经主题继承取到中文字集字体")
	probe.free()
	var sample := "0123456789%/+-·：×° "
	var sys := BoomSkillSystem.new()
	var pool_ids := sys.pool_ids()
	for skill_id in pool_ids:
		var skill := sys.get_skill(skill_id)
		sample += skill.display_name + BoomSkillSystem.description_for(skill_id)
		# 技能飘字走 Label3D（不继承 Control 主题），单独覆盖。
		sample += String(BoomSkillSystem.float_text_for(skill_id).get("text", ""))
	sys.free()
	# 击杀播报大字（HUD Control + Label3D 双路径）。
	for combo in [2, 3, 5]:
		sample += BoomGame.announce_for_combo(combo)
	# 顶层 HUD 常量：手势提示 + 无位图技能的圆心缩写（main.gd 无 class_name，
	# 经脚本常量表读取，避免测试里重复硬编码）。
	var main_script := load("res://scripts/main.gd") as GDScript
	var main_consts: Dictionary = main_script.get_script_constant_map()
	for gesture in main_consts.get("SKILL_GESTURES", []):
		sample += String(gesture)
	for abbrev in (main_consts.get("SKILL_ABBREVS", {}) as Dictionary).values():
		sample += String(abbrev)
	sample += "闪避气血"  # HUD 闪避提示 / 回血飘字（main.gd 内联字面量）
	for branch in ["basic", "skill"]:
		sample += BoomSkillSystem.branch_title(branch)
	sample += BoomBoss.DISPLAY_NAME
	for card: Dictionary in BoomLevelUpPanel.CARD_DEFS.values():
		sample += String(card["title"]) + String(card["desc"])
	for rare: Dictionary in BoomBossRewards.RARE_DEFS:
		sample += String(rare["title"]) + String(rare["desc"])
	var missing := ""
	for i in sample.length():
		var c := sample[i]
		if not missing.contains(c) and not font.has_char(c.unicode_at(0)):
			missing += c
	_check(missing == "", "全部可见文案有字形（缺字=%s）" % ("无" if missing == "" else missing))


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: ", msg)
	else:
		_failures += 1
		print("  FAIL: ", msg)


func _finish() -> void:
	# M7R 无残留保证：测试全程可能写过 user://boom_save.json，收尾清档。
	BoomSave.test_reset()
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
	_check(_main.get("_skill_presenter") != null, "四主动技能表现协调器已注入")
	var btns: Dictionary = _main.get("skill_btns")
	_check(btns.size() == 3, "技能 HUD 3 个圆形按钮已构建 (n=%d)" % btns.size())
	# 双分支新档仍装备两根节点；HUD 只投影主动技能，防止被动吞掉手势。
	_check(btns.has("0") and btns.has("1") and btns.has("2"), "HUD 按钮按槽位 key 0/1/2")
	var skill_sys_hud: BoomSkillSystem = _main.get("skill_sys")
	if (
		skill_sys_hud != null
		and skill_sys_hud.equipped == ["lamp_quick_wick", "lamp_firefly_volley"]
	):
		var slot2: Control = btns["2"]
		_check(slot2 != null and slot2.get("is_empty_slot") == true, "默认档第三主动槽为空槽灰显")
	var slot0: Control = btns["0"]
	var slot1: Control = btns["1"]
	_check(slot0 != null and slot0.get("skill_id") == "lamp_firefly_volley", "默认 tap 槽展示流萤散射")
	_check(slot1 != null and slot1.get("is_empty_slot") == true, "默认左滑主动槽为空")
	_check(_main.get("waypoints") != null, "waypoint 边缘标记层已构建")
	_check(_main.get("_combo_label") != null, "击杀播报大字 Label 已构建")
	if not has_sim:
		return
	var sim := _main.get("sim") as BoomGame
	_check(sim.player != null, "sim.player 存在")
	# M5：玩家动画管线 2D 化（design §6/§7）——默认泡泡形态 + AnimatedSprite3D 激活。
	_check(sim.player.anim_form == "bubble", "默认武器形态 = 泡泡")
	_check(sim.player.hp == sim.player.max_hp, "开局为当前武器满血")
	_check(sim.player.is_2d_form(), "玩家 2D 动画管线已激活（AnimatedSprite3D）")
	_check(sim.wave == 1, "初始波次 1")
	_check(
		BoomGame.PLAYER_BOUND_X >= 8.0 and BoomGame.PLAYER_BOUND_Z >= 24.0,
		"夜巡可玩区域已扩展（玩家边界 %.1f×%.1f）" % [BoomGame.PLAYER_BOUND_X, BoomGame.PLAYER_BOUND_Z],
	)
	var st: Dictionary = _main.call("_test_hook_get_state")
	_check(st.has("score") and st.has("wave") and st.has("hp"), "test_hook state 键完整")
	for asset_path in [
		"res://assets/images/icons/weapon_night_ruler.png",
		"res://assets/images/icons/weapon_ink_judge_brush.png",
		"res://assets/images/weapons/night_patrol/night_ruler_idle.png",
		"res://assets/images/weapons/night_patrol/night_ruler_move.png",
		"res://assets/images/weapons/night_patrol/night_ruler_recoil.png",
		"res://assets/images/weapons/night_patrol/ink_brush_idle.png",
		"res://assets/images/weapons/night_patrol/ink_brush_move.png",
		"res://assets/images/weapons/night_patrol/ink_brush_swing.png",
		"res://assets/images/effects/ink_brush_swing_fx.png",
		"res://assets/images/characters/night_patrol/hero_melee_left_body.png",
		"res://assets/images/characters/night_patrol/hero_melee_right_body.png",
		"res://assets/images/characters/night_patrol/hero_melee_whirl_body.png",
		"res://assets/images/weapons/night_patrol/ink_brush_swing_left.png",
		"res://assets/images/weapons/night_patrol/ink_brush_swing_right.png",
		"res://assets/images/weapons/night_patrol/ink_brush_swing_whirl.png",
		"res://assets/images/effects/ink_brush_swing_left_fx.png",
		"res://assets/images/effects/ink_brush_swing_right_fx.png",
		"res://assets/images/effects/ink_brush_swing_whirl_fx.png",
		"res://assets/images/characters/paper_doll_move_down.png",
		"res://assets/images/characters/paper_doll_move_up.png",
		"res://assets/images/characters/paper_doll_move_left.png",
		"res://assets/images/characters/paper_doll_move_right.png",
		"res://assets/images/characters/mist_spirit_float.png",
		"res://assets/images/backgrounds/rainy_ancient_town.png",
		"res://assets/images/floors/wet_stone_tiles.png",
		"res://assets/images/characters/night_patrol/hero_move_down_right.png",
		"res://assets/images/characters/night_patrol/hero_move_down_left.png",
		"res://assets/images/characters/night_patrol/hero_move_up_left.png",
		"res://assets/images/characters/night_patrol/hero_move_up_right.png",
	]:
		_check(ResourceLoader.exists(asset_path), "美术资源可加载: %s" % asset_path)
	for retired_path in [
		"res://assets/images/characters/bubble_captain.png",
		"res://assets/images/characters/jelly_scout.png",
		"res://assets/images/characters/water_gunner.png",
		"res://assets/images/backgrounds/carnival_arena.png",
		"res://assets/images/floors/carnival_tiles.png",
		"res://assets/images/icons/coin.png",
	]:
		_check(not ResourceLoader.exists(retired_path), "已替换素材已退出运行目录: %s" % retired_path)


# ------------------------------------------------------------------ 玩家移动


func _new_game() -> BoomGame:
	var g := BoomGame.new()
	g.auto_spawn = false
	return g


func _test_player_moves() -> void:
	print("[player-move]")
	var g := _new_game()
	for sample in [
		[Vector2(1.0, 1.0), "down_right"],
		[Vector2(-1.0, 1.0), "down_left"],
		[Vector2(-1.0, -1.0), "up_left"],
		[Vector2(1.0, -1.0), "up_right"],
	]:
		g.player.set_move(sample[0])
		_check(g.player.facing_anim == sample[1], "八向输入解析为 %s" % sample[1])
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
	# M5：props 改由 begin_match 生成（R9 把开波从构造拆出），先开战再断言。
	g.begin_match()
	var enemy := g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	_check(enemy.get("_art") != null, "纸偶/雾灵雪碧层已挂入敌人")
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
	g.begin_match()
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
	_check(inside.is_dead(), "nuke 范围内敌被 10×4 伤秒杀")
	_check(g.kills == 1, "nuke 击杀计数 +1")
	_check(outside.is_dead() == false, "nuke 范围外敌未受伤害")
	_check(g._freeze_left >= 0.14 and g._freeze_left > dmg_before, "nuke 命中触发 0.14s 顿帧")


# ------------------------------------------------------------------ §4.2 技能飘字


func _test_skill_float_text() -> void:
	print("[skill-float]")
	# 文案/颜色/字号映射（§4.2 规格表：fan 黄小字 / chain 紫大字 / nuke 金巨型）。
	var fan_spec: Dictionary = BoomSkillSystem.float_text_for("fan")
	_check(fan_spec["text"] == "嘭!", "fan 飘字文案 = 嘭!")
	_check(fan_spec["color"] == BoomSkillSystem.TEXT_COLOR_FAN, "fan 飘字颜色 = 黄")
	var chain_spec: Dictionary = BoomSkillSystem.float_text_for("chain")
	_check(chain_spec["text"] == "链!", "chain 飘字文案 = 链!")
	_check(chain_spec["color"] == BoomSkillSystem.TEXT_COLOR_CHAIN, "chain 飘字颜色 = 紫")
	var nuke_spec: Dictionary = BoomSkillSystem.float_text_for("nuke")
	_check(nuke_spec["text"] == "轰!", "nuke 飘字文案 = 轰!")
	_check(nuke_spec["color"] == BoomSkillSystem.TEXT_COLOR_NUKE, "nuke 飘字颜色 = 金")
	# 字号阶梯：小字 < 大字 < 巨型。
	var fan_sc: float = fan_spec["scale"]
	var chain_sc: float = chain_spec["scale"]
	var nuke_sc: float = nuke_spec["scale"]
	_check(fan_sc < chain_sc and chain_sc < nuke_sc, "飘字字号阶梯 fan<chain<nuke")
	_check(BoomSkillSystem.float_text_for("unknown").is_empty(), "未登记技能返回空规格")
	# fan 每命中 1 个飘字：BoomGame 驱动扇形弹命中 → skill_bullet_hit → 飘字入池。
	var g := _new_game()
	g.player.invuln_left = 10.0
	var hn := BoomHitNum.new()
	root.add_child(hn)
	g.skill_bullet_hit.connect(
		func(pos: Vector3, skill_id: String) -> void:
			var spec: Dictionary = BoomSkillSystem.float_text_for(skill_id)
			if not spec.is_empty():
				var text: String = spec["text"]
				var col: Color = spec["color"]
				var sc: float = spec["scale"]
				hn.spawn(pos, text, col, sc)
	)
	g.spawn_enemy_at(Vector3(0.0, 0.0, -5.0))
	g.cast_fan_shot()
	var guard := 0
	while guard < MAX_FRAMES and hn.active_count() == 0:
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
	_check(hn.active_count() > 0, "fan 命中后技能飘字入池")
	var lbl: Label3D = hn.first_active()
	_check(lbl != null and lbl.text == "嘭!", "fan 命中飘字文本 = 嘭!")
	root.remove_child(hn)
	hn.free()
	g.free()


# ------------------------------------------------------------------ BoomSkillSystem 冷却


func _test_skill_system_cd() -> void:
	print("[skillcd]")
	BoomSave.test_reset()
	var g := _new_game()
	var sys := BoomSkillSystem.new()
	sys.game = g
	g.add_child(sys)
	# 信号记录 fired 次数与技能 id（验证手势路由目标技能，而不只是计数）。
	var fired_box: Array = [0]
	var ids_box: Array = []
	sys.skill_fired.connect(
		func(id: String, _r: Variant) -> void:
			fired_box[0] += 1
			ids_box.append(id)
	)
	_check(sys.equipped == ["lamp_quick_wick", "lamp_firefly_volley"], "新档默认装备镇夜灯两条分支根节点")
	_check(sys.active_equipped() == ["lamp_firefly_volley"], "主动触发槽过滤被动根节点")
	_check(sys.passive_equipped() == ["lamp_quick_wick"], "被动根节点保留在构筑并持续生效")
	# tap 始终触发第一个主动技能。
	sys.handle_tap()
	_check(fired_box[0] == 1, "tap 触发第一个主动技能")
	_check(ids_box[-1] == "lamp_firefly_volley", "tap 路由到流萤散射")
	var st: Dictionary = sys.get_state()
	_check(st["lamp_firefly_volley"] > 0.0, "流萤散射施放后进入 CD (%.2f)" % st["lamp_firefly_volley"])
	sys.handle_tap()
	_check(fired_box[0] == 1, "冷却中不可重复施放")
	sys.tick(BoomSkillSystem.LAMP_VOLLEY_COOLDOWN + 0.1)
	var st2: Dictionary = sys.get_state()
	_check(st2["lamp_firefly_volley"] <= 0.0, "tick 越过 CD 后冷却归零")
	# 解锁技能终阶并装入构筑第三槽；第二个主动技能映射为左滑。
	sys.debug_grant("lamp_soul_beacon")
	_check(sys.equip("lamp_soul_beacon"), "魂灯结界装备到第三槽")
	var before: int = _active_bullets(g)
	sys.handle_swipe_left()
	_check(ids_box[-1] == "lamp_soul_beacon", "左滑路由到第二主动技能魂灯结界")
	_check(_active_bullets(g) == before + BoomGame.RING_COUNT, "魂灯结界生成 12 枚环形灵印")
	g.remove_child(sys)
	sys.free()
	g.free()
	BoomSave.test_reset()


# ------------------------------------------------------------------ M3 纯逻辑 + 结算状态机


func _test_m3_logic() -> void:
	print("[m3-logic]")
	_check(BoomGame.announce_for_combo(0) == "", "combo 0 不播报")
	_check(BoomGame.announce_for_combo(1) == "", "combo 1 不播报")
	_check(BoomGame.announce_for_combo(2) == "双杀", "combo 2 → 双杀")
	_check(BoomGame.announce_for_combo(3) == "三杀", "combo 3 → 三杀")
	_check(BoomGame.announce_for_combo(4) == "三杀", "combo 4 维持三杀档")
	_check(BoomGame.announce_for_combo(5) == "狂暴", "combo 5 → 狂暴")
	_check(BoomGame.announce_for_combo(9) == "狂暴", "combo 9 → 狂暴")
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


# ------------------------------------------------------------------ M4 波次系统


func _test_m4_waves() -> void:
	print("[m4-wave]")
	# §7.2 配额分段公式边界值。
	var g := _new_game()
	_check(BoomCombatMath.wave_quota(1) == 12, "quota W1 = 12（怪海起步）")
	_check(BoomCombatMath.wave_quota(4) == 24, "quota W4 = 24")
	_check(BoomCombatMath.wave_quota(5) == 30, "quota W5 = 30（中段起步）")
	_check(BoomCombatMath.wave_quota(9) == 54, "quota W9 = 54")
	_check(BoomCombatMath.wave_quota(10) == 64, "quota W10 = 64（怪海台阶）")
	_check(BoomCombatMath.wave_quota(99) == 96, "quota W99 封顶 96")
	# §3.4 间歇阶梯查表。
	_check(is_equal_approx(BoomCombatMath.wave_rest(1), 2.5), "rest W1 = 2.5s")
	_check(is_equal_approx(BoomCombatMath.wave_rest(4), 2.5), "rest W4 = 2.5s")
	_check(is_equal_approx(BoomCombatMath.wave_rest(5), 2.0), "rest W5 = 2.0s")
	_check(is_equal_approx(BoomCombatMath.wave_rest(10), 1.5), "rest W10 = 1.5s")
	_check(is_equal_approx(BoomCombatMath.wave_rest(15), 1.0), "rest W15 = 1.0s（下限）")
	_check(is_equal_approx(BoomCombatMath.wave_rest(40), 1.0), "rest W40 = 1.0s")
	# §3.5 波奖励查表 + 台阶波 ×2。
	_check(BoomCombatMath.wave_bonus(1) == 30, "bonus W1 = 30")
	_check(BoomCombatMath.wave_bonus(9) == 110, "bonus W9 = 110")
	_check(BoomCombatMath.wave_bonus(10) == 240, "bonus W10 = 240（台阶 ×2）")
	_check(BoomCombatMath.wave_bonus(20) == 440, "bonus W20 = 440（台阶 ×2）")
	# 怪海同屏曲线：W1=16 / W5=32 / W9 起封顶 48。
	g.wave = 8
	_check(g._max_alive() == 44, "max_alive W8 = 44")
	g.wave = 10
	_check(g._max_alive() == 48, "max_alive W10 = 48")
	g.wave = 50
	_check(g._max_alive() == 48, "max_alive W50 封顶 48")
	g.free()
	# 一次刷新批量入场；高波次每次最多 4 只，仍受同屏/配额双上限约束。
	var gh := BoomGame.new()
	gh.wave = 11  # W10 已由 M11 改为 Boss 波；用首个高阶普通波验证 burst。
	gh.begin_match()
	gh._spawn_cd = 0.0
	gh.step(DT)
	_check(gh.enemies.size() == 4, "W11 普通波单次 burst 刷入 4 只")
	_check(gh._spawned_total == 4, "burst 正确累计配额")
	# 性能结构：2D 敌人不再创建隐藏回退网格；48 敌分离按四帧轮转。
	var sample := gh.enemies[0] as BoomJelly
	var mesh_count := 0
	for child in sample.get_children():
		if child is MeshInstance3D:
			mesh_count += 1
	_check(mesh_count == 1, "2D 敌人仅保留 1 个预警圈网格（无隐藏回退网格）")
	_check(BoomGame.CROWD_SEPARATION_STRIDE == 4, "怪群 O(n²) 分离按四帧轮转")
	gh.free()
	# §7.4 属性阶梯：HP 30→40→50、W40 封顶 80；速度 1.0→1.1→1.3 封顶（硬红线）。
	var g2 := _new_game()
	_check(g2.spawn_enemy_at(Vector3(0.0, 0.0, -5.0)).hp == 30, "W1 敌 HP = 30（M8 30 点制）")
	g2.wave = 5
	_check(g2.spawn_enemy_at(Vector3(2.0, 0.0, 0.0)).hp == 40, "W5 敌 HP = 40")
	g2.wave = 10
	var j10 := g2.spawn_enemy_at(Vector3(4.0, 0.0, 0.0))
	_check(j10.hp == 50, "W10 敌 HP = 50")
	_check(absf(j10.walk_speed - 1.7 * 1.1) < 0.01, "W10 速度 ≈ 1.7×1.1")
	_check(absf(j10.lunge_speed - 11.0 * 1.1) < 0.01, "W10 冲撞速度 ≈ 11×1.1")
	g2.wave = 40
	var j40 := g2.spawn_enemy_at(Vector3(-4.0, 0.0, 0.0))
	_check(absf(j40.walk_speed - 1.7 * 1.3) < 0.01, "W40 速度封顶 1.7×1.3（硬红线）")
	_check(j40.hp == 80, "W40 敌 HP 封顶 = 80")
	g2.free()
	# §7.5 精英：W5 最后一只 HP×3（40×3=120）/ 体型×1.4 / 速度×0.85，死亡金币雨 40。
	var g3 := _new_game()
	g3.wave = 5
	var elite := g3.spawn_enemy_at(Vector3(0.0, 0.0, -5.0), true)
	_check(elite.hp == 120, "W5 精英 HP = round(40×3) = 120")
	_check(absf(elite.radius - 0.6 * 1.4) < 0.001, "精英 radius ≈ 0.6×1.4")
	_check(absf(elite.walk_speed - 1.7 * 0.85) < 0.01, "精英速度 = 1.7×0.85（更慢）")
	_check(elite.elite, "精英标记已置位")
	# 精英只在配额最后一只触发：未满额否 / 满额是 / W4 满额否。
	g3._quota_current = BoomCombatMath.wave_quota(5)
	g3._spawned_total = g3._quota_current - 1
	_check(not g3._is_elite_spawn(), "W5 非最后一只不触发精英")
	g3._spawned_total = g3._quota_current
	_check(g3._is_elite_spawn(), "W5 最后一只触发精英")
	g3.wave = 4
	g3._quota_current = BoomCombatMath.wave_quota(4)
	g3._spawned_total = g3._quota_current
	_check(not g3._is_elite_spawn(), "W4 不触发精英")
	# 击杀精英 → 金币雨 8×5 = 40 逐枚入账（§7.5 断言总额）。
	g3.player.invuln_left = 10.0
	var guard := 0
	while guard < MAX_FRAMES and not elite.is_dead():
		guard += 1
		g3.player.invuln_left = 10.0
		g3.step(DT)
	_check(elite.is_dead(), "精英被自动火力击杀")
	_check(
		g3.coins == BoomGame.ELITE_COIN_COUNT * BoomGame.ELITE_COIN_VALUE,
		"精英金币雨入账 40 (coins=%d)" % g3.coins
	)
	g3.free()
	# §7.1/§7.3 波次推进：清波信号查表 bonus → 间歇 2.4s 不换波 → 越 2.5s 换波。
	var g4 := _new_game()
	g4.player.invuln_left = 10.0
	g4.begin_match()
	var jelly := g4.spawn_enemy_at(Vector3(0.0, 0.0, -5.5))
	g4.force_wave_spawned_done()
	var cleared: Array = []
	var started: Array = []
	g4.wave_cleared.connect(func(w: int, b: int) -> void: cleared.append([w, b]))
	g4.wave_started.connect(func(w: int) -> void: started.append(w))
	var guard2 := 0
	while guard2 < MAX_FRAMES and cleared.is_empty():
		guard2 += 1
		g4.player.invuln_left = 10.0
		g4.step(DT)
	_check(
		cleared.size() == 1 and cleared[0][0] == 1 and cleared[0][1] == 30,
		"wave_cleared(1, bonus=30) 查表正确"
	)
	_run(g4, int(2.4 / DT))
	_check(g4.wave == 1, "间歇 2.4s 未换波（W1 间歇 2.5s）")
	_run(g4, int(0.5 / DT))
	_check(g4.wave == 2, "越过 2.5s 后推进到 W2")
	_check(started.size() == 1, "W2 wave_started 已发 (n=%d)" % started.size())
	# §7.7 auto_spawn=false 回归：手动刷怪路径不受配额逻辑影响。
	_check(g4.enemies.is_empty(), "auto_spawn=false 无自动刷怪")
	var manual := g4.spawn_enemy_at(Vector3(0.0, 0.0, -6.0))
	_check(manual != null and g4.enemies.size() == 1, "手动 spawn_enemy_at 正常入列")
	g4.free()


# ------------------------------------------------------------------ M5 武器系统


func _test_m5_weapons() -> void:
	print("[m5-weapon]")
	# 1) 注册表：两武器 / 默认恒泡泡 / 未知 id 回退 / 关键参数。
	var defs: Array = BoomWeapons.all()
	_check(defs.size() == 2, "注册表登记 2 把武器 (n=%d)" % defs.size())
	_check(BoomWeapons.default_id() == "bubble", "默认武器恒为泡泡枪")
	var bubble: BoomWeaponDef = BoomWeapons.get_def("bubble")
	var sword: BoomWeaponDef = BoomWeapons.get_def("greatsword")
	_check(
		bubble != null and bubble.kind == BoomWeaponDef.AttackKind.RANGED,
		"泡泡枪 = RANGED",
	)
	_check(
		sword != null and sword.kind == BoomWeaponDef.AttackKind.MELEE,
		"大剑 = MELEE",
	)
	_check(bubble != null and absf(bubble.fire_cd - 0.22) < 0.001, "泡泡 fire_cd=0.22")
	_check(
		(
			sword != null
			and sword.swing_dmg == 30
			and sword.base_attack == 30
			and sword.swing_max_targets == 12
			and absf(sword.swing_range - 2.9) < 0.001
			and absf(sword.swing_arc_deg - 150.0) < 0.001
			and absf(sword.swing_windup - 0.32) < 0.001
			and absf(sword.swing_active - 0.08) < 0.001
			and absf(sword.swing_recover - 0.36) < 0.001
			and sword.melee_combo.size() == 3
			and sword.melee_combo[0]["action"] == "swing_left"
			and sword.melee_combo[1]["action"] == "swing_right"
			and sword.melee_combo[2]["action"] == "swing_whirl"
			and absf(float(sword.melee_combo[2]["arc_deg"]) - 360.0) < 0.001
		),
		"判笔三段双手连招：左挥/右挥/360°回旋，均锁定 2.9m 斩距",
	)
	_check(
		sword != null and sword.max_hp_bonus == 20 and absf(sword.move_mult - 0.85) < 0.001,
		"大剑机体 +20HP（50→70）/ 移速×0.85",
	)
	_check(
		bubble != null and bubble.base_attack == 10 and bubble.proj_dmg == 10,
		"泡泡 base_attack=10 与 proj_dmg 同源",
	)
	_check(BoomWeapons.get_def("nope").id == "bubble", "未知武器 id 回退泡泡枪")

	# 2) 默认武器与 set_weapon 机体注入。
	var g0 := _new_game()
	_check(g0.player.weapon_id == "bubble", "BoomGame 默认武器注入泡泡")
	_check(g0.player.max_hp == 50 and g0.player.hp == 50, "泡泡默认 max_hp=50 满血（M8）")
	_check(absf(g0.player.move_speed - 5.4) < 0.001, "泡泡移速 = 5.4")
	g0.free()
	var g := _new_game()
	g.player.invuln_left = 10.0
	g.set_weapon("greatsword")
	_check(g.player.max_hp == 70 and g.player.hp == 70, "set_weapon 大剑 max_hp=70 满血")
	_check(absf(g.player.move_speed - 5.4 * 0.85) < 0.001, "set_weapon 大剑移速 ×0.85")
	_check(g.player.anim_form == "sword", "set_weapon 大剑切 sword 形态")
	g.set_weapon("bubble")
	_check(g.player.max_hp == 50 and g.player.anim_form == "bubble", "切回泡泡形态/HP 复位")

	# 3) 大剑弧斩：无目标不空挥（挥斩状态保持 NONE）。
	g.set_weapon("greatsword")
	g.input_move = Vector2.ZERO
	_run(g, 90)
	_check(
		g._swing_state == BoomGame.SwingState.NONE,
		"无目标近战待机不空挥 (state=%d)" % g._swing_state,
	)
	_check(g.kills == 0, "无目标不产生击杀")

	# 4) 弧斩命中：前方 150°×2.9m 内 4 敌一斩各 3 伤致死 + blade_hit。
	var targets: Array = [
		Vector3(-0.8, 0.0, 1.8),
		Vector3(0.8, 0.0, 1.8),
		Vector3(-1.2, 0.0, 2.2),
		Vector3(1.2, 0.0, 2.2),
	]
	for p in targets:
		g.spawn_enemy_at(p)
	var blade_box: Array = [0]
	var release_box: Array = []
	g.blade_hit.connect(func(_pos: Vector3, _dmg: int) -> void: blade_box[0] += 1)
	g.swing_released.connect(
		func(_pos: Vector3, _facing: Vector3, count: int) -> void: release_box.append(count)
	)
	var guard := 0
	while guard < MAX_FRAMES and not g.enemies.is_empty():
		guard += 1
		g.player.invuln_left = 10.0
		g.step(DT)
	_check(g.enemies.is_empty(), "弧斩清空扇区 4 敌")
	_check(g.kills == 4, "弧斩致死计数 4 (kills=%d)" % g.kills)
	_check(blade_box[0] >= 4, "blade_hit 命中 ≥4 次 (hits=%d)" % blade_box[0])
	_check(release_box.size() == 1 and release_box[0] == 4, "整次挥击只发 1 次重反馈（4 命中）")
	_check(g.combo == 4, "弧斩多杀 combo 累积到 4")
	_check(g.player.get("_weapon_fx_anim") != null, "判笔独立五帧墨迹层已构建")
	g.free()

	# 5) 选武器 UX（main 层）：选单默认泡泡 → 确认开战/隐藏/血条上限自适应。
	var sel := _main.get("_select") as BoomWeaponSelect
	_check(sel != null, "选武器面板已构建")
	if sel != null:
		_check(sel.get_child_count() > 0, "选单已渲染控件树")
		_check(sel.selected_weapon() == "bubble", "选单默认高亮泡泡枪")
	var sim := _main.get("sim") as BoomGame
	if sim == null or sel == null:
		return
	if _main.call("_is_test_mode"):
		_check(sim.match_started, "测试模式自动开战")
	else:
		_check(sel.visible, "开局停留选单（无头桌面态）")
		_check(not sim.match_started, "确认前对局未开战")
		_check(sim.player.max_hp == 70, "选单默认装备生命 50+12+8=70HP")
		_main.call("_on_weapon_confirmed", "greatsword")
		_check(sim.match_started, "确认【开战】后对局开始")
		_check(sim.player.max_hp == 90 and sim.player.hp == 90, "判笔装备开战生命 70+12+8=90HP")
		_check(sim.player.anim_form == "sword", "确认大剑后形态切换 sword")
		_check(not sel.visible, "开战后选单隐藏")


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
