extends SceneTree
## s1_11_batch0_test.gd — S1-11 Batch 0 验收：S1-10 两个 P0 数据入口 + 已有正确行为固化。
##
##   B0-46 (AT-46) 瀑布图任意位置（无峰/低 SE/噪声行）手动 Mark 一律落点并建接触；
##   B0-47 (AT-47) 明确选组后与最近测量差 >8° 仍直接加入该组；空组首点成立；
##   B0-48 (AT-48) 仅查看/切换 Contact 不隐式改变 Mark 归属；Shift＋点击才显式追加；
##   B0-49 (AT-49) 记录光标原始方位（不吸附 6° 内峰值）；删除后可在同一位置重标；
##   B0-50 (AT-50) 拖曳阵 A/B 镜像共享 evidence_id，证据数只增一次；
##   B0-51/53/54 同一 Ping 回波批次一对一分配：顺序无关、单次占用、歧义保留；
##   B0-52 (AT-52) 同一 ping 批次内一条 TT 威胁航迹最多吸收一条回波。

const OP_SCRIPT := "res://scripts/sonar/operator_sonar.gd"


func _initialize() -> void:
	var fails: Array = []
	_b0_46(fails)
	_b0_47(fails)
	_b0_48(fails)
	_b0_49(fails)
	_b0_50(fails)
	_b0_52(fails)
	_b0_51_53_54(fails)
	_b0_batch_wiring(fails)
	_finish(fails)


# ---------------- AT-46：任意位置可落点 ----------------
func _b0_46(fails: Array) -> void:
	var op := _mk_operator()
	var world := World.new()
	var tr := Tracker.new()
	var flow := _mk_flow(world, tr, op)
	var row := _free_row(12.0, [])
	var res: Dictionary = flow.handle_mark(45.0, false, row, "")
	var t: Track = res.get("track")
	_assert(fails, t != null, "B0-46 free click on empty/noise row creates a contact")
	if t == null:
		return
	var m: Measurement = t.latest_measurement()
	_assert(fails, m != null and m.detected, "B0-46 free click lands a detected measurement")
	_assert(
		fails,
		m != null and absf(NavUtils.angle_diff(m.measured_bearing_deg, 45.0)) < 1e-6,
		"B0-46 recorded bearing equals cursor bearing"
	)
	_assert(fails, world.measurements.size() == 1, "B0-46 measurement enters world stream (LOA)")


# ---------------- AT-47：显式选组直接追加（不过 8° 门） ----------------
func _b0_47(fails: Array) -> void:
	var op := _mk_operator()
	var world := World.new()
	var tr := Tracker.new()
	var flow := _mk_flow(world, tr, op)
	var group := tr.create_empty_track()
	flow.active_group_id = group.track_id
	var first: Dictionary = flow.handle_mark(10.0, false, _free_row(1.0, []), "")
	# ① 空组首点：显式指定组时首点必须成立。
	var t1: Track = tr.track_by_id(group.track_id)
	_assert(
		fails, t1.evidence_count() == 1, "B0-47 empty explicit group accepts its first measurement"
	)
	_assert(fails, first.get("track") == group, "B0-47 first point lands on the chosen group")
	# ② 与最近测量相差 >8°：仍直接加入（8° 只留给自动关联）。
	flow.active_group_id = group.track_id
	var far: Dictionary = flow.handle_mark(120.0, false, _free_row(2.0, []), "")
	_assert(
		fails,
		far.get("track") == group and group.evidence_count() == 2,
		"B0-47 >8 deg explicit mark still appends to chosen group"
	)
	_assert(
		fails,
		not str(far.get("status", "")).begins_with("Mark ignored"),
		"B0-47 explicit mark never rejected by the 8-deg auto gate"
	)


