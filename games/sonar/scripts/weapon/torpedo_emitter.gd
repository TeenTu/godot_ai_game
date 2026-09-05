class_name TorpedoEmitter
extends RefCounted
## torpedo_emitter.gd — 鱼雷声学广播子控制器（REQ 重构批拆分）。
##
## 只负责把鱼雷自身的声学事件（动力启动瞬态 / 主动 Ping / 航行噪声）写入
## AcousticEmissionBus。事件只带 torpedo_id 与自身状态/位置，绝不含任何
## 目标 Truth / target_id（§9.2 信息链纪律）。无总线时全部跳过（直接单测
## 不发射，行为与旧版一致）。

var bus: RefCounted = null  # AcousticEmissionBus（null=无总线）
var torpedo_id: String = ""
var profile: TorpedoAcousticProfile = null


## 动力启动瞬态（出管后进入 WIRE_RUN 时一次）。
func motor_start(pos: Vector3, sim_time: float) -> void:
	if bus == null or profile == null:
		return
	var t: Dictionary = profile.motor_start_transient
	(
		bus
		. record(
			AcousticEmissionEvent.TORPEDO_MOTOR_START,
			torpedo_id,
			sim_time,
			pos,
			float(t.get("center_frequency_hz", 800.0)),
			float(t.get("bandwidth_hz", 4000.0)),
			float(t.get("sl_db", 158.0)),
			float(t.get("duration_s", 1.5)),
		)
	)


## 主动 Ping 声学事件（每次进入 PINGING 记录；TOF/回波由 adapter 按
## tau=2R/c 延迟结算——绝不瞬时返回）。
func active_ping(pos: Vector3, sim_time: float, ping_id: String) -> void:
	if bus == null or profile == null:
		return
	(
		bus
		. record(
			AcousticEmissionEvent.TORPEDO_ACTIVE_PING,
			torpedo_id,
			sim_time,
			pos,
			profile.active_center_frequency_hz,
			profile.active_bandwidth_hz,
			profile.active_source_level_db,
			profile.active_pulse_duration_s,
			{"ping_id": ping_id},
		)
	)


## 航行噪声（持续声源）：源级随速度模式（§6.2：HIGH 更响）；事件 duration
## = 本次发射代表的一段时间。窄带谱线随模式（分类/频谱竞争的特征来源）。
func running_noise(
	pos: Vector3, sim_time: float, speed_mode_name: String, cadence_s: float
) -> void:
	if bus == null or profile == null:
		return
	var band: Vector2 = profile.running_noise_band_hz()
	var center: float = 0.5 * (band.x + band.y)
	var bw: float = maxf(band.y - band.x, 1.0)
	(
		bus
		. record(
			AcousticEmissionEvent.TORPEDO_RUNNING_NOISE,
			torpedo_id,
			sim_time,
			pos,
			center,
			bw,
			profile.own_noise_sl_db(speed_mode_name),
			cadence_s,
			{"tonal_lines": profile.tonal_lines(speed_mode_name)},
		)
	)
