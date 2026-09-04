class_name AcousticService
extends RefCounted
## acoustic_service.gd — 统一声学服务（S1-04 / G-03 单一声学模型）。
##
## 全游戏唯一的声呐方程实现点：被动/主动 SE、传播损失、有效噪声（线性功率
## 合成）、概率探测 P_d、方位误差 sigma(SE)。OperatorSonar、自动测量
## （MeasurementGenerator/SensorArray）与后续主动 Ping、鱼雷声自导必须复用
## 本服务，不得各自实现简化公式（禁止 24log10 之类散落硬编码）。
##
## 公式（与 DESIGN.md §4 一致）：
##   TL(f,r)   = K*log10(max(r,1)) + alpha(f)*r_km + L_env
##   N_eff     = 10*log10(Σ 10^(N_j/10))   （环境 + 本艇自噪 + 干扰源）
##   SE_pass   = SL - TL - N_eff + AG - DT
##   SE_active = SL_ping - 2*TL + TS - N_eff + AG - DT   （二维同路径近似）
##   P_d       = 1 / (1 + exp(-SE/k_d))                  （无 SE>0 硬门限）
##   sigma(SE) = σmin + (σmax-σmin)/(1+exp((SE-SE0)/k_σ))
##
## 纯静态无状态；env/ag/dt 等参数由调用方注入，可无头测试。

const DEFAULT_K_D: float = 3.0
const DEFAULT_SIGMA_MIN_DEG: float = 0.5
const DEFAULT_SIGMA_MAX_DEG: float = 5.0
const DEFAULT_SE0_DB: float = 6.0
const DEFAULT_K_SIGMA_DB: float = 4.0

## 海水声速（m/s，约 1500）——主动声呐不是光速！
## 测距的本质是测往返时间：R = c·τ/2。回波在 ping 发出后 τ=2R/c 才到达。
const SOUND_SPEED_M_S: float = 1500.0


## 声波往返传播时间 τ = 2R/c（ping 发出 → 回波到达）。S1-04 评审修正：
## 主动声呐回波必须按此延迟到达，不得瞬时返回。
static func echo_travel_time_s(range_m: float, sound_speed_m_s: float = SOUND_SPEED_M_S) -> float:
	return 2.0 * maxf(range_m, 0.0) / maxf(sound_speed_m_s, 1.0)


## 由往返时间反推距离 R = c·τ/2（测距即测时，与 echo_travel_time_s 互逆）。
static func range_from_echo_time_s(tau_s: float, sound_speed_m_s: float = SOUND_SPEED_M_S) -> float:
	return 0.5 * maxf(sound_speed_m_s, 1.0) * maxf(tau_s, 0.0)


## 传播损失（委托 EnvironmentModel 单一实现）。
static func propagation_loss(range_m: float, freq_hz: float, env: RefCounted) -> float:
	return env.propagation_loss(range_m, freq_hz)


## 有效噪声 N_eff（含环境 + 本艇自噪；委托 EnvironmentModel 线性功率合成）。
static func effective_noise_db(freq_hz: float, own_speed_kn: float, env: RefCounted) -> float:
	return env.effective_noise_db(freq_hz, own_speed_kn)


## 被动声呐信号余量 SE_passive = SL - TL - N_eff + AG - DT。
static func passive_se(
	sl_db: float,
	range_m: float,
	freq_hz: float,
	env: RefCounted,
	own_speed_kn: float,
	ag_db: float = 0.0,
	dt_db: float = 0.0
) -> float:
	var tl: float = env.propagation_loss(range_m, freq_hz)
	var n_eff: float = env.effective_noise_db(freq_hz, own_speed_kn)
	return sl_db - tl - n_eff + ag_db - dt_db


## 主动声呐信号余量 SE_active = SL_ping - 2*TL + TS - N_eff + AG - DT。
## 二维同路径近似（去程=回程）；阶段二 SSP 分路径时由调用方分别传 TL。
static func active_se(
	ping_sl_db: float,
	target_ts_db: float,
	range_m: float,
	freq_hz: float,
	env: RefCounted,
	own_speed_kn: float,
	ag_db: float = 0.0,
	dt_db: float = 0.0
) -> float:
	var tl: float = env.propagation_loss(range_m, freq_hz)
	var n_eff: float = env.effective_noise_db(freq_hz, own_speed_kn)
	return ping_sl_db - 2.0 * tl + target_ts_db - n_eff + ag_db - dt_db


## ---- S1-07A（Commit 2）：双层伪三维 layer 版声呐方程 ----
## 传播损失带深度：被动/截获单程 TL_layer(f,R,z_s,z_r)；
## 主动分别算去程（发射端深度→目标）与回程（目标→接收端深度），推广
## "2*TL 同路径近似"（S1-07 §4.3：SE_active=SL - TL_out - TL_ret + TS - N + AG - DT）。
## env 无 depth_model（旧二维）时退化为同层 base，与 passive_se/active_se 一致。


static func passive_se_layer(
	sl_db: float,
	range_m: float,
	freq_hz: float,
	env: RefCounted,
	own_speed_kn: float,
	z_s: float,
	z_r: float,
	ag_db: float = 0.0,
	dt_db: float = 0.0
) -> float:
	var tl: float = env.propagation_loss_layer(range_m, freq_hz, z_s, z_r)
	var n_eff: float = env.effective_noise_db(freq_hz, own_speed_kn)
	return sl_db - tl - n_eff + ag_db - dt_db


static func active_se_layer(
	ping_sl_db: float,
	target_ts_db: float,
	range_m: float,
	freq_hz: float,
	env: RefCounted,
	own_speed_kn: float,
	z_tx: float,
	z_rx: float,
	z_tgt: float,
	ag_db: float = 0.0,
	dt_db: float = 0.0
) -> float:
	var tl_out: float = env.propagation_loss_layer(range_m, freq_hz, z_tx, z_tgt)
	var tl_ret: float = env.propagation_loss_layer(range_m, freq_hz, z_rx, z_tgt)
	var n_eff: float = env.effective_noise_db(freq_hz, own_speed_kn)
	return ping_sl_db - tl_out - tl_ret + target_ts_db - n_eff + ag_db - dt_db


## 概率探测 P_d = 1/(1+exp(-SE/k_d))：连续、无 SE>0 硬门限。
static func detection_probability(se_db: float, k_d: float = DEFAULT_K_D) -> float:
	return 1.0 / (1.0 + exp(-se_db / maxf(k_d, 1e-6)))


## 方位标准差随 SE 下降（弱接触抖动大，强接触稳定）。
static func bearing_sigma_deg(
	se_db: float,
	sigma_min_deg: float = DEFAULT_SIGMA_MIN_DEG,
	sigma_max_deg: float = DEFAULT_SIGMA_MAX_DEG,
	se0_db: float = DEFAULT_SE0_DB,
	k_sigma_db: float = DEFAULT_K_SIGMA_DB
) -> float:
	return (
		sigma_min_deg + (sigma_max_deg - sigma_min_deg) / (1.0 + exp((se_db - se0_db) / k_sigma_db))
	)
