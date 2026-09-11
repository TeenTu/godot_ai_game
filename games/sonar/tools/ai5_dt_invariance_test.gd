extends SceneTree
## AI-05（P0-B）——反击机会的 dt 无关性 / 证据原子性 / 固定种子可复现。
##
## 文档 §6 要求（原文）：
##   「AI-05 验证同一证据流下dt=0.1/0.5/1.0秒的发射时间分布基本一致；固定时间步/
##     固定种子可复现。同一Ping不能因多个消费回调重复提升质量。测试应把感知概率与
##     doctrine分开：先向AI注入完全相同的净化观测，再比较策略。」
##
## 本测试因此**完全绕开感知概率**：不经过声呐方程/探测抽样，直接向
## EnemyTrackManager 注入同一份净化观测流（按仿真时间以固定节奏投喂，与 dt 无关），
## 只比较 EnemyDoctrineController 的策略输出。
##
## 覆盖：
##   A 证据原子性：同一 evidence_id 被多个消费回调重复投喂，质量/证据数不重复增长
##     （正对照：换一个 evidence_id 必须真的抬质量——否则本用例无法辨别"没重复"）。
##   B 泊松机会率：固定时间窗内机会次数 ≈ λ·T，且 dt=0.1/0.5/1.0 三者互相一致
##     （旧实现把固定 sample_interval_s 当机会窗口，dt=0.5 时机会数会翻数倍）。
##   C 首发射时间分布：同一注入证据流下，dt 三档的**首发射时间均值**一致。
##   D 可复现：同 seed 同 dt 双跑，每个 seed 的首发射时间逐位一致。
##
## 运行：godot --headless --path games/sonar --script res://tools/ai5_dt_invariance_test.gd

const HORIZON_S: float = 1000.0
const RATE_PER_S: float = 0.05
const RATE_TOL_FRAC: float = 0.15
const FIRE_DT_LIST: Array = [0.1, 0.5, 1.0]
const EVIDENCE_CADENCE_S: float = 5.0
## C/D 用较大 λ（均值间隔 5s）压低分布方差，使均值比较有辨别力。
const FIRE_RATE_PER_S: float = 0.2
const FIRE_SEEDS: int = 40
const FIRE_TOL_S: float = 4.0
const REACTION_S: float = 5.0


func _initialize() -> void:
	var fails: Array = []
	_part_a_evidence_atomicity(fails)
	_part_b_opportunity_rate(fails)
	_part_c_first_fire_dt_consistency(fails)
	_part_d_reproducible(fails)
	_finish(fails)


## ---- A：证据原子性 ----
func _part_a_evidence_atomicity(fails: Array) -> void:
	var mgr := EnemyTrackManager.new()
	var ev: Dictionary = _mk_evidence(45.0, 0.95, 1)
	mgr.feed(ev, 0.0)
	var q1: float = float(mgr.tracks[0]["quality"])
	var c1: int = int(mgr.tracks[0]["evidence_count"])
	# 同一 Ping 被多个消费回调重复投喂 5 次。
	for i in range(1, 6):
		mgr.feed(ev, float(i))
	var q2: float = float(mgr.tracks[0]["quality"])
	var c2: int = int(mgr.tracks[0]["evidence_count"])
	_assert(
		fails,
		absf(q2 - q1) < 1e-9 and c2 == c1,
		(
			"A same Ping fed 5x does not raise quality/evidence (q %.3f→%.3f, n %d→%d)"
			% [q1, q2, c1, c2]
		),
	)
	# 正对照：不同 evidence_id 必须真的抬质量（否则上面的断言没有辨别力）。
	mgr.feed(_mk_evidence(45.0, 0.95, 2), 6.0)
	var q3: float = float(mgr.tracks[0]["quality"])
	var c3: int = int(mgr.tracks[0]["evidence_count"])
	_assert(
		fails,
		q3 > q2 + 1e-6 and c3 == c2 + 1,
		"A new evidence id does raise quality (q %.3f→%.3f, n %d→%d)" % [q2, q3, c2, c3],
	)


## ---- B：泊松机会率的 dt 无关性 ----
func _part_b_opportunity_rate(fails: Array) -> void:
	var expected: float = RATE_PER_S * HORIZON_S
	var means: Dictionary = {}
	for dt in FIRE_DT_LIST:
		var ctl: EnemyDoctrineController = _mk_controller(
			7000, {"counterfire_rate_per_s": RATE_PER_S}
		)
		var total: float = 0.0
		var runs: int = 20
		for r in range(runs):
			ctl = _mk_controller(7000 + r, {"counterfire_rate_per_s": RATE_PER_S})
			var t: float = 0.0
			var n: int = 0
			while t < HORIZON_S:
				t += float(dt)
				if ctl._take_opportunity(t, RATE_PER_S):
					n += 1
			total += float(n)
		var mean: float = total / float(runs)
		means[float(dt)] = mean
		_assert(
			fails,
			absf(mean - expected) <= RATE_TOL_FRAC * expected,
			(
				"B opportunity count dt=%.1f within %.0f%% of λT (mean %.1f vs %.1f)"
				% [float(dt), RATE_TOL_FRAC * 100.0, mean, expected]
			),
		)
	# 三档互相比：旧实现 dt=0.5 会把机会数放大到设计值数倍，这条立刻红。
	var lo: float = float(means[FIRE_DT_LIST[0]])
	var hi: float = float(means[FIRE_DT_LIST[FIRE_DT_LIST.size() - 1]])
	for dt in FIRE_DT_LIST:
		lo = minf(lo, float(means[float(dt)]))
		hi = maxf(hi, float(means[float(dt)]))
	_assert(
		fails,
		hi - lo <= RATE_TOL_FRAC * expected,
		"B dt 0.1/0.5/1.0 opportunity rates agree (spread %.2f)" % (hi - lo),
	)