# ---------------- AT-48：看不等于加；Shift＋点击显式追加 ----------------
func _b0_48(fails: Array) -> void:
	var op := _mk_operator()
	var world := World.new()
	var tr := Tracker.new()
	var flow := _mk_flow(world, tr, op)
	var viewed := tr.create_empty_track()
	tr.append_group_direct(viewed, [op.create_mark(30.0, 1.0, "", false, _free_row(1.0, []))])
	var n0: int = viewed.evidence_count()
	# 仅"查看"该接触（selected_id 非空但未显式选组/未 Shift）：不得改其归属。
	var plain: Dictionary = flow.handle_mark(150.0, false, _free_row(2.0, []), viewed.track_id)
	_assert(
		fails,
		viewed.evidence_count() == n0,
		"B0-48 merely viewing a contact does not change its mark ownership"
	)
	_assert(
		fails,
		plain.get("track") != viewed,
		"B0-48 non-explicit click goes through auto association, not the viewed contact"
	)
	# Shift＋点击（explicit_append）：显式追加到正在查看的接触。
	var shift: Dictionary = flow.handle_mark(
		150.0, false, _free_row(3.0, []), viewed.track_id, true
	)
	_assert(
		fails,
		shift.get("track") == viewed and viewed.evidence_count() == n0 + 1,
		"B0-48 Shift+click explicitly appends to the viewed contact"
	)


# ---------------- AT-49：不吸附峰值；删除后可重标 ----------------
func _b0_49(fails: Array) -> void:
	var op := _mk_operator()
	var row := _free_row(
		5.0, [{"bearing_deg": 60.0, "peak_id": "p00", "se_db": 14.0, "snr_db": 14.0}]
	)
	var m: Measurement = op.create_mark(57.0, 5.0, "", false, row)
	_assert(
		fails,
		absf(NavUtils.angle_diff(m.measured_bearing_deg, 57.0)) < 1e-6,
		"B0-49 cursor bearing recorded verbatim (no 6-deg snap to peak)"
	)
	var world := World.new()
	var tr := Tracker.new()
	var flow := _mk_flow(world, tr, op)
	var landed: Dictionary = flow.handle_mark(57.0, false, row, "")
	var t: Track = landed.get("track")
	_assert(fails, t != null and not t.measurement_history.is_empty(), "B0-49 mark landed")
	if t == null or t.measurement_history.is_empty():
		return
	var first_m: Measurement = t.measurement_history[0]
	flow.remove_last_mark(t.track_id)
	_assert(
		fails,
		t.measurement_history.is_empty() and op.mark_cache_size() == 0,
		"B0-49 removal clears the row/peak dedupe cache"
	)
	var again: Measurement = op.create_mark(57.0, 5.0, "", false, row)
	_assert(
		fails,
		(
			again != null
			and again != first_m
			and absf(NavUtils.angle_diff(again.measured_bearing_deg, 57.0)) < 1e-6
		),
		"B0-49 re-marking the same position is allowed after removal"
	)


# ---------------- AT-50：拖曳镜像共享 evidence ----------------
func _b0_50(fails: Array) -> void:
	var op := _mk_operator()
	var row := _free_row(
		7.0,
		[
			{
				"bearing_deg": 40.0,
				"peak_id": "p00",
				"se_db": 12.0,
				"snr_db": 12.0,
				"ambiguous_pair_id": "ap1",
				"ambiguity_branch": 1,
			}
		]
	)
	row["array_id"] = "TOWED"
	row["array_heading"] = 0.0
	var grp: Array = op.create_mark_group(40.0, 7.0, "", false, row)
	_assert(fails, grp.size() == 2, "B0-50 towed arrival yields mirror group")
	if grp.size() != 2:
		return
	_assert(
		fails,
		str((grp[0] as Measurement).evidence_id) == str((grp[1] as Measurement).evidence_id),
		"B0-50 mirror branch shares one evidence_id"
	)
	var tr := Tracker.new()
	var t: Track = tr.mark(grp[0] as Measurement, "M")
	t.add_measurement(grp[1] as Measurement)
	_assert(fails, t.evidence_count() == 1, "B0-50 one physical arrival counts once")


