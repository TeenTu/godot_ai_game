extends SceneTree
## REQ-0908 Batch 0 — P0-06 失败回归：海图方向换算契约。
## 根因：ChartView 威胁 LOB 把屏幕方向 Vector2(sinθ,-cosθ) 当世界方向再
## world_to_screen → 南北翻转；鱼雷扇区/FOV/航迹线混用两套方向公式。
## 契约（§2.2）：唯一换算入口 bearing_to_world_dir / bearing_to_screen_dir，
## 0°=屏幕上、90°=右、180°=下、270°=左；绘制代码禁止散写 sin/cos。
## Batch 3 落地时本测试加入 ci_tests.txt。


func _initialize() -> void:
	var fails: Array = []

	# ---- 契约 1：唯一方向换算工具函数必须存在（nav_utils.gd）----
	var nav_src: Script = load("res://scripts/nav_utils.gd")
	var nav_text: String = nav_src.source_code
	var has_world: bool = nav_text.find("func bearing_to_world_dir") >= 0
	var has_screen: bool = nav_text.find("func bearing_to_screen_dir") >= 0
	_assert(fails, has_world, "NavUtils.bearing_to_world_dir exists")
	_assert(fails, has_screen, "NavUtils.bearing_to_screen_dir exists")
	if has_world and has_screen:
		# 经实例动态调用（静态纯函数，实例上可解析）。
		var nav: RefCounted = nav_src.new()
		var w0: Variant = nav.call("bearing_to_world_dir", 0.0)
		var w90: Variant = nav.call("bearing_to_world_dir", 90.0)
		var w180: Variant = nav.call("bearing_to_world_dir", 180.0)
		var w270: Variant = nav.call("bearing_to_world_dir", 270.0)
		var s0: Variant = nav.call("bearing_to_screen_dir", 0.0)
		var s90: Variant = nav.call("bearing_to_screen_dir", 90.0)
		var s180: Variant = nav.call("bearing_to_screen_dir", 180.0)
		var s270: Variant = nav.call("bearing_to_screen_dir", 270.0)
		_assert(fails, _is_vec(w0, 0, 1), "world 0deg -> north")
		_assert(fails, _is_vec(w90, 1, 0), "world 90deg -> east")
		_assert(fails, _is_vec(w180, 0, -1), "world 180deg -> south")
		_assert(fails, _is_vec(w270, -1, 0), "world 270deg -> west")
		_assert(fails, _is_vec(s0, 0, -1), "screen 0deg -> up")
		_assert(fails, _is_vec(s90, 1, 0), "screen 90deg -> right")
		_assert(fails, _is_vec(s180, 0, 1), "screen 180deg -> down")
		_assert(fails, _is_vec(s270, -1, 0), "screen 270deg -> left")

	# ---- 契约 2：ChartView 不得散写 sin/cos 方向 ----
	# 绘制代码必须经由唯一换算函数；允许的例外只有 nav_utils 本体与
	# 注释行。扫描 chart_view.gd 源码。
	var cv_src: Script = load("res://scripts/ui/chart_view.gd")
	var text: String = cv_src.source_code
	var lines: PackedStringArray = text.split("\n")
	var offenders: Array = []
	for i in range(lines.size()):
		var ln: String = lines[i]
		if ln.strip_edges().begins_with("#"):
			continue
		if ln.find("Vector2(sin") >= 0 or ln.find("Vector2(cos") >= 0:
			offenders.append("chart_view.gd:%d" % (i + 1))
	_assert(
		fails,
		offenders.is_empty(),
		"chart_view.gd free of raw sin/cos direction math (%s)" % str(offenders.slice(0, 4)),
	)

	_finish(fails)


func _is_vec(v: Variant, x: float, y: float) -> bool:
	return v is Vector2 and (v as Vector2).is_equal_approx(Vector2(x, y))


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("CHART-BEARING-CONTRACT TEST PASS")
		quit(0)
	else:
		print("CHART-BEARING-CONTRACT TEST FAIL (%d)" % fails.size())
		quit(1)
