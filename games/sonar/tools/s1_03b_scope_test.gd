extends SceneTree
## s1_03b_scope_test.gd — S1-03B 阵列数据作用域 + 拖曳阵歧义呈现 无头验收。
##
## 背景 bug：为实现拖曳阵真假方位，把"一个证据的两个候选解释"做成了
## "两条全局普通测量"，物理层/解算层/显示层没有隔离：
##   ① BB/NB/DEMON 共用单一行缓冲 → 切阵列后拖曳阵双峰残留其它阵列视图；
##   ② 行未固化来源阵列 → 点击旧 TOWED 行时用当前 active_array_id 生成
##      "OP_BOW + 拖曳镜像字段"的错配测量；
##   ③ 海图把 A/B 镜像两条都当普通实线 LOB（同等级），无 LR AMBIGUOUS 弱化。
##
## 覆盖（对照 S1-03B 核心要求与验收重点）：
##   S1  BB/NB/DEMON 每阵列独立缓冲：TOWED 双峰只进 TOWED 缓冲；切 BOW 后
##       BOW 瀑布为空/单峰无歧义（双峰立即消失）；切回 TOWED 独立历史恢复。
##   S2  每声呐行固化 array_id/sensor_id/bearing_frame/timestamp（bb/nb/demon）。
##   S3  历史行 Mark 使用 row.array_id：TOWED 行在 BOW active 下仍产出
##       OP_TOWED/阵心观测/歧义保留；BOW 行在 TOWED active 下产出 OP_BOW/
##       艇心观测/无歧义——绝不产生"新传感器 + 旧阵拖曳字段"错配。
##   S4  点击 BOW/FLANK 行不产生镜像 Measurement（create_mark_group size==1）；
##       普通 BOW/FLANK 测量 ambiguous_pair_id 空、ambiguity_branch==0。
##   S5  显示层隔离：TmaUiData.lob_entries 对同一 evidence 恰产生 1 条同等级
##       普通 LOB + 1 条 mirror（细虚线/半透明）；无歧义 Track 全非 mirror。
##
## 全部确定性（固定种子/解析构造），可无头运行：
##   godot --headless --path games/sonar --script res://tools/s1_03b_scope_test.gd


func _initialize() -> void:
	var fails: Array = []
	_s1_buffers_per_array(fails)
	_s2_row_context_frozen(fails)
	_s3_historical_mark_uses_row_array(fails)
	_s4_hull_array_no_mirror(fails)
	_s5_lob_mirror_isolation(fails)
	if fails.is_empty():
		print("S1_03B_SCOPE_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("S1_03B_SCOPE_TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ------------------------------------------------------------------
#  场景构造（与 towed_test T7/T8 同款确定性环境）
# ------------------------------------------------------------------


func _mk_env() -> EnvironmentModel:
	var env := EnvironmentModel.new()
	(
		env
		. from_dict(
			{
				"ambient_noise_by_frequency": {"500": 60.0},
				"own_noise_base_db": 40.0,
				"own_noise_speed_coeff": 2.0,
				"tl_spreading_k": 20.0,
				"tl_absorption_alpha": 0.5,
				"tl_environment_loss": 2.0,
			}
		)
	)
	return env


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
	return op


func _mk_targets() -> Dictionary:
	var tgt := TruthEntity.new()
	tgt.id = "T1"
	tgt.position_east_m = 1732.0
	tgt.position_north_m = 770.0
	tgt.speed_kn = 10.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 180.0})
	return {"targets": [tgt], "acs": {"T1": ac}}


## 合成行：手动构造确定性的 BOW/FLANK 历史行（单峰、无歧义、艇心站位）。
func _mk_synth_row(aid: String, brg: float, t: float) -> Dictionary:
	return {
		"t": t,
		"array_id": aid,
		"sensor_id": "OP_" + aid,
		"bearing_frame": "bow_rel",
		"course": 0.0,
		"array_heading": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"tow_center_m": 0.0,
		"tow_length_m": 0.0,
		"peaks":
		[
			{
				"bearing_deg": brg,
				"level_db": 20.0,
				"se_db": 20.0,
				"snr_db": 20.0,
				"ambiguous_pair_id": "",
				"ambiguity_branch": 0,
			}
		],
	}


