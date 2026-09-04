class_name WeaponSystem
extends RefCounted
## weapon_system.gd — 发射管 / 武器管理（S1-07 正交 TubeState 版，Commit 3）。
##
## 信息链纪律（S1-07 §2.1）：fire() 只接受 SystemSolution（玩家提交的火控解）
## 或已构造的 WeaponProgram，绝不接受 TruthEntity。瞄准点 = 解位置按解航速
## 航向外推 age 秒（只用解数据，非 Truth）。
##
## 发射模式（S1-07 §5.2，Commit 3）：SystemSolution 变成可选预填——
##   SOLUTION       fire(sys, ...)（保留射程联锁）；
##   MANUAL         fire_manual(course,...)（无解，无射程概念）；
##   BEARING_ONLY   fire_bearing_only(bearing,...)（无解只有方位，无隐藏距离）。
## 三者最终都走 fire_program（管 LOADED + 程序合法 → 发射 → 管 EMPTY）。
##
## 发射管状态（S1-07 §3.1）：
##   LOADED → FIRING → EMPTY →（RELOADING 预留）→ LOADED
## 阶段一规则：发射后保持 EMPTY；真实再装填时间与库存后移，绝不因鱼雷命中、
## 耗尽或自毁而自动补回（reload_tube 由上层显式调用）。

signal weapon_event(torpedo_id: String, kind: String, detail: Dictionary)

enum TubeState { EMPTY, LOADED, FIRING, RELOADING }

const TUBE_COUNT: int = 4
const MIN_FIRING_RANGE_M: float = 500.0
const MAX_FIRING_RANGE_M: float = 20000.0

var tubes: Array = []  # [{state: TubeState, torpedo_id}]
var torpedoes: Array = []  # 在水的 Torpedo
# Commit 5：声学事件总线（由 World 注入；null=无总线跳过发射瞬态广播）。
var emission_bus: AcousticEmissionBus = null
## 鱼雷 id 前缀（Commit 10：敌方发射器用 "ET"，与玩家 "T" 区分——净化器
## 按前缀/集合判定本艇事实 vs 敌方截获）。
var id_prefix: String = "T"
var _next_id: int = 1


func _init() -> void:
	for i in range(TUBE_COUNT):
		tubes.append({"state": TubeState.LOADED, "torpedo_id": ""})


func loaded_count() -> int:
	var n: int = 0
	for t in tubes:
		if t["state"] == TubeState.LOADED:
			n += 1
	return n


func tube_state_name(idx: int) -> String:
	if idx < 0 or idx >= tubes.size():
		return "?"
	match tubes[idx]["state"]:
		TubeState.FIRING:
			return "FIRING"
		TubeState.RELOADING:
			return "RELOADING"
		TubeState.EMPTY:
			return "EMPTY"
	return "LOADED"


## 显式装填（Commit 3 起由再装填计时/库存驱动；本批供测试与演示调用）。
func reload_tube(idx: int) -> bool:
	if idx < 0 or idx >= tubes.size():
		return false
	if tubes[idx]["state"] != TubeState.EMPTY:
		return false
	tubes[idx]["state"] = TubeState.LOADED
	tubes[idx]["torpedo_id"] = ""
	return true


## 按 SystemSolution 发射（SOLUTION 模式，保留射程联锁：解有射程概念）。
## own_depth_m：发射平台当前深度（鱼雷初始深度）。
func fire(
	sys: SystemSolution, own_e: float, own_n: float, sim_time: float, own_depth_m: float = 50.0
) -> Torpedo:
	if sys == null or sys.range_m <= 0.0:
		weapon_event.emit("", "NO_SOLUTION", {})
		return null
	if sys.range_m < MIN_FIRING_RANGE_M or sys.range_m > MAX_FIRING_RANGE_M:
		weapon_event.emit("", "RANGE_INVALID", {"range_m": sys.range_m})
		return null
	var program: WeaponProgram = _build_solution_program(sys, own_e, own_n, sim_time)
	return fire_program(program, own_e, own_n, sim_time, own_depth_m)


## S1-07 §5.2 MANUAL：无 SystemSolution 也可发射（随时可发射 = 解不是许可）。
## 无距离概念 → 不触发射程联锁，只受 fire_program 的管/程序联锁约束。
func fire_manual(
	course_deg: float,
	own_e: float,
	own_n: float,
	sim_time: float,
	own_depth_m: float = 50.0,
	initial_depth_band: String = WeaponProgram.DEPTH_BAND_UPPER,
) -> Torpedo:
	var program: WeaponProgram = WeaponProgram.make_manual(course_deg, initial_depth_band)
	return fire_program(program, own_e, own_n, sim_time, own_depth_m)


