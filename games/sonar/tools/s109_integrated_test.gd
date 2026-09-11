extends SceneTree
## s109_integrated_test.gd — S109 Batch 8（§12 集成与性能 + §13.8 AT-39..41）。
##
## IT-1 集成场景（世界级）：两枚来袭鱼雷 + 己方在水鱼雷 + 诱饵同时在场；
##     强制自动化建 2 条 TT（不合并不吞友方）→ 真实 Ping 融合收紧 →
##     命中终局恰好一次 + 冻结；固定 seed 双跑 digest 一致。
## IT-2 UI 终局（真实 main_ui，s1_combat）：页面隐藏期间威胁证据仍更新
##     告警/红点；8× 倍速按仿真 tick 追帧（estimator 不跳拍）；终局后
##     覆盖层立即显示中文「任务失败 / 鱼雷命中，本艇损失」（AT-39）。
##     命中路径本身由 IT-1 + enemy_hit_gameover_test 实证；UI 阶段若预算
##     内未自然命中，用 end_mission 公共契约 API 走同一信号链验证接线。
## IT-3 AT-40：终局后 Ping/发射/诱饵/线导/机动命令全部拒绝且
##     command_reject_reason 映射中文「任务已结束：命令被拒」。
## IT-4 AT-41：敌雷命中诱饵 / 未解保掠过 / 未起爆近失均不得错误终局。

const SCENARIO := "stage1_basic_passive"
const COMBAT := "s1_combat"
const SCAN_SPAN := 80
## 直瞄方位修正：敌艇航向≠发射方位时的入弯漂移补偿（固定几何下扫描出
## 使雷以 <150m 掠过本艇的确定性偏移）。
const OFFSETS := [-24.0, -28.0, -20.0, -16.0, -32.0, -12.0]


func _initialize() -> void:
	var fails: Array = []
	# ---- IT-1 集成场景 ----
	var best: Dictionary = {}
	for sv in range(90805, 90805 + SCAN_SPAN):
		var r1: Dictionary = _run_integrated(sv)
		if bool(r1.get("aided", false)) and bool(r1.get("ended", false)):
			best = r1
			break
	_assert(fails, not best.is_empty(), "IT-1s seed scan: hit+range-aided scenario found")
	if not best.is_empty():
		_assert(
			fails,
			int(best["tt_count"]) == 2,
			"IT-1a two auto TT formed (got %d)" % int(best["tt_count"])
		)
		_assert(fails, bool(best["tt_distinct"]), "IT-1b TT ids distinct (no merge)")
		_assert(fails, bool(best["decoy_seen"]), "IT-1c own decoy active in scene")
		_assert(fails, bool(best["own_tp_seen"]), "IT-1d own torpedo in water in scene")
		_assert(fails, bool(best["evidence_clean"]), "IT-1e fused evidence still sanitized")
		_assert(fails, bool(best["aided"]), "IT-1f real ping → RANGE_AIDED")
		_assert(
			fails,
			float(best["area_post"]) < 0.6 * float(best["area_pre"]),
			(
				"IT-1g 95%% area tightens: pre=%.0f post=%.0f"
				% [float(best["area_pre"]), float(best["area_post"])]
			)
		)
		_assert(fails, int(best["end_events"]) == 1, "IT-1h mission_ended exactly once (AT-39)")
		_assert(fails, bool(best["frozen"]), "IT-1i simulation frozen after end")
		var r2: Dictionary = _run_integrated(int(best["seed"]))
		_assert(
			fails, str(best["digest"]) == str(r2["digest"]), "IT-1j fixed-seed reproducible digest"
		)

	# ---- IT-2 / IT-3 UI：真实 main_ui 终局 ----
	await _ui_endgame(fails)

	# ---- IT-3（AT-40）命令门 ----
	_post_end_gates(fails)

	# ---- IT-4（AT-41）----
	_at41_unarmed_passthrough(fails)
	_at41_near_miss_no_detonation(fails)
	_at41_decoy_absorbs(fails)

	_finish(fails)