# ------------------------------------------------------------------
#  S1：每阵列独立缓冲（双峰只属于 TOWED）
# ------------------------------------------------------------------


func _s1_buffers_per_array(fails: Array) -> void:
	var w: Dictionary = _mk_targets()
	var op := _mk_op(20260903)
	op.set_array("TOWED")
	# TOWED 阶段：3 行、每行双 A/B 峰
	op.update(0.0, w["targets"], w["acs"])
	op.update(2.0, w["targets"], w["acs"])
	op.update(4.0, w["targets"], w["acs"])
	_assert_bool(fails, "S1 TOWED has 3 rows", op.bb_rows.size() == 3, true)
	if op.bb_rows.size() != 3:
		return
	var tow_peaks: Array = op.bb_rows[-1]["peaks"]
	_assert_bool(fails, "S1 TOWED row has A/B pair", tow_peaks.size() == 2, true)
	if tow_peaks.size() == 2:
		_assert_bool(
			fails,
			"S1 TOWED pair shares id",
			(
				str(tow_peaks[0].get("ambiguous_pair_id", "")) != ""
				and str(tow_peaks[0]["ambiguous_pair_id"]) == str(tow_peaks[1]["ambiguous_pair_id"])
			),
			true,
		)
	# 切 BOW：新缓冲为空 → 双峰立即从当前视图消失
	op.set_array("BOW")
	_assert_bool(fails, "S1 BOW buffer starts empty", op.bb_rows.is_empty(), true)
	# BOW 阶段产 2 行：即使有峰也绝不带歧义字段
	op.update(6.0, w["targets"], w["acs"])
	op.update(8.0, w["targets"], w["acs"])
	_assert_bool(fails, "S1 BOW has 2 rows", op.bb_rows.size() == 2, true)
	if op.bb_rows.size() == 2:
		for r in op.bb_rows:
			_assert_bool(fails, "S1 BOW row array_id", str(r["array_id"]) == "BOW", true)
			for pk in r["peaks"]:
				_assert_bool(
					fails,
					"S1 BOW peak never ambiguous",
					str(pk.get("ambiguous_pair_id", "")) == "",
					true,
				)
	# TOWED 独立历史未丢，切回立即恢复
	var tow_hist: Array = op.rows_by_array["TOWED"]["bb"]
	_assert_bool(fails, "S1 TOWED history preserved", tow_hist.size() == 3, true)
	op.set_array("TOWED")
	_assert_bool(fails, "S1 switch back restores TOWED rows", op.bb_rows.size() == 3, true)
	_assert_bool(
		fails, "S1 BOW history kept separate", op.rows_by_array["BOW"]["bb"].size() == 2, true
	)
	# NB/DEMON 缓冲同样按阵列隔离
	_assert_bool(
		fails,
		"S1 TOWED nb rows",
		(
			op.rows_by_array["TOWED"]["nb"].size() == 3
			and op.rows_by_array["TOWED"]["demon"].size() == 3
		),
		true,
	)


# ------------------------------------------------------------------
#  S2：每行固化来源字段
# ------------------------------------------------------------------


func _s2_row_context_frozen(fails: Array) -> void:
	var w: Dictionary = _mk_targets()
	var op := _mk_op(7)
	op.set_array("TOWED")
	op.update(0.0, w["targets"], w["acs"])
	op.update(2.0, w["targets"], w["acs"])
	var row: Dictionary = op.bb_rows[-1]
	_assert_bool(fails, "S2 row array_id", str(row.get("array_id", "")) == "TOWED", true)
	_assert_bool(fails, "S2 row sensor_id", str(row.get("sensor_id", "")) == "OP_TOWED", true)
	_assert_bool(
		fails, "S2 row bearing_frame", str(row.get("bearing_frame", "")) == "bow_rel", true
	)
	_assert_bool(fails, "S2 row has t", row.has("t") and float(row["t"]) > 0.0, true)
	_assert_bool(fails, "S2 row has array_heading", row.has("array_heading"), true)
	_assert_bool(fails, "S2 row has own station", row.has("own_e") and row.has("own_n"), true)
	# nb/demon 行固化 array_id/sensor_id
	_assert_bool(
		fails,
		"S2 nb/demon frozen",
		(
			str(op.nb_rows[-1].get("array_id", "")) == "TOWED"
			and str(op.nb_rows[-1].get("sensor_id", "")) == "OP_TOWED"
			and str(op.demon_rows[-1].get("array_id", "")) == "TOWED"
		),
		true,
	)


