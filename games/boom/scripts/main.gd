extends Node
## 《B-Boom》入口：一切节点由本脚本在 _ready 里代码构建。

const HUD_W: float = 720.0
const HUD_H: float = 1280.0

# 百怪夜巡场域：相对旧嘉年华场地（26×38）扩大到 52×76，面积约 4 倍。
const ARENA_WIDTH: float = 52.0
const ARENA_DEPTH: float = 76.0
const ARENA_HALF_X: float = 26.0
const ARENA_HALF_Z: float = 38.0

const SKILL_ZONE_X: float = 0.65  # 触点 x 归一 > 0.65 = 右侧技能手势区
const TAP_MAX_TIME: float = 0.20
const TAP_MAX_DIST: float = 14.0
const SWIPE_MIN_DIST: float = 110.0

# ---- 技能槽位 HUD（D6 §228：圆钮展示当前 equipped 槽位技能；与手势槽一一对应）----
const SKILL_SLOT_COUNT: int = 3
const SKILL_BTN_X: float = 596.0
const SKILL_BTN_YS = [760.0, 886.0, 1012.0]  # 3 槽按钮 Y（对齐原 fan/chain/nuke 布局）
const SKILL_GESTURES = ["TAP", "< SWIPE", "SWIPE >"]
## 无位图技能的圆心缩写（configure_empty 用 "—"）。
const SKILL_ABBREVS: Dictionary = {
	"fan": "F",
	"chain": "C",
	"nuke": "N",
	"ring": "R",
	"twin": "TW",
	"rapid": "RX",
	"heal": "+",
	"whirl": "W",
	"titan": "T",
	"lamp_quick_wick": "QW",
	"lamp_bright_core": "BC",
	"lamp_threefold_seal": "3S",
	"lamp_firefly_volley": "FV",
	"lamp_echo": "LE",
	"lamp_soul_beacon": "SB",
	"brush_firm_grip": "FG",
	"brush_flowing_script": "FS",
	"brush_verdict": "SV",
	"brush_ink_wave": "IW",
	"brush_focus": "OF",
	"brush_seal_domain": "SD",
}

const COL_CREAM: Color = Color("fff6e8")
const COL_GOLD: Color = Color("ffc93c")
const COL_SPIRIT_SEAL: Color = Color("f2b84b")
const COL_ENEMY: Color = Color("57c84d")
const COL_ACCENT: Color = COL_GOLD
const COL_DANGER: Color = Color("ff3b4e")
# M8 连续血条（design_m8_attributes.md §4.3）：米纸白→朱砂红渐变填充 + HP 文本。
const HP_BAR_W: float = 460.0

var sim: BoomGame
var world: Node3D
var cam: BoomCam
var fx: BoomFx
var hitnum: BoomHitNum
var audio: BoomAudio
var joystick: GameKitVirtualJoystick
var skill_sys: BoomSkillSystem
var skill_fx: BoomSkillFx
var skill_btns: Dictionary = {}  # 槽位key("0"/"1"/"2")->按钮（D6：按钮=手势槽, 展示 equipped[slot]）
var waypoints: WaypointLayer = null  # M3 屏幕边缘目标标记

# M2 手势识别状态：touch_index -> {sx,sy,t,dx,dy}
var _gestures: Dictionary = {}

var _score_label: Label
var _wave_label: Label
var _kills_label: Label
var _coin_label: Label
var _hp_bar_fill: ColorRect
var _hp_text: Label
var _stats_btn: Button
var _stats_panel: BoomStatsPanel
var _level_panel: BoomLevelUpPanel
var _boss_presenter: BoomBossPresenter
var _vignette: ColorRect
var _kill_white: ColorRect = null  # 击杀全屏泛白 overlay（峰值≤0.15，≤50ms 淡出）
var _kill_white_a: float = 0.0
var _toast: Label
var _wave_cd_label: Label  # M4 §5 波间歇倒计时
var _over_panel: Control  # BoomResultPanel（结算 + 再来一局中转）
var _hint_label: Label
var _combo_label: Label  # M3 击杀播报大字
var _combo_tween: Tween = null
var _result_stars: Array = []  # 镜像 BoomResultPanel.stars（play_test 兼容查询）
var _slowmo_until_ms: int = 0  # 结算慢镜头镜像（真实时刻在 BoomResultPanel 内）
var _started := false
var _dmg_flash := 0.0
# ---- M5 选武器（design_m5_weapons.md §3.3）----
var _hud: Control
var _select: BoomWeaponSelect = null
var _in_select := false


