extends SceneTree
## towed_test.gd — S1-03/S1-03A/S1-06 拖曳阵 无头验收。
##
## 覆盖（对照《阶段一/阶段二整合需求》）：
##   T1  S1-03 状态机初态：STOWED 全收、无声学孔径、阵轴在 STOWED 下直接跟随本艇。
##   T2  S1-03 可控长度：STREAM/HOLD/RETRIEVE，任意长度可停可反向；
##       实际缆长按固定收放速率逼近命令缆长（ACT/CMD 分离）。
##   T3  S1-03 部分长度性能：孔径比例 q_L 连续变化，回收第一帧起性能连续下降，
##       绝不"开始回收即静音"；收回后 is_acoustically_active=false。
##   T4  S1-03 阵轴滞后 tau 与实际缆长+本艇实际航速相关（慢速更"飘"、快速拖直）。
##   T5  S1-03 阵列声学中心站位 p_array = p_own − d_center·[sin ψa, cos ψa]。
##   T6  S1-03 无拖曳硬件：towed_available()=false、可用度=0（无虚构回退）；
##       TruthEntity.advance 注入实际航速推进 towed。
##   T7  S1-03A 镜像歧义：TOWED 单峰产生共享 pair_id/SE/噪声的 A/B 候选；
##       create_mark_group 镜像支 θ_B = 2ψa − θ_A；Measurement 序列化携带歧义字段。
##   T8  S1-03A Tracker 不重复：镜像候选进同一 Track（不建第二个目标）。
##   T9  S1-06 TMA 分支消歧：直航不消歧（可观测性不足）；机动后分支权重拉开，
##       mirror_resolved=true；同一拟合绝不双计镜像对。
##
## 全部确定性（固定种子/无噪声或解析构造），可无头运行：
##   godot --headless --path games/sonar --script res://tools/towed_test.gd


