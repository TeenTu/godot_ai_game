class_name OperatorSonar
extends RefCounted
## operator_sonar.gd — Sonar Operator Layer 核心（阶段三收尾）。
##
## 信息链纪律（本类是 Truth 的唯一合法入口）：
##   Truth（目标位置/航速/声学画像）只进入「声场与阵列采样」；
##   对外输出的全部是操作员视角数据：瀑布图行、检测列表、概率分类、
##   DEMON 估计——绝不含目标真实位置/航速。
##
## 三种可配置阵列（覆盖/盲区/精度/增益不同）：
##   BOW   艇艏/球形阵：全向（艉部 ±30° 盲区）
##   FLANK 舷侧阵：左右舷 ±(55..125)°，增益高、精度好
##   TOWED 拖曳线阵：相对阵轴的前视连续波束（-100..+100，阵轴滞后本艇转向），
##         对阵轴两侧等角响应 → 产生左右舷镜像 A/B 候选（S1-03A）。
##         本艇未配置拖曳硬件时 TOWED 不可选/不可用（无兼容回退，S1-03）。
##
## 瀑布图数据流（确定性，可无头测试）：
##   update(t) 每次产生一行 BB（方位-时间）、NB（频率-时间）、DEMON（包络谱）；
##   玩家在 BB 游标处 Mark → create_mark() 产生 Measurement（带阵列噪声）；
##   Measurement 只由 玩家 Mark / 已分配 Tracker / Autocrew 产生。

const BB_BINS: int = 180  # 每格 2°
const NB_BINS: int = 100  # 频段内均分（随所选频段重映射）
const NB_FMAX_HZ: float = 500.0  # 兼容旧引用：LOW 频段上限
## REQ-09/验收11：窄带频段可切换——0～500 / 500～3000 / 8000～16000 Hz。
## 预设谱线（420/540/660/840/1080/1320 Hz 等）不再被固定 0～500 Hz 过滤。
const NB_BANDS: Dictionary = {
	"LOW": Vector2(0.0, 500.0),
	"MID": Vector2(500.0, 3000.0),
	"HIGH": Vector2(8000.0, 16000.0),
}
const DEMON_BINS: int = 128  # 0..32 Hz 包络谱
const DEMON_FMAX_HZ: float = 32.0
const NOISE_FLOOR_DB: float = -28.0
# S1-04.4：谱图背景噪声 texture——每帧每 bin 有时间相关（AR(1)）的随机起伏，
# 不再用固定纯色噪声底代替声学噪声（G-04：噪声始终存在，确定性种子可复现）。
const NOISE_TEXTURE_DB: float = 2.5  # 背景起伏幅度（dB）
const NOISE_TEXTURE_RHO: float = 0.75  # 帧间相关系数
# P1-04.5：已探测样本的显示对比度下限（SE<=0 时旧实现 amp=SE*0.6<=0 →
# 逻辑上探测到、画面上隐形）。弱接触用低幅度+高抖动表达，不改 P_d。
const MIN_DISPLAY_AMP_DB: float = 1.5
const ROW_INTERVAL_S: float = 2.0
const AUTOCREW_INTERVAL_S: float = 10.0
const AUTOCREW_PD_MIN: float = 0.85

# DEMON 测速用的通用螺旋桨模型（操作员先验，非目标 Truth）
const PROP_PITCH_M: float = 2.2  # 有效螺距
const PROP_PITCH_SIGMA: float = 0.35  # 螺距不确定 → 航速不确定主项

# 概率分类模板（操作员情报库，不含本次目标真值）
const CLASS_TEMPLATES: Dictionary = {
	"MERCHANT":
	{
		"blade_rate_hz": 1.2,
		"blades": 5,
		"tonals": 4,
		"loud_db": 4.0,
		"kn_per_br_hz": 12.5,
	},
	"WARNOTHINGSHIP":
	{
		"blade_rate_hz": 4.0,
		"blades": 5,
		"tonals": 6,
		"loud_db": 2.0,
		"kn_per_br_hz": 7.5,
	},
	"SUBSONAR":
	{
		"blade_rate_hz": 2.5,
		"blades": 7,
		"tonals": 3,
		"loud_db": -6.0,
		"kn_per_br_hz": 3.2,
	},
}

## 阵列覆盖与方向响应（AC-01/AC-02）：一切数值口径集中在 SensorAcousticProfile，
## 本类不再自持 0/4/8 之类的增益常量，也不再重复实现方向衰减公式。
##   BOW   艇艏/球形阵：全向（除艉部盲区）
##   FLANK 舷侧阵：左右舷双扇区
##   TOWED 拖曳线阵：两舷广泛可用 + 端射精度退化 + 左右舷镜像歧义（A/B）
## 阵列相对方位 frame：BOW/FLANK 用 own.course；TOWED 用独立 array_heading。
const ARRAY_IDS: Array = ["BOW", "FLANK", "TOWED"]

