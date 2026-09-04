extends SceneTree
## s1_07_legacy_characterization_test.gd — S1-07 Commit 0 旧武器行为刻画测试。
##
## 目的（S1-07 文档 §13 Commit 0 / §1.2）：
##   在重构前把当前占位鱼雷的"已知缺陷行为"固化成可执行断言，作为重构的
##   行为基线（characterization net）。Commit 1 引入正交状态模型并删除
##   Truth 直读后，本文件的断言将不再成立——届时删除本文件，由
##   s1_07_state_model_test.gd（新契约）与 weapon_test.gd（更新后）接管。
##
## 当前被固化的遗留契约（全部是 S1-07 明令必须替换的行为）：
##   L1  发射后 RUN 直航，行程 >=1500m（ENABLE_RANGE_M）才转 SEARCH 开自导
##       （"一个 ENABLE 距离同时代表开机/发射/自主/解保"的反模式）。
##   L2  _seek 直接遍历 Truth targets：900m/120° 圆锥内选最近者 → 瞬时 ACQUIRE
##       （Truth 进入 Seeker 决策层，禁止项）。
##   L3  PURSUIT 每 tick 用 Truth 位置算方位并 course_deg=brg 瞬时转向
##       （不遵守转向率限制；Truth 方位直接驱动航向）。
##   L4  HIT 事件 detail 直接携带 target_id（UI 可即时确认目标沉没，禁止项）。
##   L5  鱼雷 DEAD 后对应发射管瞬间回到 LOADED（自动补装，禁止项）。
##
## 断言全部在旧代码上应通过（退出码 0）；Commit 1 重构后本文件会红，
## 按文件头说明删除并由新测试接管。运行：
##   godot --headless --path games/sonar --script res://tools/s1_07_legacy_characterization_test.gd

const DT: float = 0.5
const FIRE_AT: float = 60.0
const SIM_END: float = 900.0


func _initialize() -> void:
	var fails: Array = []
	var world := World.new()
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	world.load_scenario(sc)
	world.auto_measurements = false
	var wd: Dictionary = world.world

	while world.sim_time < FIRE_AT:
		world.tick()

	var own: RefCounted = wd["own"]
	var tgt: RefCounted = wd["targets"][0]
	var sys := SystemSolution.new()
	sys.bearing_deg = (
		NavUtils
		. bearing_to_true(
			float(own.position_east_m),
			float(own.position_north_m),
			float(tgt.position_east_m),
			float(tgt.position_north_m),
		)
	)
	sys.range_m = (
		Vector2(
			float(tgt.position_east_m) - float(own.position_east_m),
			float(tgt.position_north_m) - float(own.position_north_m),
		)
		. length()
	)
	sys.course_deg = float(tgt.course_deg)
	sys.speed_kn = float(tgt.speed_kn)
	sys.solution_time = world.sim_time
	sys.estimated_position_east_m = float(tgt.position_east_m)
	sys.estimated_position_north_m = float(tgt.position_north_m)
	sys.confidence = 0.9

	var tp: Torpedo = world.weapons.fire(
		sys, float(own.position_east_m), float(own.position_north_m), world.sim_time
	)
	if tp == null:
		fails.append("L0 fire returned null (legacy precondition)")
		_finish(fails)
		return

	var kinds: Dictionary = {}
	var hit_detail: Dictionary = {}
	tp.event_occurred.connect(
		func(_tid: String, kind: String, d: Dictionary):
			kinds[kind] = true
			if kind == "HIT":
				hit_detail.clear()
				hit_detail.merge(d, true)
	)

	# 轮询捕获 legacy 缺陷点（重构前全部成立）：
	#   - saw_pursuit + pursuit_snapped：PURSUIT 中 course 瞬时指向 Truth 方位
	#   - reloaded_at_dead：DEAD 后发射管自动回 LOADED
	var reloaded_at_dead: bool = false
	var saw_dead: bool = false
	var saw_pursuit: bool = false
	var pursuit_snapped: bool = false
	while world.sim_time < SIM_END:
		world.tick()
		if tp.state == Torpedo.State.PURSUIT:
			saw_pursuit = true
			var brg_t: float = (
				NavUtils
				. bearing_to_true(
					float(tp.pos_east_m),
					float(tp.pos_north_m),
					float(tgt.position_east_m),
					float(tgt.position_north_m),
				)
			)
			if absf(NavUtils.angle_diff(float(tp.course_deg), brg_t)) <= 1.0:
				pursuit_snapped = true
		if not saw_dead and tp.state == Torpedo.State.DEAD:
			saw_dead = true
			for t in world.weapons.tubes:
				if t["state"] == "LOADED":
					reloaded_at_dead = true
		if str(tgt.damage_state) == "sunk":
			break

	# 校验 legacy 契约成立（重构前全部为 true）
	if not saw_dead and tp.state != Torpedo.State.DEAD:
		fails.append("L1 legacy torpedo never reached DEAD (fuel/hit)")
	if not kinds.has("ENABLE"):
		fails.append("L1 no legacy ENABLE event (single-range gate)")
	if not kinds.has("ACQUIRE"):
		fails.append("L2 no legacy ACQUIRE (truth-cone capture)")
	if str(tgt.damage_state) != "sunk":
		fails.append("L2/L3 legacy truth pursuit did not sink target")
	# L3 瞬时转向：PURSUIT 中 course 直接指向 Truth 目标（无转向率限制）。
	if not saw_pursuit or not pursuit_snapped:
		fails.append("L3 legacy pursuit not snapped to truth bearing")
	# L4 HIT 事件携带 target_id（禁止项，legacy 存在）
	if not kinds.has("HIT") or not hit_detail.has("target_id"):
		fails.append("L4 legacy HIT lacks target_id payload")
	# L5 发射管自动回 LOADED
	if not reloaded_at_dead:
		fails.append("L5 legacy tube not auto-reloaded at DEAD")

	# 记录已知缺陷供 Commit 1 对照（不参与失败判定，仅审计输出）
	print(
		(
			"LEGACY_AUDIT target_id_in_hit=%s truth_snap=%s auto_reload=%s"
			% [
				str(hit_detail.has("target_id")),
				str(pursuit_snapped),
				str(reloaded_at_dead),
			]
		)
	)

	_finish(fails)


func _finish(fails: Array) -> void:
	for f in fails:
		print("LEGACY_FAIL ", f)
	if fails.is_empty():
		print("S1_07_LEGACY result=PASS")
	else:
		print("S1_07_LEGACY result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
