class_name EnemyDoctrineController
extends RefCounted
## enemy_doctrine_controller.gd — 敌方 Doctrine 状态机（S1-07 §9.7/§9.8，Commit 9）。
##
## 状态机：PATROL_PASSIVE → SUSPICIOUS → TRACKING → ATTACKING →（鱼雷告警）
## EVADING → REACQUIRE → PATROL_PASSIVE。
##
## 公平性（§9.8）：
##   - AI 只拿净化证据（方位/分类/置信），绝不读玩家 TruthEntity；
##   - 未探测到事件时 AI 行为绝不变（sensor 未产出证据即无感知）；
##   - 每个反应有 3..15s 可配置反应延迟，绝不同 tick 反应；
##   - 机动/换层/诱饵/反击按 doctrine 概率（独立派生 RNG），不靠 Truth 加成；
##   - 运动/换层全部走 TruthEntity 命令值接口（command_course/speed/depth），
##     实际值按速率逼近（AI-09）；
##   - AI 鱼雷经 BEARING_ONLY 宽扇区发射（无隐藏距离，AI-07）。
##
## World 是动作执行者：update() 返回动作列表（FIRE_TORPEDO/LAUNCH_DECOY），
## 机动与换层由本控制器直接写命令值（同一速率限制纪律）。

enum State { PATROL_PASSIVE, SUSPICIOUS, TRACKING, ATTACKING, EVADING, REACQUIRE }

var entity: RefCounted = null  # 敌方 TruthEntity（内核绑定，只写命令值）
var sensor: EnemySensorAdapter = null
var tracks: EnemyTrackManager = null
var doctrine: Dictionary = {}

var state: int = State.PATROL_PASSIVE

var _rng: RandomNumberGenerator = null
var _sample_timer_s: float = 0.0
var _pending: Array = []  # [{at, action}] 待反应（反应延迟，§9.8）
var _leg_until: float = 0.0
var _last_fire_t: float = -1e9
var _torpedo_count: int = 0
var _last_torpedo_alert_t: float = -1e9
var _evade_course_deg: float = -1.0


func configure(
	ent: RefCounted,
	sen: EnemySensorAdapter,
	mgr: EnemyTrackManager,
	doctrine_cfg: Dictionary,
	rng: RandomNumberGenerator
) -> void:
	entity = ent
	sensor = sen
	tracks = mgr
	doctrine = doctrine_cfg.duplicate(true)
	_rng = rng
	_sample_timer_s = 0.0
	_pending.clear()
	_leg_until = 0.0
	_last_fire_t = -1e9
	_torpedo_count = 0
	_last_torpedo_alert_t = -1e9
	state = State.PATROL_PASSIVE


func _d(key: String, fallback: Variant) -> Variant:
	return doctrine.get(key, fallback)


func state_name() -> String:
	return State.keys()[state] if state >= 0 and state < State.size() else "PATROL_PASSIVE"


## 周期推进：感知 → 航迹 → 状态转移（带反应延迟）→ 动作。
## 返回动作列表供 World 执行：{action:"FIRE_TORPEDO",...} / {action:"LAUNCH_DECOY",...}。
func update(now: float, dt: float, events: Array) -> Array:
	var actions: Array = []
	if entity == null or sensor == null or tracks == null:
		return actions

	# 1) 感知（固定采样间隔，§15.1）：被动接触 + 新事件截获。
	_sample_timer_s -= dt
	if _sample_timer_s <= 0.0:
		_sample_timer_s = float(_d("sample_interval_s", 2.0))
		for ev in sensor.sample_passive(entity, now):
			tracks.feed(ev, now)
	for ev in sensor.intercept_events(events, entity, now):
		tracks.feed(ev, now)
		if str(ev.get("source_class", "")) == "TORPEDO":
			_on_torpedo_alert(now)
	tracks.update(now)

	# 2) 反鱼雷告警优先：EVADING 态持续规避动作。
	if state == State.EVADING:
		_advance_evading(now, dt, actions)
		_due_actions(now, actions)
		return actions

	# 3) 状态转移（按最高质量航迹；全部经反应延迟调度）。
	var best: Dictionary = tracks.best_track()
	var q: float = float(best.get("quality", 0.0)) if not best.is_empty() else 0.0
	var fire_th: float = float(_d("fire_quality_threshold", 0.7))
	var track_th: float = float(_d("tracking_quality_threshold", 0.55))
	var susp_th: float = float(_d("suspicious_quality_threshold", 0.25))
	if q >= fire_th:
		_transition(State.ATTACKING, now)
		_try_counterfire(now, best)
	elif q >= track_th:
		_transition(State.TRACKING, now)
		_maybe_maneuver_for_tma()
	elif q >= susp_th:
		_transition(State.SUSPICIOUS, now)
		_maybe_suspicious_behavior()
	else:
		_transition(State.PATROL_PASSIVE, now)
		_patrol(now, dt)

	_due_actions(now, actions)
	return actions


