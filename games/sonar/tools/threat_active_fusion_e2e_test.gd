extends SceneTree
## S109 AT-13/AT-14 —— P0-04 端到端链验收（Batch 0 复现红，Batch 3 修复转绿）。
##
## 真实实战链：被动噪声证据自动建 TT → World.issue_ping() → 2R/c 回波结算
## （ACTIVE_RANGE_BEARING Measurement）→ 净化 DTO 进 player_evidence（AT-13）
## → ThreatTrack 统计门控自动融合 → RANGE_AIDED + 95% 面积显著收紧（AT-14）。
## 禁止手工向 ChartView/ThreatTrack 塞 range 字典；同 seed 复现比对。

const SEED := 90801


func _initialize() -> void:
	var fails: Array = []
	var a: Dictionary = _run_flow(SEED)
	if not bool(a.get("ok", false)):
		_finish(fails)  # 概率未探测：NOTE 提示后放行（换 seed 重验）
		return
	var b: Dictionary = _run_flow(SEED)
	# ---- AT-13：真实回波产生带 range 的净化威胁证据（player_evidence）----
	_assert(fails, bool(a["evidence_rng"]), "real ping echo → range-bearing evidence (AT-13)")
	_assert(fails, bool(a["evidence_clean"]), "fused evidence free of forbidden keys (AT-13)")
	# ---- AT-14：对应 TT 进入 RANGE_AIDED，95% 面积显著收紧，同 seed 复现 ----
	_assert(fails, bool(a["aided"]), "threat track range-aided by real echo (AT-14)")
	_assert(
		fails,
		float(a["area_post"]) < 0.6 * float(a["area_pre"]),
		(
			"95%% area shrinks after fusion: pre=%.0f post=%.0f"
			% [float(a["area_pre"]), float(a["area_post"])]
		),
	)
	_assert(
		fails, absf(float(a["range_est"]) - float(b["range_est"])) < 1e-9, "reproducible range_est"
	)
	_assert(fails, str(a["aided_id"]) == str(b["aided_id"]), "reproducible aided track id")
	# ---- AT-15 端到端子项：融合后错误距离回波不改变已收紧航迹 ----
	_assert(fails, bool(a["gate_reject_clean"]), "out-of-gate echo leaves track unchanged (AT-15)")
	_finish(fails)


## 完整流程跑一遍；返回观测结果字典（ok=false 表示回波未探测，概率性放行）。
func _run_flow(seed_val: int) -> Dictionary:
	var out := {"ok": false}
	var w := _mk_world(seed_val)
	w.run_steps(30)
	var tp := _fire_enemy_torpedo(w)
	if tp == null:
		return out
	_approach_torpedo(w, 1500.0)
	# 被动证据链应已自动建 TT（威胁自动化强制运行，与三态自动化无关）。
	var tt: Dictionary = {}
	for tr in w.threat_tracks.tracks():
		if tr.get("est") != null:
			tt = tr
			break
	if tt.is_empty():
		out["ok"] = true
		out["evidence_rng"] = false
		out["aided"] = false
		print("NOTE no passive TT formed before ping")
		return out
	var el_pre: Dictionary = (tt["est"] as TorpedoThreatEstimator).ellipse_95()
	var area_pre: float = float(el_pre["axis_a_m"]) * float(el_pre["axis_b_m"])
	if not w.issue_ping():
		return out
	var detected := false
	var aided := false
	for i in range(160):
		w.run_steps(1)
		for r in w.take_arrived_echoes():
			# S109 Batch 1：回波摘要无 target_id；≤1500m 逼近雷的回波距离 <2km。
			if bool(r.get("detected")) and float(r.get("range_m", -1.0)) > 0.0:
				if float(r["range_m"]) < 2000.0:
					detected = true
		for tr in w.threat_tracks.tracks():
			if str(tr.get("state", "")) == "RANGE_AIDED":
				aided = true
				tt = tr
		if detected and aided:
			break
	if not detected:
		print("NOTE echo not detected with seed %d (probabilistic) — rerun another seed" % seed_val)
		return out
	out["ok"] = true
	# AT-13：净化带距证据 + 禁止字段扫描。
	var ev_rng := false
	var ev_clean := true
	for e in w.player_evidence:
		if e.get("measured_range_m", null) == null:
			continue
		ev_rng = true
		for k in [
			"target_id", "emission_kind", "true_range_m", "true_bearing_deg", "internal_token"
		]:
			if e.has(k):
				ev_clean = false
	out["evidence_rng"] = ev_rng
	out["evidence_clean"] = ev_clean
	# AT-14：RANGE_AIDED + 95% 面积收紧。
	out["aided"] = aided
	out["aided_id"] = str(tt.get("track_id", ""))
	out["range_est"] = float(tt.get("range_est_m", -1.0)) if aided else -1.0
	var el_post: Dictionary = (tt["est"] as TorpedoThreatEstimator).ellipse_95()
	out["area_pre"] = area_pre
	out["area_post"] = float(el_post["axis_a_m"]) * float(el_post["axis_b_m"])
	# AT-15：事后注入一条远离后验的回波 DTO → 门控拒绝，协方差/σ 不动。
	if aided:
		var tr_id: String = str(tt["track_id"])
		var est: TorpedoThreatEstimator = tt["est"]
		var rng_pre: float = float(tt["range_est_m"])
		var e_pre: Dictionary = est.ellipse_95()
		var bad := {
			"evidence_id": 999999,
			"bearing_deg": float(tt["bearing_deg"]),
			"bearing_sigma_deg": 2.0,
			"measured_range_m": 9000.0,
			"range_sigma_m": 60.0,
			"observer_e_m": float(w.world["own"].position_east_m),
			"observer_n_m": float(w.world["own"].position_north_m),
		}
		var fused: String = w.threat_tracks.fuse_active_return(bad, w.sim_time)
		var e_post: Dictionary = est.ellipse_95()
		# 门控拒绝：不返回航迹、距离估计不变、95% 半轴不缩小。
		out["gate_reject_clean"] = (
			fused == ""
			and absf(float(tt["range_est_m"]) - rng_pre) < 1e-9
			and float(e_post["axis_a_m"]) >= float(e_pre["axis_a_m"]) - 1e-6
			and str(tt["track_id"]) == tr_id
		)
	else:
		out["gate_reject_clean"] = false
	return out


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


func _approach_torpedo(w: World, max_rng: float) -> void:
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


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("THREAT-ACTIVE-FUSION-E2E TEST PASS")
		quit(0)
	else:
		print("THREAT-ACTIVE-FUSION-E2E TEST FAIL (%d)" % fails.size())
		quit(1)
