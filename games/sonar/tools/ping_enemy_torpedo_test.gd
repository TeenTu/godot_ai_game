extends SceneTree
## REQ-0908 Batch 2 — 平台主动 Ping 纳入敌方鱼雷（Batch 2 验收 1-8）。
##
## 1. 敌雷在覆盖+监听窗内 → issue_ping 登记敌雷回波（固定高 SE 种子可回波）；
## 2. 同 seed 复现；多种子概率性（非全有/全无）；
## 3. 扇区外敌雷不登记回波；
## 4. 超出监听窗（往返 > 固定窗）敌雷不登记；
## 5. 回波到达时间 = emit + 2R/c；
## 6. 回波在途时敌雷死亡，已形成回波仍按发射时刻快照结算；
## 7. 主动敌雷 Measurement 可与被动敌雷 Track 关联（同一 Track）；
## 8. Measurement.to_dict 不含 internal_token/target_id/Truth 坐标。
## 验收 9（既有主动 Ping 测试全过）由 ci_tests.txt 全量回归覆盖。

const SEED := 90801


func _initialize() -> void:
	var fails: Array = []

	# ---- 验收 1/5：敌雷覆盖+窗内 → 登记回波；到达时间 = emit + 2R/c ----
	var w := _mk_world(SEED)
	w.run_steps(30)
	var tp := _fire_enemy_torpedo(w)
	_assert(fails, tp != null, "enemy torpedo launched")
	if tp == null:
		_finish(fails)
		return
	var approached := _approach_torpedo(w, 1500.0)
	_assert(fails, approached, "torpedo within 1500 m")

	var emit_t: float = w.sim_time
	_assert(fails, w.issue_ping(), "issue_ping accepted")
	var pending: int = w.pending_echo_count()
	_assert(fails, pending > 0, "pending echoes registered (pending=%d)" % pending)
	var techo: Dictionary = _torpedo_echo(w, tp)
	_assert(
		fails,
		not techo.is_empty(),
		(
			"echo registered for enemy torpedo %s (got: %s)"
			% [
				str(tp.torpedo_id),
				str(w._ping_session["echoes"].map(func(x): return str(x["target_id"]))),
			]
		),
	)
	if not techo.is_empty():
		var tau: float = AcousticService.echo_travel_time_s(
			float(techo["range_ref_m"]), w.ping_sound_speed_m_s
		)
		_assert(
			fails,
			absf(float(techo["arrive_t"]) - (emit_t + tau)) < 1e-6,
			"arrive_t == emit + 2R/c (验收5)",
		)

	# ---- 验收 6：回波在途时敌雷"死亡"（移除），回波仍按快照结算 ----
	w.enemy_weapons.torpedoes.clear()
	for i in range(60):
		w.run_steps(1)
	var results: Array = w.take_arrived_echoes()
	if not techo.is_empty():
		_assert(fails, bool(techo["settled"]), "snapshot echo settled after torpedo removed (验收6)")
	var echo_meas: Measurement = null
	for r in results:
		if str(r.get("target_id")) == str(tp.torpedo_id) and bool(r.get("detected")):
			echo_meas = r["measurement"]
			break

	# ---- 验收 8：Measurement.to_dict 无 target_id/internal_token/Truth 坐标 ----
	if echo_meas != null:
		var d: Dictionary = echo_meas.to_dict()
		_assert(
			fails,
			not d.has("target_id") and not d.has("internal_token"),
			"to_dict clean of ids (验收8)"
		)
		_assert(
			fails,
			not d.has("position_east_m") and not d.has("position_north_m"),
			"to_dict clean of Truth coords",
		)
		_assert(
			fails,
			str(d.get("measurement_type")) == "ACTIVE_RANGE_BEARING",
			"active echo type ACTIVE_RANGE_BEARING",
		)

	# ---- 验收 7：主动敌雷 Measurement 与被动敌雷 Track 关联 ----
	if echo_meas != null:
		var tr := Tracker.new()
		var pm := Measurement.new()
		pm.timestamp = emit_t - 1.0
		pm.detected = true
		pm.measured_bearing_deg = float(echo_meas.measured_bearing_deg)
		pm.bearing_sigma_deg = 2.0
		pm.evidence_id = "passive_torp_1"
		var t: Track = tr.mark(pm, "P")
		var t2: Track = tr.feed(echo_meas)
		_assert(
			fails,
			t2 != null and t2.track_id == t.track_id,
			"active torpedo echo associates with passive torpedo track (验收7)",
		)

	# ---- 验收 2a：同 seed 复现 ----
	var w2 := _mk_world(SEED)
	w2.run_steps(30)
	var tp2 := _fire_enemy_torpedo(w2)
	_approach_torpedo(w2, 1500.0)
	w2.issue_ping()
	# 立即捕获回波 dict 引用（结算原地更新 detected；冷却后 session 清空
	# 也不影响已持有的引用）。
	var techo2: Dictionary = _torpedo_echo(w2, tp2)
	for i in range(60):
		w2.run_steps(1)
	w2.take_arrived_echoes()
	_assert(
		fails,
		(
			(not techo.is_empty()) == (not techo2.is_empty())
			and (
				techo.is_empty()
				or (
					absf(float(techo["range_ref_m"]) - float(techo2["range_ref_m"])) < 1e-6
					and bool(techo["detected"]) == bool(techo2["detected"])
				)
			)
		),
		"same seed reproduces echo registration/detection (验收2a)",
	)

	# ---- 验收 2b：弱 TS 多种子 → 概率性（非全有/全无） ----
	var det: int = 0
	var total: int = 12
	for k in range(total):
		var wk := _mk_world(91000 + k)
		wk.run_steps(30)
		var tpk := _fire_enemy_torpedo(wk)
		if tpk == null:
			continue
		_approach_torpedo(wk, 1500.0)
		# 弱化 TS 使 SE 落入 Pd 抽样的敏感区（标定：TS=-45 @1.5km → Pd≈0.45，
		# 12 seeds 的全有/全无概率 ≈0）。
		tpk.acoustic_profile.active_target_strength_db = -45.0
		if not wk.issue_ping():
			continue
		for i in range(40):
			wk.run_steps(1)
		for r in wk.take_arrived_echoes():
			if str(r.get("target_id")) == str(tpk.torpedo_id) and bool(r.get("detected")):
				det += 1
				break
	_assert(
		fails,
		det > 0 and det < total,
		"weak-TS multi-seed detection is probabilistic: %d/%d (验收2b)" % [det, total],
	)

	# ---- 验收 3：扇区外敌雷不登记（collector 单元级） ----
	var w3 := _mk_world(SEED)
	w3.run_steps(5)
	var own3: TruthEntity = w3.world["own"]
	# 正南 4000m 处造一个"概念反射体"（不经武器链）。
	var far := TruthEntity.new()
	far.id = "ETSEC"
	far.position_east_m = float(own3.position_east_m)
	far.position_north_m = float(own3.position_north_m) - 4000.0
	far.depth_m = 40.0
	far.speed_kn = 20.0
	var ac3 := AcousticProfile.new()
	ac3.active_target_strength_db = 20.0
	w3.world["targets"].append(far)
	w3.world["target_acs"][far.id] = ac3
	var sensor_omni := SensorArray.new()
	(
		sensor_omni
		. from_dict(
			{
				"sensor_id": "ACT_TEST",
				"array_type": "active",
				"owner_id": str(own3.id),
				"coverage_start_deg": 0.0,
				"coverage_end_deg": 360.0,
			}
		)
	)
	var snaps_all: Array = w3._collect_active_reflectors(sensor_omni)
	var omni_tokens := {}
	for s in snaps_all:
		omni_tokens[str(s.internal_token)] = true
	_assert(fails, omni_tokens.has("ETSEC"), "in-sector reflector registered")
	var sensor_sec := SensorArray.new()
	(
		sensor_sec
		. from_dict(
			{
				"sensor_id": "ACT_SEC",
				"array_type": "active",
				"owner_id": str(own3.id),
				"coverage_start_deg": 315.0,
				"coverage_end_deg": 45.0,  # 北向扇区：正南反射体在扇区外
			}
		)
	)
	var snaps_sec: Array = w3._collect_active_reflectors(sensor_sec)
	var sec_tokens := {}
	for s in snaps_sec:
		sec_tokens[str(s.internal_token)] = true
	_assert(fails, not sec_tokens.has("ETSEC"), "sector-outside reflector excluded (验收3)")

	# ---- 验收 4：往返超监听窗（> ping_max_range_m）不登记 ----
	var far2 := TruthEntity.new()
	far2.id = "ETFAR"
	far2.position_east_m = float(own3.position_east_m)
	far2.position_north_m = float(own3.position_north_m) + (w3.ping_max_range_m() + 500.0)
	far2.depth_m = 40.0
	far2.speed_kn = 20.0
	w3.world["targets"].append(far2)
	w3.world["target_acs"][far2.id] = ac3
	var snaps_far: Array = w3._collect_active_reflectors(sensor_omni)
	var far_tokens := {}
	for s in snaps_far:
		far_tokens[str(s.internal_token)] = true
	_assert(fails, not far_tokens.has("ETFAR"), "beyond-listen-window reflector excluded (验收4)")

	_finish(fails)


