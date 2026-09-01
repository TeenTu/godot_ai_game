extends RefCounted
class_name SensorArray
## sensor_array.gd — 声呐阵列（传感器）。
## 负责：被动/主动 SE 计算、概率探测 P_d、方位误差生成、Lofar 谱线生成。
## 所有随机用注入的 RNG（可复现）。不持有 UI 状态。

var sensor_id: String = ""
var array_type: String = "passive_broadband"   # passive_broadband / passive_narrowband / active
var owner_id: String = ""
var frequency_range: Vector2 = Vector2(100, 1000)  # (min, max) Hz

var array_gain_db: float = 0.0       # AG
var detection_threshold_db: float = 0.0  # DT
var detection_k_d: float = 3.0       # 概率过渡区宽度 k_d

# 方位误差模型
var bearing_sigma_min_deg: float = 0.5
var bearing_sigma_max_deg: float = 5.0
var bearing_se0_db: float = 6.0
var bearing_k_sigma_db: float = 4.0

var coverage_sector: Vector2 = Vector2(0, 360)  # (start, end) 覆盖扇区
var baffle_sector: Vector2 = Vector2(0, 0)      # 盲区（如舰尾挡板）
var update_interval_s: float = 1.0
var tracker_capacity: int = 64
var deployed: bool = true

var _rng: RandomNumberGenerator = null


## 绑定 RNG（可注入种子以复现）。
func set_rng(rng: RandomNumberGenerator) -> void:
	_rng = rng


func _randn() -> float:
	# 用 Box-Muller 从均匀随机生成标准正态样本（确定性可复现）。
	var u1: float = maxf(_rng.randf(), 0.000001)
	var u2: float = _rng.randf()
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


## 被动声呐 SE = SL - TL - N_eff + AG - DT。
## target_sl_db 是目标当前宽带声源级，freq 取探测频段中心。
func passive_signal_excess(target_sl_db: float, range_m: float, freq_hz: float, env: RefCounted, own_speed_kn: float) -> float:
	var tl: float = env.propagation_loss(range_m, freq_hz)
	var n_eff: float = env.effective_noise_db(freq_hz, own_speed_kn)
	return target_sl_db - tl - n_eff + array_gain_db - detection_threshold_db


## 主动声呐 SE = SL_ping - 2*TL + TS - N_eff + AG - DT（两次传播损失）。
func active_signal_excess(ping_sl_db: float, target_ts_db: float, range_m: float, freq_hz: float, env: RefCounted, own_speed_kn: float) -> float:
	var tl: float = env.propagation_loss(range_m, freq_hz)
	var n_eff: float = env.effective_noise_db(freq_hz, own_speed_kn)
	return ping_sl_db - 2.0 * tl + target_ts_db - n_eff + array_gain_db - detection_threshold_db


## 概率探测 P_d = 1 / (1 + exp(-SE/k_d))。连续、非硬门限。
func detection_probability(se_db: float) -> float:
	return 1.0 / (1.0 + exp(-se_db / detection_k_d))


## 方位标准差随 SE 下降（弱接触抖动大，强接触稳定）。
func bearing_sigma_deg(se_db: float) -> float:
	return bearing_sigma_min_deg \
		+ (bearing_sigma_max_deg - bearing_sigma_min_deg) \
		/ (1.0 + exp((se_db - bearing_se0_db) / bearing_k_sigma_db))


## 生成一次带噪方位测量。
## true_bearing_deg 为本艇到目标真实方位。返回测量方位与标准差。
func noisy_bearing(true_bearing_deg: float, se_db: float) -> Dictionary:
	var sigma: float = bearing_sigma_deg(se_db)
	var measured: float = nav_utils.wrap360(true_bearing_deg + _randn() * sigma)
	return {"bearing": measured, "sigma": sigma}


## 是否在覆盖扇区内（含挡板盲区判断）。
func in_coverage(relative_bearing_deg: float) -> bool:
	var rb: float = nav_utils.wrap360(relative_bearing_deg)
	if rb < coverage_sector.x or rb > coverage_sector.y:
		return false
	# 挡板盲区
	if baffle_sector.y > baffle_sector.x:
		if rb >= baffle_sector.x and rb <= baffle_sector.y:
			return false
	return true


func from_dict(d: Dictionary) -> void:
	sensor_id = str(d.get("sensor_id", sensor_id))
	array_type = str(d.get("array_type", array_type))
	owner_id = str(d.get("owner_id", owner_id))
	frequency_range = Vector2(
		float(d.get("freq_min_hz", frequency_range.x)),
		float(d.get("freq_max_hz", frequency_range.y)),
	)
	array_gain_db = float(d.get("array_gain_db", array_gain_db))
	detection_threshold_db = float(d.get("detection_threshold_db", detection_threshold_db))
	detection_k_d = float(d.get("detection_k_d", detection_k_d))
	bearing_sigma_min_deg = float(d.get("bearing_sigma_min_deg", bearing_sigma_min_deg))
	bearing_sigma_max_deg = float(d.get("bearing_sigma_max_deg", bearing_sigma_max_deg))
	bearing_se0_db = float(d.get("bearing_se0_db", bearing_se0_db))
	bearing_k_sigma_db = float(d.get("bearing_k_sigma_db", bearing_k_sigma_db))
	coverage_sector = Vector2(
		float(d.get("coverage_start_deg", coverage_sector.x)),
		float(d.get("coverage_end_deg", coverage_sector.y)),
	)
	baffle_sector = Vector2(
		float(d.get("baffle_start_deg", baffle_sector.x)),
		float(d.get("baffle_end_deg", baffle_sector.y)),
	)
	update_interval_s = float(d.get("update_interval_s", update_interval_s))
	tracker_capacity = int(d.get("tracker_capacity", tracker_capacity))
	deployed = bool(d.get("deployed", deployed))