# ---------------- AT-52：同一 Ping 批次内 TT 航迹只吸收一条回波 ----------------
func _b0_52(fails: Array) -> void:
	var mgr := ThreatTrackManager.new()
	mgr.ingest(_noise_ev(1, 90.0), 10.0)
	var tid: String = str(mgr.tracks()[0]["track_id"])
	var dto := _return_dto("A", 90.2, 1500.0, 10.5)
	dto["batch_key"] = "P1"
	var r1: String = mgr.fuse_active_return(dto, 10.5)
	_assert(fails, r1 == tid, "B0-52 first return fuses into the TT track")
	var dto2 := _return_dto("B", 90.4, 1520.0, 10.6)
	dto2["batch_key"] = "P1"
	var r2: String = mgr.fuse_active_return(dto2, 10.6)
	_assert(fails, r2 == "", "B0-52 second return in the same ping cannot reuse that TT track")
	var dto3 := _return_dto("C", 90.6, 1540.0, 11.5)
	dto3["batch_key"] = "P2"
	_assert(
		fails,
		mgr.fuse_active_return(dto3, 11.5) == tid,
		"B0-52 exclusivity is per ping, not global"
	)


# ---------------- AT-51/53/54：批次一对一分配（顺序无关 + 歧义保留） ----------------
func _b0_51_53_54(fails: Array) -> void:
	var targets: Array = [_tgt("T1", 30.0, 3000.0), _tgt("T2", 120.0, 3000.0)]
	var returns: Array = [
		_ret("r1", 30.1, 3010.0),
		_ret("r2", 30.2, 2995.0),
		_ret("r3", 120.1, 3005.0),
	]
	var res: Dictionary = ActiveReturnBatch.assign(returns, targets)
	var asg: Dictionary = res.get("assignments", {})
	_assert(
		fails,
		asg.size() == 2 and asg.get("r3") == "T2",
		"B0-51/53 one return per track (two tracks never share a ping double-feed)"
	)
	var used: Dictionary = {}
	var dup: bool = false
	for k in asg.keys():
		if used.has(str(asg[k])):
			dup = true
		used[str(asg[k])] = true
	_assert(fails, not dup, "B0-51 no track receives two returns in one ping")
	# 顺序无关：反转输入 → 同一映射。
	var rev: Array = returns.duplicate()
	rev.reverse()
	var res2: Dictionary = ActiveReturnBatch.assign(rev, targets)
	_assert(
		fails,
		res2.get("assignments", {}) == asg,
		"B0-53 assignment is independent of return arrival order"
	)
	# 歧义：两个几何完全相同的候选 → 保留未归属（不按顺序强塞）。
	var twin: Array = [_tgt("A", 55.0, 2000.0), _tgt("B", 55.0, 2000.0)]
	var amb: Dictionary = ActiveReturnBatch.assign([_ret("x", 55.05, 2005.0)], twin)
	_assert(
		fails,
		amb.get("assignments", {}).is_empty() and amb.get("ambiguous", []).has("x"),
		"B0-54 near-equal best/second cost stays unassigned (uncertain)"
	)
	var un: Array = amb.get("unassigned", [])
	_assert(
		fails,
		un.size() == 1 and str(un[0].get("reason", "")) == "uncertain",
		"B0-54 unassigned reason recorded as uncertain"
	)


