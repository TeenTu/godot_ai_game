extends RefCounted
class_name EnvironmentModel
## environment_model.gd — 水声环境模型。
## 提供传播损失 TL 与有效噪声 N_eff（多源线性合成）的计算。
## 一切系数均可从 JSON 配置，不写死在业务代码。

var environment_type: String = "shallow"
var sea_state: int = 2

# 环境噪声（接收端自噪 + 海洋环境噪声）：按频率给出 dB 值
var ambient_noise_by_frequency: Dictionary = {}   # {freq_hz: level_db}

# 本艇自噪（随航速变化）的基准与斜率
var own_noise_base_db: float = 40.0
var own_noise_speed_coeff: float = 1.5

# 传播损失参数
var tl_spreading_k: float = 20.0      # K：球面扩散 20 / 圆柱 10
var tl_absorption_alpha: float = 0.5  # alpha(f)：频率相关吸收系数（dB/km 基准）
var tl_environment_loss: float = 0.0  # L_environment：跃变层/海底/阴影区附加损失


## 传播损失 TL = K*log10(max(r,1)) + alpha(f)*r_km + L_environment
func propagation_loss(range_m: float, freq_hz: float) -> float:
	var r: float = maxf(range_m, 1.0)
	var r_km: float = r / 1000.0
	return tl_spreading_k * log(r) / log(10.0) \
		+ tl_absorption_alpha * (freq_hz / 1000.0) * r_km \
		+ tl_environment_loss


## 环境噪声在某频率的声级（dB re 1uPa）。
func ambient_noise_db(freq_hz: float) -> float:
	return float(ambient_noise_by_frequency.get(freq_hz, 60.0))


## 本艇自噪（dB），随航速上升。
func own_noise_db(speed_kn: float) -> float:
	return own_noise_base_db + own_noise_speed_coeff * maxf(speed_kn, 0.0)


## 有效噪声 N_eff：多个 dB 源先转线性求和再转回 dB（不得直接相加）。
func effective_noise_db(freq_hz: float, own_speed_kn: float) -> float:
	var sum_linear: float = 0.0
	for src_db in [ambient_noise_db(freq_hz), own_noise_db(own_speed_kn)]:
		sum_linear += pow(10.0, src_db / 10.0)
	return 10.0 * log(sum_linear) / log(10.0)


func from_dict(d: Dictionary) -> void:
	environment_type = str(d.get("environment_type", environment_type))
	sea_state = int(d.get("sea_state", sea_state))
	ambient_noise_by_frequency = d.get("ambient_noise_by_frequency", {})
	own_noise_base_db = float(d.get("own_noise_base_db", own_noise_base_db))
	own_noise_speed_coeff = float(d.get("own_noise_speed_coeff", own_noise_speed_coeff))
	tl_spreading_k = float(d.get("tl_spreading_k", tl_spreading_k))
	tl_absorption_alpha = float(d.get("tl_absorption_alpha", tl_absorption_alpha))
	tl_environment_loss = float(d.get("tl_environment_loss", tl_environment_loss))