## ---- C：首发射时间在不同 dt 下的分布一致 ----
func _part_c_first_fire_dt_consistency(fails: Array) -> void:
	var means: Dictionary = {}
	for dt in FIRE_DT_LIST:
		var total: float = 0.0
		var fired: int = 0
		for s in range(FIRE_SEEDS):
			var t: float = _first_fire_time(8000 + s, float(dt))
			if t > 0.0:
				total += t
				fired += 1
		_assert(
			fails,
			fired == FIRE_SEEDS,
			"C all %d seeds counterfired at dt=%.1f (got %d)" % [FIRE_SEEDS, float(dt), fired],
		)
		means[float(dt)] = total / maxf(float(fired), 1.0)
	var d_lo: float = float(means[FIRE_DT_LIST[0]])
	var d_hi: float = d_lo
	for dt in FIRE_DT_LIST:
		d_lo = minf(d_lo, float(means[float(dt)]))
		d_hi = maxf(d_hi, float(means[float(dt)]))
	_assert(
		fails,
		d_hi - d_lo <= FIRE_TOL_S,
		(
			"C mean first-fire time agrees across dt (%.1f/%.1f/%.1f, spread %.1fs)"
			% [
				float(means[FIRE_DT_LIST[0]]),
				float(means[FIRE_DT_LIST[1]]),
				float(means[FIRE_DT_LIST[2]]),
				d_hi - d_lo,
			]
		),
	)


## ---- D：固定 dt + 固定 seed 双跑可复现 ----
func _part_d_reproducible(fails: Array) -> void:
	for dt in FIRE_DT_LIST:
		var ok: bool = true
		for s in range(6):
			var a: float = _first_fire_time(9100 + s, float(dt))
			var b: float = _first_fire_time(9100 + s, float(dt))
			if absf(a - b) > 1e-9:
				ok = false
		_assert(fails, ok, "D same dt/seed reproduces first-fire time (dt=%.1f)" % float(dt))


## 固定节奏注入同一份净化观测流（按仿真时间投喂，与 dt 无关），
## 返回首发射时刻（<=0 = 未发射）。
func _first_fire_time(seed_val: int, dt: float) -> float:
	var ctl: EnemyDoctrineController = _mk_controller(
		seed_val,
		{
			"counterfire_rate_per_s": FIRE_RATE_PER_S,
			"reaction_delay_min_s": REACTION_S,
			"reaction_delay_max_s": REACTION_S,
		}
	)
	var now: float = 0.0
	var next_ev: float = 0.0
	var ev_n: int = 0
	while now < 600.0:
		now += dt
		while now >= next_ev:
			ev_n += 1
			ctl.tracks.feed(_mk_evidence(45.0, 0.95, ev_n), now)
			next_ev += EVIDENCE_CADENCE_S
		var actions: Array = ctl.update(now, dt, [])
		for a in actions:
			if str((a as Dictionary).get("action", "")) == "FIRE_TORPEDO":
				return now
	return -1.0


## 最小控制器：空感知（不产生证据）、给定 doctrine、固定随机源。
func _mk_controller(seed_val: int, overrides: Dictionary) -> EnemyDoctrineController:
	var ent := TruthEntity.new()
	ent.id = "RED-1"
	ent.side = "red"
	ent.platform_type = "submarine"
	ent.position_east_m = 3000.0
	ent.position_north_m = 3000.0
	ent.depth_m = 50.0
	ent.speed_kn = 6.0
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	var ad := EnemySensorAdapter.new()
	ad.bind(w.world["env"], w.world.get("depth_model", null), [], {})
	ad.set_rng(_rng(seed_val + 7))
	ad.false_alarm_rate = 0.0
	var doctrine: Dictionary = {
		"fire_quality_threshold": 0.7,
		"tracking_quality_threshold": 0.55,
		"suspicious_quality_threshold": 0.25,
		"reaction_delay_min_s": 1.0,
		"reaction_delay_max_s": 1.0,
		"counterfire_rate_per_s": 1.0,
		"counterfire_cooldown_s": 120.0,
		"attack_min_evidence": 3,
		"attack_min_span_s": 15.0,
		"attack_max_evidence_age_s": 30.0,
		"max_simultaneous_weapons": 2,
		"sample_interval_s": 2.0,
	}
	for k in overrides:
		doctrine[k] = overrides[k]
	var ctl := EnemyDoctrineController.new()
	ctl.configure(
		ent, ad, EnemyTrackManager.new(), doctrine, _rng(seed_val), Callable(self, "_hold")
	)
	return ctl


func _hold(_band: String) -> float:
	return 180.0


func _mk_evidence(bearing_deg: float, pd: float, ev_id: int) -> Dictionary:
	return {
		"evidence_id": ev_id,
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
		print("AI5-DT-INVARIANCE TEST PASS")
		quit(0)
	else:
		print("AI5-DT-INVARIANCE TEST FAIL (%d)" % fails.size())
		quit(1)