var active_array_id: String = "BOW"
## 各阵列的有效声学口径（AC-01 单一配置源，可由场景 configure_profiles 覆盖）。
var array_profiles: Dictionary = {}
# S1-03B：BB/NB/DEMON 每阵列独立历史缓冲。切换阵列绝不把其它阵列的历史行
# 混进当前瀑布；rows_by_array[aid] = {bb:[], nb:[], demon:[]}。公开的
# bb_rows/nb_rows/demon_rows 恒为"当前 active 阵列"缓冲的引用（保留公开名与
# 既有调用方/测试兼容），set_array() 切换时重绑定。
var rows_by_array: Dictionary = {}
# 当前阵列行：{t, array_id, sensor_id, bearing_frame, course, array_heading,
#   own_e, own_n, tow_center_m, tow_length_m, values, peaks}
var bb_rows: Array = []
var nb_rows: Array = []  # 当前阵列 [{t, array_id, sensor_id, values, tonals}]
## REQ-09：当前窄带频段（预设键，见 NB_BANDS；默认 LOW 保持旧行为）。
var nb_band: String = "LOW"
var nb_fmin_hz: float = 0.0
var nb_fmax_hz: float = 500.0
var demon_rows: Array = []  # 当前阵列 [{t, array_id, sensor_id, values}]
var waterfall_seq: int = 0  # P1-10：单调递增行序号（封顶后 UI 仍可据此刷新）
var demon_estimate: Dictionary = {}  # {rpm_hz, rpm_sigma_hz, blades, speed_kn, speed_sigma_kn, ..}
var classification: Dictionary = {}  # {CLASS: p} + "best"
var detection_count: int = 0
var _last_row_t: float = -1e9
var _last_autocrew_t: float = -1e9
var _ambiguity_counter: int = 0
var _evidence_counter: int = 0  # S1-00：玩家/自动 Mark 的物理证据唯一 id
# REQ-B1-02：瀑布行/峰稳定身份 + 同峰重复点击去重（不新增物理证据）。
var _row_counter: int = 0
var _marks_by_row_peak: Dictionary = {}
var _rng: RandomNumberGenerator = null
var _env: RefCounted = null
var _own_ref: RefCounted = null
# 背景 noise texture 状态（AR(1)，S1-04.4）
var _bb_noise_tex: PackedFloat32Array = PackedFloat32Array()
var _nb_noise_tex: PackedFloat32Array = PackedFloat32Array()
var _demon_noise_tex: PackedFloat32Array = PackedFloat32Array()


## P1-04.5：显示幅度 = clamp(max(SE*scale, MIN_DISPLAY_AMP_DB), 下限, 上限)。
## 仅作用于已通过 P_d 的样本；下限保证弱接触可见（配合高方位抖动表达不确定）。
static func display_amp_db(se_db: float, scale: float = 0.6, cap_db: float = 30.0) -> float:
	var raw: float = maxf(se_db * scale, MIN_DISPLAY_AMP_DB)
	return clampf(raw, MIN_DISPLAY_AMP_DB, cap_db)


func _init() -> void:
	for aid in ARRAY_IDS:
		array_profiles[aid] = SensorAcousticProfile.builtin_profile(aid)
		rows_by_array[aid] = {"bb": [], "nb": [], "demon": []}
	_bind_rows_to_active()


## AC-01：用场景配置覆盖阵列口径（键为 array_id，值为 profile 字段字典）。
## 未列出的阵列保持内置基线；未知阵列 id 忽略。
func configure_profiles(overrides: Dictionary) -> void:
	for aid in ARRAY_IDS:
		if not overrides.has(aid):
			continue
		var src: Variant = overrides[aid]
		if src is Dictionary:
			var merged: Dictionary = _profile_dict(aid)
			for k in src as Dictionary:
				merged[k] = (src as Dictionary)[k]
			array_profiles[aid] = _profile_from(merged)
		elif src is SensorAcousticProfile:
			array_profiles[aid] = src


## 把 profile 展平成可覆盖的字段字典（保留 array_id 与默认值）。
func _profile_dict(aid: String) -> Dictionary:
	var p: SensorAcousticProfile = array_profiles[aid]
	return {
		"array_id": aid,
		"freq_min_hz": p.freq_min_hz,
		"freq_max_hz": p.freq_max_hz,
		"center_freq_hz": p.center_freq_hz,
		"bandwidth_hz": p.bandwidth_hz,
		"array_gain_db": p.array_gain_db,
		"processing_gain_db": p.processing_gain_db,
		"detection_threshold_db": p.detection_threshold_db,
		"detection_k_d": p.detection_k_d,
		"bearing_sigma_min_deg": p.sigma_min_deg,
		"bearing_sigma_max_deg": p.sigma_max_deg,
		"sigma_floor_deg": p.sigma_floor_deg,
		"beamwidth_deg": p.beamwidth_deg,
		"full_circle": p.full_circle,
		"line_array_direction": p.line_array_direction,
		"mirror_lr": p.mirror_lr,
		"sectors": p.sectors,
		"sectors_excluded": p.sectors_excluded,
		"self_noise_db": p.self_noise_db,
	}


func _profile_from(d: Dictionary) -> SensorAcousticProfile:
	var p := SensorAcousticProfile.new()
	p.from_dict(d)
	return p


## 把公开 bb/nb/demon_rows 引用绑定到当前阵列缓冲（切阵列后调用）。
func _bind_rows_to_active() -> void:
	var b: Dictionary = rows_by_array[active_array_id]
	bb_rows = b["bb"]
	nb_rows = b["nb"]
	demon_rows = b["demon"]


## REQ-09/验收11：切换窄带频段（"LOW"/"MID"/"HIGH"）；未知键保持不变。
## 返回是否切换成功。
func set_nb_band(preset: String) -> bool:
	if not NB_BANDS.has(preset):
		return false
	var band: Vector2 = NB_BANDS[preset]
	nb_band = preset
	nb_fmin_hz = band.x
	nb_fmax_hz = band.y
	return true


func setup(world_dict: Dictionary) -> void:
	_env = world_dict.get("env", null)
	_own_ref = world_dict["own"]
	_rng = world_dict.get("rng", null)
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.seed = 12345
	_bb_noise_tex.resize(BB_BINS)
	_bb_noise_tex.fill(0.0)
	_nb_noise_tex.resize(NB_BINS)
	_nb_noise_tex.fill(0.0)
	_demon_noise_tex.resize(DEMON_BINS)
	_demon_noise_tex.fill(0.0)


func set_array(id: String) -> void:
	if not array_profiles.has(id):
		return
	if id == active_array_id:
		return
	active_array_id = id
	# S1-03B：切阵列 → 重绑定瀑布缓冲，只展示该阵列自己的历史
	_bind_rows_to_active()


func _profile() -> SensorAcousticProfile:
	return array_profiles[active_array_id]


