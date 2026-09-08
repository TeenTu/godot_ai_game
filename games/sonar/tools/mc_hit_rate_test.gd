extends SceneTree
## REQ-0908 Batch 4 — 自然命中概率 Monte Carlo 验收（REQ-B4-05 / 验收 8）。
##
## 全部命中统计来自自然生产链，绝不按 Truth 瞄准：
##   A) SOLUTION 攻击链（100 seeds）：autocrew 自然声学证据 → Tracker →
##      TMA → Enter Solution → FireExecutor(SOLUTION 推荐程序) → 自治授权
##      → Seeker 捕获 → 引信起爆。场景窗口 [0.20, 0.60]。
##   B) BEARING_ONLY 攻击链（30 seeds）：只有自然测量方位，无测距/提前量，
##      宽扇区 + TIME 自治。场景窗口 [0.50, 1.00]。
##   C) 防御有效性（BASE 50 / EVADE 50 seeds，AT-06 对齐）：敌雷固定几何
##      发射（场景配置，与 Batch 0 enemy_hit 同一脚手架），鱼雷自然制导。
##      BASE=玩家匀速直航；EVADE=转向+加速+换层+MOBILE 诱饵。
##      要求 evade_rate < base_rate（规避统计上降低命中率）。
##
## 已知限制（诚实记录，见交付清单）：当前标定下玩家攻击链的脱靶机制以
## 解质量/燃料预算为主，目标侧机动/诱饵在攻击链上未表现出稳定统计降低；
## 防御链（C 组）的规避降低与 decoy_test 机制一致。

const SEEDS_ATTACK := 100
const SEEDS_BO := 30
const SEEDS_DEFENSE := 50
const BUDGET_POST_FIRE := 1400


func _initialize() -> void:
	var fails: Array = []
	var hits_a: int = 0
	for i in range(SEEDS_ATTACK):
		if _attack_seed(1000 + i, false)["hit"]:
			hits_a += 1
	var rate_a: float = float(hits_a) / float(SEEDS_ATTACK)
	print("MC SOLUTION  hit_rate=%.2f (%d/%d)" % [rate_a, hits_a, SEEDS_ATTACK])
	_assert(
		fails, rate_a >= 0.20 and rate_a <= 0.60, "SOLUTION rate in [0.20,0.60] (got %.2f)" % rate_a
	)

	var hits_b: int = 0
	for i in range(SEEDS_BO):
		if _attack_seed(3000 + i, true)["hit"]:
			hits_b += 1
	var rate_b: float = float(hits_b) / float(SEEDS_BO)
	print("MC BONLY     hit_rate=%.2f (%d/%d)" % [rate_b, hits_b, SEEDS_BO])
	_assert(
		fails,
		rate_b >= 0.50 and rate_b <= 1.0,
		"BEARING_ONLY rate in [0.50,1.00] (got %.2f)" % rate_b
	)

	var hits_c: int = 0
	for i in range(SEEDS_DEFENSE):
		if _defense_seed(7000 + i, false)["hit"]:
			hits_c += 1
	var rate_c: float = float(hits_c) / float(SEEDS_DEFENSE)
	var hits_d: int = 0
	for i in range(SEEDS_DEFENSE):
		if _defense_seed(8000 + i, true)["hit"]:
			hits_d += 1
	var rate_d: float = float(hits_d) / float(SEEDS_DEFENSE)
	print("MC DEF BASE  hit_rate=%.2f (%d/%d)" % [rate_c, hits_c, SEEDS_DEFENSE])
	print("MC DEF EVADE hit_rate=%.2f (%d/%d)" % [rate_d, hits_d, SEEDS_DEFENSE])
	_assert(fails, rate_c >= 0.05, "defense baseline rate > 0 (got %.2f)" % rate_c)
	_assert(
		fails,
		rate_d < rate_c,
		"evasion statistically reduces hit rate (%.2f < %.2f)" % [rate_d, rate_c],
	)

	if fails.is_empty():
		print("MC-HIT-RATE TEST PASS")
		quit(0)
	else:
		print("MC-HIT-RATE TEST FAIL (%d)" % fails.size())
		quit(1)