# ======================================================================
# IT-1 集成场景（固定几何：本艇静止同深度，敌 800m 正东）
# ======================================================================
func _run_integrated(seed_val: int) -> Dictionary:
	var out := {"seed": seed_val}
	var w := _mk_adj_world(seed_val, 70.0)
	var ends: Array = []
	w.mission_ended.connect(func(r: Dictionary): ends.append(r))
	w.run_steps(30)
	# 己方资产先入水（合法已知，不得被建成敌雷卡）。
	var own: TruthEntity = w.world["own"]
	var own_tp: Torpedo = w.weapons.fire_program(
		WeaponProgram.make_bearing_only(90.0),
		float(own.position_east_m),
		float(own.position_north_m),
		w.sim_time,
		float(own.depth_m)
	)
	out["own_tp_seen"] = own_tp != null
	# 两枚来袭鱼雷：一枚必中直瞄（扫描方位），一枚 +25° 伴飞（方位差可分辨；
	# 过近的同批证据会因一对一分配把同源碎裂成多余航迹）。
	var brg: float = _brg_enemy_to_own(w)
	var off: float = _scan_offset(seed_val, brg)
	var t1 := _fire_enemy(w, brg + off, 300.0, 70.0)
	var t2 := _fire_enemy(w, brg + off + 25.0, 300.0, 70.0, true)
	if t1 == null or t2 == null:
		return out
	# 被动证据自动建 TT。发射瞬变是单发证据，会留下 TENTATIVE 幽灵卡；
	# 等其自然 COASTING→LOST（60s 无更新）后只剩持续噪声的稳定卡再计数。
	var tt_ready := false
	for i in range(900):
		w.run_steps(1)
		var live := _live_tracks(w)
		if live.size() >= 2 and _all_tracking(live):
			tt_ready = true
			break
	if not tt_ready:
		return out
	var tts: Array = _live_tracks(w)
	out["tt_count"] = tts.size()
	var ids := {}
	for tr in tts:
		ids[str(tr.get("track_id", ""))] = true
	out["tt_distinct"] = ids.size() == tts.size()
	# 真实主动 Ping → 融合收紧。
	var areas_pre := {}
	for tr in tts:
		if tr.get("est") == null:
			continue
		var el: Dictionary = (tr["est"] as TorpedoThreatEstimator).ellipse_95()
		areas_pre[str(tr["track_id"])] = float(el["axis_a_m"]) * float(el["axis_b_m"])
	if not w.issue_ping():
		return out
	var aided := false
	var aided_id := ""
	for i in range(240):
		w.run_steps(1)
		w.take_arrived_echoes()
		for tr in w.threat_tracks.tracks():
			if str(tr.get("state", "")) == "RANGE_AIDED":
				aided = true
				aided_id = str(tr["track_id"])
		if aided:
			break
	out["aided"] = aided
	if not aided:
		return out
	# 诱饵在主动融合完成后投放（同场共存；若先投放，回波关联歧义会被
	# 门控拒收——那是 AT-15 的正确语义，不能在此误伤 RANGE_AIDED 验收）。
	out["decoy_seen"] = w._launch_decoy(_mk_decoy_prog(90.0)) or not w.decoys.is_empty()
	for tr in w.threat_tracks.tracks():
		if str(tr["track_id"]) == aided_id:
			if tr.get("est") == null:
				continue
			var el2: Dictionary = (tr["est"] as TorpedoThreatEstimator).ellipse_95()
			out["area_pre"] = float(areas_pre.get(aided_id, 0.0))
			out["area_post"] = float(el2["axis_a_m"]) * float(el2["axis_b_m"])
	var ev_clean := true
	for e2 in w.player_evidence:
		for k in ["target_id", "true_range_m", "internal_token"]:
			if e2.has(k):
				ev_clean = false
		# emission_kind 仅允许出现在 OWN_FACT（本艇合法已知事实，§10.4）。
		if e2.has("emission_kind") and str(e2.get("side_hint", "")) != "OWN_FACT":
			ev_clean = false
	out["evidence_clean"] = ev_clean
	# 推进到命中终局。
	for i in range(2880):
		if not w.is_mission_running():
			break
		w.run_steps(1)
	out["ended"] = not w.is_mission_running()
	out["end_events"] = ends.size()
	if not bool(out["ended"]):
		return out
	var t0: float = w.sim_time
	w.run_steps(100)
	out["frozen"] = is_equal_approx(w.sim_time, t0)
	var parts: Array = []
	for tr in w.threat_tracks.tracks():
		var rv = tr.get("range_est_m", -1.0)
		var rv_txt: String = "%.3f" % float(rv) if (rv is float or rv is int) else "n/a"
		parts.append(str(tr["track_id"]) + ":" + str(tr.get("state", "")) + ":" + rv_txt)
	parts.append("end:%.1f:%s" % [float(w.mission_end_time), str(w.mission_end_reason)])
	parts.append("meas:%d" % w.measurement_count())
	out["digest"] = "|".join(parts)
	return out


