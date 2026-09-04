class_name EnvironmentModel
extends RefCounted
## environment_model.gd — 水声环境模型。
## 提供传播损失 TL 与有效噪声 N_eff（多源线性合成）的计算。
## 一切系数均可从 JSON 配置，不写死在业务代码。

var environment_type: String = "shallow"
var sea_state: int = 2

# 环境噪声（接收端自噪 + 海洋环境噪声）：按频率给出 dB 值
var ambient_noise_by_frequency: Dictionary = {}  # {freq_hz: level_db}

# 本艇自噪（随航速变化）的基准与斜率
var own_noise_base_db: float = 40.0
var own_noise_speed_coeff: float = 1.5

# 传播损失参数
var tl_spreading_k: float = 20.0  # K：球面扩散 20 / 圆柱 10
var tl_absorption_alpha: float = 0.5  # alpha(f)：频率相关吸收系数（dB/km 基准）
var tl_environment_loss: float = 0.0  # L_environment：跃变层/海底/阴影区附加损失

# S1-07A（Commit 2）：双层伪三维深度层模型。null/disabled = 旧二维场景，
# cross_layer_extra_db 恒 0（零行为变化）。
var depth_model: RefCounted = null  # DepthLayerModel


## 传播损失 TL = K*log10(max(r,1)) + alpha(f)*r_km + L_environment
func propagation_loss(range_m: float, freq_hz: float) -> float:
	var r: float = maxf(range_m, 1.0)
	var r_km: float = r / 1000.0
	return (
		tl_spreading_k * log(r) / log(10.0)
		+ tl_absorption_alpha * (freq_hz / 1000.0) * r_km
		+ tl_environment_loss
	)


## 环境噪声在某频率的声级（dB re 1uPa）。
## S1-04：JSON 读入的键是字符串（如 "500"），必须正确匹配 float 频率，
## 不得因键型不匹配长期回退到 60 dB 默认值；频率表点之间线性插值。
func ambient_noise_db(freq_hz: float) -> float:
	if ambient_noise_by_frequency.is_empty():
		return 60.0
	var direct: Variant = ambient_noise_by_frequency.get(freq_hz, null)
	if direct != null:
		return float(direct)
	# 最近邻频率点线性插值
	var freqs: Array = []
	for k in ambient_noise_by_frequency.keys():
		freqs.append(float(k))
	freqs.sort()
	if freq_hz <= float(freqs[0]):
		return float(ambient_noise_by_frequency[ambient_key_at(freqs[0])])
	if freq_hz >= float(freqs[-1]):
		return float(ambient_noise_by_frequency[ambient_key_at(freqs[-1])])
	for i in range(freqs.size() - 1):
		var f0: float = float(freqs[i])
		var f1: float = float(freqs[i + 1])
		if freq_hz >= f0 and freq_hz <= f1:
			var t: float = (freq_hz - f0) / maxf(f1 - f0, 1e-6)
			var v0: float = float(ambient_noise_by_frequency[ambient_key_at(f0)])
			var v1: float = float(ambient_noise_by_frequency[ambient_key_at(f1)])
			return lerpf(v0, v1, t)
	return 60.0


## 取频率表中与 f 匹配的原始键（可能是 String 或 float，JSON 读入多为 String）。
func ambient_key_at(f_hz: float) -> Variant:
	if ambient_noise_by_frequency.has(f_hz):
		return f_hz
	for k in ambient_noise_by_frequency.keys():
		if absf(float(k) - f_hz) < 1e-6:
			return k
	return null


## 本艇自噪（dB），随航速上升。
func own_noise_db(speed_kn: float) -> float:
	return own_noise_base_db + own_noise_speed_coeff * maxf(speed_kn, 0.0)


## 跨温跃层附加 TL（S1-07A §4.3）：TL_layer = TL_base + w_cross*L_thermocline(f)。
## 无深度模型或模型 disabled → 0（旧二维场景零行为变化）。
func cross_layer_extra_db(freq_hz: float, z_s: float, z_r: float) -> float:
	if depth_model == null:
		return 0.0
	return depth_model.cross_layer_loss_db(freq_hz, depth_model.cross_layer_weight(z_s, z_r))


## 深度化传播损失（单程）：TL_base + 跨层附加。供 layer 版声呐方程使用。
func propagation_loss_layer(range_m: float, freq_hz: float, z_s: float, z_r: float) -> float:
	return propagation_loss(range_m, freq_hz) + cross_layer_extra_db(freq_hz, z_s, z_r)


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