func _initialize() -> void:
	var fails: Array = []

	_t1_stowed_initial(fails)
	_t2_stream_hold_reverse(fails)
	_t3_aperture_continuity(fails)
	_t4_speed_dependent_tau(fails)
	_t5_array_center_station(fails)
	_t6_no_hardware_and_advance(fails)
	_t7_mirror_pair(fails)
	_t8_tracker_no_double_count(fails)
	_t9_tma_branch_disambiguation(fails)

	if fails.is_empty():
		print("TOWED_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("TOWED_TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ------------------------------------------------------------------
#  T1：STOWED 初态
# ------------------------------------------------------------------


func _t1_stowed_initial(fails: Array) -> void:
	var t := TowedArray.new()
	t.setup({})
	_assert_bool(fails, "T1 initial STOWED", t.state == TowedArray.State.STOWED, true)
	_assert_close(fails, "T1 stowed length=0", t.actual_tow_length_m, 0.0, 1e-6)
	_assert_close(fails, "T1 stowed aperture=0", t.aperture_fraction(), 0.0, 1e-6)
	_assert_bool(fails, "T1 stowed inactive", t.is_acoustically_active(), false)
	_assert_close(fails, "T1 stowed usable=0", t.usable_fraction(), 0.0, 1e-6)
	# STOWED 时阵在艇上：阵轴直接跟随本艇航向
	t.step(1.0, 137.0)
	_assert_close(fails, "T1 stowed heading follows own", t.array_heading_deg, 137.0, 1e-6)
	# 兼容旧键：tow_length_m/deploy_time_s 折算
	var t1b := TowedArray.new()
	t1b.setup({"tow_length_m": 400.0, "deploy_time_s": 100.0})
	_assert_close(fails, "T1 legacy tow_length_m", t1b.max_tow_length_m, 400.0, 1e-6)
	_assert_close(fails, "T1 legacy deploy->rate", t1b.stream_rate_m_s, 4.0, 1e-6)


# ------------------------------------------------------------------
#  T2：STREAM / HOLD / RETRIEVE 与反向
# ------------------------------------------------------------------


func _t2_stream_hold_reverse(fails: Array) -> void:
	var t := TowedArray.new()
	t.setup({"max_tow_length_m": 400.0, "stream_rate_m_s": 6.0, "retrieve_rate_m_s": 8.0})
	# 放缆到 160m（不足全长）：STREAMING，速率恒定
	t.stream(160.0)
	_assert_bool(fails, "T2 stream->STREAMING", t.state == TowedArray.State.STREAMING, true)
	_assert_close(fails, "T2 cmd=160", t.commanded_tow_length_m, 160.0, 1e-6)
	for _i in range(10):
		t.step(1.0, 0.0)
	_assert_close(fails, "T2 length after 10s", t.actual_tow_length_m, 60.0, 1e-6)
	for _i in range(17):
		t.step(1.0, 0.0)
	_assert_close(fails, "T2 length reaches cmd", t.actual_tow_length_m, 160.0, 1e-6)
	_assert_bool(fails, "T2 reached->HOLD_PARTIAL", t.state == TowedArray.State.HOLD_PARTIAL, true)
	# HOLD：命令锁定当前长度，缆长不变
	t.hold()
	_assert_bool(fails, "T2 hold->HOLD_PARTIAL", t.state == TowedArray.State.HOLD_PARTIAL, true)
	for _i in range(10):
		t.step(1.0, 0.0)
	_assert_close(fails, "T2 hold keeps length", t.actual_tow_length_m, 160.0, 1e-6)
	# 反向：HOLD 中直接收缆（RETRIEVING），再反向放缆
	t.retrieve()
	_assert_bool(fails, "T2 retrieve->RETRIEVING", t.state == TowedArray.State.RETRIEVING, true)
	for _i in range(5):
		t.step(1.0, 0.0)
	_assert_close(fails, "T2 retrieving at 8m/s", t.actual_tow_length_m, 120.0, 1e-6)
	t.stream(400.0)
	_assert_bool(fails, "T2 reverse->STREAMING", t.state == TowedArray.State.STREAMING, true)
	for _i in range(5):
		t.step(1.0, 0.0)
	_assert_close(fails, "T2 re-streaming at 6m/s", t.actual_tow_length_m, 150.0, 1e-6)
	# 全收后回 STOWED
	t.retrieve()
	for _i in range(30):
		t.step(1.0, 0.0)
	_assert_bool(fails, "T2 fully retrieved->STOWED", t.state == TowedArray.State.STOWED, true)


# ------------------------------------------------------------------
#  T3：部分长度声学性能连续（回收不瞬间静音）
# ------------------------------------------------------------------


func _t3_aperture_continuity(fails: Array) -> void:
	var t := TowedArray.new()
	t.setup({"max_tow_length_m": 400.0, "dead_length_m": 60.0, "stream_rate_m_s": 8.0})
	t.stream()
	for _i in range(50):
		t.step(1.0, 0.0)
	_assert_close(fails, "T3 full length", t.actual_tow_length_m, 400.0, 1e-6)
	_assert_close(fails, "T3 full aperture=1", t.aperture_fraction(), 1.0, 1e-6)
	_assert_close(fails, "T3 settled usable=1", t.usable_fraction(), 1.0, 1e-4)
	# 开始回收：第一帧起性能连续下降（360m 时 q_L≈0.88，仍然活跃）
	t.retrieve()
	for _i in range(5):
		t.step(1.0, 0.0)
	_assert_close(fails, "T3 length 360 after 5s", t.actual_tow_length_m, 360.0, 1e-6)
	_assert_close(
		fails, "T3 aperture still ~0.88", t.aperture_fraction(), (360.0 - 60.0) / 340.0, 1e-3
	)
	_assert_bool(fails, "T3 still active while >dead", t.is_acoustically_active(), true)
	_assert_bool(fails, "T3 usable degraded but >0.5", t.usable_fraction() > 0.5, true)
	# 收到死区以下：无声学孔径，绝不产生测量
	for _i in range(50):
		t.step(1.0, 0.0)
	_assert_bool(fails, "T3 below dead inactive", t.is_acoustically_active(), false)
	# 孔径增益项：q_L=0.5 → 10log10(0.5) ≈ −3.01 dB
	var t2 := TowedArray.new()
	t2.setup({"max_tow_length_m": 400.0, "dead_length_m": 60.0})
	t2.actual_tow_length_m = 230.0  # q_L=(230-60)/340=0.5
	_assert_close(fails, "T3 aperture gain -3dB", t2.gain_penalty_db(), -3.01, 0.05)


# ------------------------------------------------------------------
#  T4：阵轴滞后 tau 与缆长、本艇实际航速相关
# ------------------------------------------------------------------


func _t4_speed_dependent_tau(fails: Array) -> void:
	var slow := TowedArray.new()
	var fast := TowedArray.new()
	var cfg: Dictionary = {
		"max_tow_length_m": 400.0,
		"stream_rate_m_s": 20.0,
		"full_length_heading_tau_s": 45.0,
		"short_length_heading_tau_s": 8.0,
		"ref_align_speed_ms": 2.5,
	}
	slow.setup(cfg)
	fast.setup(cfg)
	for a in [slow, fast]:
		a.stream()
		for _i in range(25):
			a.step(1.0, 0.0)  # 全放并沉降在 0°
	_assert_bool(
		fails, "T4 both settled at 0", slow.settle_factor == 1.0 and fast.settle_factor == 1.0, true
	)
	# 同样转 90° 推进 20s：慢速(0.5m/s) tau×2.5 更飘，快速(5m/s) tau×0.5 拖直
	for _i in range(20):
		slow.step(1.0, 90.0, 0.5)
		fast.step(1.0, 90.0, 5.0)
	var hs: float = slow.array_heading_deg
	var hf: float = fast.array_heading_deg
	_assert_bool(fails, "T4 fast aligns faster (hf>hs)", hf > hs + 5.0, true)
	_assert_bool(fails, "T4 both lag behind 90", hf < 85.0 and hs < 85.0, true)
	# 长期收敛到 90（慢速用更长时间）
	for _i in range(600):
		slow.step(1.0, 90.0, 0.5)
		fast.step(1.0, 90.0, 5.0)
	_assert_close(fails, "T4 slow converges to 90", slow.array_heading_deg, 90.0, 3.0)
	_assert_close(fails, "T4 fast converges to 90", fast.array_heading_deg, 90.0, 3.0)
	_assert_bool(fails, "T4 settled usable~1 after converge", slow.usable_fraction() > 0.95, true)


# ------------------------------------------------------------------
#  T5：阵列声学中心站位
# ------------------------------------------------------------------


func _t5_array_center_station(fails: Array) -> void:
	var t := TowedArray.new()
	t.setup({"max_tow_length_m": 400.0, "dead_length_m": 60.0})
	# L=340>dead：d_center = 0.5*(60+340)=200，阵轴朝北(0°) → 阵心在本艇南方 200m
	t.actual_tow_length_m = 340.0
	t.array_heading_deg = 0.0
	var c: Vector2 = t.array_center_position(0.0, 0.0)
	_assert_close(fails, "T5 center east=0", c.x, 0.0, 1e-6)
	_assert_close(fails, "T5 center north=-200", c.y, -200.0, 1e-6)
	# 阵轴朝东(90°) → 阵心在本艇西方 200m
	t.array_heading_deg = 90.0
	c = t.array_center_position(1000.0, 500.0)
	_assert_close(fails, "T5 center east=800", c.x, 800.0, 1e-6)
	_assert_close(fails, "T5 center north=500", c.y, 500.0, 1e-6)
	# L<=dead：d_center = 0.5*L
	t.actual_tow_length_m = 40.0
	t.array_heading_deg = 0.0
	c = t.array_center_position(0.0, 0.0)
	_assert_close(fails, "T5 short cable center=-20", c.y, -20.0, 1e-6)


# ------------------------------------------------------------------
#  T6：无硬件禁用 + TruthEntity 集成
# ------------------------------------------------------------------


func _t6_no_hardware_and_advance(fails: Array) -> void:
	# 无拖曳硬件：TOWED 不可用、可用度=0（不是 1！）
	var own_bare := TruthEntity.new()
	own_bare.course_deg = 0.0
	own_bare.speed_kn = 6.0
	var op := OperatorSonar.new()
	op.setup({"env": EnvironmentModel.new(), "own": own_bare, "rng": RandomNumberGenerator.new()})
	op.set_array("TOWED")
	_assert_bool(fails, "T6 no hardware towed_available=false", op.towed_available(), false)
	_assert_close(fails, "T6 no hardware usable=0", op._towed_usable_factor(), 0.0, 1e-6)
	# 无硬件 update() 也不产生任何 TOWED 行内峰
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 180.0})
	var tgt := TruthEntity.new()
	tgt.id = "T1"
	tgt.position_east_m = 1000.0
	tgt.position_north_m = 1000.0
	tgt.speed_kn = 10.0
	op.update(0.0, [tgt], {"T1": ac})
	_assert_bool(fails, "T6 no hardware -> no peaks", op.bb_rows[-1]["peaks"].is_empty(), true)
	# 有硬件：advance 注入实际航速推进 towed（含沉降收敛）
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 6.0
	own.towed = TowedArray.new()
	own.towed.setup(
		{"max_tow_length_m": 400.0, "stream_rate_m_s": 10.0, "full_length_heading_tau_s": 30.0}
	)
	own.towed.stream()
	for _i in range(60):
		own.advance(1.0)
	_assert_close(
		fails, "T6 towed streamed via advance", own.towed.actual_tow_length_m, 400.0, 1e-6
	)
	own.course_deg = 45.0
	for _i in range(200):
		own.advance(1.0)
	_assert_close(fails, "T6 array heading follows to 45", own.get_array_heading_deg(), 45.0, 3.0)


