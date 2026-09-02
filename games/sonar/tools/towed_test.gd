extends SceneTree
## towed_test.gd — 批次2+：拖曳阵物理状态机 无头验收。
##
## 验证拖曳阵不再"恒等 own.course"，而是具备真实物理生命周期：
##   1. 部署：RETRACTED → DEPLOYING(进度随时间推进) → DEPLOYED。
##   2. 转向航向滞后：阵航向对本艇转向一阶滞后收敛（不瞬间跟随），最终逼近本艇航向。
##   3. 可用度 usable_fraction()：未部署≈0；部署中随进度爬升；DEPLOYED 且沉降后→1。
##   4. 集成 TruthEntity.advance：own.towed 随步长推进。
##   5. OperatorSonar TOWED 覆盖用滞后阵航向（读 own.towed.array_heading_deg）。
##
## 全部确定性（不依赖真实目标 Truth 噪声流，只看阵自身物理）。


func _initialize() -> void:
	var fails: Array = []

	# --- 1) 部署生命周期 ---
	var t1 := TowedArray.new()
	(
		t1
		. setup(
			{
				"deploy_time_s": 100.0,
				"retract_time_s": 50.0,
				"tow_length_m": 400.0,
				"full_length_heading_tau_s": 40.0,
				"short_length_heading_tau_s": 6.0,
			}
		)
	)
	t1.array_heading_deg = 0.0
	_assert_bool(fails, "t1 initial RETRACTED", t1.state == TowedArray.State.RETRACTED, true)
	_assert_close(fails, "t1 retracted usable=0", t1.usable_fraction(), 0.0, 1e-6)
	# 布放 50s（半程）应为 DEPLOYING，进度≈0.5
	t1.deploy()
	_assert_bool(fails, "t1 deploy->DEPLOYING", t1.state == TowedArray.State.DEPLOYING, true)
	for _i in range(50):
		t1.step(1.0, 0.0)
	_assert_bool(fails, "t1 mid DEPLOYING", t1.state == TowedArray.State.DEPLOYING, true)
	_assert_close(fails, "t1 progress~0.5", t1.deployment_progress, 0.5, 0.02)
	# 再布放 50s → DEPLOYED
	for _i in range(50):
		t1.step(1.0, 0.0)
	_assert_bool(fails, "t1 full DEPLOYED", t1.state == TowedArray.State.DEPLOYED, true)
	_assert_close(fails, "t1 progress=1", t1.deployment_progress, 1.0, 1e-6)

	# --- 2) 转向航向滞后收敛 ---
	# 布放完成后阵在航向0已稳定，usable→1（用与部署相同的 tau 但先让它沉降）
	_assert_bool(fails, "t1 settled usable=1", absf(t1.usable_fraction() - 1.0) < 1e-6, true)
	# 突然本艇转90°：阵航向应滞后（未立即=90），随时间收敛到90
	for _i in range(10):
		t1.step(1.0, 90.0)  # 推进10s：阵刚开始转向，明显落后于90，但已移动
	var hdg_after_turn1: float = t1.array_heading_deg
	_assert_bool(
		fails,
		"t2 array lags turn (moved but not 90)",
		hdg_after_turn1 < 85.0 and hdg_after_turn1 > 5.0,
		true
	)
	# 推进足够长(5*tau=200s)，阵应逼近90
	for _i in range(200):
		t1.step(1.0, 90.0)
	_assert_close(fails, "t2 array converges to 90", t1.array_heading_deg, 90.0, 3.0)
	# 转向后沉降：逼近90后 usable 应回到接近1
	_assert_bool(fails, "t2 settled usable~1", t1.usable_fraction() > 0.95, true)

	# --- 3) 部署中可用度有限（不能给满覆盖/增益）---
	var t3 := TowedArray.new()
	t3.setup({"deploy_time_s": 100.0})
	t3.array_heading_deg = 0.0
	t3.deploy()
	for _i in range(30):  # 30s → progress 0.3，usable <1
		t3.step(1.0, 0.0)
	_assert_bool(fails, "t3 mid-deploy usable<1", t3.usable_fraction() < 0.5, true)

	# --- 4) 回收 ---
	var t4 := TowedArray.new()
	t4.setup({"deploy_time_s": 10.0, "retract_time_s": 20.0})
	t4.array_heading_deg = 0.0
	t4.deploy()
	for _i in range(20):
		t4.step(1.0, 0.0)  # DEPLOYED
	t4.retract()
	_assert_bool(fails, "t4 retract->RETRIEVING", t4.state == TowedArray.State.RETRIEVING, true)
	for _i in range(30):
		t4.step(1.0, 0.0)
	_assert_bool(fails, "t4 back to RETRACTED", t4.state == TowedArray.State.RETRACTED, true)
	_assert_bool(fails, "t4 retracted unusable", t4.usable_fraction() < 1e-6, true)

	# --- 5) 集成 TruthEntity：own.towed 随 advance 推进，get_array_heading_deg 返回阵航向 ---
	var own := TruthEntity.new()
	own.course_deg = 0.0
	own.speed_kn = 6.0
	own.towed = TowedArray.new()
	own.towed.setup({"deploy_time_s": 60.0, "full_length_heading_tau_s": 30.0})
	own.towed.array_heading_deg = 0.0
	own.towed.deploy()
	for _i in range(60):  # 完成部署
		own.advance(1.0)
	_assert_bool(
		fails,
		"t5 own.towed DEPLOYED via advance",
		own.towed.state == TowedArray.State.DEPLOYED,
		true
	)
	# 本艇转向 45°，advance 多步，阵航向从 get_array_heading_deg 读出（滞后，不等于course直至收敛）
	own.course_deg = 45.0
	for _i in range(150):  # 5*tau 收敛
		own.advance(1.0)
	_assert_close(fails, "t5 own heading follows to 45", own.get_array_heading_deg(), 45.0, 3.0)

	# --- 6) OperatorSonar TOWED 用滞后阵航向（读 own.towed），非恒等 own.course ---
	var op := OperatorSonar.new()
	var wd: Dictionary = {
		"env": EnvironmentModel.new(),
		"own": own,
		"rng": RandomNumberGenerator.new(),
	}
	op.setup(wd)
	op.set_array("TOWED")
	# 制造一个"阵还没沉降到本艇新航向"的情形：本艇 90°，阵航向仍停在 ~0（刚转）
	var now: float = 0.0
	# 先让阵完全部署并沉降到当前航向 0
	own.course_deg = 0.0
	for _i in range(120):
		own.advance(1.0)
	now = 120.0
	var hdg_settled: float = op._array_heading_deg()
	_assert_close(fails, "t6 TOWED heading = own at settle", hdg_settled, 0.0, 3.0)
	# 本艇骤转 90°，仅推进 2s：阵航向应仍远离 90（滞后生效）
	own.course_deg = 90.0
	for _i in range(2):
		own.advance(1.0)
	var hdg_lag: float = op._array_heading_deg()
	_assert_bool(fails, "t6 TOWED heading lags after turn", hdg_lag < 60.0, true)
	# TOWED 未沉降前 usable 应明显 <1（覆盖/增益受限）
	_assert_bool(
		fails, "t6 TOWED usable degraded after turn", op._towed_usable_factor() < 0.5, true
	)
	# 收敛后 usable 恢复
	for _i in range(300):
		own.advance(1.0)
	_assert_bool(fails, "t6 TOWED usable recovers", op._towed_usable_factor() > 0.9, true)

	if fails.is_empty():
		print("TOWED_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("TOWED_TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
