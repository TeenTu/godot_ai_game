extends SceneTree
## ai2_test.gd — P0-D 场景入口与敌方反击 无头验收（REQ-AI-01..02，AI-1..4）。
##
## AI-1  seed 复现（同 seed 同出生局面）/新 seed 分布/出生失败显式报告/
##       StartMenu 启动覆写（场景 + seed，meta 优先级）。
## AI-2  敌方事件来源过滤（自身/己方武器/己方诱饵不进截获）/诱饵类别中和
##       （DECOY_ACTIVATION → UNKNOWN_TRANSIENT）/反应延迟 ∈ [3,15]s 反击。
## AI-3  FIRE 拒发不占名额/击沉取消全部待执行动作/双向换层规避
##       （UPPER→LOWER 与 LOWER→UPPER 都按 DepthLayerModel hold 执行）。
## AI-4  教学场景无 enemy_spawn/AI；战斗场景有 doctrine；E2E 反击后来袭
##       鱼雷进入玩家被动链（ET 前缀测量）。
##
## godot --headless --path games/sonar --script res://tools/ai2_test.gd

const SEED: int = 20260906


func _initialize() -> void:
	var fails: Array = []
	_ai_1_seed_and_entry(fails)
	_ai_2_filter_neutral_counterfire(fails)
	_ai_3_lifecycle(fails)
	_ai_4_teaching_vs_combat(fails)
	_finish(fails)


## ---- AI-1：seed 复现 / 新 seed 分布 / 失败报告 / 启动覆写 ----
func _ai_1_seed_and_entry(fails: Array) -> void:
	# a) 同 seed 完全复现：同一场景两次加载，敌方出生局面逐字段一致。
	var pos_a := _load_combat_spawn(SEED)
	var pos_b := _load_combat_spawn(SEED)
	_assert_bool(
		fails,
		"AI-1a same seed same spawn",
		pos_a["e"] == pos_b["e"] and pos_a["n"] == pos_b["n"] and pos_a["d"] == pos_b["d"],
		true
	)
	# b) 新 seed 分布：不同 seed 出生位置至少两样（不是恒定 fallback）。
	var seen: Dictionary = {}
	for s in [SEED + 1, SEED + 2, SEED + 3]:
		var p := _load_combat_spawn(s)
		seen["%.0f,%.0f" % [p["e"], p["n"]]] = true
	_assert_bool(fails, "AI-1b new seed new spawn (>=2 distinct)", seen.size() >= 2, true)
	# c) 失败显式报告：无可行解且无 fallback → spawn null + last_error 非空；
	#    fallback 非法（越界）同样报告，绝不静默带病出生。
	var own := _mk_entity("own", 0.0, 0.0, 50.0)
	var g := EnemySpawnGenerator.new()
	(
		g
		. configure(
			{
				"bearing_min_deg": 0.0,
				"bearing_max_deg": 360.0,
				"range_min_m": 8000.0,
				"range_mode_m": 9000.0,
				"range_max_m": 10000.0,
				"min_separation_m": 50000.0,
				"max_generation_attempts": 5,
			},
			SEED + 9
		)
	)
	var t: TruthEntity = g.spawn(own, [], Callable())
	_assert_bool(fails, "AI-1c spawn null on infeasible", t == null, true)
	_assert_bool(fails, "AI-1c last_error reported", g.last_error != "", true)
	_ai_1c_fallback_report(fails)
	# d) StartMenu 启动覆写（REQ-AI-01）：meta > 环境变量 > 默认教程。
	UiContract.set_startup_override("s1_combat", 777)
	_assert_bool(
		fails,
		"AI-1d override scenario/seed",
		(
			UiContract.resolve_scenario_name() == "s1_combat"
			and UiContract.resolve_seed_override() == 777
		),
		true
	)
	UiContract.set_startup_override("", -1)
	_assert_bool(
		fails,
		"AI-1d cleared back to default",
		(
			UiContract.resolve_scenario_name() == UiContract.DEFAULT_SCENARIO
			and UiContract.resolve_seed_override() == -1
		),
		true
	)
	UiContract.record_last_seed(4242)
	_assert_bool(fails, "AI-1d last seed recorded", UiContract.last_seed() == 4242, true)


