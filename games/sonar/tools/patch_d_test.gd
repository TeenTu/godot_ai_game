## 评审 Patch D 测试（PD-01..05）：
## PD-01 P0-07/AT-09 威胁证据观察点快照：INTERCEPT 证据携带接收时刻本艇
##        observer 快照 + evidence_kind/available_time；本艇机动后 LOB 起点不漂移
## PD-02 P1-11 ThreatTrackManager 关联与洪泛抑制：同一威胁重复噪声同卡升级链
## PD-03 P0-10/AT-19 SeekerBeamState 单一真源：半角/中心=实际艏向；adapter
##        被动门与主动发射门同参数；边界内/外/正后目标行为
## PD-04 P1-02 海图鱼雷指示输入数据：真实 torpedo_id、tx_state、±σ、命中测试、
##        auto_frame 纳入鱼雷/威胁 LOB
## PD-05 P0-07 地图威胁 LOB 数据净化：无 Truth 字段
extends SceneTree

const SEED := 20260904

var _pass: int = 0


func _init() -> void:
	var fails: Array = []
	_pd_01_observer_snapshot(fails)
	_pd_02_threat_tracks(fails)
	_pd_03_beam_state_gates(fails)
	_pd_04_chart_inputs(fails)
	_pd_05_threat_sanitized(fails)
	for f in fails:
		print("[FAIL] " + f)
	print("passed=%d failed=%d" % [_pass, _pass + fails.size()])
	if fails.is_empty():
		print("result=PASS")
	else:
		print("result=FAIL")
	quit(0 if fails.is_empty() else 1)


func _ok(fails: Array, name: String, cond: bool) -> void:
	_pass += 1
	if not cond:
		fails.append(name)
	else:
		print("[ok] %s" % name)


func _mk_world() -> World:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = SEED
	sc["enemy_spawn"] = {}
	var w := World.new()
	w.load_scenario(sc)
	return w


func _mk_rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


func _mk_bus_event(bus: AcousticEmissionBus, kind: String, e: float, n: float) -> void:
	bus.record(kind, "ET01", 10.0, Vector3(e, n, 60.0), 1000.0, 500.0, 170.0, 0.5)


## ---- PD-01：观察点快照（AT-09）----
func _pd_01_observer_snapshot(fails: Array) -> void:
	var w := _mk_world()
	var own: TruthEntity = w.world["own"]
	var e0: float = float(own.position_east_m)
	var n0: float = float(own.position_north_m)
	# 事件源在本艇 045° 方向 500m 处。
	var src_e: float = e0 + sin(deg_to_rad(45.0)) * 500.0
	var src_n: float = n0 + cos(deg_to_rad(45.0)) * 500.0
	var bus := AcousticEmissionBus.new()
	_mk_bus_event(bus, AcousticEmissionEvent.TORPEDO_RUNNING_NOISE, src_e, src_n)
	var san := EmissionSanitizer.new()
	san.bind(w.world["env"], w.world.get("depth_model"), _mk_rng(SEED + 11))
	# REQ 批：敌方瞬态证据按单程传播时延 t_emit + R/c 出现（验收12）——
	# 事件 10.0s 发出、源距 500m → 可用时刻 ≈ 10.33s，消费点取 10.4s。
	var evs: Array = san.consume_events(bus.events, own, 10.4, {})
	_ok(fails, "PD-01a intercept evidence produced", evs.size() == 1)
	if evs.is_empty():
		return
	var ev: Dictionary = evs[0]
	_ok(
		fails,
		"PD-01b observer snapshot = receive-time own pos",
		(
			absf(float(ev.get("observer_e_m", -1e9)) - e0) < 0.5
			and absf(float(ev.get("observer_n_m", -1e9)) - n0) < 0.5
		)
	)
	_ok(
		fails,
		"PD-01c evidence_kind = RUNNING_NOISE",
		str(ev.get("evidence_kind", "")) == "RUNNING_NOISE"
	)
	_ok(
		fails,
		"PD-01d available_time present",
		absf(float(ev.get("available_time", -1)) - 10.4) < 1e-6
	)
	_ok(fails, "PD-01e sensor_id present", str(ev.get("sensor_id", "")) != "")
	# 本艇机动 1000m 后：LOB 起点仍是接收时快照（AT-09）。
	own.position_east_m = e0 + 1000.0
	var chart := ChartView.new()
	chart.set_threat_evidence(evs, 10.0)
	_ok(
		fails,
		"PD-01f chart lob origin = snapshot",
		(
			chart.threat_lobs.size() == 1
			and (chart.threat_lobs[0]["observer"] as Vector2).distance_to(Vector2(e0, n0)) < 0.5
		)
	)
	_ok(fails, "PD-01g lob finite length", float(chart.threat_lobs[0].get("length_m", 0.0)) > 0.0)
	# 第二次事件（机动后）→ 新证据观察点是新位置。
	_mk_bus_event(bus, AcousticEmissionEvent.TORPEDO_RUNNING_NOISE, src_e + 1000.0, src_n)
	var evs2: Array = san.consume_events(bus.events, own, 12.0, {})
	_ok(
		fails,
		"PD-01h second evidence observer = new pos",
		evs2.size() == 1 and absf(float(evs2[0].get("observer_e_m", -1e9)) - (e0 + 1000.0)) < 0.5
	)


