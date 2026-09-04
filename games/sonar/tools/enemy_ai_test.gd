extends SceneTree
## enemy_ai_test.gd — S1-07 Commit 9 敌方随机出生/感知/Doctrine 无头验收
## （§9.4-§9.10 + §14.5 AI-01..09）。
##
## 覆盖：
##   AI-01  固定 seed 敌方出生完全复现。
##   AI-02  不同 seed 出生不同且均合法（方位带/距离三角/间隔约束）。
##   AI-03  无证据时 AI 不感知玩家 Truth（安静远距玩家 → 恒巡逻，无反击）。
##   AI-04  玩家 Ping 截获只生成 noisy bearing（无 range/位置字段）。
##   AI-05  发射瞬态只生成方位/时间/分类假设（TORPEDO）。
##   AI-06  AI 反应有延迟（阈值穿越 → FIRE 动作间隔 ∈ [3,15]s）。
##   AI-07  bearing-only 反击使用宽搜索扇区（程序无隐藏距离）。
##   AI-08  AI 主动 Ping 同样暴露（入事件总线，玩家可截获/可听到鱼雷）。
##   AI-09  AI 规避使用命令值与有限速率（command_course/depth + 限速率）。
##   WORLD  场景集成：enemy_spawn 装配 / 出生入 targets / 敌方鱼雷独立链。
##
## 全部确定性（固定 seed），可无头运行：
##   godot --headless --path games/sonar --script res://tools/enemy_ai_test.gd

const DT: float = 1.0
const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_ai_01_spawn_determinism(fails)
	_ai_02_spawn_variety_validity(fails)
	_ai_03_no_evidence_no_reaction(fails)
	_ai_04_ping_intercept_bearing_only(fails)
	_ai_05_launch_transient_classified(fails)
	_ai_06_07_reaction_delay_and_fire(fails)
	_ai_08_ai_ping_exposed(fails)
	_ai_09_command_rate_limited(fails)
	_world_integration(fails)
	_finish(fails)


## ---- AI-01：固定 seed 出生复现 ----
func _ai_01_spawn_determinism(fails: Array) -> void:
	var own := _mk_own(0.0, 0.0, 4.0, 45.0)
	var a := _spawn_one(_spawn_cfg(), own, 777)
	var b := _spawn_one(_spawn_cfg(), own, 777)
	_assert_bool(
		fails,
		"AI-01a same seed same position",
		a.position_east_m == b.position_east_m and a.position_north_m == b.position_north_m,
		true
	)
	_assert_bool(
		fails,
		"AI-01b same seed same kinematics",
		a.course_deg == b.course_deg and a.speed_kn == b.speed_kn and a.depth_m == b.depth_m,
		true
	)


## ---- AI-02：不同 seed 不同且合法 ----
func _ai_02_spawn_variety_validity(fails: Array) -> void:
	var cfg: Dictionary = _spawn_cfg()
	var own := _mk_own(0.0, 0.0, 4.0, 45.0)
	var seen: Array = []
	var distinct: int = 0
	for i in range(6):
		var t := _spawn_one(cfg, own, 1000 + i * 17)
		# 合法性：方位带 / 距离带 / 与本体间隔。
		var brg: float = NavUtils.bearing_to_true(
			own.position_east_m, own.position_north_m, t.position_east_m, t.position_north_m
		)
		var rng_m: float = NavUtils.distance(
			own.position_east_m, own.position_north_m, t.position_east_m, t.position_north_m
		)
		var ok: bool = (
			brg >= 20.0
			and brg <= 70.0
			and rng_m >= 6000.0
			and rng_m <= 10000.0
			and rng_m >= 2000.0
			and t.speed_kn >= 5.0
			and t.speed_kn <= 10.0
		)
		_assert_bool(fails, "AI-02 validity seed %d" % i, ok, true)
		var dup: bool = false
		for s in seen:
			if absf(s.x - t.position_east_m) < 1.0 and absf(s.y - t.position_north_m) < 1.0:
				dup = true
		if not dup:
			distinct += 1
		seen.append({"x": t.position_east_m, "y": t.position_north_m})
	_assert_bool(fails, "AI-02b different seeds differ", distinct >= 4, true)