func _ready() -> void:
	Engine.time_scale = 1.0  # 场景重载/复用时兜底复位（Engine 级状态不随场景重置）。
	if not _is_test_mode():
		randomize()
	world = _build_world()
	sim = BoomGame.new()
	add_child(sim)
	fx = BoomFx.new()
	world.add_child(fx)
	hitnum = BoomHitNum.new()
	world.add_child(hitnum)
	cam = BoomCam.new()
	cam.setup_follow(sim.player)
	world.add_child(cam)
	audio = BoomAudio.new()
	add_child(audio)
	# M2 技能：逻辑系统 + 视觉 FX（先建逻辑，main.gd 在 physics 里 tick；FX 挂 world）。
	skill_sys = BoomSkillSystem.new()
	skill_sys.game = sim
	add_child(skill_sys)
	skill_fx = BoomSkillFx.new()
	world.add_child(skill_fx)
	_build_hud()
	_boss_presenter = BoomBossPresenter.new()
	add_child(_boss_presenter)
	_boss_presenter.setup(
		_hud,
		sim,
		skill_sys,
		audio,
		cam,
		hitnum,
		_is_test_mode() or DisplayServer.get_name() == "headless",
		_rebuild_skill_hud,
		_show_toast,
		_show_announce
	)
	_build_weapon_select()
	_connect_signals()
	_started = true
	_hud_refresh()
	if _is_test_mode():
		# CI / vision-e2e：跳过选单，直接默认武器开战（design §3.3 测试路径）。
		_start_match_with(BoomWeapons.default_id())
	else:
		_open_weapon_select()


func _physics_process(_delta: float) -> void:
	if not _started or sim == null:
		return
	# M5 选武器期间：摇杆输入不落入 sim（面板 STOP 已挡 gui 事件，双保险归零）。
	sim.input_move = Vector2.ZERO if _in_select else joystick.output
	if skill_sys != null:
		skill_sys.tick(_delta)
	_dmg_flash = maxf(0.0, _dmg_flash - _delta * 2.4)
	_vignette.color.a = _dmg_flash
	# 击杀白闪淡出：峰值 0.15、~3.0/s → ≤50ms 归零（§3.3 防晕铁律 3）。
	_kill_white_a = maxf(0.0, _kill_white_a - _delta * 3.0)
	if _kill_white != null:
		_kill_white.color.a = _kill_white_a
	# M3 结算慢镜头：0.3× 持续 0.35s（真实时钟），由 BoomResultPanel 轮询收尾。
	if _over_panel is BoomResultPanel:
		(_over_panel as BoomResultPanel).tick()
	_hud_refresh()


# ------------------------------------------------------------------ M5 选武器流程


## 构建选武器面板（隐藏态加入 HUD，开局/重开时显示）。
func _build_weapon_select() -> void:
	if _hud == null:
		return
	_select = BoomWeaponSelect.new()
	_select.position = Vector2.ZERO
	_select.size = Vector2(HUD_W, HUD_H)
	_hud.add_child(_select)
	_select.skill_sys = skill_sys  # M7R：技能配置区按当前武器树解锁/装备。
	_select.confirmed.connect(_on_weapon_confirmed)
	_select.visible = false


## 打开选单（默认高亮泡泡枪）；sim 处于"未开战"纯重置态。
func _open_weapon_select() -> void:
	_in_select = true
	if _select != null:
		_select.show()
		_select.set_selected(BoomWeapons.default_id())


## 选单【开战】确认回调：注入武器 → 按 max_hp 重建血条 → 开战发波。
func _on_weapon_confirmed(weapon_id: String) -> void:
	if weapon_id == "" or sim == null:
		return
	_start_match_with(weapon_id)


## 测试路径与选单确认共用：先落武器数值 + 切技能树（M7R 每武器独立树），
## 再开战（design §3.3 关键工程点 1/2）。
func _start_match_with(weapon_id: String) -> void:
	_in_select = false
	if _select != null:
		_select.hide()
	if _stats_btn != null:
		_stats_btn.visible = true
	if sim == null:
		return
	sim.set_weapon(weapon_id)
	if skill_sys != null:
		skill_sys.set_weapon_tree(weapon_id)
	# D6：equipped 在此刻最终化（面板装备+树首默认），按槽位重建技能 HUD。
	_rebuild_skill_hud()
	sim.begin_match()


# ------------------------------------------------------------------ M2 技能手势


