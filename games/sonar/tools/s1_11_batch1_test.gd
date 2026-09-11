extends SceneTree
## s1_11_batch1_test.gd — S1-11 Batch 1 验收：统一候选→证据→航迹→分类→TMA。
##
##   B1-58 (AT-58) 自动/分类/TMA/威胁链只消费净化 Measurement/声学证据，无 Truth 泄漏；
##   B1-60 (AT-60) 分类显示概率/依据/时间；单次回波只能"未知/疑似"，不揭示真实身份；
##   B1-50 (AT-50) 拖曳阵 A/B 镜像共享 evidence_id：证据数只增一次、按组关联；
##   B1-56 (AT-56) ASSIST 链连续自动 Mark / 跨帧关联；
##   B1-55 (AT-55) 单次主动 bearing+range 只给位置观测；多历元才给运动；
##   B1-57 (AT-57) Fit 按 track_id+evidence_revision 缓存：切换不清空、不重抽样。


func _initialize() -> void:
	var fails: Array = []
	_b1_60(fails)
	_b1_50(fails)
	_b1_56(fails)
	_b1_55(fails)
	_b1_57(fails)
	_b1_58(fails)
	_finish(fails)


# ---------------- AT-60：概率分类渐进标签 ----------------
func _b1_60(fails: Array) -> void:
	# 单次回波：最多"未知/疑似"，绝不"高可信"、绝不揭示真实身份。
	var single := Track.create(
		"S", 1, _mk_meas("ev1", 30.0, 0.0, [{"freq_hz": 120.0, "level_db": 6.0}])
	)
	var ra: Dictionary = TrackClassification.assess(single, 0.0)
	_assert(
		fails,
		str(ra["state"]) in [TrackClassification.STATE_UNKNOWN, TrackClassification.STATE_SUSPECT],
		"B1-60 single return is at most SUSPECT (%s)" % ra["state"]
	)
	_assert(
		fails,
		not str(ra["label"]).begins_with("高可信"),
		"B1-60 single return never reveals a high-confidence identity (%s)" % ra["label"]
	)
	_assert(
		fails,
		ra.has("evidence_summary") and ra.has("updated_time") and ra.has("probabilities"),
		"B1-60 assessment carries probabilities + evidence summary + time"
	)
	# 多历元窄带谱线：潜艇概率最高，可升级为高可信。
	var multi := Track.create("S", 2, _mk_meas("evm1", 30.0, 0.0, [{"freq_hz": 120.0}]))
	multi.add_measurement(_mk_meas("evm2", 31.0, 30.0, [{"freq_hz": 121.0}]))
	multi.add_measurement(_mk_meas("evm3", 32.0, 60.0, [{"freq_hz": 119.0}]))
	var rb: Dictionary = TrackClassification.assess(multi, 60.0)
	var probs: Dictionary = rb["probabilities"]
	_assert(
		fails,
		str(rb["best"]) == TrackClassification.SUBMARINE,
		"B1-60 tonal track best class is SUBMARINE"
	)
	_assert(
		fails,
		float(probs[TrackClassification.SUBMARINE]) > float(probs[TrackClassification.TORPEDO]),
		"B1-60 submarine prob exceeds torpedo for stalephonetic tonals"
	)
	_assert(
		fails,
		str(rb["state"]) == TrackClassification.STATE_CLASSIFIED,
		"B1-60 multi-epoch consistent tonals reach CLASSIFIED (%s)" % rb["state"]
	)
	# 鱼雷威胁证据：best = TORPEDO。
	var rt: Dictionary = (
		TrackClassification
		. assess(
			multi,
			60.0,
			[
				{
					"evidence_id": "tt1",
					"evidence_kind": "RUNNING_NOISE",
				}
			]
		)
	)
	_assert(
		fails,
		float(rt["probabilities"].get(TrackClassification.TORPEDO, 0.0)) > 0.0,
		"B1-60 torpedo running noise raises TORPEDO probability"
	)


