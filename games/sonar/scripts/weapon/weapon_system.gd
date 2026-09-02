class_name WeaponSystem
extends RefCounted
## weapon_system.gd — 发射管 / 武器管理（阶段四）。
##
## 信息链纪律：fire() 只接受 SystemSolution（玩家提交的火控解），
## 绝不接受 TruthEntity。瞄准点 = 解位置按解航速航向外推 age 秒。

signal weapon_event(torpedo_id: String, kind: String, detail: Dictionary)

const TUBE_COUNT: int = 4
const MIN_FIRING_RANGE_M: float = 500.0
const MAX_FIRING_RANGE_M: float = 20000.0

var tubes: Array = []  # [{state: "EMPTY"/"LOADED"/"FIRED", torpedo_id}]
var torpedoes: Array = []  # 在水的 Torpedo
var _next_id: int = 1


func _init() -> void:
	for i in range(TUBE_COUNT):
		tubes.append({"state": "LOADED", "torpedo_id": ""})


func loaded_count() -> int:
	var n: int = 0
	for t in tubes:
		if t["state"] == "LOADED":
			n += 1
	return n


## 按火控解发射。own_e/own_n 为本艇当前位置。
## 返回 Torpedo 或 null（无管 / 解超界）。
func fire(sys: SystemSolution, own_e: float, own_n: float, sim_time: float) -> Torpedo:
	var tube_idx: int = -1
	for i in range(tubes.size()):
		if tubes[i]["state"] == "LOADED":
			tube_idx = i
			break
	if tube_idx < 0:
		weapon_event.emit("", "NO_TUBE", {})
		return null
	if sys == null or sys.range_m <= 0.0:
		weapon_event.emit("", "NO_SOLUTION", {})
		return null
	if sys.range_m < MIN_FIRING_RANGE_M or sys.range_m > MAX_FIRING_RANGE_M:
		weapon_event.emit("", "RANGE_INVALID", {"range_m": sys.range_m})
		return null

	# 瞄准点：解位置按解航速航向 + 解龄外推（只用解数据，非 Truth）
	var v_ms: float = NavUtils.kn_to_ms(sys.speed_kn)
	var dt_age: float = maxf(sim_time - sys.solution_time, 0.0)
	var adv: Dictionary = NavUtils.advance_pos(
		sys.estimated_position_east_m,
		sys.estimated_position_north_m,
		sys.course_deg,
		v_ms * dt_age,
		1.0
	)
	var aim_e: float = adv["x"]
	var aim_n: float = adv["y"]

	var tid: String = "T%02d" % _next_id
	_next_id += 1
	var tp := Torpedo.new()
	tp.launch(tid, own_e, own_n, aim_e, aim_n, sys.course_deg, sys.speed_kn, sim_time)
	tp.event_occurred.connect(
		func(tid2: String, kind: String, d: Dictionary): weapon_event.emit(tid2, kind, d)
	)
	torpedoes.append(tp)
	tubes[tube_idx]["state"] = "FIRED"
	tubes[tube_idx]["torpedo_id"] = tid
	weapon_event.emit(tid, "LAUNCH", {"aim_e": aim_e, "aim_n": aim_n, "tube": tube_idx})
	return tp


## 推进所有在水鱼雷（由 world.tick 每步调用）。
## targets 为 Truth 目标数组（仅自导/命中判定用）。
func step(dt: float, sim_time: float, targets: Array) -> Array:
	var events: Array = []
	for tp in torpedoes:
		tp.step(dt, sim_time, targets)
		events.append({"id": tp.torpedo_id, "state": _state_name(tp.state)})
	var dead: Array = torpedoes.filter(func(t): return t.is_dead())
	for d in dead:
		weapon_event.emit(d.torpedo_id, "TUBE_RELOAD", {})
		for t in tubes:
			if t["torpedo_id"] == d.torpedo_id and t["state"] == "FIRED":
				t["state"] = "LOADED"
				t["torpedo_id"] = ""
	torpedoes = torpedoes.filter(func(t): return not t.is_dead())
	return events


func _state_name(s: int) -> String:
	match s:
		Torpedo.State.RUN:
			return "RUN"
		Torpedo.State.SEARCH:
			return "SEARCH"
		Torpedo.State.PURSUIT:
			return "PURSUIT"
		Torpedo.State.DEAD:
			return "DEAD"
	return "STANDBY"