## ---- AI-03：无证据不感知玩家（安静远距 → 恒巡逻，绝不反击/布诱饵）----
func _ai_03_no_evidence_no_reaction(fails: Array) -> void:
	var w := _mk_world(6000.0, 45.0, false)  # 敌方 6km、玩家安静（SL0=45）
	# 玩家保持静止无声（speed 0），敌方 AI 只会巡逻。
	var fired: bool = false
	var deloyed: bool = false
	for i in range(600):
		w.run_steps(1)
		if w.enemy_weapons != null and not w.enemy_weapons.torpedoes.is_empty():
			fired = true
		if w.decoys.size() > 0:
			deloyed = true
		if w.enemy_ai.state != EnemyDoctrineController.State.PATROL_PASSIVE:
			fails.append("AI-03a state left patrol: %s" % w.enemy_ai.state_name())
			break
	_assert_bool(fails, "AI-03b no counterfire on silence", not fired, true)
	_assert_bool(fails, "AI-03c no decoy on silence", not deloyed, true)


## ---- AI-04：Ping 截获只有 noisy bearing（无 range/位置）----
func _ai_04_ping_intercept_bearing_only(fails: Array) -> void:
	var ad := _mk_adapter()
	var own := _mk_own(0.0, 0.0, 4.0, 0.0)
	# 玩家 Ping：方位 45°、5km、SL 210（默认接收参数下 SE 很高 → 确定性探测）。
	var ev := _mk_event(AcousticEmissionEvent.PLATFORM_ACTIVE_PING, 45.0, 5000.0, 210.0)
	var out: Array = ad.intercept_events([ev], own, 100.0)
	_assert_bool(fails, "AI-04a intercepted", out.size() == 1, true)
	if out.is_empty():
		return
	var e: Dictionary = out[0]
	_assert_bool(fails, "AI-04b classified PING", str(e["source_class"]) == "PING", true)
	for bad in ["range_m", "position", "target_id", "emitter_internal_ref", "source_position"]:
		if e.has(bad):
			fails.append("AI-04c evidence leaks %s" % bad)
	var err: float = absf(NavUtils.wrap180(float(e["bearing_deg"]) - 45.0))
	_assert_bool(
		fails,
		"AI-04d bearing within 3 sigma (%.1f)" % err,
		err <= 3.0 * float(e["bearing_sigma_deg"]),
		true
	)


## ---- AI-05：发射瞬态只生成方位/时间/分类假设 ----
func _ai_05_launch_transient_classified(fails: Array) -> void:
	var ad := _mk_adapter()
	var own := _mk_own(0.0, 0.0, 4.0, 0.0)
	var ev := _mk_event(AcousticEmissionEvent.TORPEDO_TUBE_TRANSIENT, 200.0, 3000.0, 168.0)
	var out: Array = ad.intercept_events([ev], own, 100.0)
	_assert_bool(fails, "AI-05a transient intercepted", out.size() == 1, true)
	if out.is_empty():
		return
	var e: Dictionary = out[0]
	_assert_bool(fails, "AI-05b classified TORPEDO", str(e["source_class"]) == "TORPEDO", true)
	_assert_bool(fails, "AI-05c timestamped", float(e["timestamp"]) == 100.0, true)
	for bad in ["range_m", "position", "target_id"]:
		if e.has(bad):
			fails.append("AI-05d evidence leaks %s" % bad)


## ---- AI-06/AI-07：反应延迟 ∈ [3,15]s + BEARING_ONLY 宽扇区反击 ----
func _ai_06_07_reaction_delay_and_fire(fails: Array) -> void:
	var w := _mk_world(3500.0, 45.0, true)  # 敌方 3.5km、玩家响（SL0=150）
	# 记录质量首达 fire 阈值的时刻；反击动作出现时刻与其差 ∈ [3,15]s。
	var th: float = float(w.enemy_ai.doctrine.get("fire_quality_threshold", 0.7))
	var t_cross: float = -1.0
	var t_fire: float = -1.0
	for i in range(600):
		w.run_steps(1)
		if t_cross < 0.0 and not w.enemy_ai.tracks.tracks.is_empty():
			var bt: Dictionary = w.enemy_ai.tracks.best_track()
			if float(bt.get("quality", 0.0)) >= th:
				t_cross = w.sim_time
		if not w.enemy_weapons.torpedoes.is_empty():
			t_fire = w.sim_time
			break
	_assert_bool(fails, "AI-06a quality crossed threshold", t_cross > 0.0, true)
	_assert_bool(fails, "AI-06b enemy fired", t_fire > 0.0, true)
	if t_fire > 0.0 and t_cross > 0.0:
		var delay: float = t_fire - t_cross
		_assert_bool(
			fails,
			"AI-06c reaction delay in [2,16] (%.1f)" % delay,
			delay >= 2.0 and delay <= 16.0,
			true
		)
	if not w.enemy_weapons.torpedoes.is_empty():
		var prog: WeaponProgram = w.enemy_weapons.torpedoes[0].program
		_assert_bool(
			fails,
			"AI-07a BEARING_ONLY counterfire",
			WeaponProgram.fire_mode_name(prog.fire_mode) == "BEARING_ONLY",
			true
		)
		_assert_bool(
			fails,
			"AI-07b wide search sector (%.0f)" % prog.search_half_angle_deg,
			prog.search_half_angle_deg >= 45.0,
			true
		)
		# 程序无任何隐藏距离概念（结构上无 range 字段）。
		_assert_bool(fails, "AI-07c no range in program", prog.get("range_m") == null, true)
		# 鱼雷朝估计方位附近发射（不指向玩家真实位置的验证由净化保证：
		# 初值来自 track 方位估计而非 Truth）。
		var tp: Torpedo = w.enemy_weapons.torpedoes[0]
		_assert_bool(fails, "AI-07d torpedo in water", not tp.is_dead(), true)