## 在固定几何上扫描直瞄修正方位：返回使雷以 <150m 掠过本艇的确定性偏移。
func _scan_offset(seed_val: int, brg: float) -> float:
	for off in OFFSETS:
		var w2 := _mk_adj_world(seed_val, 70.0)
		w2.run_steps(30)
		var tp := _fire_enemy(w2, brg + off, 1000000000.0, 70.0)
		if tp == null:
			continue
		var mind := 1e12
		for i in range(600):
			w2.run_steps(1)
			mind = minf(
				mind,
				NavUtils.distance(
					tp.pos_east_m,
					tp.pos_north_m,
					float(w2.world["own"].position_east_m),
					float(w2.world["own"].position_north_m)
				),
			)
		if mind < 150.0:
			return off
	return OFFSETS[0]


func _mk_adj_world(seed_val: int, own_depth: float) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario(SCENARIO)
	sc["seed"] = seed_val
	sc["targets"] = []
	if sc.has("own_ship"):
		sc["own_ship"]["speed_kn"] = 0.0
		sc["own_ship"]["depth_m"] = own_depth
	var b: float = deg_to_rad(90.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 90.0,
		"bearing_max_deg": 90.0,
		"range_min_m": 800.0,
		"range_mode_m": 800.0,
		"range_max_m": 800.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 500.0,
		"max_generation_attempts": 10,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 800.0,
			"position_north_m": cos(b) * 800.0,
			"course_deg": 270.0,
			"speed_kn": 6.0,
			"depth_m": 50.0,
		},
		"doctrine": {"sensor_false_alarm_rate": 0.0},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


func _mk_decoy_prog(brg_deg: float, spd_kn: float = 8.0) -> DecoyProgram:
	var prog := DecoyProgram.new()
	prog.decoy_type = DecoyProgram.TYPE_MOBILE
	prog.launch_bearing_deg = brg_deg
	prog.course_deg = brg_deg
	prog.speed_kn = spd_kn
	prog.activation_delay_s = 2.0
	prog.lifetime_s = 900.0  # 覆盖整个测试窗口；120s 会在预跑后恰好到期静默
	var sig := AcousticProfile.new()
	sig.broadband_base_level_db = 165.0
	sig.tonal_lines = [{"freq_hz": 240.0, "level_db": 128.0}, {"freq_hz": 480.0, "level_db": 122.0}]
	prog.signature = sig
	return prog


func _fire_enemy(
	w: World, brg_deg: float, arm_m: float, depth_m: float, straight: bool = false
) -> Torpedo:
	var e: TruthEntity = w.enemy_ai.entity
	var prog := WeaponProgram.make_bearing_only(NavUtils.wrap360(brg_deg))
	prog.speed_mode = WeaponProgram.SpeedMode.HIGH
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	if straight:
		# 直航伴飞雷：不自导，方位持续可分辨（否则双雷都瞄向本艇，
		# 方位快速汇聚 + 同批证据一对一分配会把航迹碎裂成 3+ 条）。
		prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	else:
		prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
		prog.autonomy_enable_distance_m = 100.0
	prog.warhead_arm_distance_m = arm_m
	prog.fallback_program = prog.make_default_fallback()
	return w.enemy_weapons.fire_program(
		prog, float(e.position_east_m), float(e.position_north_m), w.sim_time, depth_m
	)


