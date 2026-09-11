class_name SensorAcousticProfile
extends RefCounted
## sensor_acoustic_profile.gd — 统一接收器声学口径（AC-01）。
##
## 全游戏唯一的"接收器性能"配置载体：频带/中心频率/带宽口径、绝对阵列增益 AG、
## 处理增益 PG、检测阈 DT、概率过渡宽度 k_d、方位误差模型、自噪/流噪入口、
## 覆盖结构与方向响应。
##
## OperatorSonar（手动/显示链）与 SensorArray（自动船员链）必须消费同一份
## profile，不得各自写 0/4/8/20 之类不明口径常量。
##
## 口径纪律：
##   1) "显示增益"（瀑布配色/幅度缩放）不属于本类，绝不参与 Pd 与 TMA 权重；
##      本类的 AG/PG/DT 是唯一的"探测口径"。
##   2) AG 与 PG 描述不同物理收益（孔径/指向性 与 时间积累/后处理），只相加一次；
##      同一种收益不得在 AG、PG、自噪、方向响应之间重复计。
##   3) 线阵端射精度退化是方向响应的一部分：SE 惩罚上限 4 dB 且连续，不形成
##      硬盲区；方位 sigma 只增大，不改 Pd。

## 端射低精度区（相对阵轴前后各 ±15°）。
const ENDFIRE_ZONE_DEG: float = 15.0
## 端射 SE 额外惩罚上限（dB，AC-02 要求 ≤4 且不能形成硬盲区）。
const ENDFIRE_PENALTY_MAX_DB: float = 4.0
## sigma ∝ 1/max(|sin α|, floor) 的有界近似下限（防端射处 sigma 发散）。
const ENDFIRE_SIN_FLOOR: float = 0.25

var array_id: String = "BOW"
var freq_min_hz: float = 100.0
var freq_max_hz: float = 1000.0
## 探测频段中心（宽带 SE / TL / N_eff 的统一取频点）。
var center_freq_hz: float = 500.0
## 接收带宽口径（Hz）：干扰源"固定总功率→PSD→带级"换算用。
var bandwidth_hz: float = 100.0
var array_gain_db: float = 0.0  # AG：孔径/指向性收益
var processing_gain_db: float = 0.0  # PG：时间积累/后处理收益
var detection_threshold_db: float = 0.0  # DT
var detection_k_d: float = 3.0
var sigma_min_deg: float = 1.2
var sigma_max_deg: float = 6.0
var bearing_se0_db: float = 6.0
var bearing_k_sigma_db: float = 4.0
## 强接触时方位 sigma 的绝对下限（deg）；低于此值不再收敛（物理抖动下限）。
var sigma_floor_deg: float = 0.2
var beamwidth_deg: float = 5.0
## 覆盖：full_circle=true 时用 sectors_excluded 表达盲区；否则用 sectors 白名单。
var full_circle: bool = false
var sectors: Array = []
var sectors_excluded: Array = []
## 线阵方向响应（可扫描被动线阵的游戏近似：两舷广泛可用、端射精度变差）。
var line_array_direction: bool = false
## 单线阵左右舷镜像歧义（A/B 候选）。
var mirror_lr: bool = false
## -1 = 采用平台默认自噪；>=0 = 显式接收机自噪（dB）。
var self_noise_db: float = -1.0
## 流噪（随航速）：N_flow = base + coeff·V。远离艇体的收益只降低自噪分量。
var flow_noise_base_db: float = 0.0
var flow_noise_speed_coeff: float = 0.0
## 显式自噪扣减（dB，≥0）：只作用于本艇自噪分量，不降低海洋环境噪声。
var self_noise_reduction_db: float = 0.0


## 探测口径总增益（AG + PG，只计一次）。
func detection_gain_db() -> float:
	return array_gain_db + processing_gain_db


## FOM_eff 的游戏近似（AC-02）：净探测优值相对于同一声源/环境。
## FOM_eff = AG + PG - DT - (N_eff - N_ambient)。
func fom_eff_db(n_eff_db: float, n_ambient_db: float) -> float:
	return detection_gain_db() - detection_threshold_db - (n_eff_db - n_ambient_db)


## 目标（阵列相对方位）是否落在覆盖内。full_circle 阵列只排除盲区扇区，
## 因此不存在"永久绑定阵轴"的硬盲区（AC-02）。
func in_coverage(array_rel_deg: float) -> bool:
	if full_circle:
		return not NavUtils.in_sectors(array_rel_deg, sectors_excluded)
	return NavUtils.in_sectors(array_rel_deg, sectors)