## 把屏幕/物理坐标经 canvas 逆变换回 720×1280 设计空间（与摇杆同一坐标系）。
func _to_canvas(sp: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * sp


## 设计坐标是否落在某个技能槽按钮内（按钮本体 + 12px 拇指容错）；返回槽位 key("0".."2")，未命中返回 ""。
func _skill_button_at(cp: Vector2) -> String:
	for id in skill_btns:
		var btn := skill_btns[id] as BoomSkillButton
		if btn == null:
			continue
		if cp.distance_to(btn.position + btn.size * 0.5) <= btn.size.x * 0.5 + 12.0:
			return id
	return ""


## 屏幕右侧(触点设计x > 屏宽*SKILL_ZONE_X)的触摸由本节点做手势识别：
## tap = 爆裂弹幕 / ←swipe = 闪电链 / →swipe = 核爆。
## 左侧触点不在此处理——交给虚拟摇杆(DYNAMIC,已设 exclude_right_x)。
func _input(event: InputEvent) -> void:
	if skill_sys == null or sim == null:
		return
	# M5 选武器期间：手势识别全部挂起（面板内控件自行处理点击）。
	if _in_select:
		return
	if event is InputEventScreenTouch:
		var idx: int = event.index
		var cp: Vector2 = _to_canvas(event.position)
		if event.pressed:
			# 仅在右侧技能区开一条手势轨迹。
			if cp.x > HUD_W * SKILL_ZONE_X:
				_gestures[idx] = {
					"sx": cp.x,
					"sy": cp.y,
					"t": Time.get_ticks_msec(),
					"dx": 0.0,
					"dy": 0.0,
				}
			return
		# 释放：归类手势。
		if not _gestures.has(idx):
			return
		var g: Dictionary = _gestures[idx]
		_gestures.erase(idx)
		var dt: float = float(Time.get_ticks_msec() - int(g["t"])) / 1000.0
		var dist: float = Vector2(g["dx"], g["dy"]).length()
		var adx: float = absf(g["dx"])
		var ady: float = absf(g["dy"])
		if dt <= TAP_MAX_TIME and dist <= TAP_MAX_DIST:
			# D6：tap 落在某槽位按钮圆内（含 12px 容错）→ 释放该槽技能（空槽越界静默）；
			# 其余手势区 tap = 槽 0（主技能）。
			var slot_hit: String = _skill_button_at(Vector2(g["sx"], g["sy"]))
			if slot_hit != "":
				skill_sys.handle_slot(int(slot_hit))
			else:
				skill_sys.handle_tap()
		elif adx >= SWIPE_MIN_DIST and adx > ady * 2.0:
			if g["dx"] < 0.0:
				skill_sys.handle_swipe_left()
			else:
				skill_sys.handle_swipe_right()
	elif event is InputEventScreenDrag:
		var idx: int = event.index
		if not _gestures.has(idx):
			return
		var cp: Vector2 = _to_canvas(event.position)
		var g: Dictionary = _gestures[idx]
		g["dx"] = cp.x - g["sx"]
		g["dy"] = cp.y - g["sy"]


## vision-e2e 用：与 test_hook.gd::_detect_test_mode 语义一致。
func _is_test_mode() -> bool:
	if not OS.has_feature("web"):
		return false
	if not Engine.has_singleton("JavaScriptBridge"):
		return false
	var v: Variant = Engine.get_singleton("JavaScriptBridge").call(
		"eval", "new URLSearchParams(location.search).get('test')"
	)
	if typeof(v) != TYPE_STRING:
		return false
	return (v as String) == "1"


func _test_hook_get_state() -> Dictionary:
	var jg: Dictionary = joystick.get_debug_geom()
	var state: Dictionary = {
		"score": sim.score,
		"wave": sim.wave,
		"kills": sim.kills,
		"coins": sim.coins,
		"combo": sim.combo,
		"hp": sim.player.hp,
		"max_hp": sim.player.max_hp,
		"enemies": sim.enemies.size(),
		"bullets": _active_bullet_count(),
		"over": sim.is_over,
		"weapon": sim.player.weapon_id,
		"match_started": sim.match_started,
		"level": sim.exp_sys.level,
		"xp": sim.exp_sys.xp,
		"pending_upgrades": sim.pending_upgrades,
		"x": sim.player.position.x,
		"z": sim.player.position.z,
		"joy_pressed": jg["pressed"],
		"joy_bx": jg["base_x"],
		"joy_by": jg["base_y"],
		"joy_kx": jg["knob_x"],
		"joy_ky": jg["knob_y"],
		"paused": get_tree().paused,
	}
	# M8（§13.2）：完整属性快照——面板显示值与战斗结算同源。
	var snap: Dictionary = sim.stats_snapshot()
	for key in snap:
		state["stat_" + key] = snap[key]
	if skill_sys == null:
		return state
	var sk: Dictionary = skill_sys.get_state()
	for skill_id in skill_sys.pool_ids():
		state["sk_" + skill_id] = sk[skill_id]
	state["sk_ready"] = sk["ready"]
	# D6：每槽技能 id（空槽 ""），供 vision-e2e 断言 HUD 与手势槽一致。
	var slot_ids: Array[String] = []
	var equipped: Array = skill_sys.equipped
	for slot in SKILL_SLOT_COUNT:
		slot_ids.append(equipped[slot] if slot < equipped.size() else "")
	state["sk_slots"] = slot_ids
	var boss_state: Dictionary = _boss_presenter.debug_state()
	for key in boss_state:
		state[key] = boss_state[key]
	state["boss_projectiles"] = _active_boss_projectile_count()
	state["sk_evolved"] = sk["evolved"]
	return state


func _active_bullet_count() -> int:
	var n := 0
	for b in sim.bullets:
		if (b as BoomBullet).active:
			n += 1
	return n


func _active_boss_projectile_count() -> int:
	var count := 0
	for projectile in sim.boss_projectiles:
		if (projectile as BoomBossProjectile).active:
			count += 1
	return count


# ------------------------------------------------------------------ 信号


func _connect_signals() -> void:
	sim.shot_fired.connect(_on_shot_fired)
	sim.enemy_damaged.connect(_on_enemy_damaged)
	sim.enemy_hit.connect(_on_enemy_hit)
	sim.enemy_died.connect(_on_enemy_died)
	sim.player_damaged.connect(_on_player_damaged)
	sim.player_dodged.connect(_on_player_dodged)
	sim.wave_started.connect(_on_wave_started)
	sim.wave_cleared.connect(_on_wave_cleared)
	sim.game_over.connect(_on_game_over)
	sim.prop_broken.connect(_on_prop_broken)
	sim.skill_bullet_hit.connect(_on_skill_bullet_hit)
	sim.swing_released.connect(_on_swing_released)
	sim.level_up.connect(_on_level_up)
	sim.player_healed.connect(_on_player_healed)
	skill_sys.skill_fired.connect(_on_skill_fired)


func _on_skill_fired(skill_id: String, result: Variant) -> void:
	var ppos: Vector3 = sim.player.position
	var hits: Array = result if result is Array else []
	match skill_id:
		"fan", "lamp_firefly_volley":
			audio.play("shoot", -9.0)
			cam.add_trauma(0.15)  # §4.2 爆裂弹幕：极轻震屏
			skill_fx.muzzle_flash(
				ppos + Vector3(0.0, 0.5, 0.0), sim.player.facing, BoomSkillSystem.FAN_COLOR
			)
		"chain", "brush_ink_wave":
			audio.play("graze", -6.0)
			if not hits.is_empty():
				# §4.2 闪电链：首跳 0.06s 顿帧 + ×0.6 震屏 + 0.10 alpha 白闪(~30ms)。
				sim.trigger_freeze(0.06)
				cam.add_trauma(0.3)
				_trigger_kill_flash(0.10)
				# P1-2：hits 含存活者（衰减伤害是常态），每个命中目标都画电弧。
				var prev: Vector3 = ppos + Vector3(0.0, 0.5, 0.0)
				for jelly in hits:
					var target := jelly as BoomJelly
					if target == null:
						continue
					var hp: Vector3 = target.position + Vector3(0.0, 0.5, 0.0)
					skill_fx.arc_bolt(prev, hp, BoomSkillSystem.CHAIN_COLOR)
					prev = hp
				# §4.2 技能飘字"链!" 紫色大字 1 个（命中才出，与电弧反馈同条件），
				# 替代 M2 起的 "CHAIN!" toast——语义重复，二选一防同屏刷字。
				_spawn_skill_float(ppos, "chain")
		"nuke", "lamp_soul_beacon", "brush_seal_domain":
			audio.play("boom", -4.0)
			cam.add_trauma(0.6)  # §4.2 核爆：×1.2 重震屏（击杀 0.5 基准）
			_trigger_kill_flash()
			skill_fx.shockwave(ppos, BoomGame.NUKE_RADIUS, BoomSkillSystem.NUKE_COLOR)
			skill_fx.burst(ppos + Vector3(0.0, 0.6, 0.0), BoomSkillSystem.NUKE_COLOR, 40)
			# §4.2 技能飘字"轰!" 金色巨型（玩家中心）；规格中的"+ 数字"由既有
			# 伤害/得分飘字管线在命中点自然补齐，避免同点双飘字叠加刷屏。
			# 替代 "NUKE!" toast，取舍同上。
			_spawn_skill_float(ppos, "nuke")


## §4.2 技能飘字统一入口：按 BoomSkillSystem.float_text_for 规格（文案/颜色/字号）
## 在给定位置弹一个飘字，复用 BoomHitNum 既有对象池与上浮淡出管线。
## fan=黄"嘭!"小字（每命中 1 个）/ chain=紫"链!"大字 / nuke=金"轰!"巨型。
func _spawn_skill_float(pos: Vector3, skill_id: String) -> void:
	if hitnum == null:
		return
	var spec: Dictionary = BoomSkillSystem.float_text_for(skill_id)
	if spec.is_empty():
		return
	var text: String = spec["text"]
	var col: Color = spec["color"]
	var sc: float = spec["scale"]
	hitnum.spawn(pos + Vector3(0.0, 0.5, 0.0), text, col, sc)


func _on_shot_fired(pos: Vector3) -> void:
	fx.puff(pos, COL_SPIRIT_SEAL, 5)
	audio.play("shoot", -14.0)


func _on_enemy_damaged(pos: Vector3, _dir: Vector3) -> void:
	fx.puff(pos, COL_SPIRIT_SEAL, 6)
	audio.play("hit", -9.0)
	cam.add_trauma(0.05)


## 一次挥击只做一次重反馈；怪海多目标不会把音效/震屏叠加十二遍。
func _on_swing_released(pos: Vector3, facing: Vector3, hit_count: int) -> void:
	if hit_count <= 0:
		return
	var impact_pos := pos + facing * minf(1.6, sim.weapon_cfg.swing_range * 0.55)
	fx.puff(impact_pos + Vector3(0.0, 0.35, 0.0), Color("5fc5ad"), mini(20, 8 + hit_count))
	audio.play("hit", -5.0)
	cam.add_trauma(minf(0.52, 0.24 + float(hit_count) * 0.025))


## M8（§6.3）：伤害数字走统一结算广播——暴击数字放大并用朱砂红高亮，
## 普通伤害维持白色；不额外触发屏幕闪白（只增加轻微打击反馈）。
func _on_enemy_hit(pos: Vector3, dmg: int, crit: bool) -> void:
	if hitnum == null:
		return
	var color := BoomHitNum.COLOR_DAMAGE
	var scale_p := 1.0
	if crit:
		color = Color("b84235")
		scale_p = 1.35
	hitnum.spawn(pos, str(dmg), color, scale_p)


func _on_enemy_died(pos: Vector3) -> void:
	# 连杀震屏每档衰减 40%（0.5^combo 近似等比衰减链）。
	var chain: float = pow(0.6, float(maxi(0, sim.combo - 1)))
	cam.add_trauma(0.5 * chain)
	fx.goo_burst(pos, COL_ENEMY)
	fx.scorch(pos, 0.7)
	audio.play("kill", -6.0)
	audio.play("boom", -16.0)
	_trigger_kill_flash()
	# 击杀得分飘字：金币色，连杀放大 1.3×（§7.2）。
	if hitnum != null:
		var scale_p := 1.3 if sim.combo >= 2 else 1.0
		hitnum.spawn(pos, "+%d" % BoomGame.KILL_SCORE, BoomHitNum.COLOR_SCORE, scale_p)
	# M3 击杀播报：DOUBLE / TRIPLE / RAMPAGE 大字 + 过冲抖动 0.3s。
	_show_combo_announce(BoomGame.announce_for_combo(sim.combo))
	if _hint_label != null:
		_hint_label.queue_free()
		_hint_label = null


func _on_prop_broken(pos: Vector3, coin_value: int) -> void:
	fx.goo_burst(pos, COL_GOLD)
	audio.play("pickup", -7.0)
	if hitnum != null:
		hitnum.spawn(pos + Vector3(0.0, 0.4, 0.0), "+%d" % coin_value, COL_GOLD, 1.15)


func _on_skill_bullet_hit(pos: Vector3, skill_id: String) -> void:
	# §4.2 爆裂弹幕：每个命中点 1 个 "嘭!" 黄色小字（弹道归属由 BoomBullet.variant 判定）。
	_spawn_skill_float(pos, skill_id)


## M8 升级流程（design_m8_attributes.md §11.3）：获得升级 → 暂停战斗 →
## 弹 3 张随机卡 → 选择后立即应用 → 恢复战斗。
func _on_level_up(new_level: int) -> void:
	audio.play("wave_clear", -8.0)
	_show_toast("LEVEL UP!  LV %d" % new_level)
	if sim == null or sim.pending_upgrades <= 0:
		return
	# headless（CI）与 web ?test=1 自动消费"伤害"卡，避免暂停阻塞测试管线。
	if _is_test_mode() or DisplayServer.get_name() == "headless":
		while sim.pending_upgrades > 0:
			sim.apply_level_upgrade(BoomStats.KIND_DMG)
		return
	# §11.3：注入对局 → 暂停战斗 → 弹 3 张卡；面板消费完 pending 后自行恢复。
	_level_panel.sim = sim
	get_tree().paused = true
	_level_panel.open_with(float(sim.player.hp) / float(sim.player.max_hp))


## M8 闪避成功反馈（§8）：不扣血/不受击红屏/不受击音效，仅短暂 "DODGE" 提示。
func _on_player_dodged(_from_pos: Vector3) -> void:
	if hitnum != null:
		var pos := sim.player.position + Vector3(0.0, 1.2, 0.0)
		hitnum.spawn(pos, "DODGE", Color("5fc5ad"), 1.1)


## M7 heal 应急维修反馈：金色 "+N HP" 飘字 + 拾取音。
func _on_player_healed(amount: int) -> void:
	audio.play("pickup", -6.0)
	if hitnum != null:
		hitnum.spawn(sim.player.position + Vector3(0.0, 1.0, 0.0), "+%d HP" % amount, COL_GOLD, 1.2)


func _on_player_damaged(_amount: int, _from_pos: Vector3) -> void:
	_dmg_flash = 0.4
	cam.add_trauma(0.65)
	audio.play("hurt", -8.0)


func _on_wave_started(wave: int) -> void:
	audio.play("wave", -12.0)
	# M4 §5 波次开场横幅：复用 M3 播报大字管线；精英波/台阶波换文案与颜色。
	if BoomBossSystem.is_boss_wave(sim, wave):
		_show_wave_banner("WAVE %d · BOSS" % wave, COL_DANGER)
	elif wave % BoomGame.ELITE_EVERY_N == 0:
		_show_wave_banner("WAVE %d · ELITE!" % wave, COL_DANGER)
	elif wave % BoomGame.WAVE_STAGE_EVERY == 0:
		_show_wave_banner("WAVE %d — STAGE UP!" % wave, COL_GOLD)
	else:
		_show_wave_banner("WAVE %d" % wave, COL_ACCENT)


func _on_wave_cleared(wave: int, bonus: int) -> void:
	audio.play("wave_clear", -6.0)
	_show_toast("WAVE %d CLEARED  +%d" % [wave, bonus])
	# M4 §5：波结算奖励飘字（波中心 = 玩家位置，bonus 此前已发但无表现）。
	if hitnum != null:
		hitnum.spawn(sim.player.position + Vector3(0.0, 1.2, 0.0), "+%d" % bonus, COL_GOLD, 1.3)


# ------------------------------------------------------------------ 3D 世界


func _build_world() -> Node3D:
	var w := Node3D.new()
	w.name = "World"
	add_child(w)
	# M8 拆分：场地构建移至 BoomArena（scripts/core/boom_arena.gd）。
	BoomArena.build(w)
	return w


# ------------------------------------------------------------------ HUD


func _build_hud() -> void:
	var hud := Control.new()
	hud.name = "HUD"
	hud.position = Vector2.ZERO
	hud.size = Vector2(HUD_W, HUD_H)  # 父节点是 Node，不能仅靠 anchors 推导设计尺寸。
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	_hud = hud
	_build_battle_frame(hud)

	_vignette = ColorRect.new()
	_vignette.color = Color(0.9, 0.1, 0.1, 0.0)
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_vignette)

	# 击杀泛白：击杀/爆炸瞬间 ≤50ms 全屏白闪，叠在受击红之上但事件不同源。
	_kill_white = ColorRect.new()
	_kill_white.color = Color(1.0, 1.0, 1.0, 0.0)
	_kill_white.set_anchors_preset(Control.PRESET_FULL_RECT)
	_kill_white.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_kill_white)
	_kill_white_a = 0.0

	_add_hud_card(hud, Vector2(14, 20), Vector2(190, 86), Color(1.0, 0.45, 0.18, 0.88))
	_add_hud_card(hud, Vector2(208, 20), Vector2(304, 70), Color(0.10, 0.68, 0.86, 0.90))
	_add_hud_card(hud, Vector2(522, 20), Vector2(184, 86), Color(1.0, 0.69, 0.16, 0.90))
	_score_label = _make_label(hud, "0", 30, COL_CREAM, Vector2(28, 28))
	_kills_label = _make_label(hud, "", 15, Color(1, 1, 1, 0.82), Vector2(28, 68))
	_wave_label = _make_label(hud, "WAVE 1", 32, COL_CREAM, Vector2(210, 29))
	_wave_label.size = Vector2(320, 46)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_coin_hud(hud)

	_hint_label = _make_label(
		hud,
		"",
		15,
		Color(0.45, 0.20, 0.10, 0.65),
		Vector2(0, 1168),
	)
	_hint_label.size = Vector2(720, 26)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_refresh_gesture_hint()

	_toast = _make_label(hud, "", 40, Color.WHITE, Vector2(0, 500))
	_toast.size = Vector2(720, 60)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false

	# M4 §5 波间歇倒计时：屏幕上沿小字"下一波 N"，最后 1s 变红（§3.4 喘息半拍）。
	_wave_cd_label = _make_label(hud, "", 22, COL_CREAM, Vector2(0, 96))
	_wave_cd_label.size = Vector2(720, 30)
	_wave_cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_cd_label.visible = false

	# M3 击杀播报大字（屏幕中央偏上，过冲抖动）。
	_combo_label = _make_label(hud, "", 72, COL_ACCENT, Vector2(0, 386))
	_combo_label.size = Vector2(720, 96)
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo_label.pivot_offset = _combo_label.size * 0.5
	_combo_label.visible = false

	_build_hp(hud)
	_build_joystick(hud)
	_build_skill_hud(hud)
	_build_waypoints(hud)
	_build_game_over(hud)
	_build_stats_ui(hud)


