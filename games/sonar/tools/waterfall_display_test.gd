extends SceneTree
## REQ-0908 Batch 0 — P1-02 失败回归：瀑布 AGC 把普通噪声映射成黄/白。
## 根因：WaterfallView 用滚动 P10/P99 全跨度映射热色表——平稳 AR(1) 噪声的
## 高分位稳定进入橙/黄/白区，背景大面积暖色，可读性崩坏。
## 契约（Batch 6）：噪声底跟踪 + 固定动态范围（默认 24dB）后，空场景
## 暖色（黄/白）像素比例 ≤1%；显示参数不得改变任何物理数据。
## Batch 6 落地时本测试加入 ci_tests.txt。

const WF_SCRIPT := "res://scripts/ui/waterfall_view.gd"


func _initialize() -> void:
	var fails: Array = []

	# ---- 合成纯噪声瀑布行（AR(1)，平稳 σ≈3.75dB，无任何目标）----
	var rng := RandomNumberGenerator.new()
	rng.seed = 90805
	var rows: Array = []
	var prev: float = 0.0
	for r in range(120):
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

	# ---- 契约：AGC 模式与调色板控件（Batch 6 新增 API）----
	_assert(fails, wf.has_method("set_agc_mode"), "WaterfallView.set_agc_mode exists")
	_assert(fails, wf.has_method("set_palette"), "WaterfallView.set_palette exists")

	wf.free()
	_finish(fails)


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
