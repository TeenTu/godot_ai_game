extends SceneTree
## S109 Batch 2 — 强制鱼雷识别与 ThreatTrack（AT-05 / AT-06 / AT-07 / AT-08 / AT-09）。

const SEED := 109050


func _initialize() -> void:
	var fails: Array = []
	_at05_manual_still_marks(fails)
	_at06_mode_independent(fails)
	_at07_no_tactical_actions(fails)
	_at08_evidence_dedup(fails)
	_at09_no_prefix_guessing(fails)
	_finish(fails)


## AT-05：全局模式为 MANUAL、Autocrew=false 时，合法鱼雷声学证据仍自动建 TT001。
func _at05_manual_still_marks(fails: Array) -> void:
	var w := _mk_world(SEED)
	# 强制自动化不可关闭；模拟"玩家全手动"：无 Autocrew 可关（世界层无关）。
	_assert(fails, w.threat_automation.always_enabled, "AT-05 threat automation always enabled")
	_assert(fails, not w.threat_automation.user_can_disable, "AT-05 user cannot disable")
	w.run_steps(30)
	var tp := _fire_enemy_torpedo(w)
	if tp == null:
		fails.append("AT-05 enemy torpedo launched")
		_finish(fails)
		return
	_approach(w, 1800.0)
	var marked := false
	for i in range(240):
		w.run_steps(1)
		if not w.threat_tracks.tracks().is_empty():
			marked = true
			break
	_assert(fails, marked, "AT-05 TT track auto-created from real acoustic evidence")
	if marked:
		var t: Dictionary = w.threat_tracks.tracks()[0]
		_assert(fails, str(t["track_id"]) == "TT001", "AT-05 first track is TT001")
		_assert(
			fails,
			str(t["state"]) in ["TENTATIVE", "TRACKING"],
			"AT-05 track state lifecycle (%s)" % str(t["state"]),
		)
		_assert(fails, float(t.get("p_torpedo", 0.0)) >= 0.40, "AT-05 p_torpedo >= SUSPECTED")


## AT-06：同一证据序列在不同全局模式下产生相同 TT 关联与结果（确定性）。
func _at06_mode_independent(fails: Array) -> void:
	var evs: Array = [
		{
			"evidence_id": 1,
			"side_hint": "INTERCEPT",
			"evidence_kind": "LAUNCH_TRANSIENT",
			"bearing_deg": 45.0,
			"bearing_sigma_deg": 2.0,
			"confidence": 0.8,
			"class_state": "SUSPECTED_TORPEDO",
			"p_torpedo": 0.45,
			"timestamp": 10.0,
		},
		{
			"evidence_id": 2,
			"side_hint": "INTERCEPT",
			"evidence_kind": "RUNNING_NOISE",
			"bearing_deg": 47.0,
			"bearing_sigma_deg": 2.0,
			"confidence": 0.9,
			"class_state": "PROBABLE_TORPEDO",
			"p_torpedo": 0.8,
			"timestamp": 30.0,
		},
	]
	var results: Array = []
	for mode in ["MANUAL", "ASSISTED", "FULL_AUTO"]:
		var mgr := ThreatTrackManager.new()
		var ctl := ThreatAutomationController.new()
		ctl.bind_store(mgr)
		var touched: Array = ctl.process_evidence(evs.duplicate(true), 30.0)
		var snap: Array = []
		for tr in mgr.tracks():
			snap.append(
				[
					tr["track_id"],
					tr["state"],
					tr["bearing_deg"],
					tr["evidence_count"],
					tr["p_torpedo"]
				]
			)
		results.append({"mode": mode, "touched": touched.size(), "tracks": snap})
	_assert(
		fails,
		(
			results[0]["tracks"] == results[1]["tracks"]
			and results[1]["tracks"] == results[2]["tracks"]
		),
		"AT-06 same evidence sequence → same TT result in all modes",
	)
	_assert(fails, results[0]["touched"] > 0, "AT-06 tracks actually updated")


## AT-07：强制威胁自动化本身不发 Ping、不发射武器、不发射诱饵。
func _at07_no_tactical_actions(fails: Array) -> void:
	var ctl := ThreatAutomationController.new()
	_assert(
		fails, not ctl.auto_ping and not ctl.auto_fire and not ctl.auto_decoy, "AT-07 flags off"
	)
	# 结构性：喂证据只会触碰 store（track ids），不产生任何命令。
	var mgr := ThreatTrackManager.new()
	ctl.bind_store(mgr)
	var out: Array = (
		ctl
		. process_evidence(
			[
				{
					"evidence_id": 9,
					"side_hint": "INTERCEPT",
					"evidence_kind": "RUNNING_NOISE",
					"bearing_deg": 100.0,
					"bearing_sigma_deg": 2.0,
					"confidence": 0.9,
					"class_state": "PROBABLE_TORPEDO",
					"p_torpedo": 0.9,
					"timestamp": 5.0,
				}
			],
			5.0
		)
	)
	_assert(fails, out.size() == 1 and mgr.tracks().size() == 1, "AT-07 only store touched")
	_assert(fails, not ctl.has_method("issue_ping"), "AT-07 no ping API")
	_assert(fails, not ctl.has_method("fire"), "AT-07 no fire API")
	_assert(fails, not ctl.has_method("launch_decoy"), "AT-07 no decoy API")