## M8 属性面板入口 + 升级三选一卡面板（§12.2/§11.3）：隐藏态构建。
func _build_stats_ui(hud: Control) -> void:
	_stats_btn = Button.new()
	_stats_btn.text = "STATS"
	_stats_btn.position = Vector2(626, 112)
	_stats_btn.size = Vector2(80, 64)
	_stats_btn.add_theme_font_size_override("font_size", 22)
	_stats_btn.focus_mode = Control.FOCUS_NONE
	_stats_btn.pressed.connect(_open_stats_panel)
	hud.add_child(_stats_btn)
	_stats_panel = BoomStatsPanel.new()
	_stats_panel.provider = sim.stats_snapshot
	_stats_panel.closed.connect(_on_stats_panel_closed)
	hud.add_child(_stats_panel)
	_level_panel = BoomLevelUpPanel.new()
	hud.add_child(_level_panel)


## M8：打开属性面板并暂停（§12.2）。结算后/未开战不允许打开。
func _open_stats_panel() -> void:
	if sim == null or not sim.match_started or sim.is_over:
		return
	get_tree().paused = true
	_stats_panel.open()


func _on_stats_panel_closed() -> void:
	get_tree().paused = false


func _build_battle_frame(hud: Control) -> void:
	var path := "res://assets/images/backgrounds/rainy_ancient_town.png"
	if not ResourceLoader.exists(path):
		return
	var frame := TextureRect.new()
	frame.texture = load(path) as Texture2D
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	frame.modulate = Color(0.86, 0.91, 1.0, 0.30)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(frame)