# ---------------- AT-50：A/B 镜像共享 evidence_id ----------------
func _b1_50(fails: Array) -> void:
	var tr := Tracker.new()
	var chain := AssistChain.new(tr)
	var a := _mk_meas("mirror1", 20.0, 0.0)
	a.ambiguous_pair_id = "pair1"
	a.ambiguity_branch = 1
	var b := _mk_meas("mirror1", 340.0, 0.0)
	b.ambiguous_pair_id = "pair1"
	b.ambiguity_branch = -1
	# 同一物理到达的 A/B 两个候选：整组作为一个证据原子。
	chain.ingest_measurements([a], 0.0)
	chain.ingest_measurements([b], 0.0)
	_assert(fails, tr.count() == 1, "B1-50 mirror pair does not create two tracks")
	var t: Track = tr.all_tracks()[0]
	_assert(
		fails,
		t.evidence_count() == 1,
		"B1-50 A/B mirror shares evidence_id -> counted once (got %d)" % t.evidence_count()
	)
	chain.ingest_measurements([a], 0.0)
	_assert(
		fails,
		chain.seen_count() == 1,
		"B1-50 duplicate evidence_id is never re-consumed by auto chain"
	)


# ---------------- AT-56：ASSIST 自动 Mark / 跨帧关联 ----------------
func _b1_56(fails: Array) -> void:
	var tr := Tracker.new()
	var chain := AssistChain.new(tr)
	var r1: Dictionary = chain.ingest_measurements([_mk_meas("a1", 40.0, 0.0)], 0.0)
	_assert(fails, int(r1["created"]) == 1, "B1-56 first detection auto-creates a track")
	# 跨帧：下一帧方位接近 -> 关联到既有航迹，不新建。
	var r2: Dictionary = chain.ingest_measurements([_mk_meas("a2", 41.0, 20.0)], 20.0)
	_assert(fails, tr.count() == 1, "B1-56 cross-frame near bearing associates, no new track")
	_assert(fails, int(r2["appended"]) == 1, "B1-56 second evidence appends to existing track")
	# 自动 Mark 带来源标签。
	var t: Track = tr.all_tracks()[0]
	_assert(
		fails,
		t.mark_source_summary().begins_with(AssistChain.SRC_PASSIVE),
		"B1-56 auto marks carry a source label (%s)" % t.mark_source_summary()
	)
	# 远方位（>8° 门）-> 新建候选，不丢证据。
	chain.ingest_measurements([_mk_meas("a3", 130.0, 40.0)], 40.0)
	_assert(
		fails, tr.count() == 2, "B1-56 far detection creates a new candidate (no evidence lost)"
	)


# ---------------- AT-55：单次位置观测 / 多历元运动 ----------------
func _b1_55(fails: Array) -> void:
	var one := Track.create("S", 5, _ranged_meas("r1", 0.0, 1000.0))
	var oa: Dictionary = ActivePositionObs.evaluate(one, 0.0)
	_assert(
		fails, bool(oa["has_position"]), "B1-55 single active return yields a position observation"
	)
	_assert(
		fails, not bool(oa["has_motion"]), "B1-55 single return does NOT fabricate course/speed"
	)
	_assert(fails, not oa.has("speed_kn"), "B1-55 no speed field before multi-epoch geometry")
	# 目标以 5 m/s 向北运动（方位 0°，距离随时间增长）。
	var multi := Track.create("S", 6, _ranged_meas("m1", 0.0, 1000.0))
	multi.add_measurement(_ranged_meas("m2", 15.0, 1075.0))
	multi.add_measurement(_ranged_meas("m3", 30.0, 1150.0))
	multi.add_measurement(_ranged_meas("m4", 45.0, 1225.0))
	var ob: Dictionary = ActivePositionObs.evaluate(multi, 45.0)
	_assert(fails, bool(ob["has_motion"]), "B1-55 multi-epoch geometry yields motion estimate")
	_assert(
		fails,
		absf(float(ob["speed_kn"]) - 5.0 * 1.94384) < 0.3,
		"B1-55 motion speed matches truth kinematics (~%.1f kn)" % float(ob["speed_kn"])
	)
	_assert(
		fails,
		absf(NavUtils.wrap180(float(ob["course_deg"]) - 0.0)) < 2.0,
		"B1-55 motion course matches north (%.1f°)" % float(ob["course_deg"])
	)


