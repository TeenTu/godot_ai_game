class_name FuzeEngine
extends RefCounted
## fuze_engine.gd — S1-07 §10（Commit 10）引信引擎，从 World 抽出的纯内核件。
##
## REQ-08：tick 起始对 prev 位置做不可变快照，全部雷检查完后统一提交缓存
## （不受遍历顺序影响）。REQ-11：debug 调试台账（内核侧，仅 Debrief/面板）。
## P1-12.4：引信独立安全保险——对发射方本侧平台绝不起爆。
## S109 AT-41：激活中诱饵纳入双方引信接触集——敌雷命中玩家诱饵时在诱饵处
## 起爆（诱饵吸雷，本艇不错误终局）；对称地，己方雷也会被敌方诱饵吸爆。
## 爆炸结算仍在 World（敌=sunk/本艇=damaged + end_mission 唯一触发点）。

var min_pass: Dictionary = {}  # torpedo_id -> 最近通过距离（内核台账）
var alive: Dictionary = {}
## REQ-11：引信调试台账（torpedo_id -> {h_m, v_m, d3_m, t, ...}）。
var debug: Dictionary = {}
var _prev_tp: Dictionary = {}
var _prev_contact: Dictionary = {}
var _safety_latched: Dictionary = {}  # torpedo_id -> bool（本 tick 曾在水的记号）

var _w: RefCounted = null  # World（鸭子类型，避免与 World class_name 循环引用）


func bind_world(w: RefCounted) -> void:
	_w = w


func reset() -> void:
	min_pass.clear()
	alive.clear()
	debug.clear()
	_prev_tp.clear()
	_prev_contact.clear()
	_safety_latched.clear()


## 每 tick 推进。接触集构造（含 S109 AT-41 诱饵）在此完成。
func advance(sim_time: float, dt: float = 0.0) -> void:
	var prev_contact: Dictionary = _prev_contact.duplicate()
	var prev_tp: Dictionary = _prev_tp.duplicate()
	var new_prev_tp: Dictionary = {}
	var touched_contact: Dictionary = {}
	var enemy_side: String = (
		str(_w.enemy_ai.entity.side)
		if _w.enemy_ai != null and _w.enemy_ai.entity != null
		else "red"
	)
	if _w.weapons != null:
		var p_contacts: Array = _w.world["targets"].duplicate()
		# S109 AT-41：敌方激活诱饵纳入己方鱼雷引信接触集（纯声学竞争对称）。
		for d in _w.decoys:
			if str(d.side) == enemy_side and d.activated and not d.expired:
				p_contacts.append(d)
		for tp in _w.weapons.torpedoes:
			_step_torpedo(
				tp,
				p_contacts,
				true,
				prev_contact,
				prev_tp,
				new_prev_tp,
				touched_contact,
				sim_time,
				dt
			)
	if _w.enemy_weapons != null:
		var e_contacts: Array = [_w.world["own"]]
		# S109 AT-41：玩家激活诱饵纳入敌雷引信接触集——敌雷命中诱饵时在
		# 诱饵处起爆，本艇不错误终局（诱饵吸雷）。激活前静默/到期不入集。
		for d in _w.decoys:
			if str(d.side) != enemy_side and d.activated and not d.expired:
				e_contacts.append(d)
		for tp in _w.enemy_weapons.torpedoes:
			_step_torpedo(
				tp,
				e_contacts,
				false,
				prev_contact,
				prev_tp,
				new_prev_tp,
				touched_contact,
				sim_time,
				dt
			)
	# 全部检查完成后统一更新缓存（REQ-08：不在检查中途覆写 prev）。
	for cid in touched_contact:
		_prev_contact[cid] = touched_contact[cid]
	for tid in new_prev_tp:
		_prev_tp[tid] = new_prev_tp[tid]