# ------------------------------------------------------------------
#  T7：S1-03A 镜像歧义对（共享 pair_id / SE / 噪声）
# ------------------------------------------------------------------


func _t7_mirror_pair(fails: Array) -> void:
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
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 6.0
	own.towed = TowedArray.new()
	own.towed.setup({"max_tow_length_m": 400.0, "stream_rate_m_s": 20.0})
	own.towed.stream()
	own.towed.actual_tow_length_m = 400.0
	own.towed.settle_factor = 1.0
	# 阵轴朝北(0°)，阵心在本艇后 230m；目标放在阵轴 60° 方向 2000m 处
	# 阵心=(0,-230)，目标=(0,−230)+2000·[sin60,cos60]=(1732, 770)
	var tgt := TruthEntity.new()
	tgt.id = "T1"
	tgt.position_east_m = 1732.0
	tgt.position_north_m = 770.0
	tgt.speed_kn = 10.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 180.0})
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260903
	op.setup({"env": env, "own": own, "rng": rng})
	op.set_array("TOWED")
	op.update(0.0, [tgt], {"T1": ac})
	var peaks: Array = op.bb_rows[-1]["peaks"]
	_assert_bool(fails, "T7 mirror produces 2 peaks", peaks.size() == 2, true)
	if peaks.size() != 2:
		return
	var pid: String = str(peaks[0].get("ambiguous_pair_id", ""))
	_assert_bool(
		fails, "T7 shared pair_id", pid != "" and str(peaks[1]["ambiguous_pair_id"]) == pid, true
	)
	var brs: Array = [
		absf(NavUtils.wrap180(float(peaks[0]["bearing_deg"]))),
		absf(NavUtils.wrap180(float(peaks[1]["bearing_deg"])))
	]
	_assert_bool(fails, "T7 peaks symmetric about axis", absf(brs[0] - brs[1]) < 1.0, true)
	_assert_close(fails, "T7 shared SE", float(peaks[0]["se_db"]), float(peaks[1]["se_db"]), 1e-6)
	var branches: Array = [int(peaks[0]["ambiguity_branch"]), int(peaks[1]["ambiguity_branch"])]
	_assert_bool(
		fails,
		"T7 branches +1/-1",
		(branches[0] == 1 and branches[1] == -1) or (branches[0] == -1 and branches[1] == 1),
		true
	)
	# create_mark_group：点其中一支 → 主测量 + 镜像测量（θ_B = 2ψa − θ_A）
	# 点击方位取实际峰的显示方位（本艇航向 0° 时 display==true），
	# 不依赖阵心/本艇视角的几何差（2000m 处约差 6°，贴近匹配容差）。
	var click_brg: float = float(peaks[0]["bearing_deg"])
	var row: Dictionary = op.bb_rows[-1]
	var group: Array = op.create_mark_group(click_brg, 0.0, "", true, row)
	_assert_bool(fails, "T7 mark_group returns pair", group.size() == 2, true)
	if group.size() != 2:
		return
	var pa: Measurement = group[0]
	var pb: Measurement = group[1]
	_assert_bool(fails, "T7 both ambiguous", pa.has_ambiguity() and pb.has_ambiguity(), true)
	_assert_bool(
		fails, "T7 same pair_id in marks", pa.ambiguous_pair_id == pb.ambiguous_pair_id, true
	)
	_assert_bool(fails, "T7 opposite branches", pa.ambiguity_branch == -pb.ambiguity_branch, true)
	var sum_brg: float = NavUtils.wrap360(pa.measured_bearing_deg + pb.measured_bearing_deg)
	# (ψa+β)+(ψa−β)=2ψa → 和 ≈ 2×阵轴（mod 360）
	var arr2: float = NavUtils.wrap360(2.0 * pa.array_heading_at_measurement_deg)
	_assert_close(fails, "T7 mirror sum=2*psi_a", sum_brg, arr2, 2.0)
	# 观察站位 = 阵心（不是本艇中心）
	_assert_close(fails, "T7 observer at array center-e", pa.observer_east_m, 0.0, 1.0)
	_assert_close(fails, "T7 observer at array center-n", pa.observer_north_m, -230.0, 2.0)
	# 序列化携带歧义字段
	var d: Dictionary = pa.to_dict()
	_assert_bool(
		fails,
		"T7 to_dict pair_id",
		str(d.get("ambiguous_pair_id", "")) == pa.ambiguous_pair_id,
		true
	)
	_assert_bool(
		fails, "T7 to_dict branch", int(d.get("ambiguity_branch", 99)) == pa.ambiguity_branch, true
	)


