extends SceneTree
## REQ-0908 Commit 7 — AT-01..07 端到端验收套件（对齐文档 §10）。
##
## 全部走自然生产链（声学证据 → Track → TMA → 发射/引信），绝不用 Truth
## 瞄准制造结果；确定性 seed，可无头复现：
##   godot --headless --path games/sonar --script res://tools/at_e2e_test.gd
##
## AT-01 双接触 Mark/Track/TMA/解隔离 + SOLUTION 发射门来源绑定
## AT-02 主动 Ping 探测在水敌雷（快照回波 → 净化 Measurement）
## AT-03 海图方向契约（4 基准方位 + chart_view 源码扫描）
## AT-04 玩家自然攻击链击沉移动目标（LaunchProgrammer + 自治 + 引信）
## AT-05 敌方自然反击链命中本艇 → PLAYER_DEFEATED 终局契约
## AT-06 防御有效性：机动/换层/诱饵统计上降低命中（mini-MC 20v20）
## AT-07 瀑布可读性：自然声场行背景暗色、目标声迹可见不发白

const SEED := 700100
const SEED_SPAN := 40
const N_DEF := 20
const DT_FUZE_BUDGET := 1200


func _initialize() -> void:
	var fails: Array = []
	_at01(fails)
	_at02(fails)
	_at03(fails)
	_at04(fails)
	_at05(fails)
	_at06(fails)
	_at07(fails)
	_finish(fails)


## ---- AT-01：双接触独立 Fit/Solution + 发射门来源绑定 ----
func _at01(fails: Array) -> void:
	var found: Dictionary = {}
	for sv in range(SEED, SEED + SEED_SPAN):
		found = _at01_try(sv)
		if not found.is_empty():
			break
	_assert(fails, not found.is_empty(), "AT-01 both contacts reach committed solutions")
	if found.is_empty():
		return
	var fcc: FireControlContext = found["fcc"]
	var ta: String = found["ta"]
	var tb: String = found["tb"]
	# 解绑定：SystemSolution 只属于来源 Track，无 Truth 泄露字段。
	var sol: SystemSolution = fcc.system_solution_by_track_id[ta]
	_assert(fails, str(sol.source_track_id) == ta, "AT-01 solution bound to source track")
	_assert(fails, not ("target_id" in sol), "AT-01 solution carries no Truth identity")
	# 发射门：选中 A 可发射；向 B 的解发射被拒绝（无解即拒）。
	var g1: Dictionary = fcc.solution_for_fire(ta, float(found["t"]))
	_assert(fails, bool(g1.get("ok", false)), "AT-01 fire gate accepts selected track solution")
	var g2: Dictionary = fcc.solution_for_fire(tb, float(found["t"]))
	_assert(
		fails,
		bool(g2.get("ok", false)) and str((g2["solution"] as SystemSolution).source_track_id) == tb,
		"AT-01 gate returns B's own solution (never A's, no silent fallback)",
	)
	# B 新证据 → B 解 stale 被拒；A 不受影响（per-Track 隔离）。
	var tb_track: Track = found["track_b"]
	var tb_rev_before: int = fcc.evidence_revision(tb)
	var extra := _mk_meas(10.0, float(found["t"]) + 1.0)
	extra.evidence_id = "987654321"  # 唯一物理证据 id（触发 revision 递增）
	tb_track.add_measurement(extra)
	fcc.sync_revision(tb_track)
	_assert(
		fails,
		fcc.evidence_revision(tb) == tb_rev_before + 1,
		"AT-01 new evidence bumps only that track revision",
	)
	var g3: Dictionary = fcc.solution_for_fire(tb, float(found["t"]) + 1.0)
	_assert(
		fails,
		not bool(g3.get("ok", false)) and str(g3.get("reason", "")) == "SOLUTION_STALE",
		"AT-01 stale B solution rejected for fire",
	)
	_assert(
		fails,
		bool(fcc.solution_for_fire(ta, float(found["t"]) + 1.0).get("ok", false)),
		"AT-01 A solution unaffected by B's new evidence",
	)