## A/B：玩家攻击移动敌方（教程护卫舰场景，自然声学证据 + TMA）。
func _attack_seed(seed_val: int, bearing_only: bool) -> Dictionary:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["duration"] = 99999.0
	sc["own_ship"]["turn_rate_deg_s"] = 1.5
	sc["doctrine"] = {
		"sensor_false_alarm_rate": 0.0,
		"counterfire_probability": 0.0,
		"fire_quality_threshold": 99.0,
		"decoy_launch_probability": 0.0,
	}
	var w := World.new()
	w.load_scenario(sc)
	# 场景配置：安静 8kn 潜深 70m 目标（同层基线；声学参数为场景定义，非 Truth 瞄准）
	var t0: TruthEntity = w.world["targets"][0]
	t0.speed_kn = 8.0
	t0.depth_m = 70.0
	var ac: Dictionary = sc["targets"][0]["acoustic"]
	ac["broadband_base_level_db"] = 138.0
	for tl in ac.get("tonal_lines", []):
		tl["level_db"] = float(tl["level_db"]) - 12.0
	# 深度不设浅水预设：鱼雷按 UPPER 层带 hold（70m，与目标同层）。
	var own: TruthEntity = w.world["own"]
	var tracker := Tracker.new()
	var fcc := FireControlContext.new()
	var op: OperatorSonar = OperatorSonar.new()
	op.setup(w.world)
	var track: Track = null
	var fired: bool = false
	# 单观测腿基线（操作员未机动场景；解质量自然有限 → 命中率 <100%）
	while w.sim_time < 420.0:
		w.run_steps(1)
		op.catch_up_rows(
			w.sim_time, w.world["targets"] + w._acoustic_scene_emitters(), w.world["target_acs"]
		)
		var auto_ms: Array = op.autocrew_step(w.sim_time)
		if auto_ms.is_empty():
			continue
		var pm: Measurement = auto_ms[0]
		var grp: Array = [pm]
		var i2: int = 1
		while (
			i2 < auto_ms.size()
			and auto_ms[i2].evidence_id == pm.evidence_id
			and auto_ms[i2].has_ambiguity()
		):
			grp.append(auto_ms[i2])
			i2 += 1
		var tt: Track = tracker.feed_evidence_group(grp, "", 8.0)
		if tt == null:
			tt = tracker.mark(pm, "M")
			for j in range(1, grp.size()):
				tt.add_measurement(grp[j] as Measurement)
		track = tt
		fcc.sync_revision(track)
		# 证据 ≥6 后尝试解算/提交/发射；SOLUTION 射程出界（RANGE_INVALID）
		# 时像真实操作员一样继续收集证据再试（上限 14 条）。
		if track.evidence_count() < 6 or (bearing_only and fired):
			continue
		if bearing_only:
			# 仅方位发射：证据足够即按下扳机（真实操作员在无解时也如此）。
			var fe_bo := FireExecutor.new()
			fe_bo.fcc = fcc
			fe_bo.tracker = tracker
			fe_bo.programmer = LaunchProgrammer.new()
			var res_bo: Dictionary = fe_bo.execute(w.weapons, w, "BEARING_ONLY", track.track_id)
			fired = true
			if not bool(res_bo.get("ok", false)):
				return {"hit": false, "r": "fire:" + str(res_bo.get("reason", ""))}
			break
		fcc.solve_and_store(track, null, w.sim_time)
		var cr: Dictionary = fcc.commit_solution(track.track_id, w.sim_time)
		if not bool(cr.get("ok", false)):
			continue
		var fe := FireExecutor.new()
		fe.fcc = fcc
		fe.tracker = tracker
		fe.programmer = LaunchProgrammer.new()
		var res: Dictionary = fe.execute(w.weapons, w, "SOLUTION", track.track_id)
		if bool(res.get("ok", false)):
			fired = true
			break
	var result := {"hit": false, "r": "no_track"}
	if not (track == null or track.evidence_count() < 4):
		var mode: String = "BEARING_ONLY" if bearing_only else "SOLUTION"
		if not fired:
			# 循环内未发射成功的兜底（SOLUTION 最后一次提交+发射）。
			var fire_ok := true
			if not bearing_only:
				fcc.solve_and_store(track, null, w.sim_time)
				var cr2: Dictionary = fcc.commit_solution(track.track_id, w.sim_time)
				fire_ok = bool(cr2.get("ok", false))
				if not fire_ok:
					result = {"hit": false, "r": "commit"}
			if fire_ok:
				var fe2 := FireExecutor.new()
				fe2.fcc = fcc
				fe2.tracker = tracker
				fe2.programmer = LaunchProgrammer.new()
				var res2: Dictionary = fe2.execute(w.weapons, w, mode, track.track_id)
				if not bool(res2.get("ok", false)):
					fire_ok = false
					result = {"hit": false, "r": "fire:" + str(res2.get("reason", ""))}
			fired = fire_ok
		if fired:
			result = {"hit": false, "r": "budget"}
			var e: TruthEntity = w.world["targets"][0]
			for i in range(BUDGET_POST_FIRE):
				w.run_steps(1)
				if str(e.damage_state) == "sunk":
					result = {"hit": true, "r": "sunk"}
					break
				if (w.weapons.torpedoes as Array).is_empty():
					result = {"hit": false, "r": "gone"}
					break
	return result