## 反应延迟调度（§9.8）：动作在 now + U(min,max) 后执行，绝不同 tick 反应。
func _schedule(action: Dictionary, now: float) -> void:
	var lo: float = float(_d("reaction_delay_min_s", 3.0))
	var hi: float = maxf(float(_d("reaction_delay_max_s", 15.0)), lo)
	_pending.append({"at": now + _rng.randf_range(lo, hi), "action": action})


func _due_actions(now: float, actions: Array) -> void:
	var keep: Array = []
	for p in _pending:
		if now >= float(p["at"]):
			var a: Dictionary = p["action"]
			if str(a.get("action", "")) == "_REACQUIRE_TIMEOUT":
				if state == State.REACQUIRE:
					state = State.PATROL_PASSIVE  # 超时回通用巡逻（§9.7）
			elif str(a.get("action", "")) == "_EVADE_INIT":
				if state == State.EVADING:
					_plan_evasion(now)  # 规避动作到时执行（反应延迟已过）
			else:
				actions.append(a)
		else:
			keep.append(p)
	_pending = keep


func _transition(to: int, now: float) -> void:
	if state == to:
		return
	# EVADING 由鱼雷告警进入/退出（不因航迹质量下降静默回巡逻）。
	if state == State.EVADING and to != State.EVADING:
		return
	state = to
	if to == State.REACQUIRE:
		_reacquire_entered(now)


func _reacquire_entered(now: float) -> void:
	# 规避结束后按保存航迹被动重搜；无航迹则回巡逻（§9.7 REACQUIRE）。
	var t: float = float(_d("reacquire_timeout_s", 90.0))
	_pending.append({"at": now + t, "action": {"action": "_REACQUIRE_TIMEOUT"}})


func _on_torpedo_alert(now: float) -> void:
	_last_torpedo_alert_t = now
	if state == State.EVADING:
		return
	if _rng.randf() > float(_d("evade_trigger_probability", 0.9)):
		return
	state = State.EVADING
	# 规避动作经反应延迟调度（§9.8：绝不同 tick 反应）。
	_schedule({"action": "_EVADE_INIT"}, now)


## 规避计划（§9.7 EVADING）：变向（背离鱼雷方位）、变速、换层、放诱饵——
## 全部按 doctrine 概率 + 反应延迟；命令值接口 + 有限速率（AI-09）。
func _plan_evasion(now: float) -> void:
	var tt: Dictionary = tracks.torpedo_track(now)
	var away: float = (
		NavUtils.wrap360(float(tt.get("bearing_est_deg", 0.0)) + 180.0)
		if not tt.is_empty()
		else _rng.randf() * 360.0
	)
	_away_course(away)
	if _rng.randf() < float(_d("evade_speed_change_probability", 0.8)):
		entity.command_speed(float(_d("evade_speed_kn", 14.0)))
	if _rng.randf() < float(_d("layer_change_probability", 0.4)):
		var dm_band: String = "LOWER" if _depth_band() == "UPPER" else "UPPER"
		entity.command_depth(float(_d("evade_other_band_hold_depth_m", 180.0)))
		doctrine["_evade_band"] = dm_band
	if _rng.randf() < float(_d("decoy_launch_probability", 0.7)):
		_schedule({"action": "LAUNCH_DECOY", "bearing_deg": _rng.randf() * 360.0}, now)


## 背离航向：一次性命令（±10° 抖动）；后续持续修正见 _advance_evading。
func _away_course(away_bearing: float) -> void:
	_evade_course_deg = NavUtils.wrap360(away_bearing + _rng.randf_range(-10.0, 10.0))
	entity.command_course(_evade_course_deg)


