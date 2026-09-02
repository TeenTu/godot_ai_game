class_name Torpedo
extends RefCounted
## torpedo.gd — 鱼雷实体（阶段四：武器与攻击）。
##
## 信息链纪律：
##   - 发射决策 / 初始瞄准点只来自 SystemSolution（玩家提交的火控解）；
##   - 航行/搜索段绝不读目标 Truth；
##   - 声自导捕获与命中判定是「仿真引擎内部」的探测行为，与传感器同类，
##     允许在本类 step() 内接触 Truth targets，但对外只暴露状态/位置/事件。
##
## 生命周期：
##   STANDBY → RUN（直航到 enable 点，未开自导）→ SEARCH（蛇形/圆形搜索）
##   → PURSUIT（自导锁定追踪）→ DEAD（命中 / 燃料耗尽 / 自毁）

signal event_occurred(torpedo_id: String, kind: String, detail: Dictionary)

enum State { STANDBY, RUN, SEARCH, PURSUIT, DEAD }

const WEAPON_SPEED_KN: float = 45.0
const ENABLE_RANGE_M: float = 1500.0  # 安全距离后开启自导
const SEEKER_RANGE_M: float = 900.0  # 自导捕获半径（主动声自导）
const SEEKER_CONE_DEG: float = 120.0  # 自导扇区（半角*2）
const HIT_RADIUS_M: float = 60.0
const ENDURANCE_S: float = 1200.0
const SEARCH_TURN_RATE_DEG_S: float = 8.0  # 搜索圈角速度
const SEARCH_LEG_S: float = 90.0  # 蛇形搜索每段直航时长

var torpedo_id: String = ""
var state: int = State.STANDBY
var pos_east_m: float = 0.0
var pos_north_m: float = 0.0
var course_deg: float = 0.0
var speed_kn: float = WEAPON_SPEED_KN
var fuel_left_s: float = ENDURANCE_S

# 发射时装入的火控信息（来自 SystemSolution，非 Truth）
var aim_east_m: float = 0.0
var aim_north_m: float = 0.0
var tgt_course_deg: float = 0.0
var tgt_speed_kn: float = 0.0

var trail: Array = []  # [{e, n, t}] 供海图画轨迹（自身状态，非 Truth）
var _search_phase_s: float = 0.0
var _search_leg: int = 0
var _acq_tgt: RefCounted = null  # 当前锁定的 Truth 引用（仅引擎内部）


## 用火控解初始化（aim 为解外推的预期目标位置）。
func launch(
	id: String,
	from_e: float,
	from_n: float,
	aim_e: float,
	aim_n: float,
	t_course: float,
	t_speed: float,
	sim_time: float
) -> void:
	torpedo_id = id
	state = State.RUN
	pos_east_m = from_e
	pos_north_m = from_n
	aim_east_m = aim_e
	aim_north_m = aim_n
	tgt_course_deg = t_course
	tgt_speed_kn = t_speed
	# 初始航向直指瞄准点
	course_deg = NavUtils.wrap360(rad_to_deg(atan2(aim_e - from_e, aim_n - from_n)))
	trail.append({"e": from_e, "n": from_n, "t": sim_time})
	event_occurred.emit(torpedo_id, "LAUNCH", {"course_deg": course_deg})


func is_dead() -> bool:
	return state == State.DEAD


## 推进一步（dt 秒）。targets 为 Truth 目标数组（仅供自导捕获/命中判定）。
## 返回 true 表示发生事件（捕获/命中/耗尽），事件通过 event_occurred 发出。
func step(dt: float, sim_time: float, targets: Array) -> bool:
	if state == State.DEAD or state == State.STANDBY:
		return false
	fuel_left_s -= dt
	if fuel_left_s <= 0.0:
		_die("FUEL_OUT", {})
		return true

	var fired_event: bool = false
	match state:
		State.RUN:
			# 直航到 enable 点（航程超过 enable 距离或已接近瞄准点即开自导）
			var d_aim: float = Vector2(aim_east_m - pos_east_m, aim_north_m - pos_north_m).length()
			var traveled: float = (ENDURANCE_S - fuel_left_s) * speed_kn * NavUtils.KNOT_TO_MS
			if traveled >= ENABLE_RANGE_M or d_aim < SEEKER_RANGE_M * 0.6:
				state = State.SEARCH
				_search_phase_s = 0.0
				_search_leg = 0
				event_occurred.emit(torpedo_id, "ENABLE", {"range_m": traveled})
				fired_event = true
		State.SEARCH:
			# 蛇形搜索：直航 SEARCH_LEG_S 秒，然后大舵角转向 120°，
			# 形成扩张扫掠；也覆盖瞄准点附近区域
			_search_phase_s += dt
			if _search_phase_s >= SEARCH_LEG_S:
				_search_phase_s = 0.0
				_search_leg += 1
				course_deg = NavUtils.wrap360(course_deg + 120.0)
		State.PURSUIT:
			if _acq_tgt != null and str(_acq_tgt.damage_state) != "sunk":
				var brg: float = NavUtils.bearing_to_true(
					pos_east_m,
					pos_north_m,
					float(_acq_tgt.position_east_m),
					float(_acq_tgt.position_north_m)
				)
				course_deg = brg
			else:
				_acq_tgt = null
				state = State.SEARCH

	# 匀速平移
	var v_ms: float = NavUtils.kn_to_ms(speed_kn)
	var next: Dictionary = NavUtils.advance_pos(pos_east_m, pos_north_m, course_deg, v_ms, dt)
	pos_east_m = next["x"]
	pos_north_m = next["y"]
	trail.append({"e": pos_east_m, "n": pos_north_m, "t": sim_time})
	if trail.size() > 4000:
		trail.pop_front()

	# 自导捕获（RUN 段不开自导；SEARCH/PURSUIT 段开启）
	if state != State.RUN:
		fired_event = fired_event or _seek(targets)
	return fired_event


## 主动声自导：在扇区内找最近目标，进入 PURSUIT；贴上即命中。
func _seek(targets: Array) -> bool:
	var best: RefCounted = null
	var best_r: float = SEEKER_RANGE_M
	for t in targets:
		if t == null or str(t.damage_state) == "sunk":
			continue
		var d := Vector2(
			float(t.position_east_m) - pos_east_m, float(t.position_north_m) - pos_north_m
		)
		var r: float = d.length()
		if r > best_r:
			continue
		var brg: float = NavUtils.wrap360(rad_to_deg(atan2(d.x, d.y)))
		if absf(NavUtils.angle_diff(brg, course_deg)) > SEEKER_CONE_DEG * 0.5:
			continue
		best = t
		best_r = r
	var fired_event: bool = false
	if best != null and state != State.PURSUIT:
		_acq_tgt = best
		state = State.PURSUIT
		event_occurred.emit(torpedo_id, "ACQUIRE", {"range_m": best_r})
		fired_event = true
	if _acq_tgt != null and best_r < HIT_RADIUS_M:
		_acq_tgt.damage_state = "sunk"
		event_occurred.emit(torpedo_id, "HIT", {"target_id": str(_acq_tgt.id), "range_m": best_r})
		_die("HIT", {"target_id": str(_acq_tgt.id)})
		fired_event = true
	return fired_event


func _die(kind: String, detail: Dictionary) -> void:
	state = State.DEAD
	event_occurred.emit(torpedo_id, kind, detail)