func profile_for(aid: String) -> SensorAcousticProfile:
	return array_profiles.get(aid, array_profiles[active_array_id])


## 本艇是否真的安装了拖曳阵硬件（S1-03：无硬件时 TOWED 禁用，不提供
## "跟艇+满可用"的虚构回退）。
func towed_available() -> bool:
	return _own_ref != null and _own_ref.get("towed") != null


## 当前阵列的物理航向(deg)：BOW/FLANK = own.course；TOWED 用拖曳阵自身航向。
## TOWED 优先走 own 的拖曳阵状态机（带转向滞后的 array_heading）；
## 未配置硬件时返回 own.course，但 towed_available()=false 会禁止任何 TOWED 接触。
func _array_heading_deg() -> float:
	if _own_ref == null:
		return 0.0
	if active_array_id == "TOWED":
		var t: TowedArray = _own_ref.get("towed")
		if t != null:
			return t.array_heading_deg
	return float(_own_ref.course_deg)


## TOWED 的"声学可用度"0..1：孔径比例 × 沉降（外加弯曲/高速损失见
## TowedArray.gain_penalty_db）。BOW/FLANK 恒 1；无硬件 = 0（不是 1！）。
func _towed_usable_factor() -> float:
	if active_array_id != "TOWED" or _own_ref == null:
		return 1.0
	var t: TowedArray = _own_ref.get("towed")
	if t == null:
		return 0.0
	return t.usable_fraction()


## 该目标(阵列相对方位)是否落在当前阵列的覆盖内。
## AC-01/AC-02：覆盖结构由 SensorAcousticProfile 唯一定义（全向阵列只排盲区，
## 线阵两舷广泛可用、不设硬盲区）。
static func in_array_coverage(array_rel_deg: float, prof: SensorAcousticProfile) -> bool:
	return prof.in_coverage(array_rel_deg)


## 方向性增益(dB)：委托 profile 的连续方向响应（AC-02 已删除"前视 ±100°、
## 侧向 −25 dB"的旧模型）。完全不在覆盖内由调用方直接跳过。
static func _array_direction_gain_db(array_rel_deg: float, prof: SensorAcousticProfile) -> float:
	return prof.direction_gain_db(array_rel_deg)


func _randn() -> float:
	var u1: float = maxf(_rng.randf(), 0.000001)
	var u2: float = _rng.randf()
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


## 推进背景噪声 texture（AR(1) 时间相关，S1-04.4）。
func _advance_noise_tex(tex: PackedFloat32Array) -> void:
	# REQ-AC-05：AR(1) 平稳口径 x'=ρx+√(1-ρ²)z → 平稳标准差=1（乘
	# NOISE_TEXTURE_DB 后即配置起伏幅度；旧写法只给了 0.378 的平稳 std）。
	var g: float = sqrt(1.0 - NOISE_TEXTURE_RHO * NOISE_TEXTURE_RHO)
	for i in range(tex.size()):
		tex[i] = NOISE_TEXTURE_RHO * tex[i] + g * _randn()


## 某 bin 的背景声级（噪声底 + texture 起伏）。
func _noise_floor_at(tex: PackedFloat32Array, i: int) -> float:
	return NOISE_FLOOR_DB + NOISE_TEXTURE_DB * tex[i]


## REQ-AC-01：按仿真节拍追帧推进（倍速/低帧率不跳行）。UI 每帧调用：
## 落后多少个 ROW_INTERVAL 就补多少行（上限 max_rows 防卡顿），行时刻按
## _last_row_t + ROW_INTERVAL_S 递增，物理随机序列与 1x 逐行调用一致。
func catch_up_rows(sim_time: float, targets: Array, acs: Dictionary, max_rows: int = 8) -> int:
	if _last_row_t < -1.0e8:
		_last_row_t = 0.0  # 首次调用：从仿真起点开始补行
	var n: int = 0
	while sim_time - _last_row_t >= ROW_INTERVAL_S and n < max_rows:
		update(_last_row_t + ROW_INTERVAL_S, targets, acs)
		n += 1
	return n