func _add_hud_card(hud: Control, pos: Vector2, card_size: Vector2, color: Color) -> void:
	var panel := Panel.new()
	panel.position = pos
	panel.size = card_size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 20
	style.corner_radius_top_right = 20
	style.corner_radius_bottom_left = 20
	style.corner_radius_bottom_right = 20
	style.set_border_width_all(3)
	style.border_color = Color(1.0, 0.97, 0.88, 0.72)
	panel.add_theme_stylebox_override("panel", style)
	hud.add_child(panel)


func _build_coin_hud(hud: Control) -> void:
	var coin := TextureRect.new()
	coin.position = Vector2(532, 28)
	coin.size = Vector2(54, 54)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var coin_path := "res://assets/images/icons/spirit_seal_coin.png"
	if ResourceLoader.exists(coin_path):
		coin.texture = load(coin_path) as Texture2D
	hud.add_child(coin)
	_coin_label = _make_label(hud, "0", 30, COL_CREAM, Vector2(588, 34))
	_coin_label.size = Vector2(104, 44)
	_coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_skill_hud(hud: Control) -> void:
	# D6 §228：3 圆钮 = 3 手势槽，展示当前 equipped 槽位技能；空槽灰显占位（成长设计）。
	var equipped: Array = skill_sys.equipped if skill_sys != null else []
	for slot in SKILL_SLOT_COUNT:
		var button := BoomSkillButton.new()
		button.slot = slot
		button.position = Vector2(SKILL_BTN_X, float(SKILL_BTN_YS[slot]))
		if slot < equipped.size():
			var sid: String = equipped[slot]
			var skill := skill_sys.get_skill(sid) if skill_sys != null else null
			var cd: float = skill.cooldown if skill != null else 0.0
			var color: Color = skill.icon_color if skill != null else Color.WHITE
			button.setup(
				sid,
				BoomSkillSystem.icon_path(sid),
				cd,
				color,
				SKILL_GESTURES[slot],
				str(SKILL_ABBREVS.get(sid, String(sid).left(1).to_upper())),
				skill != null and skill.is_passive
			)
		else:
			button.configure_empty(SKILL_GESTURES[slot])
		hud.add_child(button)
		skill_btns[str(slot)] = button