## AI-1c 补充：fallback 非法（离本艇越界）也必须报告而不是硬出生。
func _ai_1c_fallback_report(fails: Array) -> void:
	var own := _mk_entity("own", 0.0, 0.0, 50.0)
	var g := EnemySpawnGenerator.new()
	(
		g
		. configure(
			{
				"bearing_min_deg": 0.0,
				"bearing_max_deg": 360.0,
				"range_min_m": 1000.0,
				"range_mode_m": 2000.0,
				"range_max_m": 3000.0,
				"max_range_from_own_m": 10000.0,
				"min_separation_m": 50000.0,
				"max_generation_attempts": 2,
				"fallback_spawn":
				{
					"position_east_m": 99000.0,
					"position_north_m": 0.0,
					"course_deg": 0.0,
					"speed_kn": 6.0,
					"depth_m": 70.0,
				},
			},
			SEED + 10
		)
	)
	var t: TruthEntity = g.spawn(own, [], Callable())
	_assert_bool(fails, "AI-1c invalid fallback rejected", t == null, true)
	_assert_bool(
		fails, "AI-1c fallback failure reported", str(g.last_error).contains("fallback"), true
	)


## ---- AI-2：来源过滤 / 诱饵类别中和 / 反应延迟反击 ----
func _ai_2_filter_neutral_counterfire(fails: Array) -> void:
	# a) filter_interceptable：敌方自身/己方在水鱼雷/己方诱饵的事件被滤掉，
	#    玩家事件保留且顺序不变。
	var ctl := EnemyDoctrineController.new()
	var evs: Array = [
		{"event_id": 1, "emitter_internal_ref": "RED-1", "kind": "X"},
		{"event_id": 2, "emitter_internal_ref": "own", "kind": "Y"},
		{"event_id": 3, "emitter_internal_ref": "ET-1", "kind": "Z"},
		{"event_id": 4, "emitter_internal_ref": "DCY-1", "kind": "W"},
	]
	var refs: Dictionary = {"RED-1": true, "ET-1": true, "DCY-1": true}
	var kept: Array = ctl.filter_interceptable(evs, refs)
	_assert_bool(fails, "AI-2a own emitters filtered", kept.size() == 1, true)
	_assert_bool(
		fails,
		"AI-2a player event kept in order",
		not kept.is_empty() and int(kept[0]["event_id"]) == 2,
		true
	)
	_assert_bool(
		fails, "AI-2a empty refs passthrough", ctl.filter_interceptable(evs, {}).size() == 4, true
	)
	# b) 诱饵类别中和：玩家诱饵激活事件 → 敌方只见 UNKNOWN_TRANSIENT，
	#    分类假设绝不是 DECOY（防自动识破反制）。
	var ad := _mk_adapter()
	var own2 := _mk_entity("own", 0.0, 0.0, 50.0)
	var ev := _mk_event(AcousticEmissionEvent.DECOY_ACTIVATION, 60.0, 2000.0, 168.0)
	var out: Array = ad.intercept_events([ev], own2, 100.0)
	_assert_bool(fails, "AI-2b decoy transient intercepted", out.size() == 1, true)
	if not out.is_empty():
		var e: Dictionary = out[0]
		_assert_bool(
			fails,
			"AI-2b kind neutralized",
			str(e.get("emission_kind", "")) == "UNKNOWN_TRANSIENT",
			true
		)
		_assert_bool(
			fails, "AI-2b class not DECOY", str(e.get("source_class", "")) != "DECOY", true
		)
	# c) 反应延迟 ∈ [3,15]s 的完整反击闭环（响亮本艇 3.5km）。
	var w := _mk_combat_world(3500.0, 45.0, true)
	var th: float = float(w.enemy_ai.doctrine.get("fire_quality_threshold", 0.7))
	var t_cross: float = -1.0
	var t_fire: float = -1.0
	for i in range(900):
		w.run_steps(1)
		if t_cross < 0.0 and not w.enemy_ai.tracks.tracks.is_empty():
			var bt: Dictionary = w.enemy_ai.tracks.best_track()
			if float(bt.get("quality", 0.0)) >= th:
				t_cross = w.sim_time
		if not w.enemy_weapons.torpedoes.is_empty():
			t_fire = w.sim_time
			break
	_assert_bool(fails, "AI-2c quality crossed threshold", t_cross > 0.0, true)
	_assert_bool(fails, "AI-2c enemy counterfired", t_fire > 0.0, true)
	if t_fire > 0.0 and t_cross > 0.0:
		var delay: float = t_fire - t_cross
		_assert_bool(
			fails,
			"AI-2c reaction delay in [2,16] (%.1f)" % delay,
			delay >= 2.0 and delay <= 16.0,
			true
		)