## 推进一行操作员数据（main_ui 按 ROW_INTERVAL_S 调用）。
## targets: Truth 目标数组；acs: 目标声学画像字典（id -> AcousticProfile）。
func update(sim_time: float, targets: Array, acs: Dictionary) -> void:
	if sim_time - _last_row_t < ROW_INTERVAL_S:
		return
	_last_row_t = sim_time
	var prof: SensorAcousticProfile = _profile()
	var gain: float = prof.detection_gain_db()
	var dt_db: float = prof.detection_threshold_db
	var center_freq: float = prof.center_freq_hz
	var own: RefCounted = _own_ref
	var own_speed: float = float(own.speed_kn)
	var own_depth: float = float(own.depth_m)
	var own_course: float = float(own.course_deg)
	# BB 瀑布 x 轴为艇艏相对方位（艇艏=0）。BOW/FLANK 覆盖判断用同一 frame。
	var array_heading: float = _array_heading_deg()

	var bb: PackedFloat32Array = PackedFloat32Array()
	bb.resize(BB_BINS)
	var nb: PackedFloat32Array = PackedFloat32Array()
	nb.resize(NB_BINS)
	var demon: PackedFloat32Array = PackedFloat32Array()
	demon.resize(DEMON_BINS)
	# 背景：噪声底 + 时间相关随机起伏（非固定纯色，G-04/S1-04.4）
	_advance_noise_tex(_bb_noise_tex)
	_advance_noise_tex(_nb_noise_tex)
	_advance_noise_tex(_demon_noise_tex)
	for i in range(BB_BINS):
		bb[i] = _noise_floor_at(_bb_noise_tex, i)
	for i in range(NB_BINS):
		nb[i] = _noise_floor_at(_nb_noise_tex, i)
	for i in range(DEMON_BINS):
		demon[i] = _noise_floor_at(_demon_noise_tex, i)
	var bb_peaks: Array = []
	var nb_tonals: Array = []
	var tonal_count: int = 0
	var total_se: float = -INF
	# TOWED 硬件门槛（S1-03）：无硬件 = 阵不存在，不产生任何 TOWED 接触
	var tow: TowedArray = null
	if active_array_id == "TOWED" and _own_ref != null:
		tow = _own_ref.get("towed")
	var mirror_lr: bool = prof.mirror_lr
	# S1-03C-P0-02：本行传感器原点 —— BOW/FLANK/ACTIVE = 艇心；TOWED = 阵列
	# 声学中心。方位/距离/TL/LOB 全部从该原点出发，杜绝"艇心算方位、阵心写
	# observer"的 ~6° 系统误差（距离越近、缆越长越明显）。
	var obs_e: float = float(own.position_east_m)
	var obs_n: float = float(own.position_north_m)
	if active_array_id == "TOWED" and tow != null:
		var ctr: Vector2 = tow.array_center_position(obs_e, obs_n)
		obs_e = ctr.x
		obs_n = ctr.y
	# REQ-AC-05：DEMON 摘要取本行最强 SE 接触，不再被 targets 遍历顺序
	# 偏向最后处理目标。
	var demon_best_se: float = -INF
	var demon_best_rpm: float = 0.0
	var demon_best_blades: int = 0

	for tgt in targets:
		var ac: RefCounted = acs.get(tgt.id, null)
		if ac == null:
			continue
		if active_array_id == "TOWED":
			if tow == null:
				continue  # 未安装拖曳硬件：严格无 TOWED 测量
			# P1-03/REQ-09：STOWED 或有效孔径≤死区 → 本行只出背景噪声，不产生
			# 任何目标 peak/tonal/DEMON 特征（与 DESIGN.md is_acoustically_active
			# 语义一致）；部分布放超过 dead_length 后由 usable_fraction 连续恢复。
			if not tow.is_acoustically_active():
				continue
		var d: Vector2 = Vector2(tgt.position_east_m - obs_e, tgt.position_north_m - obs_n)
		var rng_m: float = d.length()
		var true_brg: float = rad_to_deg(atan2(d.x, d.y))
		# 阵列相对方位决定覆盖/方向增益（问题2/3）；BB 显示相对方位用于瀑布/mark。
		var array_rel: float = NavUtils.true_to_array(array_heading, true_brg)
		if not in_array_coverage(array_rel, prof):
			continue
		# AC-02/AC-03：方向响应 + 拖曳阵连续性能损失（孔径/沉降/弯曲/流噪各计一次）。
		var dir_gain: float = _array_direction_gain_db(array_rel, prof)
		if tow != null:
			dir_gain += tow.performance_loss_db()
		var speed_kn: float = float(tgt.speed_kn)
		# S1-04/G-03 统一声学模型：TL 走 EnvironmentModel（含频率吸收），
		# 不得散落 20log10*1.2 之类简化公式
		var tl: float = AcousticService.propagation_loss(rng_m, center_freq, _env)
		var noise: float = prof.receiver_noise_db(_env, own_speed)
		# REQ-AC-03：BB SE 吃宽带干扰（按接触方位的波束响应，线性功率合成）。
		var jam_bb: float = _env.interference_noise_db(
			center_freq, obs_e, obs_n, own_depth, true_brg, prof.beamwidth_deg
		)
		noise = EnvironmentModel.combine_db(noise, jam_bb)
		var level_db: float = ac.broadband_sl_db(speed_kn, float(tgt.depth_m)) - tl
		var se_db: float = level_db + gain + dir_gain - noise - dt_db
		# S1-07A（Commit 2）：跨温跃层附加 TL（与自动测量链同源；旧场景=0）。
		se_db -= _env.cross_layer_extra_db(center_freq, own_depth, float(tgt.depth_m))
		total_se = maxf(total_se, se_db)
		# 概率探测 P_d（S1-04/AC-01）：不再用 SE<=0 硬门限，弱目标间歇出现；
		# k_d 与 DT 同出一份 profile（与自动船员链一致）。
		var pd: float = prof.detection_probability(se_db)
		# REQ-AC-01：BB 一次 miss 不再整体跳过 NB/DEMON——窄带特征按自身
		# 频率 SE/概率独立积累（BB 与 NB 带宽/处理增益可不同）。
		var bb_hit: bool = _rng.randf() < pd
		var contact_freqs: Array = []  # REQ-10：本接触本行实测谱线频率（附到峰）
		var contact_peaks: Array = []  # REQ-10：本接触本行的峰引用（回填 freqs_hz）
		if bb_hit:
			detection_count += 1
			# BB 行：高斯波束峰（幅度∝SE），叠加每行随机方位噪声
			var beamw: float = prof.beamwidth_deg
			# AC-02：显示/测量方位噪声统一走 profile 的误差模型（线阵端射按
			# 1/|sin α| 有界放大）；显示幅度（amp）只影响配色，不参与 Pd。
			var brg_noise: float = _randn() * prof.bearing_sigma_deg(se_db, array_rel)
			var amp: float = display_amp_db(se_db)
			# TOWED 单线阵：对阵轴两侧等角响应 → 生成共享证据的 A/B 镜像候选
			# （S1-03A：pair 同 ID/同 SE/同噪声样本，消歧前对玩家等价，不标真假）。
			var pair_id: String = ""
			var disp_brgs: Array = []  # [{bearing_deg, branch}]
			if mirror_lr and active_array_id == "TOWED":
				_ambiguity_counter += 1
				pair_id = "AMB%04d" % _ambiguity_counter
				# P1-01/REQ-06：单次离轴角噪声 → 两支严格关于阵轴对称。
				# 旧实现两支加同号 brg_noise：(A+B)/2 = psi+e ≠ psi，破坏对称。
				# 正确：alpha_hat = 离轴角 + 一次噪声；theta_A = psi+alpha_hat、
				# theta_B = psi-alpha_hat，则 wrap360(theta_A + theta_B) = 2*psi。
				var alpha_hat: float = array_rel + brg_noise
				var theta_a: float = NavUtils.wrap360(array_heading + alpha_hat)
				var theta_b: float = NavUtils.wrap360(array_heading - alpha_hat)
				disp_brgs.append(
					{"bearing_deg": NavUtils.true_to_display(own_course, theta_a), "branch": 1}
				)
				disp_brgs.append(
					{"bearing_deg": NavUtils.true_to_display(own_course, theta_b), "branch": -1}
				)
			else:
				# 瀑布/玩家看到的方位 = 艇艏相对方位（问题2）
				disp_brgs.append(
					{
						"bearing_deg": NavUtils.true_to_display(own_course, true_brg) + brg_noise,
						"branch": 0
					}
				)
			for pb in disp_brgs:
				var brg_disp: float = float(pb["bearing_deg"])
				for i in range(BB_BINS):
					var bin_brg: float = -180.0 + 2.0 * i
					var db: float = absf(NavUtils.angle_diff(bin_brg, brg_disp))
					if db < 12.0:
						bb[i] = maxf(bb[i], NOISE_FLOOR_DB + amp * exp(-0.5 * pow(db / beamw, 2.0)))
				var peak: Dictionary = {
					"peak_id": "p%02d" % bb_peaks.size(),
					"bearing_deg": brg_disp,
					"level_db": amp,
					"se_db": se_db,
					"snr_db": se_db,
					"ambiguous_pair_id": pair_id,
					"ambiguity_branch": int(pb["branch"]),
				}
				bb_peaks.append(peak)
				contact_peaks.append(peak)
		# NB 行：目标音线（每条谱线用自身频率算 TL/N_eff，S1-04.2 不得全按 500 Hz；
		# 可见度随 SNR 概率变化，不再 lvl<=0 硬切）
		for line_v in ac.tonal_lines:
			var f_hz: float = float(line_v["freq_hz"])
			if f_hz <= nb_fmin_hz or f_hz >= nb_fmax_hz:
				continue
			var tl_f: float = AcousticService.propagation_loss(rng_m, f_hz, _env)
			var noise_f: float = _env.effective_noise_db(f_hz, own_speed)
			# REQ-AC-03：NB 谱线同样吃宽带干扰（同一 N_eff 口径）。
			var jam_f: float = _env.interference_noise_db(
				f_hz, obs_e, obs_n, own_depth, true_brg, prof.beamwidth_deg
			)
			noise_f = EnvironmentModel.combine_db(noise_f, jam_f)
			# P1-03/REQ-08：NB tonal 也吃方向增益 + 部署/弯曲/超速损失——与 BB 同源，
			# 不得只进 BB se_db（否则 FLANK 扇区边缘谱线强度不随方向衰减）。
			var lvl: float = float(line_v["level_db"]) + gain + dir_gain - tl_f - noise_f
			# S1-07A：NB tonal 同吃跨层附加 TL（按谱线频率）。
			lvl -= _env.cross_layer_extra_db(f_hz, own_depth, float(tgt.depth_m))
			var p_line: float = AcousticService.detection_probability(lvl)
			if _rng.randf() >= p_line:
				continue
			var bi: int = clampi(
				int((f_hz - nb_fmin_hz) / maxf(nb_fmax_hz - nb_fmin_hz, 1.0) * NB_BINS),
				0,
				NB_BINS - 1,
			)
			nb[bi] = maxf(nb[bi], NOISE_FLOOR_DB + minf(lvl * 0.5, 28.0))
			nb_tonals.append({"freq_hz": f_hz, "level_db": lvl})
			contact_freqs.append(f_hz)
			tonal_count += 1
		# REQ-10：把本接触本行实测谱线频率附到其 BB 峰上（玩家 Mark 时
		# 保留测得频率供关联兼容性判断；不重复加噪）。
		for pk_ref in contact_peaks:
			pk_ref["freqs_hz"] = contact_freqs.duplicate()
		# DEMON：桨叶率谐波（blades × 轴转速）
		var rpm_hz: float = speed_kn * float(ac.turns_per_knot) / 60.0
		var blade_rate: float = rpm_hz * float(ac.blade_count)
		if blade_rate > 0.5 and blade_rate < DEMON_FMAX_HZ:
			var d_amp: float = display_amp_db(se_db, 0.5, 24.0)
			for k in range(1, 6):
				var fh: float = blade_rate * k
				if fh >= DEMON_FMAX_HZ:
					break
				var di: int = clampi(int(fh / DEMON_FMAX_HZ * DEMON_BINS), 0, DEMON_BINS - 1)
				demon[di] = maxf(demon[di], NOISE_FLOOR_DB + d_amp * pow(0.7, k - 1))
		if se_db > demon_best_se:
			demon_best_se = se_db
			demon_best_rpm = rpm_hz
			demon_best_blades = int(ac.blade_count)

	# REQ-AC-05：本行 DEMON 摘要只在遍历结束后按最强接触更新一次。
	if demon_best_se > -INF:
		_update_demon_estimate(demon_best_rpm, demon_best_blades, demon_best_se)

	# 每行固化自身观测上下文（S1-01/S1-03）：历史行点击时 Mark 必须用
	# 那一行的时刻/艏向/阵轴/站位，而不是当前仿真状态。
	var tow_center_m: float = tow.array_center_offset_m() if tow != null else 0.0
	var tow_len_m: float = tow.actual_tow_length_m if tow != null else 0.0
	(
		bb_rows
		. append(
			{
				"row_id": _next_row_id(),
				"t": sim_time,
				"array_id": active_array_id,
				"sensor_id": "OP_" + active_array_id,
				"bearing_frame": "bow_rel",  # 峰坐标恒为艇艏相对帧（TRUE 瀑布仅显示重排）
				"values": bb,
				"peaks": bb_peaks,
				"course": own_course,
				"array_heading": array_heading,
				"own_e": float(own.position_east_m),
				"own_n": float(own.position_north_m),
				"observer_e": obs_e,
				"observer_n": obs_n,
				"tow_center_m": tow_center_m,
				"tow_length_m": tow_len_m,
			}
		)
	)
	(
		nb_rows
		. append(
			{
				"t": sim_time,
				"array_id": active_array_id,
				"sensor_id": "OP_" + active_array_id,
				"values": nb,
				"tonals": nb_tonals,
			}
		)
	)
	demon_rows.append(
		{
			"t": sim_time,
			"array_id": active_array_id,
			"sensor_id": "OP_" + active_array_id,
			"values": demon
		}
	)
	# P1-10：每新行递增单调序号（pop_front 封顶后 size 不再变化，UI 比较
	# newest_sequence 而非数组长度，否则 600 行后瀑布永久冻结）。
	waterfall_seq += 1
	if bb_rows.size() > 600:
		bb_rows.pop_front()
		nb_rows.pop_front()
		demon_rows.pop_front()
	_update_classification(tonal_count, total_se)