# ------------------------------------------------------------------
#  T8：Tracker 不重复计数（镜像候选进同一 Track）
# ------------------------------------------------------------------


func _t8_tracker_no_double_count(fails: Array) -> void:
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
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 6.0
	own.towed = TowedArray.new()
	own.towed.setup({"max_tow_length_m": 400.0, "stream_rate_m_s": 20.0})
	own.towed.stream()
	own.towed.actual_tow_length_m = 400.0
	own.towed.settle_factor = 1.0
	var tgt := TruthEntity.new()
	tgt.id = "T1"
	tgt.position_east_m = 1732.0
	tgt.position_north_m = 770.0
	tgt.speed_kn = 10.0
	var ac := AcousticProfile.new()
	ac.from_dict({"broadband_base_level_db": 180.0})
	var op := OperatorSonar.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	op.setup({"env": env, "own": own, "rng": rng})
	op.set_array("TOWED")
	op.update(0.0, [tgt], {"T1": ac})
	var click_brg8: float = float(op.bb_rows[-1]["peaks"][0]["bearing_deg"])
	var group: Array = op.create_mark_group(click_brg8, 0.0, "", true, op.bb_rows[-1])
	if group.size() != 2:
		fails.append("T8 expected mirror pair from mark_group")
		return
	var tracker := Tracker.new()
	var t: Track = tracker.mark(group[0], "M")
	t.add_measurement(group[1])
	_assert_bool(fails, "T8 single track", tracker.all_tracks().size() == 1, true)
	_assert_bool(fails, "T8 both meas in one track", t.measurement_history.size() == 2, true)
	var m0: Measurement = t.measurement_history[0]
	var m1: Measurement = t.measurement_history[1]
	_assert_bool(fails, "T8 same pair in track", m0.ambiguous_pair_id == m1.ambiguous_pair_id, true)