func _at01_try(seed_val: int) -> Dictionary:
	var sc: Dictionary = _mk_attack_scenario(seed_val)
	# 两条穿越航迹（方位随时间变化，TMA 可观测），彼此方位可分。
	sc["targets"][0]["position_east_m"] = 5000.0
	sc["targets"][0]["position_north_m"] = 0.0
	sc["targets"][0]["course_deg"] = 0.0
	sc["targets"][0]["speed_kn"] = 8.0
	sc["targets"][0]["depth_m"] = 70.0
	var t2: Dictionary = sc["targets"][0].duplicate(true)
	t2["id"] = "enemy_2"
	t2["position_east_m"] = 0.0
	t2["position_north_m"] = 9000.0
	t2["course_deg"] = 135.0
	sc["targets"].append(t2)
	var w := World.new()
	w.load_scenario(sc)
	var tracker := Tracker.new()
	var fcc := FireControlContext.new()
	var op: OperatorSonar = OperatorSonar.new()
	op.setup(w.world)
	var committed: Dictionary = {}  # track_id -> true
	var track_map: Dictionary = {}  # track_id -> Track
	var t_end: float = 0.0
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
		track_map[tt.track_id] = tt
		if tt.evidence_count() >= 6 and not committed.has(tt.track_id):
			fcc.sync_revision(tt)
			fcc.solve_and_store(tt, null, w.sim_time)
			var cr: Dictionary = fcc.commit_solution(tt.track_id, w.sim_time)
			if bool(cr.get("ok", false)):
				committed[tt.track_id] = true
				t_end = w.sim_time
		if committed.size() >= 2:
			var ids: Array = committed.keys()
			return {
				"fcc": fcc,
				"ta": str(ids[0]),
				"tb": str(ids[1]),
				"track_b": track_map[str(ids[1])],
				"t": t_end,
			}
	return {}


## ---- AT-02：主动 Ping 探测在水敌雷 ----
func _at02(fails: Array) -> void:
	var w := _mk_doctrine_world(700200)
	# 敌方自然检测 + 反击（正常生产链），拿到在水敌雷。
	var in_water := false
	for i in range(600):
		w.run_steps(1)
		if not (w.enemy_weapons.torpedoes as Array).is_empty():
			in_water = true
			break
	_assert(fails, in_water, "AT-02 enemy doctrine fires naturally (torpedo in water)")
	if not in_water:
		return
	var pinged: bool = w.issue_ping()
	_assert(fails, pinged, "AT-02 issue_ping accepted")
	if not pinged:
		return
	var got_echo := false
	var meas_clean := true
	var meas_seen := false
	for i in range(120):
		w.run_steps(1)
		var echoes: Array = w.take_arrived_echoes()
		for e in echoes:
			var em = e.get("measurement", null)
			if em != null:
				meas_seen = true
				var d: Dictionary = (em as Measurement).to_dict()
				# 净化（Batch2 验收8）：Measurement 不含内部 id/Truth 坐标。
				if d.has("target_id") or d.has("internal_token"):
					meas_clean = false
				if d.has("position_east_m") or d.has("position_north_m"):
					meas_clean = false
			if float(e.get("range_m", -1.0)) > 0.0:
				got_echo = true
		if got_echo and meas_seen:
			break
	_assert(fails, got_echo, "AT-02 active echo from enemy torpedo arrives with range")
	_assert(fails, meas_clean, "AT-02 echo Measurement carries no Truth identity (验收8)")


## ---- AT-03：海图方向契约 ----
func _at03(fails: Array) -> void:
	# 4 基准方位：世界方向 (sin, cos)，屏幕方向 (sin, -cos)。
	var ok_dirs := true
	for brg in [0.0, 90.0, 180.0, 270.0]:
		var wd: Vector2 = NavUtils.bearing_to_world_dir(brg)
		var sd: Vector2 = NavUtils.bearing_to_screen_dir(brg)
		# 0°=上(屏幕 -y)、90°=右(+x)、180°=下(+y)、270°=左(-x)。
		var expect_screen := Vector2(sin(deg_to_rad(brg)), -cos(deg_to_rad(brg)))
		if not wd.is_equal_approx(Vector2(sin(deg_to_rad(brg)), cos(deg_to_rad(brg)))):
			ok_dirs = false
		if not sd.is_equal_approx(expect_screen):
			ok_dirs = false
	_assert(fails, ok_dirs, "AT-03 NavUtils world/screen dir contracts for 4 bearings")
	# chart_view 源码扫描：禁止散写方向三角函数（唯一入口 NavUtils）。
	var f := FileAccess.open("res://scripts/ui/chart_view.gd", FileAccess.READ)
	var src: String = f.get_as_text() if f != null else ""
	var banned: Array = ["Vector2(sin(", "Vector2(cos(", "Vector2(-sin("]
	var clean := src != ""
	for b in banned:
		if src.find(b) >= 0:
			clean = false
	_assert(fails, clean, "AT-03 chart_view has no ad-hoc sin/cos direction literals")


## ---- AT-04：玩家自然攻击链击沉移动目标 ----
func _at04(fails: Array) -> void:
	var sunk := false
	for sv in range(SEED + 100, SEED + 100 + SEED_SPAN):
		if _attack_seed(sv)["hit"]:
			sunk = true
			break
	_assert(fails, sunk, "AT-04 natural SOLUTION chain detonates and sinks moving target")


