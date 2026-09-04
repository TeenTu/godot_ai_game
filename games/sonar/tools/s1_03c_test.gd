extends SceneTree
## s1_03c_test.gd — S1-03C 拖曳阵证据组关联 + 阵列中心几何 无头验收（P0 首批）。
##
## 背景 bug（腾讯文档 DZkRDb09rb2d6cVdh 评审）：
##   P0-01  一次 A/B 镜像组被当成两条普通测量：main_ui 用全局 tracker.feed(m)
##          关联且不约束 selected_track；Track.latest_measurement() 常是 sibling，
##          下次点同一可见支时方位差超门限 → 静默新建 M02/M03……（跨时刻分裂）。
##   P0-02  拖曳阵方位从艇心算（≈66°），写入 Measurement/LOB 却以阵列中心
##          (0,-230) 为起点（≈60°）→ ~6° 系统误差（距离越近、缆越长越明显）。
##   P0-03  TMA 门槛用 measurement_history.size()（拖曳 2 次点击=4 行即放行），
##          未按物理 evidence 计数。
##
## 覆盖（对齐评审 TEST-01..05 / 首批任务）：
##   C1  连续五次 TOWED 手动 Mark（第 3 次改点另一支）：1 Track / 5 evidence /
##       10 candidate rows，绝不出现 M02；selected_track 真正约束目标 Track。
##   C2  Autocrew 跨五个到达时刻：1 Track / 5 evidence，不因 latest 是 sibling
##       而新建 Contact。
##   C3  TMA 门槛按物理 evidence：2 evidence(4 rows) 不可拟合；4 evidence(8 rows)
##       可拟合；拖曳 2 次点击(4 rows) 不得被 size>=4 误放行。
##   C4  阵列中心方位一致性：target=(1732,770)、own=(0,0)、阵心=(0,-230)、
##       阵轴 0° 时生成真方位 ≈60°（非艇心 66°）；Measurement observer == (0,-230)；
##       LOB 从 observer 发出穿过目标；TL 用阵心距离 ~2000m。
##
## 全部确定性（固定种子/解析构造），可无头运行：
##   godot --headless --path games/sonar --script res://tools/s1_03c_test.gd
##
## 注：C1/C2 依赖 ambiguity-aware 的 Tracker.feed_evidence_group(group,
## preferred_track_id, gate) API（S1-03C 新增）；实现前这些场景无法通过。


func _initialize() -> void:
	var fails: Array = []
	_c1_marks_no_split(fails)
	_c2_autocrew_no_split(fails)
	_c3_evidence_gate(fails)
	_c4_array_center_bearing(fails)
	if fails.is_empty():
		print("S1_03C_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("S1_03C_TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ------------------------------------------------------------------
#  确定性场景构造（与 s1_03b / towed_test 同款环境）
# ------------------------------------------------------------------


func _mk_env() -> EnvironmentModel:
	var env := EnvironmentModel.new()
	(
		env
		. from_dict(
			{
				"ambient_noise_by_frequency": {"500": 55.0},
				"own_noise_base_db": 38.0,
				"own_noise_speed_coeff": 1.5,
				"tl_spreading_k": 20.0,
				"tl_absorption_alpha": 0.5,
				"tl_environment_loss": 2.0,
			}
		)
	)
	return env


## 本艇 (0,0) 航向 0；拖曳阵 400m 部署完毕 → 阵心 = (0,-230)（dead 60m）。
func _mk_own() -> TruthEntity:
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 6.0
	own.towed = TowedArray.new()
	own.towed.setup({"max_tow_length_m": 400.0, "stream_rate_m_s": 20.0})
	own.towed.stream()
	own.towed.actual_tow_length_m = 400.0
	own.towed.settle_factor = 1.0
	return own


func _mk_op(seed: int) -> OperatorSonar:
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	op.setup({"env": _mk_env(), "own": _mk_own(), "rng": rng})
	op.set_array("TOWED")
	return op


## 高 SL 目标（保证每行稳定出 A/B 峰，pd≈1）。
func _mk_target(east: float, north: float) -> Dictionary:
	var tgt := TruthEntity.new()
	tgt.id = "T1"
	tgt.position_east_m = east
	tgt.position_north_m = north
	tgt.speed_kn = 6.0
	tgt.depth_m = 0.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 195.0})
	return {"targets": [tgt], "acs": {"T1": ac}}