## DEMON 估计（轴转速/桨叶数/航速，全部带不确定度）。
## 注意：只依赖操作员可测的谐波频率，速度用通用螺距先验换算。
func _update_demon_estimate(rpm_hz: float, blades_hint: int, se_db: float) -> void:
	if rpm_hz <= 0.0:
		return
	var rpm_meas: float = rpm_hz + _randn() * maxf(0.05 * rpm_hz, 0.02)
	var blade_meas: int = blades_hint if se_db > 8.0 else 0  # 低 SNR 时桨叶数不确定
	var speed_kn_est: float = rpm_meas * PROP_PITCH_M / 0.514444  # REQ-AC-05：V=f_shaft·pitch/0.5144
	var sigma_kn: float = (
		speed_kn_est * (PROP_PITCH_SIGMA / PROP_PITCH_M) + 1.0 + maxf(0.0, 6.0 - se_db) * 0.5
	)
	demon_estimate = {
		"rpm_hz": rpm_meas,
		"rpm_sigma_hz": maxf(0.05 * rpm_meas, 0.02),
		"blades": blade_meas,
		"speed_kn": speed_kn_est,
		"speed_sigma_kn": sigma_kn,
		"confidence": clampf(se_db / 15.0, 0.0, 1.0),
	}


## 概率分类：比较观测（桨叶率/音线数/响度）与情报库模板，softmax 出概率。
## 分类最佳匹配后，用模板的 kn_per_br_hz 先验重估 DEMON 航速（带 sigma）。
## 仅当本行确有接触(se_db 有限且 >0)才重算；空行保留上一分类，避免 NaN。
func _update_classification(tonal_count: int, se_db: float) -> void:
	if not is_finite(se_db) or se_db <= 0.0:
		if demon_estimate.is_empty() and classification.is_empty():
			classification = {}
		return
	if demon_estimate.is_empty() and tonal_count == 0:
		classification = {}
		return
	var scores: Dictionary = {}
	var blade_rate_obs: float = (
		float(demon_estimate.get("rpm_hz", 0.0)) * float(demon_estimate.get("blades", 1))
		if demon_estimate.get("blades", 0) > 0
		else 0.0
	)
	for cname in CLASS_TEMPLATES:
		var tpl: Dictionary = CLASS_TEMPLATES[cname]
		var s: float = 0.0
		if blade_rate_obs > 0.0:
			s -= absf(blade_rate_obs - float(tpl["blade_rate_hz"])) * 1.5
		s -= absf(tonal_count - int(tpl["tonals"])) * 0.8
		s -= absf(minf(se_db, 20.0) - float(tpl["loud_db"])) * 0.3
		scores[cname] = s
	var mx: float = -INF
	for cname in scores:
		mx = maxf(mx, float(scores[cname]))
	var sum: float = 0.0
	var probs: Dictionary = {}
	for cname in scores:
		var p: float = exp(float(scores[cname]) - mx)
		probs[cname] = p
		sum += p
	for cname in probs:
		probs[cname] = float(probs[cname]) / maxf(sum, 1e-9)
	probs["best"] = _argmax(probs)
	classification = probs
	# 用最佳匹配模板只作先验提示，绝不静默覆盖实测航速（REQ-AC-05）。
	# （模板 blade_rate/kn 换算仅供 UI 参考；实测 speed_kn_est 已在上面固化。）