# ---------------- 接线：控制器/威胁链走批次路径 ----------------
## PG-05 起归属是**全局一次**：World 把 TT 候选与普通接触候选放进同一个代价矩阵
## （ActiveReturnAttribution.attribute，经 ActiveReturnAttributionBridge 接线），
## UI 侧只消费归属结果，不再自己另跑一份。
func _b0_batch_wiring(fails: Array) -> void:
	var ctrl: String = (load("res://scripts/ui/active_ping_controller.gd") as Script).source_code
	_assert(
		fails,
		ctrl.find("world.take_attribution(") >= 0,
		"B0-51 controller consumes the world-wide attribution"
	)
	_assert(fails, ctrl.find("_pending_batch") >= 0, "B0-51 controller buffers by ping_id")
	_assert(
		fails,
		ctrl.find("tracker.feed(m)") < 0,
		"B0-51 per-echo greedy feed removed from the active return path"
	)
	var wsrc: String = (load("res://scripts/world.gd") as Script).source_code
	_assert(
		fails, wsrc.find("_attribute_active_returns") >= 0, "B0-52 world settles the batch once"
	)
	_assert(
		fails,
		wsrc.find("ActiveReturnAttributionBridge.resolve") >= 0,
		"B0-52 world delegates to one global attribution"
	)
	var bsrc: String = (
		(load("res://scripts/acoustic/active_return_attribution_bridge.gd") as Script).source_code
	)
	_assert(
		fails,
		bsrc.find("ActiveReturnAttribution.attribute") >= 0,
		"B0-52 TT + contacts share one matrix"
	)
	_assert(
		fails,
		wsrc.find("last_closed_ping_id") >= 0,
		"B0-51 world exposes the closed ping id to the UI batch"
	)


# ---------------- helpers ----------------
func _mk_operator() -> RefCounted:
	var own := TruthEntity.new()
	own.position_east_m = 0.0
	own.position_north_m = 0.0
	own.course_deg = 0.0
	own.depth_m = 50.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 91100
	var op: RefCounted = load(OP_SCRIPT).new()
	op.setup({"own": own, "rng": rng})
	return op


func _mk_flow(world: World, tr: Tracker, op: RefCounted) -> MarkFlow:
	var flow := MarkFlow.new()
	flow.tracker = tr
	flow.op = op
	flow.world = world
	return flow


func _free_row(t: float, peaks: Array) -> Dictionary:
	return {
		"array_id": "BOW",
		"t": t,
		"course": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"row_id": "row_free_%d" % int(t * 100.0),
		"peaks": peaks,
	}


func _noise_ev(id: int, brg: float) -> Dictionary:
	return {
		"evidence_id": id,
		"evidence_kind": "RUNNING_NOISE",
		"bearing_deg": brg,
		"bearing_sigma_deg": 1.0,
		"confidence": 0.8,
		"p_torpedo": 0.8,
		"class_state": "PROBABLE_TORPEDO",
		"observer_e_m": 0.0,
		"observer_n_m": 0.0,
		"timestamp": 10.0,
	}


func _return_dto(rid: String, brg: float, rng_m: float, t: float) -> Dictionary:
	return {
		"evidence_id": rid,
		"evidence_kind": "ACTIVE_RETURN",
		"source_mode": "ACTIVE_RETURN",
		"timestamp": t,
		"available_time": t,
		"sensor_id": "OP_BOW",
		"observer_e_m": 0.0,
		"observer_n_m": 0.0,
		"bearing_deg": brg,
		"bearing_sigma_deg": 0.5,
		"measured_range_m": rng_m,
		"range_sigma_m": 30.0,
		"signal_excess_db": 10.0,
		"detection_probability": 0.9,
	}


func _tgt(id: String, brg: float, rng_m: float) -> Dictionary:
	return {
		"id": id,
		"bearing_deg": brg,
		"bearing_sigma_deg": 1.0,
		"range_m": rng_m,
		"range_sigma_m": 40.0,
		"time": 10.0,
		"freqs": [],
	}


func _ret(id: String, brg: float, rng_m: float) -> Dictionary:
	return {
		"id": id,
		"bearing_deg": brg,
		"bearing_sigma_deg": 1.0,
		"range_m": rng_m,
		"range_sigma_m": 40.0,
		"time": 10.0,
		"freqs": [],
	}


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH0 TEST PASS")
		quit(0)
	else:
		print("S1-11 BATCH0 TEST FAIL (%d)" % fails.size())
		quit(1)