## ---- PD-02：ThreatTrack 关联与洪泛抑制（P1-11）----
func _pd_02_threat_tracks(fails: Array) -> void:
	var mgr := ThreatTrackManager.new()
	var now: float = 100.0
	var tid: String = ""
	var same: bool = true
	for i in range(10):
		var e := {
			"evidence_id": i + 1,
			"evidence_kind": "RUNNING_NOISE",
			"bearing_deg": 45.0 + float(i) * 0.3,
			"bearing_sigma_deg": 2.0,
			"confidence": 0.7,
		}
		var got: String = mgr.ingest(e, now + float(i))
		if tid == "":
			tid = got
		elif got != tid:
			same = false
	_ok(fails, "PD-02a 10s of noise → same threat card", same and tid != "")
	_ok(fails, "PD-02b exactly one track", mgr.tracks().size() == 1)
	_ok(fails, "PD-02c evidence_count = 10", int(mgr.tracks()[0]["evidence_count"]) == 10)
	# 证据升级链：TRANSIENT → NOISE → PING 同一张卡（方位一致）。
	mgr.ingest(
		{
			"evidence_id": 20,
			"evidence_kind": "ACTIVE_PING",
			"bearing_deg": 47.0,
			"bearing_sigma_deg": 2.0,
			"confidence": 0.8
		},
		now + 11.0
	)
	_ok(fails, "PD-02d chain upgrade keeps single track", mgr.tracks().size() == 1)
	_ok(fails, "PD-02e kind upgraded to ACTIVE_PING", str(mgr.tracks()[0]["kind"]) == "ACTIVE_PING")
	# 远方位新威胁 → 新 track。
	mgr.ingest(
		{
			"evidence_id": 30,
			"evidence_kind": "RUNNING_NOISE",
			"bearing_deg": 200.0,
			"bearing_sigma_deg": 2.0,
			"confidence": 0.7
		},
		now + 12.0
	)
	_ok(fails, "PD-02f far bearing → new track", mgr.tracks().size() == 2)
	# 时间间隔超门限 → 新 track（即便方位接近）。
	mgr.ingest(
		{
			"evidence_id": 40,
			"evidence_kind": "RUNNING_NOISE",
			"bearing_deg": 46.0,
			"bearing_sigma_deg": 2.0,
			"confidence": 0.7
		},
		now + 12.0 + 60.0
	)
	_ok(fails, "PD-02g stale gap → new track", mgr.tracks().size() == 3)
	# 非威胁类证据不建 track。
	var tid2: String = mgr.ingest(
		{"evidence_id": 50, "evidence_kind": "DETONATION", "bearing_deg": 46.0}, now + 13.0
	)
	_ok(fails, "PD-02h non-threat ignored", tid2 == "")


