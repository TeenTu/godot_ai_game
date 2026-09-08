class_name LaunchProgrammer
extends RefCounted
## launch_programmer.gd — REQ-0908 Batch 4：发射前武器编程控制器（REQ-B4-01/02）。
##
## 职责：把发射前面板的玩家可编辑项合并进各模式的推荐默认程序，交给
## WeaponSystem.fire_program 发射。绝不读取 Truth；SOLUTION 模式的解来源
## 绑定与 stale/mismatch 联锁由 FireControlContext.solution_for_fire 把关。
##
## 推荐默认（REQ-B4-02）：
##   SOLUTION      解外推拦截方位；自治 DISTANCE（授权距离=解射程×0.45，
##                 UI 明示）；主动 MANUAL；被动接收机默认 ON（鱼雷侧）。
##   BEARING_ONLY  只用选中 Contact 最新测量方位；宽扇区 60°；自治 TIME
##                 180s（可编辑，不隐藏在 MANUAL）；主动 MANUAL。
##   MANUAL        玩家显式航向（无 Track 也安全发射）；接管条件在 UI 显示。
##
## 编辑项（-1/-默认 = 沿用推荐值）：initial_course / search_center /
## search_half_angle / search_pattern / speed_mode / active / autonomy /
## wire_guidance_enabled / fuze_mode / warhead_arm_distance_m。

## 玩家可编辑草稿（<0 = 未改，用推荐默认）。
var initial_course_deg: float = -1.0
var search_center_deg: float = -1.0
var search_half_angle_deg: float = -1.0
var search_pattern: int = -1
var speed_mode: int = -1
var active_enable_mode: int = -1
var active_enable_value: float = -1.0  # DISTANCE=m / TIME=s / 其他忽略
var autonomy_enable_mode: int = -1
var autonomy_enable_value: float = -1.0
var wire_guidance_enabled: bool = true
var fuze_mode: String = FuzeController.FUZE_CONTACT
var warhead_arm_distance_m: float = 300.0
## 最近一次 build_program 的推荐说明（UI 明示授权条件/风险）。
var last_notice: String = ""


func build_program(
	mode: String,
	ws: WeaponSystem,
	world: World,
	fcc: FireControlContext,
	tracker: Tracker,
	selected_id: String,
) -> Dictionary:
	last_notice = ""
	var own: RefCounted = world.world["own"]
	var own_e: float = float(own.position_east_m)
	var own_n: float = float(own.position_north_m)
	var program: WeaponProgram = null
	if mode == "SOLUTION":
		var gate: Dictionary = fcc.solution_for_fire(selected_id, world.sim_time)
		if not bool(gate.get("ok", false)):
			return {"ok": false, "reason": str(gate.get("reason", "?"))}
		var sys: SystemSolution = gate["solution"]
		# 射程联锁（与 WeaponSystem.fire 一致）：解射程为正且出界时拒绝。
		# range_m <= 0（如 MULTIMODAL 无唯一射程）不拒绝——程序按拦截方位
		# 外推发射，不消费任何隐藏距离。
		if (
			sys.range_m > 0.0
			and (
				sys.range_m < WeaponSystem.MIN_FIRING_RANGE_M
				or sys.range_m > WeaponSystem.MAX_FIRING_RANGE_M
			)
		):
			return {"ok": false, "reason": "RANGE_INVALID"}
		program = ws._build_solution_program(sys, own_e, own_n, world.sim_time)
		var dist: float = clampf(sys.range_m * 0.45, 800.0, 8000.0)
		last_notice = (
			"SOLUTION src=%s v%d age=%.0fs | autonomy DISTANCE %.0fm (from est range %.0fm)"
			% [
				sys.source_track_id,
				sys.source_fit_version,
				world.sim_time - sys.solution_time,
				dist,
				sys.range_m
			]
		)
	elif mode == "BEARING_ONLY":
		var track: Track = tracker.track_by_id(selected_id) if tracker != null else null
		var lm: Measurement = track.latest_measurement() if track != null else null
		if lm == null:
			return {"ok": false, "reason": "no measurement on selected contact"}
		program = WeaponProgram.make_bearing_only(lm.measured_bearing_deg)
		last_notice = (
			"BEARING_ONLY brg %.1f° — no range/lead; wide %.0f° sector; autonomy TIME %.0fs"
			% [
				lm.measured_bearing_deg,
				program.search_half_angle_deg,
				program.autonomy_enable_time_s
			]
		)
	else:
		var crs: float = (
			NavUtils.wrap360(initial_course_deg)
			if initial_course_deg >= 0.0
			else float(own.course_deg)
		)
		program = WeaponProgram.make_manual(crs)
		last_notice = "MANUAL crs %.0f° — no guidance input; all takeover conditions shown" % crs
	_apply_overrides(program)
	ws._apply_depth_preset(program)
	return {"ok": true, "program": program, "reason": ""}


## 合并玩家编辑项（只有显式修改过的字段覆盖推荐默认）。
func _apply_overrides(p: WeaponProgram) -> void:
	if initial_course_deg >= 0.0 and p.fire_mode != WeaponProgram.FireMode.MANUAL:
		p.initial_course_deg = NavUtils.wrap360(initial_course_deg)
	if search_center_deg >= 0.0:
		p.search_center_deg = NavUtils.wrap360(search_center_deg)
	if search_half_angle_deg > 0.0:
		p.search_half_angle_deg = clampf(search_half_angle_deg, 1.0, 180.0)
	if search_pattern >= 0:
		p.search_pattern = search_pattern
	if speed_mode >= 0:
		p.speed_mode = speed_mode
	if active_enable_mode >= 0:
		p.active_enable_mode = active_enable_mode
		if active_enable_value >= 0.0:
			if active_enable_mode == WeaponProgram.ActiveEnableMode.DISTANCE:
				p.active_enable_distance_m = active_enable_value
			elif active_enable_mode == WeaponProgram.ActiveEnableMode.TIME:
				p.active_enable_time_s = active_enable_value
	if autonomy_enable_mode >= 0:
		p.autonomy_enable_mode = autonomy_enable_mode
		if autonomy_enable_value >= 0.0:
			if autonomy_enable_mode == WeaponProgram.AutonomyEnableMode.DISTANCE:
				p.autonomy_enable_distance_m = autonomy_enable_value
			elif autonomy_enable_mode == WeaponProgram.AutonomyEnableMode.TIME:
				p.autonomy_enable_time_s = autonomy_enable_value
	p.wire_guidance_enabled = wire_guidance_enabled
	p.fuze_mode = fuze_mode
	if warhead_arm_distance_m >= 0.0:
		p.warhead_arm_distance_m = warhead_arm_distance_m
	p.fallback_program = p.make_default_fallback()