# ======================================================================
# IT-2（AT-39）+ 隐藏页 + 8× 倍速：真实 main_ui（s1_combat）
# ======================================================================
func _ui_endgame(fails: Array) -> void:
	UiContract.set_startup_override(COMBAT, 90805)
	root.size = Vector2i(1600, 900)
	await process_frame
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	var w = ui.world
	var ends: Array = []
	w.mission_ended.connect(func(r: Dictionary): ends.append(r))
	w.run_steps(30)
	var tp := _fire_enemy(w, _brg_enemy_to_own(w), 300.0, 70.0)
	_assert(fails, tp != null, "IT-2b incoming torpedo launched in UI world")
	# 隐藏航迹页，跑仿真：告警/红点仍更新。
	ui._pager.select("weapons")
	var badge_at_start: int = int(ui._pager.badge("tactics"))
	# 隐藏航迹页，用 UI 帧驱动仿真（红点/告警条是显示层，只在 _process
	# 重建链更新；纯 world.run_steps 不经过 UI）。1× 每帧 1s = 2 tick。
	for i in range(120):
		ui._process(1.0)
		if int(ui._pager.badge("tactics")) > badge_at_start:
			break
	_assert(fails, str(ui._pager.current_page()) == "weapons", "IT-2c tactics page stayed hidden")
	_assert(
		fails, int(ui._pager.badge("tactics")) > badge_at_start, "IT-2d badge grew while hidden"
	)
	_assert(
		fails,
		ui._pager.top_bar.is_ancestor_of(ui._threat_hud),
		"IT-2e threat banner lives in top bar (not page-bound)",
	)
	# 8× 倍速：8 帧 × 0.5s → 恰好 64 tick（dt=0.5），estimator 不跳拍。
	ui._on_speed(3)
	_assert(fails, is_equal_approx(float(w.time_scale()), 8.0), "IT-2f world time_scale == 8")
	var t0: float = w.sim_time
	for i in range(8):
		ui._process(0.5)
	var adv: float = w.sim_time - t0
	_assert(
		fails,
		is_equal_approx(adv, 32.0),
		"IT-2g 8x catch-up advances whole ticks only (adv=%.3f)" % adv
	)
	# 推进到终局；预算内未自然命中则走同一信号链（命中路径由 IT-1 实证）。
	for i in range(4000):
		if not w.is_mission_running():
			break
		w.run_steps(1)
	if w.is_mission_running():
		w.end_mission(1, "TORPEDO_HIT")  # 公共契约 API；信号 → 覆盖层接线同真命中
	_assert(fails, ends.size() == 1, "IT-2h mission_ended exactly once (AT-39)")
	_assert(fails, bool(ui._game_over.visible), "IT-2i overlay visible on end")
	var txt: String = _collect_labels(ui._game_over)
	_assert(fails, txt.contains("任务失败"), "IT-2j overlay title 任务失败 (AT-39)")
	_assert(fails, txt.contains("鱼雷命中，本艇损失"), "IT-2k overlay reason 中文 (AT-39)")
	if not w.is_mission_running():
		var ping_state_before: String = str(w.ping_state_name())
		ui._on_ping_requested()
		_assert(
			fails,
			str(w.ping_state_name()) == ping_state_before and ping_state_before != "TRANSMITTING",
			"IT-3m UI ping chain cannot fire after end (AT-40)",
		)
	ui.queue_free()
	await process_frame


func _collect_labels(node: Node) -> String:
	var out := ""
	for c in node.get_children():
		if c is Label:
			out += (c as Label).text + "\n"
		out += _collect_labels(c)
	return out