## 阵轴距离（0=端射，90=正横，与左右舷对称）。
static func axis_distance_deg(array_rel_deg: float) -> float:
	var d: float = absf(NavUtils.wrap180(array_rel_deg))
	return minf(d, 180.0 - d)


## 方向响应（dB，≤0）。线阵为关于阵轴对称的连续曲线；非线阵沿用扇区衰减。
func direction_gain_db(array_rel_deg: float) -> float:
	if line_array_direction:
		return endfire_penalty_db(array_rel_deg)
	if full_circle:
		return 0.0
	var secs: Array = sectors
	if secs.is_empty():
		return 0.0
	var best: float = -INF
	for s in secs:
		var c: float = NavUtils.wrap180((float(s.x) + float(s.y)) * 0.5)
		best = maxf(best, NavUtils.sector_gain_db(array_rel_deg, c, 40.0))
	return best


## 端射额外 SE 惩罚（dB，≤0，连续、上限 4 dB、无硬盲区）。
func endfire_penalty_db(array_rel_deg: float) -> float:
	if not line_array_direction:
		return 0.0
	var d_axis: float = axis_distance_deg(array_rel_deg)
	if d_axis >= ENDFIRE_ZONE_DEG:
		return 0.0
	return -ENDFIRE_PENALTY_MAX_DB * (1.0 - d_axis / ENDFIRE_ZONE_DEG)


## 方位标准差（deg）。强接触按下限收敛；线阵在端射附近按 1/|sin α| 放大（有界），
## 正横主工作区不受惩罚；A/B 两支共用同一 sigma，只符号相反（不因两个候选而
## 扩大随机误差）。
func bearing_sigma_deg(se_db: float, array_rel_deg: float = 999.0) -> float:
	var base: float = maxf(sigma_min_deg * pow(2.0, -se_db / 6.0), sigma_floor_deg)
	if not line_array_direction or absf(array_rel_deg) > 360.0:
		return base
	var s: float = maxf(absf(sin(deg_to_rad(array_rel_deg))), ENDFIRE_SIN_FLOOR)
	return base / s


## 统一接收端 N_eff（不含干扰源；干扰由调用方线性合成）。
##   self_noise_db < 0 → 平台默认自噪（env.effective_noise_db，含随航速项）；
##   否则 环境噪声 + (显式自噪 − 远离艇体收益) + 流噪，线性功率合成。
func receiver_noise_db(env: RefCounted, own_speed_kn: float) -> float:
	if self_noise_db < 0.0:
		return env.effective_noise_db(center_freq_hz, own_speed_kn)
	var ambient: float = env.ambient_noise_db(center_freq_hz)
	var self_db: float = maxf(self_noise_db - self_noise_reduction_db, -50.0)
	return EnvironmentModel.combine_db(ambient, self_db + flow_noise_db(own_speed_kn))


## 流噪（dB，随航速上升）。远离艇体的收益只减自噪分量，不降海洋环境噪声。
func flow_noise_db(own_speed_kn: float) -> float:
	return flow_noise_base_db + flow_noise_speed_coeff * maxf(own_speed_kn, 0.0)


## 被动 SE（统一入口，自动/手动链共用同一公式与口径）。
func passive_se_db(sl_db: float, range_m: float, env: RefCounted, own_speed_kn: float) -> float:
	return AcousticService.passive_se(
		sl_db,
		range_m,
		center_freq_hz,
		env,
		own_speed_kn,
		detection_gain_db(),
		detection_threshold_db
	)


func detection_probability(se_db: float) -> float:
	return AcousticService.detection_probability(se_db, detection_k_d)


## 导出为 SensorArray.from_dict() 可消费的字典（自动船员链复用同一 profile）。
func to_sensor_dict() -> Dictionary:
	var d: Dictionary = {
		"sensor_id": "OP_" + array_id,
		"array_type": "passive_broadband",
		"freq_min_hz": freq_min_hz,
		"freq_max_hz": freq_max_hz,
		"array_gain_db": detection_gain_db(),
		"detection_threshold_db": detection_threshold_db,
		"detection_k_d": detection_k_d,
		"bearing_sigma_min_deg": sigma_min_deg,
		"bearing_sigma_max_deg": sigma_max_deg,
		"bearing_se0_db": bearing_se0_db,
		"bearing_k_sigma_db": bearing_k_sigma_db,
		"deployed": true,
	}
	if full_circle:
		d["coverage_start_deg"] = 0.0
		d["coverage_end_deg"] = 360.0
	elif not sectors.is_empty():
		d["coverage_start_deg"] = float((sectors[0] as Vector2).x)
		d["coverage_end_deg"] = float((sectors[0] as Vector2).y)
	return d