## S1-07 §5.2 BEARING_ONLY：只有玩家可见方位即可发射；程序不含任何隐藏距离。
func fire_bearing_only(
	bearing_deg: float, own_e: float, own_n: float, sim_time: float, own_depth_m: float = 50.0
) -> Torpedo:
	var program: WeaponProgram = WeaponProgram.make_bearing_only(bearing_deg)
	return fire_program(program, own_e, own_n, sim_time, own_depth_m)


## 用已构造程序发射（SOLUTION 预填后玩家编辑、以及后续 MANUAL/BEARING_ONLY
## 共用此路径）。程序先 snapshot 再交给鱼雷，保证不可变。
func fire_program(
	program: WeaponProgram, own_e: float, own_n: float, sim_time: float, own_depth_m: float = 50.0
) -> Torpedo:
	var tube_idx: int = -1
	for i in range(tubes.size()):
		if tubes[i]["state"] == TubeState.LOADED:
			tube_idx = i
			break
	if tube_idx < 0:
		weapon_event.emit("", "NO_TUBE", {})
		return null
	if program == null:
		weapon_event.emit("", "INVALID_PROGRAM", {})
		return null
	var errs: Array = program.validation_errors()
	if not errs.is_empty():
		weapon_event.emit("", "INVALID_PROGRAM", {"errors": errs})
		return null

	var tid: String = "T%02d" % _next_id
	_next_id += 1
	var tp := Torpedo.new()
	tp.launch(tid, program, own_e, own_n, own_depth_m, sim_time)
	# Commit 5（§9.2）：出管瞬态声源（发射平台位置/深度，一次；不保证被发现）。
	if emission_bus != null and tp.acoustic_profile != null:
		var t: Dictionary = tp.acoustic_profile.tube_launch_transient
		(
			emission_bus
			. record(
				AcousticEmissionEvent.TORPEDO_TUBE_TRANSIENT,
				tid,
				sim_time,
				Vector3(own_e, own_n, own_depth_m),
				float(t.get("center_frequency_hz", 1500.0)),
				float(t.get("bandwidth_hz", 8000.0)),
				float(t.get("sl_db", 168.0)),
				float(t.get("duration_s", 0.5)),
			)
		)
	tp.event_occurred.connect(
		func(tid2: String, kind: String, d: Dictionary): weapon_event.emit(tid2, kind, d)
	)
	torpedoes.append(tp)
	tubes[tube_idx]["state"] = TubeState.FIRING
	tubes[tube_idx]["torpedo_id"] = tid
	weapon_event.emit(
		tid, "LAUNCH", {"tube": tube_idx, "fire_mode": _fire_mode_name(program.fire_mode)}
	)
	# 出管即 EMPTY（S1-07 §3.1：发射后保持 EMPTY，不瞬时补装）。
	tubes[tube_idx]["state"] = TubeState.EMPTY
	return tp


## 由 SystemSolution 构建 SOLUTION 程序（瞄准点 = 解位置按解航速/航向 + 解龄
## 外推；只用解数据，非 Truth）。玩家修改后会以 snapshot 形式成为实际程序。
func _build_solution_program(
	sys: SystemSolution, own_e: float, own_n: float, sim_time: float
) -> WeaponProgram:
	var v_ms: float = NavUtils.kn_to_ms(sys.speed_kn)
	var dt_age: float = maxf(sim_time - sys.solution_time, 0.0)
	var adv: Dictionary = (
		NavUtils
		. advance_pos(
			sys.estimated_position_east_m,
			sys.estimated_position_north_m,
			sys.course_deg,
			v_ms * dt_age,
			1.0,
		)
	)
	var aim_e: float = adv["x"]
	var aim_n: float = adv["y"]
	var lead_bearing: float = NavUtils.wrap360(rad_to_deg(atan2(aim_e - own_e, aim_n - own_n)))
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.SOLUTION
	p.initial_course_deg = lead_bearing
	p.search_center_deg = lead_bearing
	p.search_half_angle_deg = 30.0
	p.speed_mode = WeaponProgram.SpeedMode.CRUISE
	p.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	p.wire_guidance_enabled = true
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 300.0
	p.fallback_program = p.make_default_fallback()
	return p


## 推进所有在水鱼雷（由 world.tick 每步调用）。
## ctx: TorpedoContext（服务接口；绝不含 Truth targets）。
func step(dt: float, sim_time: float, ctx: RefCounted) -> Array:
	var events: Array = []
	for tp in torpedoes:
		tp.step(dt, sim_time, ctx)
		events.append({"id": tp.torpedo_id, "state": tp.mission_state_name()})
	var dead: Array = torpedoes.filter(func(t): return t.is_dead())
	for d in dead:
		# S1-07 §3.1：发射管保持 EMPTY，绝不自动补装。
		for t in tubes:
			if t["torpedo_id"] == d.torpedo_id and t["state"] == TubeState.EMPTY:
				t["torpedo_id"] = ""
	torpedoes = torpedoes.filter(func(t): return not t.is_dead())
	return events


func _fire_mode_name(m: int) -> String:
	return WeaponProgram.fire_mode_name(m)