# ---------------- AT-57：Fit 按 revision 缓存 ----------------
func _b1_57(fails: Array) -> void:
	var tr := Tracker.new()
	var t := Track.create("S", 7, _mk_meas("f1", 20.0, 0.0))
	for i in range(1, 5):
		t.add_measurement(_mk_meas("f%d" % (i + 1), 20.0 + float(i), float(i) * 30.0))
	var fcc := FireControlContext.new()
	_assert(fails, fcc.needs_refit(t), "B1-57 no cached fit -> needs_refit true")
	var r: Dictionary = fcc.solve_and_store(t, null, 120.0)
	_assert(
		fails, not fcc.needs_refit(t), "B1-57 after fit with same revision -> needs_refit false"
	)
	var v1: int = int(r.get("fit_version", 0))
	# 切换目标再切回来：缓存与版本保持，不重抽样。
	var cached: Dictionary = fcc.cached_fit(t.track_id)
	_assert(
		fails,
		int(cached.get("fit_version", -1)) == v1,
		"B1-57 cached fit survives target switch (same fit_version)"
	)
	_assert(fails, not fcc.needs_refit(t), "B1-57 switching target does not trigger a refit")
	# 新证据 -> revision 变化 -> 需要重算。
	t.add_measurement(_mk_meas("f9", 27.0, 180.0))
	_assert(
		fails,
		fcc.needs_refit(t),
		"B1-57 new physical evidence increments revision -> needs_refit true"
	)


# ---------------- AT-58：信息边界（无 Truth/target_id 泄漏） ----------------
func _b1_58(fails: Array) -> void:
	var tr := Tracker.new()
	var chain := AssistChain.new(tr)
	chain.ingest_measurements([_mk_meas("s1", 15.0, 0.0)], 0.0)
	var t: Track = tr.all_tracks()[0]
	# 分类评估 DTO 不含 target_id / 真实身份字段。
	var a: Dictionary = TrackClassification.assess(
		t, 0.0, [{"evidence_id": "e", "evidence_kind": "RUNNING_NOISE"}]
	)
	_assert(
		fails,
		not a.has("target_id") and not a.has("truth_position"),
		"B1-58 classification DTO carries no target_id/truth fields"
	)
	# 位置观测 DTO 同样只有可测几何量。
	var obs: Dictionary = ActivePositionObs.evaluate(
		Track.create("S", 8, _ranged_meas("z1", 0.0, 800.0)), 0.0
	)
	_assert(
		fails,
		not obs.has("target_id") and not obs.has("truth"),
		"B1-58 position observation DTO carries no target_id/truth fields"
	)
	# 源文件静态扫描：新 DTO 模块不得出现 TruthEntity 引用。
	var srcs: Array = [
		"res://scripts/track_classification.gd",
		"res://scripts/active_position_obs.gd",
		"res://scripts/automation/assist_chain.gd",
	]
	for p in srcs:
		var f := FileAccess.open(p, FileAccess.READ)
		var txt: String = f.get_as_text() if f != null else ""
		_assert(
			fails,
			txt.find("TruthEntity") < 0 and txt.find("target_id") < 0,
			"B1-58 %s contains no TruthEntity/target_id" % p.get_file()
		)


# ---------------- helpers ----------------
func _mk_meas(eid: String, brg: float, t: float, freqs: Array = []) -> Measurement:
	var m := Measurement.new()
	m.evidence_id = eid
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.5
	m.timestamp = t
	m.detected = true
	m.detected_frequencies = freqs
	return m


func _ranged_meas(eid: String, t: float, range_m: float) -> Measurement:
	var m := Measurement.new()
	m.evidence_id = eid
	m.measurement_type = "ACTIVE_RANGE_BEARING"
	m.measured_bearing_deg = 0.0
	m.bearing_sigma_deg = 1.0
	m.measured_range_m = range_m
	m.range_sigma_m = 30.0
	m.timestamp = t
	m.detected = true
	m.observer_east_m = 0.0
	m.observer_north_m = 0.0
	return m


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH1 TEST PASS")
		quit(0)
	else:
		print("S1-11 BATCH1 TEST FAIL (%d)" % fails.size())
		quit(1)