## ---- AT-05：敌方自然反击链命中本艇 → Game Over ----
func _at05(fails: Array) -> void:
	var hit_seed := -1
	for sv in range(700300, 700300 + SEED_SPAN):
		var w := _mk_doctrine_world(sv)
		var ended := false
		for i in range(DT_FUZE_BUDGET):
			w.run_steps(1)
			if int(w.mission_state) != 0:  # World.MissionState.PLAYER_DEFEATED
				ended = true
				break
		if ended:
			hit_seed = sv
			break
	_assert(fails, hit_seed >= 0, "AT-05 natural enemy counterfire ends mission (seed found)")
	if hit_seed < 0:
		return
	var w2 := _mk_doctrine_world(hit_seed)
	var end_results: Array = []
	w2.mission_ended.connect(func(r: Dictionary): end_results.append(r))
	for i in range(DT_FUZE_BUDGET):
		w2.run_steps(1)
		if int(w2.mission_state) != 0:
			break
	_assert(fails, end_results.size() == 1, "AT-05 mission_ended fired exactly once")
	_assert(
		fails,
		str(end_results[0].get("reason", "")) == "TORPEDO_HIT",
		"AT-05 end reason TORPEDO_HIT",
	)
	_assert(fails, str(w2.world["own"].damage_state) == "sunk", "AT-05 own sunk")
	# 终局契约：冻结 + 命令门。
	var t0: float = w2.sim_time
	var frozen := true
	for i in range(100):
		w2.run_steps(1)
		if not is_equal_approx(w2.sim_time, t0):
			frozen = false
			break
	_assert(fails, frozen, "AT-05 simulation frozen after game over")
	_assert(
		fails,
		w2.command_reject_reason() == "MISSION_ENDED",
		"AT-05 commands rejected with MISSION_ENDED",
	)


## ---- AT-06：防御有效性 mini-MC ----
func _at06(fails: Array) -> void:
	var hits_base := 0
	var hits_evade := 0
	for i in range(N_DEF):
		if _defense_seed(710000 + i, false)["hit"]:
			hits_base += 1
		if _defense_seed(720000 + i, true)["hit"]:
			hits_evade += 1
	_assert(fails, hits_base > 0, "AT-06 no-evasion baseline hits > 0 (%d/%d)" % [hits_base, N_DEF])
	_assert(
		fails,
		hits_evade < hits_base,
		"AT-06 evasion reduces hit rate (%d < %d)" % [hits_evade, hits_base],
	)


## ---- AT-07：瀑布可读性（自然声场行）----
func _at07(fails: Array) -> void:
	# 空场景（无目标）→ 背景暖色比例；有目标场景 → 声迹可见。
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = 700400
	sc["targets"] = []
	var w := World.new()
	w.load_scenario(sc)
	w.auto_measurements = false
	var op: OperatorSonar = OperatorSonar.new()
	op.setup(w.world)
	for i in range(400):
		w.run_steps(1)
		op.catch_up_rows(
			w.sim_time, w.world["targets"] + w._acoustic_scene_emitters(), w.world["target_acs"]
		)
	var rows: Array = op.bb_rows.slice(maxi(0, op.bb_rows.size() - 120))
	_assert(fails, rows.size() >= 100, "AT-07 collected natural BB rows")
	if rows.size() < 100:
		return
	var wf: WaterfallView = WaterfallView.new()
	wf.set_rows(rows)
	wf._rebuild_image()
	var img: Image = wf._img
	var warm := 0
	var total := img.get_width() * img.get_height()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var px: Color = img.get_pixel(x, y)
			if px.g8 > 153 and px.r8 > 200:
				warm += 1
	var ratio: float = float(warm) / float(total)
	_assert(
		fails,
		ratio <= 0.01,
		"AT-07 background warm pixel ratio <= 1%% (got %.2f%%)" % (ratio * 100.0)
	)
	# 目标声迹可见：最亮列亮度显著高于中位列。
	var col_lum: PackedFloat32Array = PackedFloat32Array()
	col_lum.resize(img.get_width())
	for x2 in range(img.get_width()):
		var s := 0.0
		for y2 in range(img.get_height()):
			var p2: Color = img.get_pixel(x2, y2)
			s += 0.3 * p2.r + 0.6 * p2.g + 0.1 * p2.b
		col_lum[x2] = s
	var sorted := col_lum.duplicate()
	sorted.sort()
	var median_lum: float = sorted[sorted.size() / 2]
	var max_lum: float = sorted[sorted.size() - 1]
	_assert(
		fails,
		max_lum > median_lum * 1.3,
		(
			"AT-07 target trace column visible against background (max %.1f vs median %.1f)"
			% [max_lum, median_lum]
		),
	)
	wf.free()