# ------------------------------------------------------------------
#  T9：S1-06 TMA 分支消歧（直航不消歧 / 机动消歧）
# ------------------------------------------------------------------


## 构造 TOWED 镜像观测：own 航迹解析给定，阵列朝向=本艇航向（已沉降近似），
## 观察站位=阵心。A 支=真实方位 θ_A；B 支=镜像 θ_B=wrap360(2ψ−θ_A)。
func _mirror_meas(
	t: float,
	own_p: Vector2,
	course_deg: float,
	tow_offset_m: float,
	tgt_p: Vector2,
	pair_id: String,
	sigma: float
) -> Array:
	var rad: float = course_deg * NavUtils.DEG_TO_RAD
	var center := Vector2(own_p.x - tow_offset_m * sin(rad), own_p.y - tow_offset_m * cos(rad))
	var d: Vector2 = tgt_p - center
	var theta_a: float = NavUtils.wrap360(rad_to_deg(atan2(d.x, d.y)))
	var theta_b: float = NavUtils.wrap360(2.0 * course_deg - theta_a)
	var a: Dictionary = {
		"time": t,
		"observer_e": center.x,
		"observer_n": center.y,
		"bearing": theta_a,
		"sigma": sigma,
		"ambiguous_pair_id": pair_id,
		"ambiguity_branch": 1,
	}
	var b: Dictionary = a.duplicate(true)
	b["bearing"] = theta_b
	b["ambiguity_branch"] = -1
	return [a, b]


