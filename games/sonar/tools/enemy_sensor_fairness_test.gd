extends SceneTree
## S109 Batch 1 — 敌方感知公平性（AT-20 / AT-21 / AT-22 / AT-23）。

const SEED := 109020


func _initialize() -> void:
	var fails: Array = []
	_at21_enum_irrelevance(fails)
	_at22_decay_rate_independent(fails)
	_at20_propagation_delay(fails)
	_at23_no_evidence_no_truth(fails)
	_finish(fails)


## AT-21：删除/随机化事件枚举但保留相同接收特征，敌方分类/行为统计不变。
## （单元级：同一特征、不同 emission_kind → 截获证据完全一致。）
func _at21_enum_irrelevance(fails: Array) -> void:
	var outs: Array = []
	for kind in ["TORPEDO_RUNNING_NOISE", "UNKNOWN_X", "DECOY_ACTIVATION"]:
		var ad := EnemySensorAdapter.new()
		var env := EnvironmentModel.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 777
		ad.bind(env, null, [], {})
		ad.set_rng(rng)
		var observer := TruthEntity.new()
		observer.position_east_m = 0.0
		observer.position_north_m = 0.0
		observer.depth_m = 60.0
		observer.speed_kn = 0.0
		var ev: Dictionary = AcousticEmissionEvent.make(
			1,
			kind,
			"anom",
			0.0,
			Vector3(0.0, 2000.0, 40.0),
			900.0,
			2900.0,
			150.0,
			1.0,
			{"tonal_lines": [{"freq_hz": 540.0, "level_db": 110.0}]}
		)
		outs.append(ad.intercept_events([ev], observer, 100.0))
	var a: Dictionary = outs[0][0] if not outs[0].is_empty() else {}
	var b: Dictionary = outs[1][0] if not outs[1].is_empty() else {}
	var c: Dictionary = outs[2][0] if not outs[2].is_empty() else {}
	_assert(
		fails, not a.is_empty() and not b.is_empty() and not c.is_empty(), "AT-21 evidence produced"
	)
	if a.is_empty() or b.is_empty() or c.is_empty():
		return
	_assert(fails, _same_obs(a, b), "AT-21 enum swap A->UNKNOWN identical")
	_assert(fails, _same_obs(a, c), "AT-21 enum swap A->DECOY identical")
	# 且三份证据都绝不含枚举字段。
	for e in [a, b, c]:
		_assert(fails, not e.has("emission_kind"), "AT-21 evidence clean of emission_kind")


func _same_obs(a: Dictionary, b: Dictionary) -> bool:
	for k in ["bearing_deg", "bearing_sigma_deg", "se_db", "pd", "source_class", "p_torpedo"]:
		if absf(float(a.get(k, -1e9)) - float(b.get(k, -1e9))) > 1e-9:
			return false
	return true


## AT-22：同一证据和总时长，以 0.1s/0.5s/2.0s 调用 update，最终 quality 近似一致。
func _at22_decay_rate_independent(fails: Array) -> void:
	var finals: Array = []
	for step in [0.1, 0.5, 2.0]:
		var mgr := EnemyTrackManager.new()
		var ev := {"bearing_deg": 90.0, "pd": 0.8, "se_db": 15.0, "source_class": "TORPEDO"}
		mgr.feed(ev, 0.0)
		var t: float = 0.0
		while t < 60.0 - 1e-9:
			t += step
			mgr.update(t)
		finals.append(float(mgr.tracks[0]["quality"]))
	var spread: float = absf(finals[0] - finals[2])
	_assert(
		fails,
		spread < 0.05,
		"AT-22 decay independent of update rate (spread=%.4f)" % spread,
	)


## AT-20：玩家在距离 R 发 Ping，敌方最早感知不得早于 t_emit + R/c。
func _at20_propagation_delay(fails: Array) -> void:
	var w := _mk_world(SEED)
	w.run_steps(20)
	# 静音本艇 + 拉开到 8km：排除被动接触干扰，隔离“Ping 截获时序”。
	var en: TruthEntity = w.enemy_ai.entity
	var own: TruthEntity = w.world["own"]
	own.speed_kn = 0.0
	en.position_east_m = float(own.position_east_m) + 8000.0
	en.position_north_m = float(own.position_north_m)
	w.run_steps(5)
	var n0: int = w.enemy_ai.tracks.tracks.size()
	var r: float = NavUtils.distance(
		float(own.position_east_m),
		float(own.position_north_m),
		float(en.position_east_m),
		float(en.position_north_m)
	)
	var t_emit: float = w.sim_time
	_assert(fails, w.issue_ping(), "AT-20 ping issued")
	var t_arrive: float = t_emit + r / AcousticService.SOUND_SPEED_M_S
	var first_new_t: float = -1.0
	for i in range(400):
		w.run_steps(1)
		var n: int = w.enemy_ai.tracks.tracks.size()
		if n > n0 and first_new_t < 0.0:
			first_new_t = w.sim_time
			break
	_assert(fails, first_new_t > 0.0, "AT-20 enemy eventually perceived the ping")
	if first_new_t > 0.0:
		_assert(
			fails,
			first_new_t >= t_arrive - 0.26,
			(
				"AT-20 perception not before t_emit+R/c (first=%.2f arrive=%.2f)"
				% [first_new_t, t_arrive]
			),
		)
		_assert(
			fails,
			first_new_t < t_arrive + 20.0,
			"AT-20 perception arrives reasonably soon after t_emit+R/c",
		)


## AT-23：未探测到任何玩家证据时，改变玩家 Truth 绝对位置不改变敌方行为序列。
## 两个同 seed 世界保持相同的相对几何（敌 40km 正东于各自本艇），仅绝对
## 位置不同：作弊实现（读绝对 Truth）会分叉，守纪律实现逐位一致。
func _at23_no_evidence_no_truth(fails: Array) -> void:
	var wa := _mk_world(SEED)
	var wb := _mk_world(SEED)
	for w in [wa, wb]:
		var own: TruthEntity = w.world["own"]
		var en: TruthEntity = w.enemy_ai.entity
		own.speed_kn = 0.0
		en.position_east_m = float(own.position_east_m) + 40000.0
		en.position_north_m = float(own.position_north_m)
	var traj_a: Array = []
	var traj_b: Array = []
	for i in range(300):
		wa.run_steps(1)
		wb.run_steps(1)
		var ea: TruthEntity = wa.enemy_ai.entity
		var eb: TruthEntity = wb.enemy_ai.entity
		traj_a.append([float(ea.position_east_m), float(ea.position_north_m)])
		traj_b.append([float(eb.position_east_m), float(eb.position_north_m)])
	var same: bool = true
	for i in range(traj_a.size()):
		if absf(traj_a[i][0] - traj_b[i][0]) > 1e-6 or absf(traj_a[i][1] - traj_b[i][1]) > 1e-6:
			same = false
			break
	var no_evid: bool = wa.enemy_ai.tracks.tracks.is_empty()
	_assert(fails, no_evid, "AT-23 no evidence at 40km isolation")
	_assert(fails, same, "AT-23 no-evidence enemy behavior independent of player Truth")


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


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("ENEMY-SENSOR-FAIRNESS TEST PASS")
		quit(0)
	else:
		print("ENEMY-SENSOR-FAIRNESS TEST FAIL (%d)" % fails.size())
		quit(1)