## ---- AI-3：拒发不占名额 / 击沉取消 / 双向换层规避 ----
func _ai_3_lifecycle(fails: Array) -> void:
	# a) FIRE 调度→名额占用→拒发回执归还（拒发绝不占死在水武器名额）。
	var ctl := _mk_controller(50.0)
	var ev := _mk_evidence(45.0, 0.95)
	ctl.tracks.feed(ev, 0.0)
	var actions: Array = ctl.update(0.0, 0.5, [])
	_assert_bool(
		fails,
		"AI-3a no same-tick fire (reaction delay)",
		_find_action(actions, "FIRE_TORPEDO").is_empty(),
		true
	)
	_assert_bool(
		fails,
		"AI-3a scheduled while ATTACKING",
		ctl.state == EnemyDoctrineController.State.ATTACKING,
		true
	)
	for p in ctl._pending:
		if str(p["action"].get("action", "")) == "FIRE_TORPEDO":
			p["at"] = 1.0  # 压缩反应延迟到 1s，验证到期执行
	var actions2: Array = ctl.update(2.0, 0.5, [])
	_assert_bool(
		fails,
		"AI-3a fire due after delay",
		not _find_action(actions2, "FIRE_TORPEDO").is_empty(),
		true
	)
	_assert_bool(fails, "AI-3a slot occupied", ctl.active_torpedo_count() == 1, true)
	ctl.notify_fire_rejected()
	_assert_bool(fails, "AI-3a rejected fire returns slot", ctl.active_torpedo_count() == 0, true)
	# b) 击沉：取消全部待执行动作，停止一切新动作。
	var ctl2 := _mk_controller(50.0)
	ctl2.tracks.feed(_mk_evidence(90.0, 0.9), 0.0)
	ctl2.update(0.0, 0.5, [])
	ctl2.entity.damage_state = "sunk"
	var actions3: Array = ctl2.update(3.0, 0.5, [])
	_assert_bool(fails, "AI-3b sunk no actions", actions3.is_empty(), true)
	_assert_bool(fails, "AI-3b sunk clears pending", ctl2._pending.is_empty(), true)
	# c) 双向换层规避：UPPER→LOWER 命令 LOWER hold；LOWER→UPPER 反向同样执行。
	var c_up := _mk_controller(50.0)  # 50 m 在 UPPER（热层界 120 m）
	c_up.doctrine["layer_change_probability"] = 1.0
	c_up.doctrine["evade_speed_change_probability"] = 0.0
	c_up.doctrine["decoy_launch_probability"] = 0.0
	c_up._plan_evasion(0.0)
	_assert_bool(
		fails,
		"AI-3c UPPER evades to LOWER hold 180",
		float(c_up.entity.commanded_depth_m) == 180.0,
		true
	)
	var c_dn := _mk_controller(200.0)  # 200 m 在 LOWER
	c_dn.doctrine["layer_change_probability"] = 1.0
	c_dn.doctrine["evade_speed_change_probability"] = 0.0
	c_dn.doctrine["decoy_launch_probability"] = 0.0
	c_dn._plan_evasion(0.0)
	_assert_bool(
		fails,
		"AI-3c LOWER evades to UPPER hold 70",
		float(c_dn.entity.commanded_depth_m) == 70.0,
		true
	)