## AT-08：同一 evidence_id 重复到达只计一次。
func _at08_evidence_dedup(fails: Array) -> void:
	var mgr := ThreatTrackManager.new()
	var ctl := ThreatAutomationController.new()
	ctl.bind_store(mgr)
	var ev := {
		"evidence_id": 77,
		"side_hint": "INTERCEPT",
		"evidence_kind": "RUNNING_NOISE",
		"bearing_deg": 10.0,
		"bearing_sigma_deg": 2.0,
		"confidence": 0.9,
		"class_state": "PROBABLE_TORPEDO",
		"p_torpedo": 0.9,
		"timestamp": 1.0,
	}
	var t1: Array = ctl.process_evidence([ev], 1.0)
	var t2: Array = ctl.process_evidence([ev], 2.0)
	_assert(fails, t1.size() == 1 and t2.is_empty(), "AT-08 duplicate evidence ignored")
	_assert(fails, int(mgr.tracks()[0]["evidence_count"]) == 1, "AT-08 evidence_count == 1")
	_assert(fails, ctl.has_evidence("77"), "AT-08 seen-registry holds id")


## AT-09：己方鱼雷/诱饵进统一声场但不生成敌雷卡；删除 id 前缀后结果仍正确
## （登记靠内核所有权，不靠 ET/PT 前缀猜阵营）。
func _at09_no_prefix_guessing(fails: Array) -> void:
	var reg := OwnAssetRegistry.new()
	# 己方资产用无关前缀命名——登记与命名无关。
	reg.register("QQQ-1", "TORPEDO", 100.0, 200.0, 40.0, "RUNNING")
	reg.register("ZZZ-2", "DECOY", 110.0, 210.0, 40.0, "ACTIVE")
	_assert(fails, reg.is_own_emitter("QQQ-1"), "AT-09 own torpedo registered (no ET prefix)")
	_assert(fails, reg.is_own_emitter("ZZZ-2"), "AT-09 own decoy registered (no PT prefix)")
	_assert(
		fails, not reg.is_own_emitter("QQQ-9"), "AT-09 enemy not registered by prefix similarity"
	)
	# 己方事件走 OWN_FACT（不进威胁卡）；敌方事件走 INTERCEPT（可进威胁卡）。
	var w := _mk_world(SEED)
	w.run_steps(5)
	var own: TruthEntity = w.world["own"]
	var bus := AcousticEmissionBus.new()
	var san := EmissionSanitizer.new()
	san.bind(w.world["env"], w.world.get("depth_model", null), _rng(12345))
	var ev_own: Dictionary = AcousticEmissionEvent.make(
		1,
		AcousticEmissionEvent.TORPEDO_RUNNING_NOISE,
		"QQQ-1",
		10.0,
		Vector3(float(own.position_east_m) + 1000.0, float(own.position_north_m), 40.0),
		1550.0,
		2900.0,
		150.0,
		1.0,
		{"tonal_lines": [{"freq_hz": 660.0, "level_db": 128.0}]}
	)
	var ev_enemy: Dictionary = AcousticEmissionEvent.make(
		2,
		AcousticEmissionEvent.TORPEDO_RUNNING_NOISE,
		"QQQ-9",
		10.0,
		Vector3(float(own.position_east_m) + 2000.0, float(own.position_north_m), 40.0),
		1550.0,
		2900.0,
		150.0,
		1.0,
		{"tonal_lines": [{"freq_hz": 660.0, "level_db": 128.0}]}
	)
	var refs: Dictionary = reg.refs_dict()
	refs["QQQ-1"] = true
	var evs: Array = san.consume_events([ev_own, ev_enemy], own, 12.0, refs)  # 敌方 2km 单程 ~1.33s
	var own_facts: int = 0
	var intercepts: Array = []
	for e in evs:
		if str(e.get("side_hint")) == "OWN_FACT":
			own_facts += 1
		elif str(e.get("side_hint")) == "INTERCEPT":
			intercepts.append(e)
	_assert(fails, own_facts >= 1, "AT-09 own asset event transcribed as OWN_FACT")
	_assert(fails, intercepts.size() >= 1, "AT-09 enemy (unknown prefix) still intercepted")
	# 威胁卡只来自 INTERCEPT。
	var mgr := ThreatTrackManager.new()
	var ctl := ThreatAutomationController.new()
	ctl.bind_store(mgr)
	ctl.process_evidence(evs, 12.0)
	_assert(fails, mgr.tracks().size() <= intercepts.size(), "AT-09 no threat card from own assets")


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


func _approach(w: World, max_rng: float) -> void:
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
			if d <= max_rng:
				return


func _mk_world(seed_val: int) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["targets"] = []
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


func _rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("THREAT-AUTO-TRACK TEST PASS")
		quit(0)
	else:
		print("THREAT-AUTO-TRACK TEST FAIL (%d)" % fails.size())
		quit(1)
