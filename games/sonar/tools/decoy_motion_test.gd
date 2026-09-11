extends SceneTree
## decoy_motion_test.gd — P1-C DC-01/DC-02/DC-03：诱饵运动独立性 + 单方向 + 分离阶段
## （T27 / T28）。
##
## 运行：godot --headless --path games/sonar --script res://tools/decoy_motion_test.gd
## 必须输出 "DECOY_MOTION_TEST result=PASS"。
##
## T27 本艇向北、诱饵分别向东/西释放；本艇随后转弯/提速/换层 → 诱饵轨迹独立
##     （世界坐标增量只由诱饵自身 course/speed 决定）；地图平移缩放改窗口不改世界坐标，
##     且本艇/诱饵/鱼雷/航线共用同一 world_to_screen 映射。
## T28 同向同速对照与静止干扰器对照可解释：同向同速近似平行（不是绑定）；
##     干扰器存在**真实有限分离阶段**（数十米位移后降到漂浮），声学激活延迟不阻止运动。
##
## DC-01 的复现记录：本测试显式打开 world.decoy_trace（默认关闭），把出管时刻、发射方位、
## 本艇与诱饵各自世界坐标、实际/命令航向航速、相机与绘制坐标落成记录并打印。
##
## headless 下不推进 _process：显式 ui._process()；布局需 await 帧。

const SCENARIO: String = "stage1_basic_passive"
const EPS: float = 0.6

var _trace_lines: Array = []


func _init() -> void:
	await _run()


func _run() -> void:
	var fails: Array = []
	await _t27_independent_tracks(fails)
	_t28_same_heading_control(fails)
	_t28_jammer_separation(fails)
	_finish(fails)