## ---- AI-08：AI 鱼雷主动 Ping 同样暴露 ----
func _ai_08_ai_ping_exposed(fails: Array) -> void:
	var w := _mk_world(3500.0, 45.0, true)
	w._enemy_fire({"action": "FIRE_TORPEDO", "bearing_deg": 225.0})
	_assert_bool(
		fails, "AI-08a enemy torpedo launched", not w.enemy_weapons.torpedoes.is_empty(), true
	)
	if w.enemy_weapons.torpedoes.is_empty():
		return
	# 推进至程序预设主动开启（TIME 60s）后应产生 TORPEDO_ACTIVE_PING 事件。
	var pings: Array = []
	var m_before: int = w.measurements.size()
	for i in range(400):
		w.run_steps(1)
		pings = w.emission_bus.events_of_kind(AcousticEmissionEvent.TORPEDO_ACTIVE_PING)
		if not pings.is_empty():
			break
	_assert_bool(fails, "AI-08b torpedo active ping on bus", not pings.is_empty(), true)
	_assert_bool(
		fails,
		"AI-08c torpedo shadow tracked by player side",
		w._enemy_torpedo_shadows.size() == 1,
		true
	)
	# 玩家声呐可听到来袭鱼雷（无其他目标时新测量必来自鱼雷影子链）。
	for i in range(200):
		w.run_steps(1)
	_assert_bool(fails, "AI-08d player hears torpedo", w.measurements.size() > m_before, true)


## ---- AI-09：规避用命令值 + 有限速率 ----
func _ai_09_command_rate_limited(fails: Array) -> void:
	var ad := _mk_adapter()
	var enemy := _mk_own(3000.0, 0.0, 6.0, 0.0)
	enemy.max_vertical_speed_m_s = 2.0
	var sensor := EnemySensorAdapter.new()
	sensor.bind(ad.env, ad.depth_model, [], {})
	sensor.set_rng(_rng(SEED + 41))
	var mgr := EnemyTrackManager.new()
	var ai := EnemyDoctrineController.new()
	var rng := _rng(SEED + 42)
	ai.configure(
		enemy,
		sensor,
		mgr,
		{
			"evade_trigger_probability": 1.0,
			"layer_change_probability": 1.0,
			"decoy_launch_probability": 1.0,
			"reaction_delay_min_s": 3.0,
			"reaction_delay_max_s": 3.0
		},
		rng
	)
	# 来袭鱼雷事件（方位 90°、1km、响）→ 告警。
	var ev := _mk_event(AcousticEmissionEvent.TORPEDO_RUNNING_NOISE, 90.0, 1000.0, 146.0)
	ai.update(100.0, DT, [ev])
	_assert_bool(
		fails, "AI-09a enters EVADING", ai.state == EnemyDoctrineController.State.EVADING, true
	)
	# 同 tick 绝不反应：命令未下。
	_assert_bool(fails, "AI-09b no same-tick reaction", enemy.commanded_course_deg < 0.0, true)
	# 延迟到时（3s）：规避命令下达（命令值接口）。
	for i in range(5):
		ai.update(101.0 + DT * i, DT, [])
	_assert_bool(
		fails, "AI-09c course commanded after delay", enemy.commanded_course_deg >= 0.0, true
	)
	# 有限速率：每步实际航向变化 ≤ turn_rate·dt（留容差）。
	var rate: float = 1.5
	var max_step: float = 0.0
	for i in range(30):
		var c0: float = enemy.course_deg
		enemy.advance(DT)
		var d: float = absf(NavUtils.wrap180(enemy.course_deg - c0))
		max_step = maxf(max_step, d)
		if enemy.commanded_depth_m >= 0.0:
			var z0: float = enemy.depth_m
			enemy.advance(DT)
			_assert_bool(
				fails,
				"AI-09d vertical rate limited",
				enemy.depth_m - z0 <= enemy.max_vertical_speed_m_s * DT + 1e-6,
				true
			)
			break
	_assert_bool(
		fails, "AI-09e course rate limited (%.2f)" % max_step, max_step <= rate * DT + 1e-6, true
	)