## D6：按当前 equipped 重建技能 HUD（开战确认时调用一次；槽位技能对局内不变）。
func _rebuild_skill_hud() -> void:
	for key in skill_btns:
		var old := skill_btns[key] as Control
		if old != null and old.get_parent() != null:
			old.queue_free()
	skill_btns.clear()
	if _hud != null:
		_build_skill_hud(_hud)
	_refresh_gesture_hint()


## 底部手势提示文案：按当前槽位技能刷新（空槽显示 "—"）。
func _refresh_gesture_hint() -> void:
	if _hint_label == null or skill_sys == null:
		return
	var equipped: Array = skill_sys.equipped
	var parts: Array[String] = []
	for slot in SKILL_SLOT_COUNT:
		var label: String = SKILL_GESTURES[slot].replace(" ", "")
		var sid: String = equipped[slot] if slot < equipped.size() else ""
		parts.append("%s:%s" % [label, sid.to_upper() if sid != "" else "-"])
	_hint_label.text = "LEFT: MOVE  ·  RIGHT  " + "  ·  ".join(parts)


func _build_hp(hud: Control) -> void:
	# M8 连续血条（§4.3）：暗槽 + 渐变填充 + "当前/最大"文本，替换旧分段方块。
	var slot := ColorRect.new()
	slot.color = Color(0.52, 0.20, 0.12, 0.72)
	slot.size = Vector2(HP_BAR_W, 34)
	slot.position = Vector2(14, 111)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(slot)
	_hp_bar_fill = ColorRect.new()
	_hp_bar_fill.position = Vector2(18, 115)
	_hp_bar_fill.size = Vector2(HP_BAR_W - 8.0, 26)
	_hp_bar_fill.color = Color("f4e8d0")
	_hp_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_hp_bar_fill)
	_hp_text = _make_label(hud, "", 20, COL_CREAM, Vector2(14 + HP_BAR_W + 12.0, 113))
	_hp_text.size = Vector2(130, 30)