func _argmax(probs: Dictionary) -> String:
	var best: String = ""
	var bv: float = -1.0
	for cname in probs:
		if cname == "best":
			continue
		if float(probs[cname]) > bv:
			bv = float(probs[cname])
			best = cname
	return best


## 最新 BB 行的主峰列表（供 UI/测试发现目标）。
## REQ-B1-02：瀑布行稳定唯一 ID（行生成时分配一次）。
func _next_row_id() -> String:
	_row_counter += 1
	return "row_%05d" % _row_counter


func latest_peaks() -> Array:
	if bb_rows.is_empty():
		return []
	return bb_rows[-1]["peaks"]


## 玩家 Mark：在 BB 峰（或任意游标方位）处产生一条 Measurement。
## bearing_deg 语义由 as_true 决定：
##   as_true=false（默认，RELATIVE 瀑布）：输入为"该行"的艇艏相对方位(display)，
##     内部反算成真方位(βtrue=wrap360(ψown+βdisplay)，问题2)才写入 Measurement——
##     绝不让相对方位直入 TMA。
##   as_true=true（TRUE STABILIZED 瀑布）：输入已是真北方位，直接加噪声写入。
## row（S1-01/S1-03 历史行上下文）：点击瀑布时必须传入被点行——Measurement 的
##   时间/本艇站位/艏向/阵轴/拖曳阵心全部取自那一行，而不是当前仿真状态。
## S1-03B：传感器/阵心/测向精度一律以"被点行自己的 array_id"为准，绝不使用
##   点击时刻的 active_array_id（切阵列后点旧行不得生成"新阵列传感器 + 旧阵
##   拖曳字段"的错配测量）。
## 峰匹配用 canonical frame（S1-01）：峰方位存的是显示 frame（相对该行艏向），
##   TRUE 输入先转成该行显示 frame 再比较，不得混用。
## 这是 Measurement 的合法来源之一（玩家手动）。
func create_mark(
	bearing_deg: float,
	sim_time: float,
	_target_id: String = "",
	as_true: bool = false,
	row: Dictionary = {}
) -> Measurement:
	# S1-03B：行来源阵列优先；无行上下文（旧调用）才回退当前 active 阵列
	var src_array: String = str(row.get("array_id", active_array_id))
	if not array_profiles.has(src_array):
		src_array = active_array_id
	var prof: SensorAcousticProfile = profile_for(src_array)
	# ---- 行上下文（缺省回退当前状态，仅供旧测试兼容）----
	var r_t: float = float(row.get("t", sim_time))
	var own_course: float = float(row.get("course", float(_own_ref.course_deg)))
	var own_e: float = float(row.get("own_e", float(_own_ref.position_east_m)))
	var own_n: float = float(row.get("own_n", float(_own_ref.position_north_m)))
	var arr_hdg: float = float(row.get("array_heading", _array_heading_deg()))
	var peaks: Array = row.get("peaks", latest_peaks()) if not row.is_empty() else latest_peaks()
	# ---- 峰匹配（canonical true bearing ↔ 显示 frame 统一）----
	var input_disp: float = bearing_deg
	if as_true:
		input_disp = NavUtils.true_to_display(own_course, bearing_deg)
	var matched: Dictionary = {}
	var se_db: float = -1.0
	# REQ-10：选**最近**峰（6° 门内角差最小），而非首个命中峰——重叠峰
	# 顺序随机时首中会选错峰。
	var best_disp_diff: float = 6.0
	for pk in peaks:
		var dd: float = absf(NavUtils.angle_diff(float(pk["bearing_deg"]), input_disp))
		if dd < best_disp_diff:
			best_disp_diff = dd
			se_db = float(pk["se_db"])
			matched = pk
	# REQ-B1-02：同一 row_id+peak_id 重复点击返回既有 Measurement——不新增
	# 物理证据、不重抽噪声；主流程改为"选中既有 Mark"。
	var dedupe_key := ""
	if row.has("row_id") and not matched.is_empty() and matched.has("peak_id"):
		dedupe_key = "%s:%s" % [str(row["row_id"]), str(matched["peak_id"])]
		if _marks_by_row_peak.has(dedupe_key):
			return _marks_by_row_peak[dedupe_key]
	# AC-02：方位 sigma 统一走 profile 的误差模型（线阵端射按 1/|sin α| 有界放大，
	# A/B 两支共用同一 sigma，只符号相反）。
	var peak_true_brg: float = (
		NavUtils.wrap360(bearing_deg) if as_true else NavUtils.rel_to_true(own_course, input_disp)
	)
	var peak_array_rel: float = NavUtils.true_to_array(arr_hdg, peak_true_brg)
	var sigma: float = prof.bearing_sigma_deg(se_db, peak_array_rel)
	var m: Measurement = Measurement.new()
	m.timestamp = r_t
	m.sensor_id = "OP_" + src_array
	# S109 P0-06：玩法层 Measurement 不携带 target_id（参数仅为旧调用方兼容）。
	# S1-00：操作员 Mark 是一次玩家确认的探测（detected=true），每次物理
	# 到达发唯一 evidence_id（镜像对在 create_mark_group 中共享）。
	m.detected = true
	_evidence_counter += 1
	m.evidence_id = "ev_%05d" % _evidence_counter
	# S1-03C-P0-02：观察站位优先取行固化的传感器原点（update 已从阵列声学中心
	# 算好并写入行）；历史行点击绝不事后用 tow_center_m 重建（杜绝艇心/阵心错配
	# 与 ~6° 系统误差）。旧行（无 observer 字段）回退 S1-03 公式。
	var tow_center_m: float = float(row.get("tow_center_m", 0.0))
	var tow_len_m: float = float(row.get("tow_length_m", 0.0))
	if row.has("observer_e") and row.has("observer_n"):
		m.observer_east_m = float(row["observer_e"])
		m.observer_north_m = float(row["observer_n"])
	elif src_array == "TOWED" and tow_center_m > 0.0:
		var rad: float = arr_hdg * NavUtils.DEG_TO_RAD
		m.observer_east_m = own_e - tow_center_m * sin(rad)
		m.observer_north_m = own_n - tow_center_m * cos(rad)
	else:
		m.observer_east_m = own_e
		m.observer_north_m = own_n
	# P1-01/REQ-06：谱图峰与 Mark 候选使用同一组方位——点击命中谱图峰时
	# （matched 非空）直接用峰方位转帧，不再二次抽样（峰已含测量噪声，二次
	# 抽样会让 Measurement 方位 ≠ 玩家所见峰方位）。仅无峰上下文
	# （测试/直接调用）保留一次加噪模拟测量误差。
	# REQ-B1-02：点击值即玩家所见测量值——无峰自由点击直接用点击方位，
	# 不再重抽随机误差（物理噪声只在行生成时抽一次）；峰命中沿用峰方位。
	# S1-11 §3.3/AT-49：玩家光标原始方位即 Measurement 方位——不在 6° 门内吸附
	# 峰值、不重新抽一次噪声。峰匹配只用于回填 SE/谱线/镜像歧义等元数据。
	var brg_in: float = bearing_deg
	if as_true:
		m.measured_bearing_deg = NavUtils.wrap360(brg_in)
	else:
		m.measured_bearing_deg = NavUtils.rel_to_true(own_course, brg_in)
	m.bearing_sigma_deg = sigma
	m.signal_excess_db = se_db
	m.snr_db = se_db
	m.detection_probability = AcousticService.detection_probability(se_db)
	# MK-03：未命中任何实测峰（玩家在数据区自由落点）时，这是一条"人工假设"：
	# 方位证据有效、可进 TMA 与发射链，但不冒充自动探测成功。
	m.manual_hypothesis = matched.is_empty()
	# REQ-10/PG-02：保留测得频率（峰上回填的本行实测谱线）供关联兼容性判断。
	# 峰上的 freqs_hz 是纯数值数组，此处统一迁移成 SpectralFeature DTO，
	# 让主动回波（本来就是字典）与被动 Mark 在消费侧同型。
	if not matched.is_empty() and matched.has("freqs_hz"):
		m.detected_frequencies = Measurement.spectral_features(matched["freqs_hz"])
	# 拖曳镜像歧义字段随 Measurement 固化（S1-03A）
	if not matched.is_empty() and str(matched.get("ambiguous_pair_id", "")) != "":
		m.ambiguous_pair_id = str(matched["ambiguous_pair_id"])
		m.ambiguity_branch = int(matched.get("ambiguity_branch", 0))
		m.array_heading_at_measurement_deg = arr_hdg
		m.array_center_east_m = m.observer_east_m
		m.array_center_north_m = m.observer_north_m
		m.actual_tow_length_m = tow_len_m
	if dedupe_key != "":
		_marks_by_row_peak[dedupe_key] = m
	return m