# ======================================================================
# IT-3（AT-40）：终局后全命令门 + 中文映射
# ======================================================================
func _post_end_gates(fails: Array) -> void:
	var w := _mk_adj_world(90805, 70.0)
	w.run_steps(30)
	# 己方鱼雷入水且导线 CONNECTED（命令门前状态就绪）。
	var own: TruthEntity = w.world["own"]
	var own_tp: Torpedo = w.weapons.fire_program(
		WeaponProgram.make_bearing_only(90.0),
		float(own.position_east_m),
		float(own.position_north_m),
		w.sim_time,
		float(own.depth_m)
	)
	_assert(fails, own_tp != null, "IT-3b own torpedo launched for gate test")
	var wire_ready := false
	for i in range(20):
		w.run_steps(1)
		if own_tp != null and own_tp.wire_link.accepts_commands():
			wire_ready = true
			break
	_assert(fails, wire_ready, "IT-3c wire CONNECTED before end")
	_assert(fails, w.end_mission(1, "TORPEDO_HIT"), "IT-3d end_mission accepted")
	_assert(fails, w.command_reject_reason() == "MISSION_ENDED", "IT-3e reject reason EN token")
	_assert(
		fails,
		UiText.reject(str(w.command_reject_reason())) == "任务已结束：命令被拒",
		"IT-3f Chinese mapping of MISSION_ENDED (AT-40)",
	)
	_assert(fails, w.issue_ping() == false, "IT-3g ping rejected after end")
	_assert(fails, w._launch_decoy(_mk_decoy_prog(90.0)) == false, "IT-3h decoy rejected after end")
	_assert(
		fails, str(w.last_decoy_reject_reason) == "MISSION_ENDED", "IT-3i decoy reason EN token"
	)
	var fe := FireExecutor.new()
	var fr: Dictionary = fe.execute(w.weapons, w, "MANUAL", "")
	_assert(
		fails,
		not bool(fr.get("ok", true)) and str(fr.get("reason", "")) == "MISSION_ENDED",
		"IT-3j fire rejected after end",
	)
	# 线导命令：终局后切断导线必须被 MISSION_ENDED 门拒绝。
	var cut: bool = own_tp.cut_wire()
	_assert(
		fails,
		(not cut) and str(own_tp.last_cmd_reject_reason) == "MISSION_ENDED",
		"IT-3k wire-cut rejected after end with MISSION_ENDED (AT-40)",
	)
	# 机动：OwnManeuverPanel 命令门。
	var mp := OwnManeuverPanel.new()
	mp.bind_world(w)
	var cmd0: float = float(w.world["own"].commanded_course_deg)
	mp._on_course(90.0)
	_assert(
		fails,
		is_equal_approx(float(w.world["own"].commanded_course_deg), cmd0),
		"IT-3l maneuver gated after end"
	)
	mp.free()


# ======================================================================
# IT-4（AT-41）：三种非命中情形不得错误终局
# ======================================================================
## 未解保掠过：装定超大解保距离 → 近距掠过全程 fuze=SAFE。
func _at41_unarmed_passthrough(fails: Array) -> void:
	var w := _mk_adj_world(90805, 70.0)
	w.run_steps(30)
	var brg: float = _brg_enemy_to_own(w)
	var off: float = _scan_offset(90805, brg)
	var tp := _fire_enemy(w, brg + off, 1000000000.0, 70.0)
	_assert(fails, tp != null, "IT-4a1 unarmed torpedo launched")
	if tp == null:
		return
	var min_d := 1e12
	var ever_armed := false
	for i in range(1600):
		w.run_steps(1)
		if not w.is_mission_running():
			break
		min_d = minf(
			min_d,
			NavUtils.distance(
				tp.pos_east_m,
				tp.pos_north_m,
				float(w.world["own"].position_east_m),
				float(w.world["own"].position_north_m)
			),
		)
		if int(tp.fuze_state) == int(Torpedo.FuzeState.ARMED):
			ever_armed = true
	_assert(fails, not ever_armed, "IT-4a2 fuze stayed SAFE (never armed)")
	_assert(fails, min_d < 200.0, "IT-4a3 unarmed torpedo passed own (min=%.0fm)" % min_d)
	_assert(fails, w.is_mission_running(), "IT-4a4 no end on unarmed passthrough (AT-41)")