# ------------------------------------------------------------------
#  S3：历史行 Mark 必须用 row.array_id（禁止 active_array_id 定来源）
# ------------------------------------------------------------------


func _s3_historical_mark_uses_row_array(fails: Array) -> void:
	var w: Dictionary = _mk_targets()
	var op := _mk_op(11)
	# 先在 TOWED active 下采集真实拖曳行（含 A/B 峰与阵心），再切到 BOW
	op.set_array("TOWED")
	op.update(0.0, w["targets"], w["acs"])
	op.update(2.0, w["targets"], w["acs"])
	var tow_row: Dictionary = op.bb_rows[-1]
	op.set_array("BOW")
	_assert_bool(fails, "S3 active is now BOW", op.active_array_id == "BOW", true)
	if tow_row["peaks"].is_empty():
		fails.append("S3 no TOWED peak available to click")
		return
	var tow_click: float = float(tow_row["peaks"][0]["bearing_deg"])
	var grp_tow: Array = op.create_mark_group(tow_click, 0.0, "", true, tow_row)
	_assert_bool(fails, "S3 TOWED row in BOW ctx -> pair", grp_tow.size() == 2, true)
	if grp_tow.size() != 2:
		return
	var m_tow: Measurement = grp_tow[0]
	_assert_bool(fails, "S3 sensor from row (OP_TOWED)", m_tow.sensor_id == "OP_TOWED", true)
	# 观察站位用 row 的阵心（own_n 0 − 230 = −230），不是 BOW 艇心
	_assert_close(fails, "S3 TOWED row observer-n", m_tow.observer_north_m, -230.0, 2.0)
	_assert_bool(fails, "S3 TOWED row keeps ambiguity", m_tow.has_ambiguity(), true)

	# 反向：BOW 行在 TOWED active 下点击 → OP_BOW / 艇心 / 无歧义
	op.set_array("TOWED")
	_assert_bool(fails, "S3 active is now TOWED", op.active_array_id == "TOWED", true)
	var row_b: Dictionary = _mk_synth_row("BOW", 66.0, 6.0)
	var m_b: Measurement = op.create_mark(66.0, 6.0, "", true, row_b)
	_assert_bool(fails, "S3 BOW row sensor OP_BOW", m_b.sensor_id == "OP_BOW", true)
	_assert_close(fails, "S3 BOW row observer at own", m_b.observer_north_m, 0.0, 1e-6)
	_assert_bool(fails, "S3 BOW row no ambiguity", not m_b.has_ambiguity(), true)
	_assert_bool(fails, "S3 BOW row empty pair field", m_b.ambiguous_pair_id == "", true)
	_assert_bool(fails, "S3 BOW row branch 0", m_b.ambiguity_branch == 0, true)
	# FLANK 行同理（合成）
	var row_f: Dictionary = _mk_synth_row("FLANK", -80.0, 7.0)
	var m_f: Measurement = op.create_mark(-80.0, 7.0, "", true, row_f)
	_assert_bool(fails, "S3 FLANK row sensor OP_FLANK", m_f.sensor_id == "OP_FLANK", true)
	_assert_bool(fails, "S3 FLANK row no ambiguity", not m_f.has_ambiguity(), true)


# ------------------------------------------------------------------
#  S4：点击 BOW/FLANK 行不产生镜像 Measurement（一次到达一个候选）
# ------------------------------------------------------------------