## ---- PD-03：SeekerBeamState 单一真源 + 适配器门（P0-10/AT-19）----
func _pd_03_beam_state_gates(fails: Array) -> void:
	var w := _mk_world()
	var own: TruthEntity = w.world["own"]
	var tp = w.weapons.fire_bearing_only(
		45.0, float(own.position_east_m), float(own.position_north_m), w.sim_time, 50.0
	)
	_ok(fails, "PD-03a torpedo launched", tp != null)
	if tp == null:
		return
	# 出管入水（LAUNCHING→WIRE_RUN）后导线才接受命令（PC-05 同几何）。
	w.run_steps(30)
	var beam: Dictionary = SeekerBeamState.new_from(tp).to_dict()
	var prof = tp.acoustic_profile
	_ok(
		fails,
		"PD-03b half angle = profile/2",
		(
			absf(float(beam["passive_half_angle_deg"]) - 0.5 * float(prof.horizontal_beamwidth_deg))
			< 1e-6
		)
	)
	# 线控命令 090°：一 tick 后扇区中心仍是实际艏向（不随命令瞬移）。
	_ok(fails, "PD-03c course command accepted", tp.command_course(90.0))
	w.run_steps(1)
	var beam2: Dictionary = SeekerBeamState.new_from(tp).to_dict()
	_ok(
		fails,
		"PD-03d center = actual course",
		absf(float(beam2["center_true_deg"]) - float(tp.course_deg)) < 1e-6
	)
	_ok(fails, "PD-03e center did NOT snap to command", float(tp.course_deg) < 89.0)
	_ok(fails, "PD-03f tx_state OFF initially", str(beam2["tx_state"]) == "OFF")
	_ok(fails, "PD-03g display_range_mode SYMBOLIC", str(beam2["display_range_mode"]) == "SYMBOLIC")
	_ok(fails, "PD-03h set_active_tx → WAITING_TRIGGER", tp.set_active_tx(true))
	_ok(
		fails,
		"PD-03i beam tx_state follows authority",
		str(SeekerBeamState.new_from(tp).to_dict()["tx_state"]) == "WAITING_TRIGGER"
	)
	# 适配器被动/主动发射门与 beam 同参数：边界内 1° 有回波、外 1°/正后无。
	var ad := TorpedoSensorAdapter.new()
	ad.bind(w.world["env"], w.world.get("depth_model"), [], {})
	ad.rng = _mk_rng(SEED + 21)
	var contacts: Array = []
	var acs: Dictionary = {}
	var tor: TruthEntity = TruthEntity.new()
	tor.position_east_m = 0.0
	tor.position_north_m = 0.0
	tor.course_deg = 0.0
	tor.speed_kn = 40.0
	tor.depth_m = 50.0
	for spec in [[0.0, "C_CENTER"], [59.0, "C_IN"], [61.0, "C_OUT"], [180.0, "C_BACK"]]:
		var c := TruthEntity.new()
		c.id = spec[1]
		var br: float = deg_to_rad(float(spec[0]))
		c.position_east_m = sin(br) * 300.0
		c.position_north_m = cos(br) * 300.0
		c.speed_kn = 0.0
		c.depth_m = 50.0
		contacts.append(c)
		var p := AcousticProfile.new()
		p.broadband_base_level_db = 185.0
		p.speed_noise_a = 0.0
		acs[str(c.id)] = p
	ad.contacts = contacts
	ad.contact_acs = acs
	ad.schedule_active_echoes("T99", 0.0, 0.0, 0.0, prof, 1.0, "P1", 50.0, 40.0)
	var scheduled: int = ad.pending_echo_count()
	_ok(
		fails,
		"PD-03j active gate: center+in scheduled, out/back not (got %d)" % scheduled,
		scheduled == 2
	)
	var passive: Array = ad.sample_passive(0.0, 0.0, 50.0, 40.0, 0.0, prof, 1.0)
	var modes_ok: bool = true
	for r in passive:
		var brg: float = float(r.bearing_deg)
		if absf(NavUtils.wrap180(brg - 61.0)) < 0.5 or absf(NavUtils.wrap180(brg - 180.0)) < 0.5:
			modes_ok = false
	_ok(fails, "PD-03k passive gate excludes outside/back returns", modes_ok)