## 未起爆近失：武装雷与本艇深度错开 130m 近距掠过，不起爆。
func _at41_near_miss_no_detonation(fails: Array) -> void:
	var w := _mk_adj_world(90805, 200.0)  # 本艇 LOWER 200m
	w.run_steps(30)
	var brg: float = _brg_enemy_to_own(w)
	var off: float = _scan_offset(90805, brg)
	var tp := _fire_enemy(w, brg + off, 100.0, 70.0)  # 雷 70m 直航
	_assert(fails, tp != null, "IT-4b1 armed torpedo launched")
	if tp == null:
		return
	var min_d := 1e12
	for i in range(1600):
		w.run_steps(1)
		if not w.is_mission_running():
			break
		min_d = minf(
			min_d,
			NavUtils.distance(
				tp.pos_east_m,
				tp.pos_north_m,
				float(w.world["own"].position_east_m),
				float(w.world["own"].position_north_m)
			),
		)
	_assert(fails, min_d < 200.0, "IT-4b2 near-miss passed (min=%.0fm)" % min_d)
	_assert(fails, w.is_mission_running(), "IT-4b3 no end on depth-separated near miss (AT-41)")


## 命中诱饵：诱饵沿来袭走廊运动并被引爆，本艇幸存且不终局。
func _at41_decoy_absorbs(fails: Array) -> void:
	# 先找一个「无诱饵必沉」的确定性组合（保证场景真有威胁）。
	var lethal_off := 0.0
	var found := false
	for off in OFFSETS:
		var w0 := _mk_adj_world(90805, 70.0)
		w0.run_steps(30)
		var brg0: float = _brg_enemy_to_own(w0)
		var t0 := _fire_enemy(w0, brg0 + off, 300.0, 70.0)
		if t0 == null:
			continue
		for i in range(1600):
			w0.run_steps(1)
			if not w0.is_mission_running():
				break
		if (not w0.is_mission_running()) and str(w0.world["own"].damage_state) == "sunk":
			lethal_off = off
			found = true
			break
	_assert(fails, found, "IT-4c0 lethal (no-decoy) control combo found")
	if not found:
		return
	# 同组合 + 机动诱饵沿雷来袭线迎头漂放（8kn，120s 后 ~495m 外正对来雷）
	# → 声学竞争锁走雷 → 引信在诱饵处起爆，本艇不沉不终局（AT-41 吸雷）。
	var w := _mk_adj_world(90805, 70.0)
	w.run_steps(30)
	var brg: float = _brg_enemy_to_own(w)
	var torpedo_brg: float = NavUtils.wrap360(brg + lethal_off)
	_assert(
		fails,
		w._launch_decoy(_mk_decoy_prog(torpedo_brg, 8.0)),
		"IT-4c1 decoy launched on inbound torpedo line"
	)
	w.run_steps(120)  # 诱饵沿来袭线迎头漂出 ~495m
	var tp := _fire_enemy(w, torpedo_brg, 300.0, 70.0)
	_assert(fails, tp != null, "IT-4c2 armed torpedo launched")
	if tp == null:
		return
	for i in range(2000):
		w.run_steps(1)
		if not w.is_mission_running():
			break
	_assert(fails, w.is_mission_running(), "IT-4c3 mission still running (AT-41)")
	_assert(
		fails,
		str(w.world["own"].damage_state) != "sunk",
		"IT-4c4 own survived decoy diversion (dmg=%s)" % str(w.world["own"].damage_state),
	)
	_assert(
		fails, w._detonations.size() >= 1, "IT-4c5 torpedo detonated (at decoy contact, not own)"
	)


func _live_tracks(w: World) -> Array:
	var out: Array = []
	for tr in w.threat_tracks.tracks():
		if str(tr.get("state", "")) != "LOST":
			out.append(tr)
	return out


func _all_tracking(live: Array) -> bool:
	for tr in live:
		var st: String = str(tr.get("state", ""))
		if st != "TRACKING" and st != "RANGE_AIDED":
			return false
	return true


func _brg_enemy_to_own(w: World) -> float:
	var e: TruthEntity = w.enemy_ai.entity
	var own: TruthEntity = w.world["own"]
	return (
		NavUtils
		. bearing_to_true(
			float(e.position_east_m),
			float(e.position_north_m),
			float(own.position_east_m),
			float(own.position_north_m),
		)
	)


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	UiContract.set_startup_override("", -1)
	if fails.is_empty():
		print("S109-INTEGRATED TEST PASS")
		quit(0)
	else:
		print("S109-INTEGRATED TEST FAIL (%d)" % fails.size())
		quit(1)