func _t9_tma_branch_disambiguation(fails: Array) -> void:
	var sigma: float = 0.3
	var tow_offset: float = 230.0
	var tgt := Vector2(2500.0, 3000.0)

	# --- 直航：可观测性不足（rank<4）→ 不允许消歧 ---
	var straight: Array = []
	for i in range(20):
		var t: float = i * 60.0
		var own_p := Vector2(0.0, 3.0 * t)  # 朝北直航 3m/s
		var pair: Array = _mirror_meas(t, own_p, 0.0, tow_offset, tgt, "P1", sigma)
		straight.append(pair[0])
		straight.append(pair[1])
	var rs: Dictionary = TmaSolver.solve_auto(straight, {"now_time": 1200.0})
	_assert_bool(
		fails, "T9 straight not resolved", bool(rs.get("mirror_resolved", true)) == false, true
	)
	# --- 机动：分支代价拉开 → 消歧成功，胜者=真实几何（A 支）---
	var man: Array = []
	# 腿1：0..600s 朝北；腿2：600..1200s 朝东（阵轴同步转 90°）
	for i in range(11):
		var t1: float = i * 60.0
		var p1 := Vector2(0.0, 3.0 * t1)
		var g1: Array = _mirror_meas(t1, p1, 0.0, tow_offset, tgt, "P1", sigma)
		man.append(g1[0])
		man.append(g1[1])
	for i in range(1, 11):
		var t2: float = 600.0 + i * 60.0
		var p2 := Vector2(3.0 * (t2 - 600.0), 1800.0)
		var g2: Array = _mirror_meas(t2, p2, 90.0, tow_offset, tgt, "P1", sigma)
		man.append(g2[0])
		man.append(g2[1])
	var rm: Dictionary = TmaSolver.solve_auto(man, {"now_time": 1200.0})
	_assert_bool(fails, "T9 maneuver resolved", bool(rm.get("mirror_resolved", false)), true)
	var w: Dictionary = rm.get("mirror_weights", {})
	_assert_bool(
		fails,
		"T9 winner weight >= 0.9",
		maxf(float(w.get("A", 0.0)), float(w.get("B", 0.0))) >= 0.9,
		true
	)
	# 胜者应收敛到真实目标（A 支几何）：位置误差 < 300m
	var best: Dictionary = rm.get("best", {})
	if best.is_empty():
		fails.append("T9 maneuver best empty")
	else:
		var vp := best.get("p_ref", Vector2.ZERO) as Vector2
		var vv := best.get("v_ms", Vector2.ZERO) as Vector2
		var dt_ref: float = 1200.0 - float(best.get("t_ref", 1200.0))
		var est := vp + vv * dt_ref
		_assert_bool(fails, "T9 winner near truth", est.distance_to(tgt) < 300.0, true)
	# 无歧义输入直通 _solve_core：mirror_resolved=true
	var plain: Array = []
	for i in range(12):
		var t3: float = i * 60.0
		var g3: Array = _mirror_meas(t3, Vector2(0.0, 3.0 * t3), 0.0, tow_offset, tgt, "", sigma)
		plain.append(g3[0])
	var rp: Dictionary = TmaSolver.solve_auto(plain, {"now_time": 700.0})
	_assert_bool(
		fails, "T9 no-ambiguity mirror_resolved=true", bool(rp.get("mirror_resolved", false)), true
	)


# ------------------------------------------------------------------
#  断言工具
# ------------------------------------------------------------------


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