## ---- PD-04：海图鱼雷/威胁输入数据（P1-02）----
func _pd_04_chart_inputs(fails: Array) -> void:
	var chart := ChartView.new()
	chart.size = Vector2(800, 600)
	chart.own_pos = Vector2.ZERO
	var entry := {
		"trail": [{"e": 2000.0, "n": 2000.0, "t": 0.0}],
		"state": "SEARCH",
		"torpedo_id": "T01",
		"course_deg": 45.0,
		"tx_state": "PINGING",
		"search_center_deg": 45.0,
		"search_half_deg": 30.0,
		"fov_half_deg": 60.0,
		"track_bearing_deg": 90.0,
		"track_sigma_deg": 2.5,
		"beam": {"passive_half_angle_deg": 60.0},
	}
	chart.torpedoes = [entry]
	var cps: Array = chart.torpedo_click_points()
	_ok(
		fails,
		"PD-04a click point with real id",
		cps.size() == 1 and str(cps[0]["torpedo_id"]) == "T01"
	)
	var got_t: Array = []
	chart.torpedo_selected.connect(func(tid: String): got_t.append(tid))
	chart._on_click(cps[0]["pos"] as Vector2)
	chart._on_click(Vector2(10, 10))
	_ok(
		fails,
		"PD-04b click selects / blank deselects",
		got_t.size() == 2 and str(got_t[0]) == "T01" and str(got_t[1]) == ""
	)
	# 威胁 LOB 点击 → evidence_id 信号。
	var ev := {
		"evidence_id": 7,
		"side_hint": "INTERCEPT",
		"observer_e_m": 1000.0,
		"observer_n_m": 0.0,
		"bearing_deg": 45.0,
		"bearing_sigma_deg": 2.0,
		"evidence_kind": "RUNNING_NOISE",
		"timestamp": 5.0,
		"threat_track_id": "TT001",
	}
	chart.set_threat_evidence([ev], 6.0)
	var tps: Array = chart.threat_click_points()
	_ok(
		fails,
		"PD-04c threat click point at observer",
		(
			tps.size() == 1
			and (
				(tps[0]["pos"] as Vector2).distance_to(chart.world_to_screen(Vector2(1000, 0)))
				< 0.5
			)
		)
	)
	var got_e: Array = []
	chart.threat_selected.connect(func(eid: int): got_e.append(eid))
	chart._on_click(tps[0]["pos"] as Vector2)
	_ok(fails, "PD-04d threat click emits evidence_id", got_e == [7])
	# auto_frame 纳入鱼雷轨迹 + 威胁 LOB 原点。
	chart.own_track = [Vector2.ZERO]
	chart.auto_frame()
	var head_s: Vector2 = chart.world_to_screen(Vector2(2000, 2000))
	var lob_s: Vector2 = chart.world_to_screen(Vector2(1000, 0))
	_ok(
		fails,
		"PD-04e auto_frame covers torpedo head",
		head_s.x >= 0 and head_s.x <= chart.size.x and head_s.y >= 0 and head_s.y <= chart.size.y
	)
	_ok(
		fails,
		"PD-04f auto_frame covers threat lob",
		lob_s.x >= 0 and lob_s.x <= chart.size.x and lob_s.y >= 0 and lob_s.y <= chart.size.y
	)
	# 绘图输入与物理同源（P0-10.7）：entry 扇区值 = beam 字段。
	_ok(
		fails,
		"PD-04g entry fov = beam half",
		absf(float(entry["fov_half_deg"]) - float(entry["beam"]["passive_half_angle_deg"])) < 1e-6
	)


## ---- PD-05：威胁证据/track 无 Truth 泄漏（P0-07/AT-10 部分）----
func _pd_05_threat_sanitized(fails: Array) -> void:
	var w := _mk_world()
	var own: TruthEntity = w.world["own"]
	var bus := AcousticEmissionBus.new()
	_mk_bus_event(
		bus,
		AcousticEmissionEvent.TORPEDO_TUBE_TRANSIENT,
		float(own.position_east_m) + 800.0,
		float(own.position_north_m) + 300.0
	)
	var san := EmissionSanitizer.new()
	san.bind(w.world["env"], w.world.get("depth_model"), _mk_rng(SEED + 31))
	# REQ 批：瞬态证据按 t_emit + R/c 出现——源距 ~854m → 时延 ~0.57s，
	# 消费点取 11.0s。
	var evs: Array = san.consume_events(bus.events, own, 11.0, {})
	_ok(fails, "PD-05a transient evidence produced", evs.size() == 1)
	if evs.is_empty():
		return
	var ev: Dictionary = evs[0]
	var clean: bool = true
	for bad in [
		"target_id",
		"truth_range",
		"truth_position",
		"truth_course",
		"range_m",
		"emitter_internal_ref",
		"source_position_internal"
	]:
		if ev.has(bad):
			clean = false
	_ok(fails, "PD-05b no Truth fields in evidence", clean)
	var mgr := ThreatTrackManager.new()
	var tid: String = mgr.ingest(ev, 10.0)
	_ok(fails, "PD-05c track assigned", tid != "")
	var tr: Dictionary = mgr.tracks()[0]
	var clean2: bool = true
	for bad2 in ["target_id", "truth_position", "range_m"]:
		if tr.has(bad2):
			clean2 = false
	_ok(fails, "PD-05d no Truth fields in track", clean2)
	_ok(
		fails,
		"PD-05e evidence annotated",
		(
			str(ev.get("threat_track_id", "")) == tid
			and str(ev.get("source_class_hypothesis", "")) == "TORPEDO"
		)
	)
