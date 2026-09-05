class_name EnvironmentModel
extends RefCounted
## environment_model.gd — 水声环境模型。
## 提供传播损失 TL 与有效噪声 N_eff（多源线性合成）的计算。
## 一切系数均可从 JSON 配置，不写死在业务代码。

## 波束外/旁瓣衰减（dB）：波束内 0，波束外按旁瓣衰减参与（不无差别全向）。
const BEAM_SIDELOBE_LOSS_DB := 18.0

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

# REQ-AC-03：活动宽带干扰源（JAMMER）。由 World 每 tick 从激活且未过期的
# JAMMER 诱饵同步。元素口径：
#   {e, n, z, sl_band_db, band_min_hz, band_max_hz}
#   sl_band_db = 频带内总声级（固定总功率）；接收端单频贡献 =
#   sl_band_db - 10log10(bandwidth) + 10log10(B_eff)（固定总功率加宽容积不变）。
var interferers: Array = []
## 接收端分析带宽 B_eff（Hz）：PSD→带级换算口径（可配置）。
var analysis_bandwidth_hz: float = 100.0


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


## P1-05：环境噪声 + 显式自噪（dB 线性域合成）。供平台专用接收机自噪模型
## （鱼雷 receiver_self_noise_db）替代潜艇级 own_noise_db 参与同一 SE 方程。
func effective_noise_db_with_self(freq_hz: float, self_noise_db: float) -> float:
	var sum_linear: float = 0.0
	for src_db in [ambient_noise_db(freq_hz), self_noise_db]:
		sum_linear += pow(10.0, src_db / 10.0)
	return 10.0 * log(sum_linear) / log(10.0)


## REQ-AC-03：单干扰源在接收端的带内贡献（dB）。按传播（TL+跨层）与
## 波束响应（波束内 0 / 波束外旁瓣衰减）计算；频带外不贡献。
static func interferer_noise_db(
	itf: Dictionary,
	freq_hz: float,
	env: RefCounted,
	rx_e: float,
	rx_n: float,
	rx_z: float,
	rx_course_deg: float = -1.0,
	beam_half_deg: float = 180.0,
) -> float:
	var f_min: float = float(itf.get("band_min_hz", 0.0))
	var f_max: float = float(itf.get("band_max_hz", 0.0))
	if f_max > f_min and (freq_hz < f_min or freq_hz > f_max):
		return -INF  # 频带外（按响应不贡献；非宽带全部表示）
	var e: float = float(itf.get("e", 0.0))
	var n: float = float(itf.get("n", 0.0))
	var z: float = float(itf.get("z", 0.0))
	var r: float = sqrt((e - rx_e) * (e - rx_e) + (n - rx_n) * (n - rx_n))
	var j: float = float(itf.get("sl_band_db", 0.0))
	var bw: float = f_max - f_min
	if bw > 1.0:
		# 固定总功率→PSD→接收 B_eff 带级：带宽信息不丢，总能量不凭空增加。
		j -= 10.0 * log(bw) / log(10.0)
		j += 10.0 * log(maxf(env.analysis_bandwidth_hz, 1.0)) / log(10.0)
	j -= env.propagation_loss_layer(r, freq_hz, z, rx_z)
	# 波束响应：已知接收航向时，波束外按旁瓣衰减（不能把近旁 JAMMER
	# 无差别加到所有方位）。
	if rx_course_deg >= 0.0 and beam_half_deg < 180.0:
		var brg: float = rad_to_deg(atan2(e - rx_e, n - rx_n))
		var rel: float = absf(NavUtils.wrap180(brg - rx_course_deg))
		if rel > beam_half_deg:
			j -= BEAM_SIDELOBE_LOSS_DB
	return j


## 两个 dB 级线性功率合成（多源相加，绝不用 max() 冒充）。
static func combine_db(a_db: float, b_db: float) -> float:
	if a_db <= -INF:
		return b_db
	if b_db <= -INF:
		return a_db
	return 10.0 * log(pow(10.0, a_db / 10.0) + pow(10.0, b_db / 10.0)) / log(10.0)


## REQ-AC-03：全部干扰源的合成贡献（dB，线性功率合成；无干扰源返回 -INF）。
## 接收端按位置 + 波束响应（rx_course<0 = 全向）独立计算。
func interference_noise_db(
	freq_hz: float,
	rx_e: float,
	rx_n: float,
	rx_z: float,
	rx_course_deg: float = -1.0,
	beam_half_deg: float = 180.0,
) -> float:
	if interferers.is_empty():
		return -INF
	var sum_linear: float = 0.0
	for itf in interferers:
		var j: float = interferer_noise_db(
			itf, freq_hz, self, rx_e, rx_n, rx_z, rx_course_deg, beam_half_deg
		)
		if j > -INF:
			sum_linear += pow(10.0, j / 10.0)
	if sum_linear <= 0.0:
		return -INF
	return 10.0 * log(sum_linear) / log(10.0)


## REQ-AC-03：统一 N_eff（环境 + 自噪/本艇自噪 + 全部干扰源线性功率合成）。
## 无干扰源时与 effective_noise_db_with_self 完全同值（旧场景零行为变化）。
## 混合声场一律线性功率合成（绝不用 max() 冒充多源相加）。
func effective_noise_db_at(
	freq_hz: float,
	self_noise_db: float,
	own_speed_kn: float,
	rx_e: float,
	rx_n: float,
	rx_z: float,
	rx_course_deg: float = -1.0,
	beam_half_deg: float = 180.0,
) -> float:
	var base: float = (
		effective_noise_db_with_self(freq_hz, self_noise_db)
		if self_noise_db >= 0.0
		else effective_noise_db(freq_hz, own_speed_kn)
	)
	var jam: float = interference_noise_db(freq_hz, rx_e, rx_n, rx_z, rx_course_deg, beam_half_deg)
	if jam <= -INF:
		return base
	var sum_linear: float = pow(10.0, base / 10.0) + pow(10.0, jam / 10.0)
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
	analysis_bandwidth_hz = float(d.get("analysis_bandwidth_hz", analysis_bandwidth_hz))