## C：敌雷命中玩家（固定几何发射=场景脚手架；鱼雷自然制导）。
## evade=true 时玩家在敌雷入水后转向+加速+换层+放 MOBILE 诱饵（合法操作）。
func _defense_seed(seed_val: int, evade: bool) -> Dictionary:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["duration"] = 99999.0
	sc["targets"] = []
	var b: float = deg_to_rad(90.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 90.0,
		"bearing_max_deg": 90.0,
		"range_min_m": 2000.0,
		"range_mode_m": 2000.0,
		"range_max_m": 2000.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 10,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 2000.0,
			"position_north_m": cos(b) * 2000.0,
			"course_deg": 270.0,
			"speed_kn": 6.0,
			"depth_m": 50.0,
		},
		"doctrine": {"sensor_false_alarm_rate": 0.0},
	}
	var w := World.new()
	w.load_scenario(sc)
	var own: TruthEntity = w.world["own"]
	own.command_speed(8.0)
	w.run_steps(40)
	var e: TruthEntity = w.enemy_ai.entity
	var brg: float = (
		NavUtils
		. bearing_to_true(
			float(e.position_east_m),
			float(e.position_north_m),
			float(own.position_east_m),
			float(own.position_north_m),
		)
	)
	var prog := WeaponProgram.make_bearing_only(brg)
	prog.speed_mode = WeaponProgram.SpeedMode.HIGH
	prog.wire_guidance_enabled = false
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 100.0
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	var tp: Torpedo = w.enemy_weapons.fire_program(
		prog, float(e.position_east_m), float(e.position_north_m), w.sim_time, float(e.depth_m)
	)
	if tp == null:
		return {"hit": false, "r": "launch_fail"}
	var evaded := false
	for i in range(1200):
		w.run_steps(1)
		if evade and not evaded and w.sim_time >= 50.0:
			own.command_course(45.0)
			own.command_speed(8.0)
			own.command_depth(180.0)
			var dprog := DecoyProgram.new()
			dprog.course_deg = 90.0
			dprog.speed_kn = 8.0
			dprog.signature = _mk_ac()
			w._launch_decoy(dprog)
			evaded = true
		var ds: String = str(own.damage_state)
		if ds == "damaged" or ds == "sunk":
			return {"hit": true, "r": "hit@%.0f" % w.sim_time}
		if (w.enemy_weapons.torpedoes as Array).is_empty():
			return {"hit": false, "r": "gone"}
	return {"hit": false, "r": "budget"}


func _mk_ac() -> AcousticProfile:
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = 138.0
	ac.tonal_lines = [
		{"freq_hz": 120.0, "level_db": 126.0},
		{"freq_hz": 240.0, "level_db": 120.0},
	]
	return ac


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)