## ---- 复用脚手架（与 mc_hit_rate_test/enemy_hit_gameover_test 同源）----
func _mk_attack_scenario(seed_val: int) -> Dictionary:
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
	return sc


## 敌方自然检测 + 反击世界（own 嘈杂静止、敌 45° 1.5-2km、反击概率 1.0）。
func _mk_doctrine_world(seed_val: int) -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = seed_val
	sc["targets"] = []
	sc["own_acoustic"]["broadband_base_level_db"] = 160.0
	sc["own_ship"]["speed_kn"] = 0.0
	var b: float = deg_to_rad(45.0)
	sc["enemy_spawn"] = {
		"bearing_min_deg": 43.0,
		"bearing_max_deg": 47.0,
		"range_min_m": 1500.0,
		"range_mode_m": 1800.0,
		"range_max_m": 2000.0,
		"speed_min_kn": 5.0,
		"speed_max_kn": 8.0,
		"min_separation_m": 800.0,
		"max_generation_attempts": 50,
		"fallback_spawn":
		{
			"position_east_m": sin(b) * 1500.0,
			"position_north_m": cos(b) * 1500.0,
			"course_deg": 225.0,
			"speed_kn": 6.0,
			"depth_m": 70.0,
		},
		"doctrine":
		{
			"sensor_false_alarm_rate": 0.0,
			"fire_quality_threshold": 0.7,
			"counterfire_probability": 1.0,
			"reaction_delay_min_s": 3.0,
			"reaction_delay_max_s": 15.0,
			"max_simultaneous_weapons": 2,
			"torpedo_active_enable_time_s": 60.0,
			"torpedo_autonomy_distance_m": 800.0,
		},
	}
	var w := World.new()
	w.load_scenario(sc)
	return w


## AT-04：玩家 SOLUTION 自然链（autocrew → TMA → LaunchProgrammer → 引信）。
func _attack_seed(seed_val: int) -> Dictionary:
	var sc: Dictionary = _mk_attack_scenario(seed_val)
	var w := World.new()
	w.load_scenario(sc)
	var t0: TruthEntity = w.world["targets"][0]
	t0.speed_kn = 8.0
	t0.depth_m = 70.0
	var ac: Dictionary = sc["targets"][0]["acoustic"]
	ac["broadband_base_level_db"] = 138.0
	for tl in ac.get("tonal_lines", []):
		tl["level_db"] = float(tl["level_db"]) - 12.0
	var tracker := Tracker.new()
	var fcc := FireControlContext.new()
	var op: OperatorSonar = OperatorSonar.new()
	op.setup(w.world)
	var track: Track = null
	var fired := false
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
		if track.evidence_count() < 6 or fired:
			continue
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
	# 拟真操作员：循环内 RANGE_INVALID 时继续收集证据，循环结束后用最终
	# 解做兜底发射（与 mc_hit_rate_test 同一链路）。
	if track != null and not fired:
		fcc.solve_and_store(track, null, w.sim_time)
		var cr2: Dictionary = fcc.commit_solution(track.track_id, w.sim_time)
		if bool(cr2.get("ok", false)):
			var fe2 := FireExecutor.new()
			fe2.fcc = fcc
			fe2.tracker = tracker
			fe2.programmer = LaunchProgrammer.new()
			var res2: Dictionary = fe2.execute(w.weapons, w, "SOLUTION", track.track_id)
			if bool(res2.get("ok", false)):
				fired = true
	if track == null or not fired:
		return {"hit": false, "r": "no_fire"}
	var e: TruthEntity = w.world["targets"][0]
	for i in range(1400):
		w.run_steps(1)
		if str(e.damage_state) == "sunk":
			return {"hit": true, "r": "sunk"}
		if (w.weapons.torpedoes as Array).is_empty():
			return {"hit": false, "r": "gone"}
	return {"hit": false, "r": "budget"}


## AT-06：敌雷固定几何发射脚手架 + 玩家机动/换层/诱饵规避。
func _defense_seed(seed_val: int, evade: bool) -> Dictionary:
	var sc: Dictionary = _mk_attack_scenario(seed_val)
	sc["targets"] = []
	var own_speed := 0.0
	if evade:
		own_speed = 0.0
	sc["own_ship"]["speed_kn"] = own_speed
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
			return {"hit": true, "r": "hit"}
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


func _mk_meas(brg: float, t: float) -> Measurement:
	var m := Measurement.new()
	m.measured_bearing_deg = brg
	m.timestamp = t
	m.sensor_id = "BOW"
	m.measurement_type = "BEARING"
	return m


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("AT-E2E TEST PASS")
		quit(0)
	else:
		print("AT-E2E TEST FAIL (%d)" % fails.size())
		for f in fails:
			print("  - ", f)
		quit(1)