func _advance_evading(now: float, dt: float, actions: Array) -> void:
	# 持续背离：实际航向按速率逼近命令（TruthEntity 命令纪律）；诱饵按冷却
	# 间隔追加；告警陈旧 → REACQUIRE。
	if _evade_course_deg >= 0.0:
		var err: float = absf(NavUtils.wrap180(float(entity.course_deg) - _evade_course_deg))
		if err > 15.0 and entity.commanded_course_deg < 0.0:
			_away_course(_evade_course_deg)
	var cd: float = float(_d("evade_decoy_interval_s", 45.0))
	if _rng.randf() < float(_d("decoy_launch_probability", 0.7)) * dt / maxf(cd, 1.0):
		actions.append({"action": "LAUNCH_DECOY", "bearing_deg": _rng.randf() * 360.0})
	if now - _last_torpedo_alert_t > float(_d("evade_sustain_s", 120.0)):
		state = State.REACQUIRE
		_reacquire_entered(now)


## ---- 巡逻 / 悬疑 / 跟踪行为（§9.7）----


func _patrol(now: float, _dt: float) -> void:
	# 随机巡逻腿：绝不朝玩家 Truth 追踪（只按自己的轴/随机角）。
	if now >= _leg_until:
		var lo: float = float(_d("patrol_leg_time_min_s", 60.0))
		var hi: float = maxf(float(_d("patrol_leg_time_max_s", 180.0)), lo)
		_leg_until = now + _rng.randf_range(lo, hi)
		var course: float = _patrol_course()
		entity.command_course(course)
		if _rng.randf() < 0.3:
			entity.command_speed(float(_d("patrol_speed_kn", 6.0)))


func _patrol_course() -> float:
	if str(_d("course_distribution", "UNIFORM")) == "PATROL_BIASED":
		var axis: float = float(_d("patrol_axis_deg", 0.0))
		var spread: float = float(_d("patrol_spread_deg", 60.0))
		return NavUtils.wrap360(axis + _rng.randf_range(-spread, spread))
	return _rng.randf() * 360.0


func _maybe_suspicious_behavior() -> void:
	# 悬疑：降速建立观测基线；不生成伪精确距离（§9.7 SUSPICIOUS）。
	if _rng.randf() < 0.02:
		entity.command_speed(float(_d("suspicious_speed_kn", 4.0)))
		var best: Dictionary = tracks.best_track()
		if not best.is_empty() and _rng.randf() < float(_d("maneuver_for_tma_probability", 0.5)):
			entity.command_course(NavUtils.wrap360(float(best["bearing_est_deg"]) + 60.0))


func _maybe_maneuver_for_tma() -> void:
	if _rng.randf() < float(_d("maneuver_for_tma_probability", 0.5)) * 0.01:
		var best: Dictionary = tracks.best_track()
		if not best.is_empty():
			entity.command_course(NavUtils.wrap360(float(best["bearing_est_deg"]) + 60.0))


## ---- 反击（§9.7 ATTACKING）----


func _try_counterfire(now: float, best: Dictionary) -> void:
	var max_w: int = int(_d("max_simultaneous_weapons", 1))
	if _torpedo_count >= max_w:
		return
	if now - _last_fire_t < float(_d("counterfire_cooldown_s", 120.0)):
		return
	if _rng.randf() > float(_d("counterfire_probability", 0.5)):
		return
	# 只有较可信方位 → BEARING_ONLY 宽扇区（无隐藏距离，AI-07；SOLUTION 需
	# 敌方自建 range 证据，本版敌方无主动声呐，接口留给后续）。
	_last_fire_t = now
	_torpedo_count += 1
	_schedule(
		{
			"action": "FIRE_TORPEDO",
			"bearing_deg": float(best["bearing_est_deg"]),
			"quality": float(best["quality"]),
			"speed_kn": float(entity.speed_kn),
			"fire_mode": "BEARING_ONLY",
		},
		now,
	)


## World 回调：敌方鱼雷死亡/耗尽后归还并发余量。
func notify_torpedo_resolved() -> void:
	_torpedo_count = maxi(_torpedo_count - 1, 0)


## P1-09：在水武器计数只读视图（World 结算释放后应递减；测试/诊断用）。
func active_torpedo_count() -> int:
	return _torpedo_count


func _depth_band() -> String:
	var dm: Variant = sensor.depth_model if sensor != null else null
	if dm != null and bool(dm.get("enabled")):
		var b: String = str(dm.call("depth_band", float(entity.depth_m)))
		return "LOWER" if b == "LOWER" else "UPPER"
	return "UPPER" if float(entity.depth_m) < 120.0 else "LOWER"