func _mk_meas(brg: float, t: float, ev: String, pair: String, branch: int) -> Measurement:
	var m := Measurement.new()
	m.timestamp = t
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.0
	m.detected = true
	m.evidence_id = ev
	m.ambiguous_pair_id = pair
	m.ambiguity_branch = branch
	m.sensor_id = "OP_TOWED"
	return m


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.3f want=%.3f±%.3f" % [name, got, want, tol])


# ------------------------------------------------------------------
#  C1：连续五次 TOWED 手动 Mark 不分裂（第 3 次改点另一支）
# ------------------------------------------------------------------


func _c1_marks_no_split(fails: Array) -> void:
	var op := _mk_op(101)
	var td: Dictionary = _mk_target(1500.0, 3500.0)
	var tracker := Tracker.new()
	var selected: String = ""
	var tr: Track = null
	for i in range(1, 6):
		var t: float = 10.0 * i
		op.update(t, td["targets"], td["acs"])
		var row: Dictionary = op.bb_rows[-1]
		# 第 3 次点击 B 支（-1），其余点 A 支（+1）——点击哪支不得决定真假/分裂
		var want_branch: int = -1 if i == 3 else 1
		var peak: Dictionary = {}
		for pk in row.get("peaks", []):
			if int(pk.get("ambiguity_branch", 0)) == want_branch:
				peak = pk
				break
		if peak.is_empty():
			fails.append(
				"C1 row %d missing branch=%d peak (rows=%d)" % [i, want_branch, op.bb_rows.size()]
			)
			return
		var grp: Array = op.create_mark_group(float(peak["bearing_deg"]), t, "", false, row)
		if grp.is_empty():
			fails.append("C1 mark %d produced empty group" % i)
			return
		var pm: Measurement = grp[0] as Measurement
		if selected == "":
			tr = tracker.mark(pm, "M")
			for j in range(1, grp.size()):
				tr.add_measurement(grp[j] as Measurement)
		else:
			tr = tracker.feed_evidence_group(grp, selected, 8.0)
			if tr == null:
				fails.append("C1 mark %d split: could not associate to selected %s" % [i, selected])
				return
		selected = tr.track_id
	# 验收：一个 Track、五个物理 evidence、十个候选行；没有第二个接触
	if tracker.count() != 1:
		fails.append("C1 tracker.count=%d want=1" % tracker.count())
		return
	_assert_bool(fails, "C1 single track evidence_count=5", tr.evidence_count() == 5, true)
	_assert_bool(fails, "C1 candidate rows=10", tr.measurement_history.size() == 10, true)
	_assert_bool(fails, "C1 track_id stable S01", tr.track_id == "M01", true)


# ------------------------------------------------------------------
#  C2：Autocrew 跨五个到达时刻不分裂
# ------------------------------------------------------------------


func _c2_autocrew_no_split(fails: Array) -> void:
	var op := _mk_op(202)
	var td: Dictionary = _mk_target(1500.0, 3500.0)
	var tracker := Tracker.new()
	for i in range(1, 6):
		var t: float = 10.0 * i
		op.update(t, td["targets"], td["acs"])
		var auto_ms: Array = op.autocrew_step(t)
		if auto_ms.is_empty():
			fails.append("C2 autocrew %d produced no measurements" % i)
			return
		# 与 main_ui._op_step 相同的按 evidence 分组消费，但走 evidence-group API
		var i2: int = 0
		while i2 < auto_ms.size():
			var pm: Measurement = auto_ms[i2]
			var grp: Array = [pm]
			i2 += 1
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
	if tracker.count() != 1:
		fails.append("C2 autocrew tracker.count=%d want=1" % tracker.count())
		return
	var tr: Track = tracker.all_tracks()[0]
	_assert_bool(fails, "C2 autocrew evidence_count=5", tr.evidence_count() == 5, true)
	_assert_bool(fails, "C2 autocrew rows=10", tr.measurement_history.size() == 10, true)


# ------------------------------------------------------------------
#  C3：TMA 门槛按物理 evidence（P0-03 数据语义）
# ------------------------------------------------------------------