func _fire_enemy_torpedo(w: World) -> Torpedo:
	var e: TruthEntity = w.enemy_ai.entity
	var brg_e2own: float = (
		NavUtils
		. bearing_to_true(
			float(e.position_east_m),
			float(e.position_north_m),
			float(w.world["own"].position_east_m),
			float(w.world["own"].position_north_m),
		)
	)
	var prog := WeaponProgram.make_bearing_only(brg_e2own)
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 100.0
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	return w.enemy_weapons.fire_program(
		prog, float(e.position_east_m), float(e.position_north_m), w.sim_time, float(e.depth_m)
	)


func _approach_torpedo(w: World, max_rng: float) -> bool:
	for i in range(300):
		w.run_steps(1)
		if not w.enemy_weapons.torpedoes.is_empty():
			var t0: Torpedo = w.enemy_weapons.torpedoes[0]
			var d: float = (
				NavUtils
				. distance(
					float(t0.pos_east_m),
					float(t0.pos_north_m),
					float(w.world["own"].position_east_m),
					float(w.world["own"].position_north_m),
				)
			)
			if d <= max_rng and not t0.is_dead():
				return true
	return false


func _torpedo_echo(w: World, tp: Torpedo) -> Dictionary:
	for e2 in w._ping_session["echoes"]:
		if str(e2["target_id"]) == str(tp.torpedo_id):
			return e2
	return {}


func _mk_world(seed_val: int) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["targets"] = []  # 只留随机出生敌雷，隔离"P0-01 不含敌雷"的缺陷面
	var b: float = deg_to_rad(0.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 0.0,
		"bearing_max_deg": 0.0,
		"range_min_m": 3000.0,
		"range_mode_m": 3000.0,
		"range_max_m": 3000.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 10,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 3000.0,
			"position_north_m": cos(b) * 3000.0,
			"course_deg": 180.0,
			"speed_kn": 6.0,
			"depth_m": 60.0,
		},
		"doctrine": {"sensor_false_alarm_rate": 0.0},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("PING-ENEMY-TORPEDO TEST PASS")
		quit(0)
	else:
		print("PING-ENEMY-TORPEDO TEST FAIL (%d)" % fails.size())
		quit(1)