func from_dict(d: Dictionary) -> void:
	array_id = str(d.get("array_id", d.get("sensor_id", array_id)))
	freq_min_hz = float(d.get("freq_min_hz", freq_min_hz))
	freq_max_hz = float(d.get("freq_max_hz", freq_max_hz))
	center_freq_hz = float(d.get("center_freq_hz", (freq_min_hz + freq_max_hz) * 0.5))
	bandwidth_hz = float(d.get("bandwidth_hz", bandwidth_hz))
	array_gain_db = float(d.get("array_gain_db", array_gain_db))
	processing_gain_db = float(d.get("processing_gain_db", processing_gain_db))
	detection_threshold_db = float(d.get("detection_threshold_db", detection_threshold_db))
	detection_k_d = float(d.get("detection_k_d", detection_k_d))
	sigma_min_deg = float(d.get("bearing_sigma_min_deg", d.get("sigma_min", sigma_min_deg)))
	sigma_max_deg = float(d.get("bearing_sigma_max_deg", d.get("sigma_max", sigma_max_deg)))
	sigma_floor_deg = float(d.get("sigma_floor_deg", sigma_floor_deg))
	bearing_se0_db = float(d.get("bearing_se0_db", bearing_se0_db))
	bearing_k_sigma_db = float(d.get("bearing_k_sigma_db", bearing_k_sigma_db))
	beamwidth_deg = float(d.get("beamwidth_deg", beamwidth_deg))
	full_circle = bool(d.get("full_circle", full_circle))
	line_array_direction = bool(d.get("line_array_direction", line_array_direction))
	mirror_lr = bool(d.get("mirror_lr", mirror_lr))
	self_noise_db = float(d.get("self_noise_db", self_noise_db))
	flow_noise_base_db = float(d.get("flow_noise_base_db", flow_noise_base_db))
	flow_noise_speed_coeff = float(d.get("flow_noise_speed_coeff", flow_noise_speed_coeff))
	self_noise_reduction_db = float(d.get("self_noise_reduction_db", self_noise_reduction_db))
	sectors = _read_sectors(d.get("sectors", null), sectors)
	sectors_excluded = _read_sectors(d.get("sectors_excluded", null), sectors_excluded)


static func _read_sectors(src: Variant, fallback: Array) -> Array:
	if src == null:
		return fallback
	var out: Array = []
	for s in src as Array:
		if s is Vector2:
			out.append(s)
		elif s is Array and (s as Array).size() >= 2:
			out.append(Vector2(float(s[0]), float(s[1])))
	return out


## 内置基线口径（场景未显式配置时的回退；数值均为游戏参数，非实装规格）。
##   BOW   艇艏/球形阵：全向（艉部盲区）
##   FLANK 舷侧阵：左右舷双扇区，较 BOW 高 ~4.5 dB
##   TOWED 拖曳线阵：满长稳定时较 BOW 高 ≥12 dB，带左右舷歧义与端射退化
static func builtin_profile(id: String) -> SensorAcousticProfile:
	var p := SensorAcousticProfile.new()
	p.array_id = id
	p.freq_min_hz = 100.0
	p.freq_max_hz = 1000.0
	p.center_freq_hz = 500.0
	p.detection_k_d = 3.0
	match id:
		"FLANK":
			p.sectors = [Vector2(55.0, 125.0), Vector2(-125.0, -55.0)]
			p.array_gain_db = 4.0
			p.sigma_min_deg = 0.6
			p.sigma_max_deg = 4.0
			p.sigma_floor_deg = 0.15
			p.beamwidth_deg = 3.0
			p.bearing_se0_db = 6.0
			p.bearing_k_sigma_db = 4.0
		"TOWED":
			p.full_circle = true
			p.line_array_direction = true
			p.mirror_lr = true
			p.array_gain_db = 12.0
			p.sigma_min_deg = 0.30
			p.sigma_max_deg = 2.0
			p.sigma_floor_deg = 0.10
			p.beamwidth_deg = 4.0
			p.bearing_se0_db = 6.0
			p.bearing_k_sigma_db = 4.0
			p.flow_noise_base_db = -80.0
		_:
			p.full_circle = true
			p.sectors_excluded = [Vector2(150.0, 210.0)]
			p.array_gain_db = 0.0
			p.sigma_min_deg = 1.2
			p.sigma_max_deg = 6.0
			p.sigma_floor_deg = 0.2
			p.beamwidth_deg = 5.0
			p.bearing_se0_db = 6.0
			p.bearing_k_sigma_db = 4.0
	return p