func _c3_evidence_gate(fails: Array) -> void:
	# 拖曳阵：2 evidence = 4 candidate rows（每 evidence 一对 A/B）→ 不可拟合
	var ta: Track = Track.new()
	ta.track_id = "S01"
	ta.add_measurement(_mk_meas(40.0, 10.0, "e1", "p1", 1))
	ta.add_measurement(_mk_meas(-40.0, 10.0, "e1", "p1", -1))
	ta.add_measurement(_mk_meas(41.0, 20.0, "e2", "p2", 1))
	ta.add_measurement(_mk_meas(-41.0, 20.0, "e2", "p2", -1))
	_assert_bool(fails, "C3 2-evidence rows=4", ta.measurement_history.size() == 4, true)
	_assert_bool(fails, "C3 2-evidence count=2", ta.evidence_count() == 2, true)
	# 若 UI 门槛按 size>=4：4 rows 会被误放行 → 断言"不应放行"（修复语义）
	var gate_rows: bool = ta.measurement_history.size() >= 4
	var gate_ev: bool = ta.evidence_count() >= 4
	_assert_bool(fails, "C3 2-evidence must reject by evidence", gate_ev, false)
	if gate_rows and not gate_ev:
		pass  # 行门槛误放行但证据门槛拒绝 —— 正是要修的 P0-03（此处仅记录语义）
	# 4 evidence = 8 rows → 允许拟合
	var tb: Track = Track.new()
	tb.track_id = "S02"
	for k in range(1, 5):
		var ev: String = "e%d" % k
		tb.add_measurement(_mk_meas(40.0 + k, 10.0 * k, ev, "p%d" % k, 1))
		tb.add_measurement(_mk_meas(-40.0 - k, 10.0 * k, ev, "p%d" % k, -1))
	_assert_bool(fails, "C3 4-evidence rows=8", tb.measurement_history.size() == 8, true)
	_assert_bool(fails, "C3 4-evidence count=4", tb.evidence_count() == 4, true)
	_assert_bool(fails, "C3 4-evidence passes gate", tb.evidence_count() >= 4, true)


# ------------------------------------------------------------------
#  C4：阵列中心方位一致性（P0-02，评审 TEST-05 几何）
# ------------------------------------------------------------------


func _c4_array_center_bearing(fails: Array) -> void:
	var op := _mk_op(303)
	# target=(1732,770)、own=(0,0)、阵心=(0,-230)、阵轴 0°
	# 从阵心看 delta=(1732,1000) → bearing=60°；从艇心看 ≈66°（系统误差来源）
	var td: Dictionary = _mk_target(1732.0, 770.0)
	op.update(10.0, td["targets"], td["acs"])
	if op.bb_rows.is_empty():
		fails.append("C4 no TOWED row generated")
		return
	var row: Dictionary = op.bb_rows[-1]
	var peak: Dictionary = {}
	for pk in row.get("peaks", []):
		if int(pk.get("ambiguity_branch", 0)) == 1:
			peak = pk
			break
	if peak.is_empty():
		fails.append("C4 row missing branch=+1 peak")
		return
	var grp: Array = op.create_mark_group(float(peak["bearing_deg"]), 10.0, "", false, row)
	if grp.is_empty():
		fails.append("C4 mark produced empty group")
		return
	var m: Measurement = grp[0] as Measurement
	# 观察站位 = 阵列声学中心（own course 0 / 阵轴 0 → 正后方 230m）
	_assert_close(fails, "C4 observer_east", m.observer_east_m, 0.0, 5.0)
	_assert_close(fails, "C4 observer_north", m.observer_north_m, -230.0, 5.0)
	# 真方位从 observer 出发 ≈60°（修复前 ≈66°）
	_assert_close(fails, "C4 true bearing from array center", m.measured_bearing_deg, 60.0, 2.0)
	# LOB（observer + bearing）应穿过目标：点到直线距离 < 60m
	var rad: float = m.measured_bearing_deg * NavUtils.DEG_TO_RAD
	var dir := Vector2(sin(rad), cos(rad))
	var obs := Vector2(m.observer_east_m, m.observer_north_m)
	var tgt_pos := Vector2(1732.0, 770.0)
	var to_tgt: Vector2 = tgt_pos - obs
	var along: float = to_tgt.dot(dir)
	var closest: Vector2 = obs + dir * along
	_assert_close(fails, "C4 LOB passes target", closest.distance_to(tgt_pos), 0.0, 60.0)
	# TL 距离基准 = 阵心距离 ~2000m（非艇心 ~1896m）
	_assert_close(fails, "C4 observer range to target", obs.distance_to(tgt_pos), 2000.0, 20.0)
