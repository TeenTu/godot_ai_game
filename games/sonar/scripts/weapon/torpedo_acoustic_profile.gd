class_name TorpedoAcousticProfile
extends RefCounted
## torpedo_acoustic_profile.gd — 鱼雷声学画像（S1-07 §6.1/§6.2，Commit 5）。
##
## 纯数据 + 派生查询，无 Truth、无传感器逻辑。负责把"速度模式"映射到：
##   - 对地速度与续航（§6.2：QUIET 低噪低俗长续航 / CRUISE 平衡 / HIGH 高速
##     高噪短续航——不得只改地图速度而不改声学与续航）；
##   - 鱼雷自身辐射噪声源级（运行噪声，可被探测；自身 N_eff 耦合在 Commit 6
##     被动 Seeker 方程中消费）；
##   - 主动发射机参数（中心频率/带宽/源级/脉宽/周期，§6.1/§6.4 PingSession）；
##   - 出管瞬态 / 动力启动瞬态（§9.2 发射声三阶段之二）。
##
## 数值为游戏性标定（§18：不宣称复现任何现实武器机密参数），全部可配置。

## ---- 速度模式 → 速度 / 续航 / 运行噪声源级（String 键："QUIET"/"CRUISE"/"HIGH"）
var speed_kn_by_mode: Dictionary = {"QUIET": 28.0, "CRUISE": 40.0, "HIGH": 50.0}
var endurance_s_by_mode: Dictionary = {"QUIET": 1800.0, "CRUISE": 1200.0, "HIGH": 800.0}
## 运行噪声宽带源级（SL@1m 游戏标定；越高越易被被动探测）。
var own_noise_sl_db_by_mode: Dictionary = {"QUIET": 112.0, "CRUISE": 128.0, "HIGH": 146.0}

## ---- 被动接收（§6.1；Seeker 采样 Commit 6 消费，本批先承载参数）
var passive_frequency_min_hz: float = 100.0
var passive_frequency_max_hz: float = 3000.0

## ---- 主动发射机（§6.1/§6.4）
var active_center_frequency_hz: float = 12000.0
var active_bandwidth_hz: float = 4000.0
var active_source_level_db: float = 195.0
var active_pulse_duration_s: float = 0.02
var active_ping_interval_s: float = 8.0

## ---- 接收机参数（Commit 6 被动/主动 Seeker 方程消费）
var receiver_array_gain_db: float = 12.0
var detection_threshold_db: float = 0.0
var detection_k_d: float = AcousticService.DEFAULT_K_D
var horizontal_beamwidth_deg: float = 120.0

## ---- 发射声两阶段（§9.2）
var tube_launch_transient: Dictionary = {
	"sl_db": 168.0, "duration_s": 0.5, "bandwidth_hz": 8000.0, "center_frequency_hz": 1500.0
}
var motor_start_transient: Dictionary = {
	"sl_db": 158.0, "duration_s": 1.5, "bandwidth_hz": 4000.0, "center_frequency_hz": 800.0
}

## ---- 方位/测距误差模型（§6.1，Commit 6 消费）
var bearing_sigma_min_deg: float = 0.5
var bearing_sigma_max_deg: float = 5.0
var range_sigma_model: Dictionary = {}


static func make_default() -> TorpedoAcousticProfile:
	return TorpedoAcousticProfile.new()


func speed_kn(mode_name: String) -> float:
	return float(speed_kn_by_mode.get(mode_name, speed_kn_by_mode.get("CRUISE", 40.0)))


func endurance_s(mode_name: String) -> float:
	return float(endurance_s_by_mode.get(mode_name, endurance_s_by_mode.get("CRUISE", 1200.0)))


## 运行噪声宽带源级（§6.2：HIGH > CRUISE > QUIET，可探测性随速度上升）。
func own_noise_sl_db(mode_name: String) -> float:
	return float(
		own_noise_sl_db_by_mode.get(mode_name, own_noise_sl_db_by_mode.get("CRUISE", 128.0))
	)


## 运行噪声频带 (min_hz, max_hz)：宽带辐射取被动接收频段，简单一致。
func running_noise_band_hz() -> Vector2:
	return Vector2(passive_frequency_min_hz, passive_frequency_max_hz)


## 从场景/配置字典覆盖（未给出的键保持现值）。
func from_dict(d: Dictionary) -> void:
	speed_kn_by_mode = d.get("speed_kn_by_mode", speed_kn_by_mode)
	endurance_s_by_mode = d.get("endurance_s_by_mode", endurance_s_by_mode)
	own_noise_sl_db_by_mode = d.get("own_noise_sl_db_by_mode", own_noise_sl_db_by_mode)
	passive_frequency_min_hz = float(d.get("passive_frequency_min_hz", passive_frequency_min_hz))
	passive_frequency_max_hz = float(d.get("passive_frequency_max_hz", passive_frequency_max_hz))
	active_center_frequency_hz = float(
		d.get("active_center_frequency_hz", active_center_frequency_hz)
	)
	active_bandwidth_hz = float(d.get("active_bandwidth_hz", active_bandwidth_hz))
	active_source_level_db = float(d.get("active_source_level_db", active_source_level_db))
	active_pulse_duration_s = float(d.get("active_pulse_duration_s", active_pulse_duration_s))
	active_ping_interval_s = float(d.get("active_ping_interval_s", active_ping_interval_s))
	receiver_array_gain_db = float(d.get("receiver_array_gain_db", receiver_array_gain_db))
	detection_threshold_db = float(d.get("detection_threshold_db", detection_threshold_db))
	detection_k_d = float(d.get("detection_k_d", detection_k_d))
	horizontal_beamwidth_deg = float(d.get("horizontal_beamwidth_deg", horizontal_beamwidth_deg))
	tube_launch_transient = d.get("tube_launch_transient", tube_launch_transient)
	motor_start_transient = d.get("motor_start_transient", motor_start_transient)
	bearing_sigma_min_deg = float(d.get("bearing_sigma_min_deg", bearing_sigma_min_deg))
	bearing_sigma_max_deg = float(d.get("bearing_sigma_max_deg", bearing_sigma_max_deg))
	range_sigma_model = d.get("range_sigma_model", range_sigma_model)