func _s4_hull_array_no_mirror(fails: Array) -> void:
	var op := _mk_op(13)
	# active=TOWED 时点击 BOW/FLANK 历史行也绝不生成镜像
	op.set_array("TOWED")
	var g_b: Array = op.create_mark_group(66.0, 6.0, "", true, _mk_synth_row("BOW", 66.0, 6.0))
	_assert_bool(fails, "S4 BOW click group size 1", g_b.size() == 1, true)
	var g_f: Array = op.create_mark_group(-80.0, 7.0, "", true, _mk_synth_row("FLANK", -80.0, 7.0))
	_assert_bool(fails, "S4 FLANK click group size 1", g_f.size() == 1, true)
	# 镜像歧义只可能来自 mirror_lr 的 TOWED 行
	var tow_row: Dictionary = _mk_synth_row("TOWED", 66.0, 6.0)
	(
		tow_row
		. merge(
			{
				"tow_center_m": 230.0,
				"tow_length_m": 400.0,
				"peaks":
				[
					{
						"bearing_deg": 66.0,
						"level_db": 20.0,
						"se_db": 20.0,
						"snr_db": 20.0,
						"ambiguous_pair_id": "AMB0001",
						"ambiguity_branch": 1,
					}
				],
			},
			true
		)
	)
	var g_t: Array = op.create_mark_group(66.0, 6.0, "", true, tow_row)
	_assert_bool(fails, "S4 TOWED ambiguous row -> pair", g_t.size() == 2, true)
	if g_t.size() == 2:
		_assert_bool(
			fails,
			"S4 pair shares evidence_id",
			g_t[0].evidence_id == g_t[1].evidence_id and g_t[0].evidence_id != "",
			true,
		)
		_assert_bool(
			fails,
			"S4 opposite branches",
			(
				(g_t[0].ambiguity_branch == 1 and g_t[1].ambiguity_branch == -1)
				or (g_t[0].ambiguity_branch == -1 and g_t[1].ambiguity_branch == 1)
			),
			true,
		)


# ------------------------------------------------------------------
#  S5：显示层隔离 —— lob_entries 同一 evidence 恰 1 实线 + 1 mirror
# ------------------------------------------------------------------


func _s5_lob_mirror_isolation(fails: Array) -> void:
	var op := _mk_op(17)
	var tow_row: Dictionary = _mk_synth_row("TOWED", 66.0, 6.0)
	tow_row["tow_center_m"] = 230.0
	tow_row["peaks"] = [
		{
			"bearing_deg": 66.0,
			"level_db": 20.0,
			"se_db": 20.0,
			"snr_db": 20.0,
			"ambiguous_pair_id": "AMB0099",
			"ambiguity_branch": 1,
		}
	]
	var grp: Array = op.create_mark_group(66.0, 6.0, "", true, tow_row)
	_assert_bool(fails, "S5 pair produced", grp.size() == 2, true)
	if grp.size() != 2:
		return
	var tracker := Tracker.new()
	var t: Track = tracker.mark(grp[0], "M")
	t.add_measurement(grp[1])
	var lobs: Array = TmaUiData.lob_entries(t, Color(0.9, 0.5, 0.1), true, {})
	_assert_bool(fails, "S5 two lob entries", lobs.size() == 2, true)
	if lobs.size() != 2:
		return
	var mirror_n: int = 0
	var main_n: int = 0
	for lob in lobs:
		if bool(lob.get("mirror", false)):
			mirror_n += 1
		else:
			main_n += 1
	_assert_bool(fails, "S5 exactly 1 mirror per evidence", mirror_n == 1, true)
	_assert_bool(fails, "S5 exactly 1 main per evidence", main_n == 1, true)
	# 普通 BOW/FLANK Track：全非 mirror（不会出现两条同等级以外的东西）
	var t2: Track = tracker.mark(_mk_plain("BOW", 30.0, 8.0), "M")
	var lobs2: Array = TmaUiData.lob_entries(t2, Color(0.2, 0.8, 0.3), true, {})
	for lob in lobs2:
		_assert_bool(fails, "S5 hull lob never mirror", not bool(lob.get("mirror", false)), true)


func _mk_plain(aid: String, brg: float, t: float) -> Measurement:
	var m := Measurement.new()
	m.timestamp = t
	m.sensor_id = "OP_" + aid
	m.detected = true
	m.evidence_id = "ev_plain_%s_%d" % [aid, int(t)]
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.0
	m.observer_east_m = 0.0
	m.observer_north_m = 0.0
	return m


# ------------------------------------------------------------------
#  断言工具
# ------------------------------------------------------------------


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f tol=%.4f" % [name, got, want, tol])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
