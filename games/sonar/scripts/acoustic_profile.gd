extends RefCounted
class_name AcousticProfile
## acoustic_profile.gd — 平台声学特征（Truth 层派生参数）。
## 负责从平台状态 + 声学特征计算"瞬时声源级 SL"与"空化状态"。

var broadband_base_level_db: float = 0.0       # SL0
var speed_noise_a: float = 15.0                # A：速度噪声斜率
var speed_noise_n: float = 2.0                 # n：速度指数
var speed_noise_vref_kn: float = 5.0           # Vref

var cavitation_speed_kn_at_surface: float = 12.0   # 水面空化临界速度
var cavitation_depth_slope: float = 1.2            # 每米深度提升的空化临界速度增量
var cavitation_extra_db: float = 12.0              # C_cav：空化附加声级

var tonal_lines: Array = []      # [{freq_hz, level_db}] 窄带谱线
var turns_per_knot: int = 1
var blade_count: int = 7
var shaft_count: int = 1
var active_target_strength_db: float = 10.0
var decoy_similarity: float = 0.0


## 空化临界速度（随深度增加而提高）：Vcav(z) = Vcav_surf + slope * depth
func cavitation_speed_kn(depth_m: float) -> float:
	return cavitation_speed_kn_at_surface + cavitation_depth_slope * maxf(depth_m, 0.0)


## 当前是否处于空化状态（航速超过该深度的空化临界速度）。
func is_cavitating(speed_kn: float, depth_m: float) -> bool:
	return speed_kn > cavitation_speed_kn(depth_m)


## 宽带声源级 SL_BB(V, z)。
## SL_BB = SL0 + A*log10(1 + (V/Vref)^n) + C_cav * I(V > Vcav(z))
func broadband_sl_db(speed_kn: float, depth_m: float) -> float:
	var ratio: float = maxf(speed_kn, 0.0) / maxf(speed_noise_vref_kn, 0.0001)
	var sl: float = broadband_base_level_db + speed_noise_a * log(1.0 + pow(ratio, speed_noise_n)) / log(10.0)
	if is_cavitating(speed_kn, depth_m):
		sl += cavitation_extra_db
	return sl


## 取指定频率处的窄带谱线声级；找不到返回 null。
func tonal_level_at(freq_hz: float) -> Variant:
	for t in tonal_lines:
		if absf(float(t.get("freq_hz", 0.0)) - freq_hz) < 0.5:
			return float(t.get("level_db", 0.0))
	return null


func from_dict(d: Dictionary) -> void:
	broadband_base_level_db = float(d.get("broadband_base_level_db", broadband_base_level_db))
	speed_noise_a = float(d.get("speed_noise_a", speed_noise_a))
	speed_noise_n = float(d.get("speed_noise_n", speed_noise_n))
	speed_noise_vref_kn = float(d.get("speed_noise_vref_kn", speed_noise_vref_kn))
	cavitation_speed_kn_at_surface = float(d.get("cavitation_speed_kn_at_surface", cavitation_speed_kn_at_surface))
	cavitation_depth_slope = float(d.get("cavitation_depth_slope", cavitation_depth_slope))
	cavitation_extra_db = float(d.get("cavitation_extra_db", cavitation_extra_db))
	tonal_lines = d.get("tonal_lines", [])
	turns_per_knot = int(d.get("turns_per_knot", turns_per_knot))
	blade_count = int(d.get("blade_count", blade_count))
	shaft_count = int(d.get("shaft_count", shaft_count))
	active_target_strength_db = float(d.get("active_target_strength_db", active_target_strength_db))
	decoy_similarity = float(d.get("decoy_similarity", decoy_similarity))