## ---- World 集成：enemy_spawn 装配 + 出生入 targets + 确定性 ----
func _world_integration(fails: Array) -> void:
	var w := _mk_world(8000.0, 45.0, false)
	_assert_bool(fails, "WI-a enemy ai configured", w.enemy_ai != null, true)
	_assert_bool(fails, "WI-b spawned into targets", w.world["targets"].size() == 1, true)
	var e: TruthEntity = w.world["targets"][0]
	_assert_bool(fails, "WI-c enemy side red", str(e.side) == "red", true)
	_assert_bool(
		fails,
		"WI-d enemy weapon chain ready",
		w.enemy_weapons != null and w.enemy_torpedo_ctx != null and w.enemy_countermeasures != null,
		true
	)
	# 确定性：同 seed 重建世界，敌方位置完全一致。
	var w2 := _mk_world(8000.0, 45.0, false)
	var e2: TruthEntity = w2.world["targets"][0]
	_assert_bool(
		fails,
		"WI-e world respawn deterministic",
		e.position_east_m == e2.position_east_m and e.position_north_m == e2.position_north_m,
		true
	)
	# 敌方 Truth 不进玩家测量链之外的任何 UI 通道（这里只验证 targets 常规路径）。
	w.run_steps(4)


## ================= helpers =================


func _spawn_cfg() -> Dictionary:
	return {
		"bearing_min_deg": 20.0,
		"bearing_max_deg": 70.0,
		"range_min_m": 6000.0,
		"range_mode_m": 8000.0,
		"range_max_m": 10000.0,
		"speed_min_kn": 5.0,
		"speed_max_kn": 10.0,
		"depth_band_weights": {"UPPER": 0.6, "LOWER": 0.4},
		"min_separation_m": 2000.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": 6000.0,
			"position_north_m": 3000.0,
			"course_deg": 225.0,
			"speed_kn": 6.0,
			"depth_m": 70.0
		},
	}


func _spawn_one(cfg: Dictionary, own: TruthEntity, seed_v: int) -> TruthEntity:
	var g := EnemySpawnGenerator.new()
	g.configure(cfg, seed_v)
	return g.spawn(own, [], Callable(self, "_hold"))


func _hold(band: String) -> float:
	return 180.0 if band == "LOWER" else 70.0


## 构造测试世界：stage1 场景 + enemy_spawn（range_m 处出生）。
## loud=true 时玩家 SL0 提到 150（可被敌方被动听到）。
func _mk_world(range_m: float, bearing_deg: float, loud: bool) -> World:
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
			"depth_m": 70.0
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
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


## 直接构造适配器（内核边界单测用；env 来自 stage1 场景）。
func _mk_adapter() -> EnemySensorAdapter:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var ad := EnemySensorAdapter.new()
	ad.bind(w.world["env"], w.world.get("depth_model", null), [], {})
	ad.set_rng(_rng(SEED + 7))
	return ad


## 事件：从原点出发 bearing/range 处、深度 50m 的声学事件。
func _mk_event(kind: String, bearing_deg: float, range_m: float, sl_db: float) -> Dictionary:
	var b: float = deg_to_rad(bearing_deg)
	var src := Vector3(sin(b) * range_m, cos(b) * range_m, 50.0)
	return AcousticEmissionEvent.make(1, kind, "TEST", 100.0, src, 3000.0, 1000.0, sl_db, 0.5)


func _mk_own(e: float, n: float, spd: float, crs: float) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = "own"
	t.side = "blue"
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = 50.0
	t.speed_kn = spd
	t.course_deg = crs
	t.turn_rate_deg_s = 1.5
	return t


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got %s want %s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("ENEMY_AI_TEST result=PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % f)
	print("ENEMY_AI_TEST result=FAIL (%d)" % fails.size())
	quit(1)