func _step_torpedo(
	tp: RefCounted,
	contacts: Array,
	from_player: bool,
	prev_contact: Dictionary,
	prev_tp: Dictionary,
	new_prev_tp: Dictionary,
	touched_contact: Dictionary,
	sim_time: float,
	dt: float,
) -> void:
	if tp.is_dead() or not tp._in_water():
		alive.erase(str(tp.torpedo_id))
		_prev_tp.erase(str(tp.torpedo_id))
		return
	# P1-08/REQ-08：prev 从 tick 起始不可变快照读，末态写暂存，检查完统一提交。
	var tid: String = str(tp.torpedo_id)
	var tp_now := Vector3(float(tp.pos_east_m), float(tp.pos_north_m), float(tp.actual_depth_m))
	var tp_prev: Vector3 = tp_now
	if prev_tp.has(tid):
		tp_prev = prev_tp[tid]
	new_prev_tp[tid] = tp_now
	alive[tid] = true
	# 引信解保（§10.2 双保险；REQ-08 与 Torpedo 侧统一）。
	var since_launch: float = sim_time - float(tp._launch_t)
	var fc := FuzeController.new()
	var prog: WeaponProgram = tp.program
	fc.configure(prog.fuze_mode, prog.warhead_arm_distance_m)
	if not fc.is_armed(tp.traveled_m, since_launch):
		if (
			tp.fuze_state == tp.FuzeState.SAFE
			and tp.traveled_m >= prog.warhead_arm_distance_m
			and since_launch >= FuzeController.FUZE_MIN_ARM_TIME_S
		):
			tp.fuze_state = tp.FuzeState.ARMED
			tp.event_occurred.emit(tp.torpedo_id, "FUZE_ARMED", {"traveled_m": tp.traveled_m})
		return
	var dbg: Dictionary = debug.get(tid, {})  # REQ-11 调试台账
	dbg["fuze_mode"] = fc.fuze_mode
	dbg["armed"] = true
	dbg["sat_time_s"] = float(dbg.get("sat_time_s", 0.0)) + (dt if bool(tp.turn_saturated) else 0.0)
	var min_d: float = INF
	var min_v: float = INF
	var min_d3: float = INF
	for c in contacts:
		if str(c.damage_state) == "sunk":
			continue
		var c_now := Vector3(float(c.position_east_m), float(c.position_north_m), float(c.depth_m))
		var c_prev: Vector3 = c_now
		if prev_contact.has(str(c.id)):
			c_prev = prev_contact[str(c.id)]
		touched_contact[str(c.id)] = c_now
		var rel0 := c_prev - tp_prev
		var rel1 := c_now - tp_now
		var h0 := Vector2(rel0.x, rel0.y)
		var h1 := Vector2(rel1.x, rel1.y)
		var hd: float = FuzeController.swept_min_distance_h_m(h0, h1)
		min_d = minf(min_d, hd)
		min_d3 = minf(min_d3, FuzeController.swept_min_distance_m(rel0, rel1))
		var t_ca: float = FuzeController.swept_closest_t(h0, h1)
		min_v = minf(min_v, absf(lerpf(rel0.z, rel1.z, t_ca)))
	if min_d < float(min_pass.get(str(tp.torpedo_id), INF)):
		min_pass[str(tp.torpedo_id)] = min_d
	if min_d3 < float(dbg.get("d3_m", INF)):
		dbg["d3_m"] = min_d3
		dbg["h_m"] = min_d
		dbg["v_m"] = min_v
		dbg["t"] = sim_time
	debug[tid] = dbg
	# P1-12.4：引信独立安全保险——对发射方本侧平台绝不起爆。
	var safety_c: RefCounted = null
	if from_player:
		safety_c = _w.world["own"]
	elif _w.enemy_ai != null:
		safety_c = _w.enemy_ai.entity
	if safety_c != null:
		var s_now := Vector3(
			float(safety_c.position_east_m),
			float(safety_c.position_north_m),
			float(safety_c.depth_m),
		)
		var s_prev: Vector3 = s_now
		if prev_contact.has(str(safety_c.id)):
			s_prev = prev_contact[str(safety_c.id)]
		var sh0 := Vector2(s_prev.x - tp_prev.x, s_prev.y - tp_prev.y)
		var sh1 := Vector2(s_now.x - tp_now.x, s_now.y - tp_now.y)
		var sd: float = FuzeController.swept_min_distance_h_m(sh0, sh1)
		var sv: float = absf(s_now.z - tp_now.z)
		if sd <= fc.trigger_radius_m() and sv <= FuzeController.FUZE_VERTICAL_GATE_M:
			if not _safety_latched.has(tid):
				_safety_latched[tid] = true
				tp.event_occurred.emit(tid, "FUZE_SAFETY_INHIBIT", {"reason": "OWN_SIDE"})
			return
	# 几何触发判定（swept 连续碰撞；REQ-08：同一时刻水平+垂直同判）。
	var res: Dictionary = fc.check_trigger_swept(
		tp_now, tp_prev, contacts, prev_contact, fc.trigger_radius_m()
	)
	if not bool(res["triggered"]):
		return
	var contact: RefCounted = res["contact"]
	# REQ-08：起爆成功后才结算伤害/战果（detonate 二次查 ARMED，双保险）。
	if not tp.detonate({"min_distance_m": float(res["min_distance_m"])}):
		return
	# 爆炸结算：EXPLOSION 声学事件 + Truth 伤害。
	(
		_w
		. emission_bus
		. record(
			AcousticEmissionEvent.EXPLOSION,
			str(tp.torpedo_id),
			sim_time,
			Vector3(tp.pos_east_m, tp.pos_north_m, tp.actual_depth_m),
			500.0,
			4000.0,
			180.0,
			2.0,
		)
	)
	if not from_player:
		# 敌方鱼雷命中本艇（REQ-B5-02 唯一合法触发点：仅当接触=本艇；
		# 敌雷命中诱饵绝不触发）。原子顺序：EXPLOSION → sunk → end_mission →
		# mission_ended（信号在 end_mission 内发出）；同 tick 后续事件幂等。
		if contact == _w.world["own"]:
			_w.world["own"].damage_state = "sunk"
			_w.end_mission(_w.MissionState.PLAYER_DEFEATED, "TORPEDO_HIT")
	else:
		contact.damage_state = "sunk"
		# S1-11 D-10/AT-40：玩家鱼雷有效命中任务敌方目标 → 立即胜利，且只需一次。
		# 命中诱饵/非任务目标绝不触发（is_mission_target 只认场景敌对实体）。
		if _w.is_mission_target(contact):
			_w.end_mission(_w.MissionState.PLAYER_VICTORY, "TARGET_DESTROYED")
	(
		_w
		. _detonations
		. append(
			{
				"time": sim_time,
				"torpedo_id": str(tp.torpedo_id),
				"target_internal_ref": contact,
				"target_id_internal": str(contact.id),  # 仅 Debrief/调试通道
				"min_pass_distance_m": float(min_pass.get(str(tp.torpedo_id), min_d)),
				"detonated": true,
				"from_player": from_player,
			}
		)
	)
	alive.erase(tid)
	_prev_tp.erase(tid)
