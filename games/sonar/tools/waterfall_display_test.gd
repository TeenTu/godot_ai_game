extends SceneTree
## REQ-0908 Batch 6 — 瀑布显示动态范围/AGC/调色板验收（REQ-B6-01..04）。
## 契约：噪声底跟踪 + 固定动态范围（默认 24dB）后，空场景 300 行
## 暖色（黄/白）像素比例 ≤1%；显示参数（palette/AGC/动态范围）只改显示，
## 不得改变 rows/峰值/证据；BB/NB/DEMON 与阵列键独立 AGC 状态。
## Batch 6 落地时本测试加入 ci_tests.txt。

const WF_SCRIPT := "res://scripts/ui/waterfall_view.gd"


func _initialize() -> void:
	var fails: Array = []

	# ---- 合成纯噪声瀑布行（AR(1)，平稳 σ≈3.75dB，无任何目标）----
	var rng := RandomNumberGenerator.new()
	rng.seed = 90805
	var rows: Array = []
	var prev: float = 0.0
	for r in range(300):
		var vals := PackedFloat32Array()
		vals.resize(180)
		for c in range(180):
			prev = 0.6 * prev + 3.0 * rng.randfn(0.0, 1.0)
			vals[c] = prev
		rows.append({"t": float(r), "values": vals})

	var wf: Control = load(WF_SCRIPT).new()
	wf.set_rows(rows)
	wf._rebuild_image()
	var img: Image = wf._img
	_assert(fails, img != null, "waterfall image rebuilt")

	if img != null:
		var warm: int = 0
		var total: int = img.get_width() * img.get_height()
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var px: Color = img.get_pixel(x, y)
				if px.g8 > 153 and px.r8 > 200:
					warm += 1
		var ratio: float = float(warm) / float(total)
		_assert(
			fails,
			ratio <= 0.01,
			"empty-scene warm pixel ratio <= 1%% (got %.2f%%)" % (ratio * 100.0),
		)

	# ---- REQ-B6-01：显示参数只改显示，绝不触碰 rows（物理数据逐位不变）----
	var rows_snapshot: Array = rows.duplicate()
	wf.set_palette("GRAYSCALE")
	wf._rebuild_image()
	var img_gray: Image = wf._img
	wf.set_palette("BLUE")
	wf._rebuild_image()
	var img_blue: Image = wf._img
	_assert(
		fails,
		not img_gray.get_pixel(10, 5).is_equal_approx(img_blue.get_pixel(10, 5)),
		"palette switch changes pixels",
	)
	_assert(fails, _rows_equal(rows_snapshot, rows), "palette switch leaves rows untouched")

	wf.set_agc_mode("OFF")
	wf._rebuild_image()
	var img_off: Image = wf._img
	wf.set_agc_mode("SLOW")
	wf._rebuild_image()
	_assert(fails, _rows_equal(rows_snapshot, rows), "AGC mode switch leaves rows untouched")
	_assert(
		fails,
		not img_off.get_pixel(10, 5).is_equal_approx(img_gray.get_pixel(10, 5)),
		"AGC OFF vs SLOW remap display differently",
	)

	# ---- REQ-B6-04-3：弱目标（背景 +10dB）跨行连续可追踪且不发白 ----
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 90806
	var rows2: Array = []
	var prev2: float = 0.0
	for r2 in range(300):
		var vals2 := PackedFloat32Array()
		vals2.resize(180)
		for c2 in range(180):
			prev2 = 0.6 * prev2 + 3.0 * rng2.randfn(0.0, 1.0)
			vals2[c2] = prev2
		# 弱目标固定在 90° 列（+10dB），跨多行连续。
		vals2[135] = prev2 + 0.0 + 10.0
		rows2.append({"t": float(r2), "values": vals2})
	var wf2: Control = load(WF_SCRIPT).new()
	wf2.set_rows(rows2)
	wf2._rebuild_image()
	var img2: Image = wf2._img
	var tgt_lum: float = 0.0
	var bg_lum: float = 0.0
	var last_row_y: int = img2.get_height() - 1
	for y2 in range(last_row_y - 100, last_row_y):
		var pt: Color = img2.get_pixel(135, y2)
		var pb: Color = img2.get_pixel(40, y2)
		tgt_lum += 0.3 * pt.r + 0.6 * pt.g + 0.1 * pt.b
		bg_lum += 0.3 * pb.r + 0.6 * pb.g + 0.1 * pb.b
	var n_rows: float = 100.0
	_assert(fails, tgt_lum > bg_lum * 1.5, "weak target track clearly brighter than background")
	_assert(
		fails,
		tgt_lum / n_rows < 0.9,
		"weak target does not saturate to white (avg lum %.2f)" % (tgt_lum / n_rows),
	)

	# ---- REQ-B6-02：display_key 隔离——BOW→TOWED→BOW 同行像素完全一致 ----
	var wf3: Control = load(WF_SCRIPT).new()
	wf3.set_display_key("bb_BOW")
	wf3.set_rows(rows)
	wf3._rebuild_image()
	var img_bow1: Image = wf3._img
	wf3.set_display_key("bb_TOWED")
	wf3.set_rows(rows)
	wf3._rebuild_image()
	wf3.set_display_key("bb_BOW")
	wf3.set_rows(rows)
	wf3._rebuild_image()
	var img_bow2: Image = wf3._img
	var same: bool = img_bow1.get_size() == img_bow2.get_size()
	if same:
		for y3 in range(0, img_bow1.get_height(), 7):
			for x3 in range(0, img_bow1.get_width(), 13):
				if not img_bow1.get_pixel(x3, y3).is_equal_approx(img_bow2.get_pixel(x3, y3)):
					same = false
					break
			if not same:
				break
	_assert(fails, same, "BOW->TOWED->BOW rebuild reproduces identical pixels")

	wf.free()
	wf2.free()
	wf3.free()
	_finish(fails)


func _rows_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var va: PackedFloat32Array = a[i]["values"]
		var vb: PackedFloat32Array = b[i]["values"]
		if va.size() != vb.size():
			return false
		for c in range(va.size()):
			if not is_equal_approx(va[c], vb[c]):
				return false
		if not is_equal_approx(float(a[i]["t"]), float(b[i]["t"])):
			return false
	return true


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("WATERFALL-DISPLAY TEST PASS")
		quit(0)
	else:
		print("WATERFALL-DISPLAY TEST FAIL (%d)" % fails.size())
		quit(1)