# ============================================================== T27 独立性
func _t27_independent_tracks(fails: Array) -> void:
	var w: World = _mk_world()
	var own: TruthEntity = w.world["own"]
	own.course_deg = 0.0
	own.commanded_course_deg = -1.0
	own.speed_kn = 8.0
	own.commanded_speed_kn = -1.0
	own.depth_m = 50.0
	own.commanded_depth_m = -1.0
	# DC-01：打开复现记录（默认关闭）。
	w.decoy_trace.set_enabled(true)
	var east: Decoy = _launch(w, DecoyProgram.TYPE_MOBILE, 90.0)
	var west: Decoy = _launch(w, DecoyProgram.TYPE_MOBILE, 270.0)
	_assert_bool(fails, "T27 east launched", east != null, true)
	_assert_bool(fails, "T27 west launched", west != null, true)
	if east == null or west == null:
		_finish(fails)
		return
	# DC-02：未设高级独立巡航方向 → 出管航向就是投放方向。
	_assert_close(
		fails, "T27 east course=launch bearing", float(east.commanded_course_deg), 90.0, EPS
	)
	_assert_close(
		fails, "T27 west course=launch bearing", float(west.commanded_course_deg), 270.0, EPS
	)
	_assert_bool(fails, "T27 no hidden advanced course", east.advanced_course, false)
	# 记录出管时刻的三类状态（DC-01）。
	_record_launch_line(w, own, east, "east")
	_record_launch_line(w, own, west, "west")

	var own0: Vector2 = Vector2(own.position_east_m, own.position_north_m)
	var e0: Vector2 = Vector2(east.position_east_m, east.position_north_m)
	var w0: Vector2 = Vector2(west.position_east_m, west.position_north_m)
	# --- 本艇随后机动：转向 180° + 提速到 20 节 + 下潜 200 米 ---
	own.command_course(180.0)
	own.command_speed(20.0)
	own.command_depth(200.0)
	var course_samples: Array = []
	var east_course0: float = float(east.course_deg)
	var west_course0: float = float(west.course_deg)
	for i in range(_steps(150.0)):
		w.run_steps(1)
		if i % 40 == 0:
			course_samples.append([float(east.course_deg), float(west.course_deg)])
	_assert_bool(
		fails,
		"T27 course command took effect",
		absf(NavUtils.wrap180(float(own.course_deg) - 180.0)) < 5.0,
		true
	)
	_assert_bool(fails, "T27 own depth ordered", absf(float(own.depth_m) - 200.0) < 5.0, true)
	_assert_bool(fails, "T27 own speed ordered", absf(float(own.speed_kn) - 20.0) < 0.5, true)
	var de: Vector2 = Vector2(east.position_east_m, east.position_north_m) - e0
	var dw: Vector2 = Vector2(west.position_east_m, west.position_north_m) - w0
	# 诱饵只沿自己的投放方向走：东投的正东位移显著、南北位移可忽略（本艇此时向北机动）。
	_assert_bool(fails, "T27 east decoy moves east", de.x > 200.0, true)
	_assert_bool(fails, "T27 west decoy moves west", dw.x < -200.0, true)
	_assert_bool(fails, "T27 east decoy north drift small", absf(de.y) < 20.0, true)
	_assert_bool(fails, "T27 west decoy north drift small", absf(dw.y) < 20.0, true)
	# 本艇确实动了（否则上面的"小漂移"没有辨别力）。
	var down: Vector2 = Vector2(own.position_east_m, own.position_north_m) - own0
	print(
		(
			"[T27] 本艇位移=(%.1f,%.1f) 东投诱饵位移=(%.1f,%.1f) 西投诱饵位移=(%.1f,%.1f)"
			% [down.x, down.y, de.x, de.y, dw.x, dw.y]
		)
	)
	_assert_bool(fails, "T27 own actually moved", down.length() > 500.0, true)
	# 诱饵航向不随本艇转向而变。
	_assert_close(fails, "T27 east keeps course", float(east.course_deg), east_course0, EPS)
	_assert_close(fails, "T27 west keeps course", float(west.course_deg), west_course0, EPS)
	for s in course_samples:
		_assert_close(fails, "T27 east course stable", float(s[0]), 90.0, EPS)
		_assert_close(fails, "T27 west course stable", float(s[1]), 270.0, EPS)
	# 诱饵深度命令独立于本艇换层（本艇下潜到 200 米，诱饵仍按自己的层带 hold）。
	_assert_bool(fails, "T27 decoy depth independent", float(east.depth_m) < 150.0, true)
	# --- DC-01 第三类状态：仅平移/缩放地图（不改世界状态）→ 世界坐标不变 ---
	var e_before: Vector2 = Vector2(east.position_east_m, east.position_north_m)
	var w_before: Vector2 = Vector2(west.position_east_m, west.position_north_m)
	_camera_probe(fails)
	_assert_bool(
		fails,
		"T27 camera cannot move east decoy",
		(Vector2(east.position_east_m, east.position_north_m) - e_before).length() < 1e-6,
		true
	)
	_assert_bool(
		fails,
		"T27 camera cannot move west decoy",
		(Vector2(west.position_east_m, west.position_north_m) - w_before).length() < 1e-6,
		true
	)
	# DC-01：打印复现记录（只在调试通道）。
	w.decoy_trace.dump("T27")
	_trace_lines = w.decoy_trace.records
	_assert_bool(fails, "T27 trace recorded", w.decoy_trace.records.size() > 4, true)
	await process_frame


## 相机平移/缩放/改窗口：只改显示映射，不改世界坐标（DC-01 第三类状态）。
## 同时验证往返映射自洽（screen_to_world(world_to_screen(p)) == p）——"改了相机就换了
## 世界坐标"这类坐标错误会在这里暴露。
func _camera_probe(fails: Array) -> void:
	var cv := ChartView.new()
	cv.cam_center = Vector2(1234.0, -5678.0)
	cv.view_radius_m = 4200.0
	cv.size = Vector2(800.0, 600.0)
	var p := Vector2(100.0, 200.0)
	var s1: Vector2 = cv.world_to_screen(p)
	_assert_bool(
		fails,
		"T27 camera round-trip consistent",
		(cv.screen_to_world(s1) - p).length() < 0.01,
		true
	)
	cv.set_view(Vector2(0.0, 0.0), 20000.0)
	var s2: Vector2 = cv.world_to_screen(p)
	_assert_bool(fails, "T27 camera mapping differs after pan", (s1 - s2).length() > 1.0, true)
	_assert_bool(
		fails, "T27 camera round-trip after pan", (cv.screen_to_world(s2) - p).length() < 0.01, true
	)
	cv.size = Vector2(1600.0, 900.0)  # 改窗口尺寸
	var s3: Vector2 = cv.world_to_screen(p)
	_assert_bool(fails, "T27 camera mapping follows resize", (s3 - s2).length() > 1.0, true)
	_assert_bool(
		fails,
		"T27 camera round-trip after resize",
		(cv.screen_to_world(s3) - p).length() < 0.01,
		true
	)
	cv.free()