## ---- AI-4：教学 vs 战斗入口差异 + E2E 来袭鱼雷进玩家被动链 ----
func _ai_4_teaching_vs_combat(fails: Array) -> void:
	# a) 教学场景：无 enemy_spawn 块 → 完全没有敌方 AI/武器链（零行为变化）。
	var wt := World.new()
	wt.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	_assert_bool(
		fails,
		"AI-4a teaching has no enemy AI",
		wt.enemy_ai == null and wt.enemy_weapons == null,
		true
	)
	# b) 战斗场景：enemy_ai/doctrine/enemy_weapons/countermeasures 全就绪。
	var wc := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("s1_combat")
	sc["seed"] = SEED
	wc.load_scenario(sc)
	_assert_bool(fails, "AI-4b combat has doctrine", wc.enemy_ai != null, true)
	_assert_bool(
		fails,
		"AI-4b doctrine configured",
		wc.enemy_ai != null and not wc.enemy_ai.doctrine.is_empty(),
		true
	)
	_assert_bool(fails, "AI-4b combat has enemy weapons", wc.enemy_weapons != null, true)
	# 方位区间已放开（0..360）：出生点可以出现在任意象限。
	var ent: TruthEntity = wc.enemy_ai.entity
	var rng_out: float = NavUtils.distance(
		float(wc.world["own"].position_east_m),
		float(wc.world["own"].position_north_m),
		float(ent.position_east_m),
		float(ent.position_north_m)
	)
	_assert_bool(
		fails,
		"AI-4b spawn within range band (%.0f)" % rng_out,
		rng_out >= 5000.0 and rng_out <= 11000.0,
		true
	)
	# c) E2E：敌方反击后，来袭鱼雷影子进入玩家被动测量流（ET 前缀可见）。
	wc = _mk_combat_world(3500.0, 45.0, true)
	var fired: bool = false
	var et_meas: bool = false
	for i in range(1200):
		wc.run_steps(1)
		if not fired and not wc.enemy_weapons.torpedoes.is_empty():
			fired = true
		if fired:
			for m in wc.measurements:
				if str(m.target_id).begins_with("ET"):
					et_meas = true
					break
		if et_meas:
			break
	_assert_bool(fails, "AI-4c enemy torpedo in water", fired, true)
	_assert_bool(fails, "AI-4c incoming torpedo heard by player", et_meas, true)


## ---- 构造工具 ----


## 用 s1_combat 场景加载 World（教学与生产同路径），返回敌方出生快照。
func _load_combat_spawn(seed_val: int) -> Dictionary:
	var w := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("s1_combat")
	sc["seed"] = seed_val
	w.load_scenario(sc)
	if w.enemy_ai == null or w.enemy_ai.entity == null:
		return {"e": -1.0, "n": -1.0, "d": -1.0}
	var e: TruthEntity = w.enemy_ai.entity
	return {
		"e": float(e.position_east_m),
		"n": float(e.position_north_m),
		"d": float(e.depth_m),
	}