## 玩家 Mark（组版本，S1-03A）：点击拖曳阵镜像峰时默认创建一组关联候选。
## 返回 [主测量(所点支), 镜像测量(对支)]；非镜像单峰返回 [主测量]。
## 镜像方位 θ_B = wrap360(2ψ_a − θ_A)（关于测量时刻阵轴对称），共享
## pair_id / SE / 观察站位；Tracker/TMA 不得把两支当独立目标或双倍计数。
func create_mark_group(
	bearing_deg: float,
	sim_time: float,
	target_id: String = "",
	as_true: bool = false,
	row: Dictionary = {}
) -> Array:
	var primary: Measurement = create_mark(bearing_deg, sim_time, target_id, as_true, row)
	var out: Array = [primary]
	if not primary.has_ambiguity():
		return out
	# 镜像支：噪声独立采样，方位关于阵轴镜像
	var arr_hdg: float = primary.array_heading_at_measurement_deg
	var theta_mirror: float = NavUtils.wrap360(2.0 * arr_hdg - primary.measured_bearing_deg)
	var sibling: Measurement = Measurement.new()
	sibling.timestamp = primary.timestamp
	sibling.sensor_id = primary.sensor_id
	sibling.observer_east_m = primary.observer_east_m
	sibling.observer_north_m = primary.observer_north_m
	sibling.measured_bearing_deg = theta_mirror
	sibling.bearing_sigma_deg = primary.bearing_sigma_deg
	sibling.signal_excess_db = primary.signal_excess_db
	sibling.snr_db = primary.snr_db
	sibling.detection_probability = primary.detection_probability
	sibling.detected_frequencies = primary.detected_frequencies
	sibling.ambiguous_pair_id = primary.ambiguous_pair_id
	sibling.ambiguity_branch = -primary.ambiguity_branch
	sibling.array_heading_at_measurement_deg = arr_hdg
	sibling.array_center_east_m = primary.array_center_east_m
	sibling.array_center_north_m = primary.array_center_north_m
	sibling.actual_tow_length_m = primary.actual_tow_length_m
	# S1-00：镜像支与主支共享同一 evidence_id（同一物理到达，只计一次证据）。
	sibling.detected = primary.detected
	sibling.evidence_id = primary.evidence_id
	out.append(sibling)
	return out


