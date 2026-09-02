class_name World
extends RefCounted
## world.gd — 固定步长仿真主循环（阶段一，无 UI）。
##
## 职责：
##   - 持有全部 Truth 实体（本艇 + 目标）、环境、传感器、测量生成器
##   - 按固定步长推进运动学
##   - 按各传感器 update_interval 触发测量生成
##   - 收集所有测量流（Measurement）
##   - 支持暂停 / 时间加速（1x/2x/4x/8x）——阶段三接 UI，阶段一保留接口
##
## Truth 隔离：本类只产出 Measurement，绝不把 Truth 位置直接暴露给上层 UI。

var world: Dictionary = {}
var sim_time: float = 0.0
var measurements: Array = []  # 全部生成的 Measurement
# Operator Layer：false 时传感器不再自动产生 Measurement，
# 测量只能由玩家 Mark / 已分配 Tracker / Autocrew 产生。
var auto_measurements: bool = true
var weapons: WeaponSystem = null  # 阶段四：发射管与在水鱼雷
var _sensor_timers: Dictionary = {}  # sensor_id -> 下次触发时间
var _paused: bool = false
var _time_scale: float = 1.0


## 从场景 JSON 构建并初始化世界。
func load_scenario(scenario: Dictionary) -> void:
	world = ScenarioLoader.build(scenario)
	sim_time = 0.0
	measurements.clear()
	weapons = WeaponSystem.new()
	_sensor_timers.clear()
	for s in world["sensors"]:
		_sensor_timers[s.sensor_id] = 0.0


## 推进内部仿真时间 dt（秒）。dt 已由上层按 time_scale 折算。
## 固定步长：world.dt 是每 tick 的物理步长。
func tick() -> void:
	if _paused:
		return
	if not auto_measurements:
		_advance_only()
		return
	var dt: float = world["dt"]
	sim_time += dt

	# 1) 推进所有 Truth 实体
	world["own"].advance(dt)
	for t in world["targets"]:
		t.advance(dt)

	# 2) 按传感器更新间隔触发测量
	for sensor in world["sensors"]:
		var next_t: float = _sensor_timers.get(sensor.sensor_id, 0.0)
		if sim_time >= next_t:
			_emit_for_sensor(sensor)
			_sensor_timers[sensor.sensor_id] = sim_time + sensor.update_interval_s

## 仅推进实体运动（Operator 模式：无自动测量）。
	# 3) 推进在水鱼雷（自导/命中为仿真引擎内部行为）
	if weapons != null and not weapons.torpedoes.is_empty():
		weapons.step(dt, sim_time, world["targets"])


func _advance_only() -> void:
	var dt: float = world["dt"]
	sim_time += dt
	world["own"].advance(dt)
	for t in world["targets"]:
		t.advance(dt)
	if weapons != null and not weapons.torpedoes.is_empty():
		weapons.step(dt, sim_time, world["targets"])


## 为某个传感器生成一次测量（针对所有目标）。
func _emit_for_sensor(sensor: RefCounted) -> void:
	var gen: RefCounted = world["generator"]
	for t in world["targets"]:
		var ac: RefCounted = world["target_acs"][t.id]
		var m: Measurement
		if sensor.array_type == "active":
			var ping_sl_db: float = 210.0  # 阶段一用默认值，后续外部化
			m = gen.generate_active(world["own"], t, ac, sensor, ping_sl_db, sim_time)
		else:
			m = gen.generate_passive(world["own"], t, ac, sensor, sim_time)
		measurements.append(m)


## 推进 n 个固定步长。
func run_steps(n: int) -> void:
	for i in range(n):
		tick()


func set_paused(p: bool) -> void:
	_paused = p


func is_paused() -> bool:
	return _paused


func set_time_scale(scale: float) -> void:
	_time_scale = maxf(scale, 1.0)


func time_scale() -> float:
	return _time_scale


## 当前所有测量（只读）。调试时可按需过滤。
func measurement_count() -> int:
	return measurements.size()
