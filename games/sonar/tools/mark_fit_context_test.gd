extends SceneTree
## REQ-0908 Batch 0 — P0-02/P0-03 失败回归：Mark 重复点击与 Fit/解隔离。
## P0-03 根因：OperatorSonar.create_mark() 无峰命中时每次重新 _randn() 抽
## 噪声，且每次调用生成新 evidence_id → 同一像素重复点击制造新物理证据。
## P0-02 根因：main_ui 只有全局单份 trial/system_sol/last_fit，SystemSolution
## 无 source_track_id/source_fit_version/source_evidence_revision。
## Batch 1 落地时本测试加入 ci_tests.txt。

const OP_SCRIPT := "res://scripts/sonar/operator_sonar.gd"


func _initialize() -> void:
	var fails: Array = []

	# ---- P0-03a：无峰自由点击不得重抽随机噪声 ----
	var op := _mk_operator()
	var row := {
		"array_id": "BOW",
		"t": 10.0,
		"course": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"peaks": [],  # 无峰上下文：点击方位必须原样成为测量方位
	}
	var m1: Measurement = op.create_mark(45.0, 10.0, "", false, row)
	var m2: Measurement = op.create_mark(45.0, 10.0, "", false, row)
	_assert(
		fails,
		absf(NavUtils.angle_diff(m1.measured_bearing_deg, m2.measured_bearing_deg)) < 1e-9,
		"repeat free-click keeps identical bearing (%.4f vs %.4f)"
		% [m1.measured_bearing_deg, m2.measured_bearing_deg],
	)

	# ---- P0-04：SystemSolution 必须携带来源 Track/版本身份 ----
	var sol := SystemSolution.new()
	_assert(
		fails,
		sol.get("source_track_id") != null,
		"SystemSolution.source_track_id exists",
	)
	_assert(
		fails,
		sol.get("source_fit_version") != null,
		"SystemSolution.source_fit_version exists",
	)
	_assert(
		fails,
		sol.get("source_evidence_revision") != null,
		"SystemSolution.source_evidence_revision exists",
	)

	# ---- P0-02：per-track Fit 上下文（main_ui 不得只有全局单份）----
	var src: Script = load("res://scripts/ui/main_ui.gd")
	var text: String = src.source_code
	_assert(fails, text.find("fit_by_track_id") >= 0, "main_ui has per-track fit context")
	_assert(
		fails,
		text.find("system_solution_by_track_id") >= 0,
		"main_ui has per-track system solution",
	)

	_finish(fails)


func _mk_operator() -> RefCounted:
	# OperatorSonar.setup(world_dict)：own 参考实体 + 确定性 RNG。
	var own := TruthEntity.new()
	own.position_east_m = 0.0
	own.position_north_m = 0.0
	own.course_deg = 0.0
	own.depth_m = 50.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 90802
	var op: RefCounted = load(OP_SCRIPT).new()
	op.setup({"own": own, "rng": rng})
	return op


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("MARK-FIT-CONTEXT TEST PASS")
		quit(0)
	else:
		print("MARK-FIT-CONTEXT TEST FAIL (%d)" % fails.size())
		quit(1)