## S1-11 §3.3/AT-49：Mark 被删除后允许在同一位置重新标记——清掉该物理
## Measurement 的 row/peak 去重缓存（去重只针对"仍存在的既有 Mark"）。
func drop_mark_cache(m: Measurement) -> void:
	if m == null:
		return
	for k in _marks_by_row_peak.keys():
		if _marks_by_row_peak[k] == m:
			_marks_by_row_peak.erase(k)


## row_id+peak_id 去重缓存条目数（测试/诊断用）。
func mark_cache_size() -> int:
	return _marks_by_row_peak.size()


## Autocrew（默认关闭）：对强检测自动 Mark。## 返回本时刻自动产生的测量（调用方负责 feed tracker）。
## S1-03B：①携带被点最新行上下文（阵心/时刻/阵轴，不再用无行缺省）；②拖曳
## 阵 A/B 同 pair 只处理一次并走 create_mark_group（返回共享 evidence 的两支），
## 调用方须把同 evidence 镜像支并入同一 Track（不双计、不建第二个目标）。
func autocrew_step(sim_time: float) -> Array:
	var out: Array = []
	if sim_time - _last_autocrew_t < AUTOCREW_INTERVAL_S:
		return out
	_last_autocrew_t = sim_time
	if bb_rows.is_empty():
		return out
	var latest: Dictionary = bb_rows[-1]
	var seen_pairs := {}
	for pk in latest.get("peaks", []):
		var pid: String = str(pk.get("ambiguous_pair_id", ""))
		if pid != "" and seen_pairs.has(pid):
			continue  # 同一物理到达的镜像峰只 Mark 一次（S1-03B）
		if float(pk.get("snr_db", 0.0)) >= 9.0:
			# REQ-AC-02：物理 P_d，不再用 clamp(SNR/12) 冒充探测概率。
			var pd: float = AcousticService.detection_probability(float(pk["snr_db"]))
			if pd >= AUTOCREW_PD_MIN:
				seen_pairs[pid] = true
				var grp: Array = create_mark_group(
					float(pk["bearing_deg"]), sim_time, "", false, latest
				)
				for gm in grp:
					out.append(gm)
	return out