## 构造响/静战斗世界：stage1 场景 + enemy_spawn（range_m 处出生）。
func _mk_combat_world(range_m: float, bearing_deg: float, loud: bool) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["targets"] = []  # 移除默认目标，玩家声呐只可能听到敌方鱼雷
	if loud:
		sc["own_acoustic"]["broadband_base_level_db"] = 150.0
		sc["own_ship"]["speed_kn"] = 10.0
	else:
		sc["own_ship"]["speed_kn"] = 0.0
	var b: float = deg_to_rad(bearing_deg)
	sc["enemy_spawn"] = {
		"bearing_min_deg": bearing_deg - 2.0,
		"bearing_max_deg": bearing_deg + 2.0,
		"range_min_m": range_m,
		"range_mode_m": range_m + 500.0,
		"range_max_m": range_m + 1000.0,
		"speed_min_kn": 5.0,
		"speed_max_kn": 8.0,
		"min_separation_m": 2000.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * range_m,
			"position_north_m": cos(b) * range_m,
			"course_deg": 225.0,
			"speed_kn": 6.0,
			"depth_m": 70.0,
		},
		"countermeasures": {"ready_rounds": 2, "inventory": 2, "launch_cooldown_s": 10.0},
		"doctrine":
		{
			"sensor_false_alarm_rate": 0.0,
			"fire_quality_threshold": 0.7,
			"tracking_quality_threshold": 0.55,
			"suspicious_quality_threshold": 0.25,
			"reaction_delay_min_s": 3.0,
			"reaction_delay_max_s": 15.0,
			"counterfire_probability": 1.0,
			"counterfire_cooldown_s": 120.0,
			"max_simultaneous_weapons": 2,
			"sample_interval_s": 2.0,
			"torpedo_active_enable_time_s": 60.0,
			"torpedo_autonomy_distance_m": 800.0,
			"evade_trigger_probability": 0.85,
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


## 最小 Doctrine 控制器（单测用）：空感知、确定性 λ（必反击）、1s 反应延迟。
func _mk_controller(depth_m: float) -> EnemyDoctrineController:
	var ent := _mk_entity("RED-1", 3000.0, 3000.0, depth_m)
	var ad := _mk_adapter()
	var mgr := EnemyTrackManager.new()
	var doctrine: Dictionary = {
		"fire_quality_threshold": 0.7,
		"tracking_quality_threshold": 0.55,
		"suspicious_quality_threshold": 0.25,
		"reaction_delay_min_s": 1.0,
		"reaction_delay_max_s": 1.0,
		"counterfire_probability": 1000.0,  # λ·Δt 大 → p≈1（确定性调度）
		"counterfire_cooldown_s": 120.0,
		"max_simultaneous_weapons": 1,
		"sample_interval_s": 2.0,
		"evade_other_band_hold_depth_m": 180.0,
	}
	var ctl := EnemyDoctrineController.new()
	ctl.configure(ent, ad, mgr, doctrine, _rng(SEED + 11), Callable(self, "_hold"))
	return ctl


func _hold(band: String) -> float:
	return 180.0 if band == "LOWER" else 70.0


func _mk_entity(id: String, e: float, n: float, depth: float) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = id
	t.side = "red"
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = depth
	t.speed_kn = 6.0
	return t


## 直接构造适配器（内核边界单测用；env 来自 stage1 场景）。
func _mk_adapter() -> EnemySensorAdapter:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var ad := EnemySensorAdapter.new()
	ad.bind(w.world["env"], w.world.get("depth_model", null), [], {})
	ad.set_rng(_rng(SEED + 7))
	ad.false_alarm_rate = 0.0
	return ad


## 事件：从原点出发 bearing/range 处、深度 50m 的声学事件。
func _mk_event(kind: String, bearing_deg: float, range_m: float, sl_db: float) -> Dictionary:
	var b: float = deg_to_rad(bearing_deg)
	var src := Vector3(sin(b) * range_m, cos(b) * range_m, 50.0)
	return AcousticEmissionEvent.make(1, kind, "TEST", 100.0, src, 3000.0, 1000.0, sl_db, 0.5)


## 高置信净化证据（喂航迹管理用）。
func _mk_evidence(bearing_deg: float, pd: float) -> Dictionary:
	return {
		"evidence_id": 1,
		"timestamp": 0.0,
		"kind": "EMISSION_INTERCEPT",
		"source_class": "PLATFORM",
		"emission_kind": "PLATFORM_ACTIVE_PING",
		"bearing_deg": bearing_deg,
		"bearing_sigma_deg": 2.0,
		"se_db": 30.0,
		"pd": pd,
		"confidence": pd,
		"freq_hz": 1000.0,
	}


func _find_action(actions: Array, name: String) -> Array:
	var out: Array = []
	for a in actions:
		if str(a.get("action", "")) == name:
			out.append(a)
	return out


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	for f in fails:
		print("AI2_FAIL ", f)
	if fails.is_empty():
		print("AI2_TEST result=PASS")
	else:
		print("AI2_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