# ============================================== T28 同向同速 / 干扰器分离
## 对照 A：诱饵按本艇航向与航速投放 → 两者近似平行（可解释的"同向同速"，不是绑定）。
func _t28_same_heading_control(fails: Array) -> void:
	var w: World = _mk_world()
	var own: TruthEntity = w.world["own"]
	own.course_deg = 45.0
	own.speed_kn = 8.0
	# 显式下令（命令一旦下达，旧"无命令常加速"路径退役）——对照口径：同向同速。
	own.command_course(45.0)
	own.command_speed(8.0)
	var d: Decoy = _launch(w, DecoyProgram.TYPE_MOBILE, 45.0)
	if d == null:
		fails.append("T28 control decoy launched")
		return
	var o0: Vector2 = Vector2(own.position_east_m, own.position_north_m)
	var d0: Vector2 = Vector2(d.position_east_m, d.position_north_m)
	for i in range(_steps(120.0)):
		w.run_steps(1)
	var od: Vector2 = Vector2(own.position_east_m, own.position_north_m) - o0
	var dd: Vector2 = Vector2(d.position_east_m, d.position_north_m) - d0
	# 同向同速 → 位移方向一致、大小接近（可解释），且这是两个独立积分的结果：
	# 断掉诱饵自身的 advance 后本断言会立刻变红（见负向对照）。
	_assert_bool(
		fails, "T28 same-heading both move", od.length() > 400.0 and dd.length() > 400.0, true
	)
	var cos_sim: float = od.normalized().dot(dd.normalized())
	_assert_bool(fails, "T28 same-heading tracks parallel", cos_sim > 0.99, true)
	_assert_bool(
		fails,
		"T28 same-heading length close",
		absf(od.length() - dd.length()) < 0.25 * od.length(),
		true
	)


## 对照 B（DC-03）：干扰器有真实有限分离阶段——出管后数十米位移，随后降到漂浮。
func _t28_jammer_separation(fails: Array) -> void:
	var w: World = _mk_world()
	var own: TruthEntity = w.world["own"]
	own.course_deg = 0.0
	own.speed_kn = 8.0
	own.command_course(0.0)
	own.command_speed(8.0)
	var j: Decoy = _launch(w, DecoyProgram.TYPE_JAMMER, 90.0)
	if j == null:
		fails.append("T28 jammer launched")
		return
	_assert_bool(
		fails, "T28 jammer has separation phase", float(j.separation_duration_s) > 0.0, true
	)
	_assert_bool(fails, "T28 jammer separation speed set", float(j.separation_speed_kn) > 0.5, true)
	var j0: Vector2 = Vector2(j.position_east_m, j.position_north_m)
	# ① 声学激活延迟之内就已经在动（DC-03：延迟不阻止出管后的运动）。
	for i in range(_steps(1.5)):
		w.run_steps(1)
	var moved_early: float = (Vector2(j.position_east_m, j.position_north_m) - j0).length()
	_assert_bool(fails, "T28 jammer moves before activation", moved_early > 0.5, true)
	_assert_bool(fails, "T28 jammer not yet active", j.activated, false)
	# ② 分离阶段结束（配置 20s）→ 位移达到数十米量级，且沿投放方向。
	for i in range(_steps(20.0)):
		w.run_steps(1)
	var sep: Vector2 = Vector2(j.position_east_m, j.position_north_m) - j0
	print(
		(
			"[T28-jammer] 分离期位移=%.1f m（配置 %.1f 节/%.0f 秒）出管初速=%.1f 节 初期位移=%.1f m"
			% [
				sep.length(),
				float(j.separation_speed_kn),
				float(j.separation_duration_s),
				float(j.initial_speed_kn),
				moved_early,
			]
		)
	)
	_assert_bool(fails, "T28 jammer separation displacement real", sep.length() > 30.0, true)
	_assert_bool(
		fails, "T28 jammer separation along bearing", sep.x > 30.0 and absf(sep.y) < 1.0, true
	)
	# ③ 给足减速时间（6→0.2 节 @1kn/s）→ 降到漂浮速度。
	for i in range(_steps(10.0)):
		w.run_steps(1)
	_assert_bool(fails, "T28 jammer reached drift", float(j.speed_kn) < 1.0, true)
	# ④ 之后 → 位移接近平台期（低速漂浮，不再持续挪动）。
	var p1: Vector2 = Vector2(j.position_east_m, j.position_north_m)
	for i in range(_steps(30.0)):
		w.run_steps(1)
	var after: float = (Vector2(j.position_east_m, j.position_north_m) - p1).length()
	_assert_bool(fails, "T28 jammer plateaus after separation", after < 15.0, true)
	# 静止干扰器对照可解释：漂移位移量级远小于真实分离位移（不是"全程 0 节"）。
	_assert_bool(fails, "T28 drift much slower than separation", after * 3.0 < sep.length(), true)