func _build_joystick(hud: Control) -> void:
	joystick = GameKitVirtualJoystick.new()
	joystick.mode = GameKitVirtualJoystick.Mode.DYNAMIC
	joystick.base_radius = 84.0
	joystick.knob_radius = 34.0
	joystick.dead_zone = 0.08
	joystick.exclude_right_x = SKILL_ZONE_X
	joystick.position = Vector2(8, 900)
	joystick.size = Vector2(360, 372)
	joystick.modulate = Color(1.0, 0.56, 0.24, 0.92)
	hud.add_child(joystick)


## M3 目标指示（design_boom.md §7.3）：离屏敌人投影 + 屏幕边缘吸附箭头 + 距离。
func _build_waypoints(hud: Control) -> void:
	waypoints = WaypointLayer.new()
	waypoints.cam = cam
	waypoints.game = sim
	hud.add_child(waypoints)
	waypoints.set_anchors_preset(Control.PRESET_FULL_RECT)


## 击杀/技能白闪：peak 0.15（击杀）或 0.10（闪电链 §4.2）；
## _physics_process 以 3.0/s 衰减 → ≤50ms 归零（§3.3 防晕铁律 3）。
func _trigger_kill_flash(peak: float = 0.15) -> void:
	if _kill_white != null:
		_kill_white_a = peak


func _build_game_over(hud: Control) -> void:
	var panel := BoomResultPanel.new()
	hud.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.setup_score_label(_score_label)
	panel.retry_pressed.connect(_on_retry)
	_over_panel = panel
	_result_stars = panel.stars


## M5 重开闭环（design §3.3 工程点 4）：不再 reload_current_scene——
## 隐藏结算 → sim 纯重置 → 弹回选武器（保留"失败后快速换武器再战"的节奏）。
func _on_retry() -> void:
	var panel := _over_panel as BoomResultPanel
	if panel != null:
		panel.reset_for_retry()
		panel.visible = false
	_slowmo_until_ms = 0
	Engine.time_scale = 1.0
	_kill_white_a = 0.0
	_dmg_flash = 0.0
	if _vignette != null:
		_vignette.color.a = 0.0
	if _hint_label != null:
		_hint_label.visible = true
	if sim == null:
		return
	if _boss_presenter != null:
		_boss_presenter.reset()
	if skill_sys != null:
		skill_sys.reset()
	sim.restart()
	_open_weapon_select()


