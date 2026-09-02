extends SceneTree
## fix_batch1_test.gd — 声呐综合修复 批次1：统一方位换算层无头验收。
##
## 对应修复需求"七、必须增加的自动化测试"中的坐标系相关项：
##   1. 本艇航向0°、目标真方位45°：相对显示为 +45°。
##   2. 本艇转到90°：相对显示变为 −45°，TMA Measurement 仍约 45°（真方位）。
##   10. 切换分析方位后，其他方位目标的音线明显衰减（方向性——本文件验方位换算数学）。
## 纯函数验证，不依赖 Truth / 声场。


func _initialize() -> void:
	var fails: Array = []
	var tol: float = 1e-6

	# --- 测试 1：航向0°、真方位45° → 相对显示 +45 ---
	var d1: float = NavUtils.true_to_display(0.0, 45.0)
	_assert_close(fails, "t1 rel=+45 (course 0, true 45)", d1, 45.0, tol)

	# --- 测试 2：航向90°、真方位45° → 相对显示 −45；真方位仍 45 ---
	var d2: float = NavUtils.true_to_display(90.0, 45.0)
	_assert_close(fails, "t2 rel=-45 (course 90, true 45)", d2, -45.0, tol)
	# 反算回真方位
	var back2: float = NavUtils.rel_to_true(90.0, d2)
	_assert_close(fails, "t2 true back=45", back2, 45.0, tol)

	# --- 绕零界：真方位0、航向350 → 相对 +10（非 −350/怪值）---
	var d3: float = NavUtils.true_to_display(350.0, 0.0)
	_assert_close(fails, "t3 rel=+10 (course 350, true 0)", d3, 10.0, tol)
	var back3: float = NavUtils.rel_to_true(350.0, d3)
	_assert_close(fails, "t3 true back=0", back3, 0.0, tol)

	# --- 阵列方位：TOWED 用独立航向（设 array_heading=180）---
	# 目标真方位0，阵列航向180 → 阵列相对 ±180（正艉），wrap360 表示即 180
	var a1: float = NavUtils.true_to_array(180.0, 0.0)
	_assert_close(fails, "t4 array rel wrap360=180", NavUtils.wrap360(a1), 180.0, tol)
	var a2: float = NavUtils.true_to_array(180.0, 200.0)
	_assert_close(fails, "t5 array rel (hdg180,true200)=20", a2, 20.0, tol)

	# --- 扇区判断：FLANK 双舷扇区 [55,125] ∪ [-125,-55] ---
	var flank: Array = [Vector2(55, 125), Vector2(-125, -55)]
	_assert_bool(fails, "t6 FLANK +100 in", NavUtils.in_sectors(100.0, flank), true)
	_assert_bool(fails, "t7 FLANK -100 in", NavUtils.in_sectors(-100.0, flank), true)
	_assert_bool(fails, "t8 FLANK +30 NOT in", NavUtils.in_sectors(30.0, flank), false)

	# --- 方向性增益：扇区中心内0dB，扇区外衰减 ---
	var g_in: float = NavUtils.sector_gain_db(80.0, 90.0, 35.0)
	_assert_close(fails, "t9 sector gain in=0", g_in, 0.0, tol)
	var g_out: float = NavUtils.sector_gain_db(30.0, 90.0, 35.0)  # 差60°,超半宽25° → -12.5dB
	_assert_close(fails, "t10 sector gain out <0", g_out, -12.5, tol)

	# --- 结果 ---
	if fails.is_empty():
		print("FIX_BATCH1 PASS: nav utils bearing/conversion correct")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("FIX_BATCH1 FAIL: %d problem(s)" % fails.size())
		quit(1)


func _assert_close(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