# ============================================================== 辅助
func _mk_world() -> World:
	var w := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario(SCENARIO)
	sc["seed"] = 20260912
	# 本测试只关心运动/方向/分离：把冷却清零，让同一次运行能连投两枚（冷却与库存
	# 语义由 decoy_test CM-02 与 weapon_ui_test UIW-03 覆盖）。
	sc["own_ship"]["countermeasures"] = {
		"ready_rounds": 2, "inventory": 4, "launch_cooldown_s": 0.0
	}
	w.load_scenario(sc)
	w.auto_measurements = false
	var own: TruthEntity = w.world["own"]
	# 测试节拍：默认 1.5°/s 转 180° 要 120 秒，太慢；场景化的可观测机动。
	own.turn_rate_deg_s = 6.0
	own.acceleration_kn_s = 1.0
	return w


## 用统一构建器投放，返回部署的诱饵（DC-02/DC-05：面板与地图走同一处构建）。
func _launch(w: World, decoy_type: String, bearing_deg: float) -> Decoy:
	var own: TruthEntity = w.world["own"]
	var prog: DecoyProgram = DecoyLaunchBuilder.build(
		w.countermeasures, decoy_type, bearing_deg, own
	)
	var n0: int = w.decoys.size()
	var ok: bool = w._launch_decoy(prog)
	if not ok:
		return null
	if w.decoys.size() <= n0:
		return null
	return w.decoys[w.decoys.size() - 1]


func _steps(seconds: float) -> int:
	var dt: float = 0.5
	return int(round(seconds / dt))


func _record_launch_line(w: World, own: TruthEntity, d: Decoy, tag: String) -> void:
	# DC-01：相机参数 + 本艇/诱饵的绘制坐标（与海图 world_to_screen 同一映射）。
	var cv := ChartView.new()
	cv.size = Vector2(880.0, 620.0)
	cv.set_view(Vector2(0.0, 0.0), 12000.0)
	var cam: Dictionary = {
		"center_e": float(cv.cam_center.x),
		"center_n": float(cv.cam_center.y),
		"view_radius_m": float(cv.view_radius_m),
		"size_x": float(cv.size.x),
		"size_y": float(cv.size.y),
		"own_screen": cv.world_to_screen(Vector2(own.position_east_m, own.position_north_m)),
		"decoy_screen": cv.world_to_screen(Vector2(d.position_east_m, d.position_north_m)),
	}
	cv.free()
	w.decoy_trace.set_camera(cam)
	var tpl: String = (
		"[T27-%s] t=%.1f 出管 方位=%.0f°"
		+ " 本艇(e=%.1f,n=%.1f,z=%.1f,crs=%.0f,v=%.1f)"
		+ " 诱饵(e=%.1f,n=%.1f,z=%.1f,crs=%.0f,v=%.1f) cam=%s"
	)
	print(
		(
			tpl
			% [
				tag,
				float(w.sim_time),
				float(d.launch_bearing_deg),
				float(own.position_east_m),
				float(own.position_north_m),
				float(own.depth_m),
				float(own.course_deg),
				float(own.speed_kn),
				float(d.position_east_m),
				float(d.position_north_m),
				float(d.depth_m),
				float(d.course_deg),
				float(d.speed_kn),
				str(cam),
			]
		)
	)


func _assert_bool(fails: Array, name: String, got: Variant, want: Variant) -> void:
	if bool(got) != bool(want):
		fails.append("%s (got=%s want=%s)" % [name, str(got), str(want)])


func _assert_close(fails: Array, name: String, got: float, want: float, eps: float) -> void:
	if absf(got - want) > eps:
		fails.append("%s (got=%.3f want=%.3f±%.3f)" % [name, got, want, eps])


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("DECOY_MOTION_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("TEST FAIL: " + str(f))
		print("DECOY_MOTION_TEST result=FAIL (%d)" % fails.size())
		quit(1)