## M3 结算状态机入口（design_boom.md §7.2）：表现细节收进 BoomResultPanel。
func _on_game_over(score: int) -> void:
	# M7R 货币语义：结算时把本局累积的跨局金币落盘（对局中已即时入账内存）。
	BoomSave.save()
	audio.play("over", -4.0)
	cam.add_trauma(0.8)
	if _hint_label != null:
		_hint_label.visible = false
	var panel := _over_panel as BoomResultPanel
	if panel == null:
		return
	panel.show_game_over(score, sim.kills, sim.wave)
	_slowmo_until_ms = panel.slowmo_deadline_ms


## 结束慢镜头并启动结算序列（委托 BoomResultPanel，幂等）。
func _end_slowmo() -> void:
	var panel := _over_panel as BoomResultPanel
	if panel != null:
		panel.end_slowmo()
	_slowmo_until_ms = 0


func _make_label(parent: Node, text: String, font_size: int, color: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _show_toast(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.visible = true
	_toast.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_interval(0.5)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.4)


## M3 击杀播报：大字 1.6×→1.0 过冲（TRANS_BACK，0.3s）后淡出；空文案不播。
func _show_combo_announce(text: String) -> void:
	if text == "":
		return
	var color := COL_ACCENT
	if text == "RAMPAGE":
		color = COL_DANGER
	elif text == "DOUBLE":
		color = Color.WHITE
	_show_announce(text, color)


## M4 §5 波次横幅：WAVE N（默认金）/ 台阶波（金）/ 精英波（红），复用播报动画。
func _show_wave_banner(text: String, color: Color) -> void:
	_show_announce(text, color)


func _show_announce(text: String, color: Color) -> void:
	if _combo_label == null:
		return
	if _combo_tween != null and _combo_tween.is_valid():
		_combo_tween.kill()
	_combo_label.text = text
	_combo_label.add_theme_color_override("font_color", color)
	_combo_label.visible = true
	_combo_label.modulate = Color(1, 1, 1, 1)
	_combo_label.scale = Vector2(1.6, 1.6)
	_combo_tween = create_tween()
	(
		_combo_tween
		. tween_property(_combo_label, "scale", Vector2.ONE, 0.3)
		. set_trans(Tween.TRANS_BACK)
		. set_ease(Tween.EASE_OUT)
	)
	_combo_tween.tween_interval(0.35)
	_combo_tween.tween_property(_combo_label, "modulate:a", 0.0, 0.25)
	_combo_tween.tween_callback(func() -> void: _combo_label.visible = false)


func _hud_refresh() -> void:
	if sim == null:
		return
	# 结算数字滚动期间由 BoomResultPanel 的 tween 写分数，避免每帧覆盖造成回跳。
	var rp := _over_panel as BoomResultPanel
	if rp == null or not rp.counting:
		_score_label.text = str(sim.score)
	_kills_label.text = "KILLS %d   COMBO x%d" % [sim.kills, maxi(1, sim.combo)]
	_wave_label.text = "WAVE %d" % sim.wave
	# M4 §5：间歇期显示"下一波 N"倒计时，最后 1s 变红提示。
	if _wave_cd_label != null:
		if sim._between_waves and sim._next_wave_cd > 0.0:
			_wave_cd_label.visible = true
			_wave_cd_label.text = "NEXT IN %d" % int(ceilf(sim._next_wave_cd))
			var urgent := sim._next_wave_cd <= 1.0
			_wave_cd_label.add_theme_color_override(
				"font_color", COL_DANGER if urgent else COL_CREAM
			)
		else:
			_wave_cd_label.visible = false
	if _coin_label != null:
		_coin_label.text = str(sim.coins)
	if skill_sys != null:
		var skill_state := skill_sys.get_state()
		var equipped: Array = skill_sys.equipped
		for slot_key in skill_btns:
			var btn := skill_btns[slot_key] as BoomSkillButton
			if btn == null or btn.is_empty_slot:
				continue
			var slot: int = int(slot_key)
			if slot >= equipped.size():
				continue
			btn.set_cooldown(float(skill_state[equipped[slot]]))
	# M8 连续血条（§4.3）：宽度按 HP 比例填充，颜色米纸白→朱砂红渐变。
	if _hp_bar_fill != null:
		var max_hp: float = maxf(1.0, float(sim.player.max_hp))
		var ratio: float = clampf(float(sim.player.hp) / max_hp, 0.0, 1.0)
		_hp_bar_fill.size.x = (HP_BAR_W - 8.0) * ratio
		_hp_bar_fill.color = Color("b84235").lerp(Color("f4e8d0"), ratio)
	if _hp_text != null:
		_hp_text.text = "%d / %d" % [sim.player.hp, sim.player.max_hp]

# ------------------------------------------------------------------ 程序化控件

## M3 目标指示层已拆分至 scripts/ui/waypoint_layer.gd（class_name WaypointLayer）。
