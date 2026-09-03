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
const NB_BINS: int = 100  # 0..500 Hz，每格 5 Hz
const NB_FMAX_HZ: float = 500.0
const DEMON_BINS: int = 128  # 0..32 Hz 包络谱
const DEMON_FMAX_HZ: float = 32.0
const NOISE_FLOOR_DB: float = -28.0
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

## 阵列覆盖（声呐综合修复 问题3）：以"阵列相对方位"(deg, wrap180)描述，不再用单一 Vector2。
##   BOW    全向（除艉部盲区 aft baffle 150..210°）——由 full_circle + sectors_excluded 表达
##   FLANK  左右舷双扇区 [+55..+125, −125..−55]
##   TOWED  相对拖曳阵自身航向前视扇区（航向滞后由批次2 拖曳阵状态机注入）
## 阵列相对方位 frame：BOW/FLANK 用 own.course；TOWED 用独立 array_heading。
const ARRAY_DEFS: Dictionary = {
	"BOW":
	{
		"full_circle": true,
		"sectors_excluded": [Vector2(150.0, 210.0)],
		"gain_db": 0.0,
		"sigma_min": 1.2,
		"beamwidth_deg": 5.0,
	},
	"FLANK":
	{
		"sectors": [Vector2(55.0, 125.0), Vector2(-125.0, -55.0)],
		"gain_db": 4.0,
		"sigma_min": 0.6,
		"beamwidth_deg": 3.0,
	},
	"TOWED":
	{
		"sectors": [Vector2(-100.0, 100.0)],
		"gain_db": 8.0,
		"sigma_min": 0.9,
		"beamwidth_deg": 4.0,
		"mirror_lr": true,  # 单线阵：对阵轴两侧等角响应 → A/B 镜像候选（S1-03A）
	},
}

var active_array_id: String = "BOW"
var bb_rows: Array = []  # [{t, values, peaks:[{bearing_deg, level_db, se_db, snr_db}]}]
var nb_rows: Array = []  # [{t, values: PackedFloat32Array(dB), tonals: [{freq_hz, level_db}]}]
var demon_rows: Array = []  # [{t, values: PackedFloat32Array(dB)}]
var demon_estimate: Dictionary = {}  # {rpm_hz, rpm_sigma_hz, blades, speed_kn, speed_sigma_kn, ..}
var classification: Dictionary = {}  # {CLASS: p} + "best"
var detection_count: int = 0
var _last_row_t: float = -1e9
var _last_autocrew_t: float = -1e9
var _ambiguity_counter: int = 0
var _rng: RandomNumberGenerator = null
var _env: RefCounted = null
var _own_ref: RefCounted = null


func setup(world_dict: Dictionary) -> void:
	_env = world_dict.get("env", null)
	_own_ref = world_dict["own"]
	_rng = world_dict.get("rng", null)
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.seed = 12345


func set_array(id: String) -> void:
	if ARRAY_DEFS.has(id):
		active_array_id = id


func _array_def() -> Dictionary:
	return ARRAY_DEFS[active_array_id]


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
## 覆盖结构：sectors(被覆盖) 或 full_circle+sectors_excluded(除盲区外全向)。
static func in_array_coverage(array_rel_deg: float, def: Dictionary) -> bool:
	if bool(def.get("full_circle", false)):
		var excl: Array = def.get("sectors_excluded", [])
		return not NavUtils.in_sectors(array_rel_deg, excl)
	return NavUtils.in_sectors(array_rel_deg, def.get("sectors", []))


## 方向性增益(dB)：目标位于某覆盖扇区内→0(扇区中心)，偏离→连续衰减。
## 多扇区阵列取"所有覆盖扇区中响应最高的一支"（S1-01：初始化为 -INF 取 maxf，
## 不得取 min——否则 FLANK 一侧永远被对侧扇区的最差值惩罚）。
## 完全不在覆盖内→极弱(调用方应直接跳过该接触)。
## full_circle(全向)阵列无方向性，恒 0。
static func _array_direction_gain_db(array_rel_deg: float, def: Dictionary) -> float:
	if bool(def.get("full_circle", false)):
		return 0.0
	var sectors: Array = def.get("sectors", [])
	if sectors.is_empty():
		return 0.0
	var best: float = -INF
	for s in sectors:
		var c: float = NavUtils.wrap180((float(s.x) + float(s.y)) * 0.5)
		best = maxf(best, NavUtils.sector_gain_db(array_rel_deg, c, 40.0))
	return best


func _randn() -> float:
	var u1: float = maxf(_rng.randf(), 0.000001)
	var u2: float = _rng.randf()
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


## 推进一行操作员数据（main_ui 按 ROW_INTERVAL_S 调用）。
## targets: Truth 目标数组；acs: 目标声学画像字典（id -> AcousticProfile）。
func update(sim_time: float, targets: Array, acs: Dictionary) -> void:
	if sim_time - _last_row_t < ROW_INTERVAL_S:
		return
	_last_row_t = sim_time
	var def := _array_def()
	var gain: float = def["gain_db"]
	var own: RefCounted = _own_ref
	var own_speed: float = float(own.speed_kn)
	var own_depth: float = float(own.depth_m)
	var own_course: float = float(own.course_deg)
	# BB 瀑布 x 轴为艇艏相对方位（艇艏=0）。BOW/FLANK 覆盖判断用同一 frame。
	var array_heading: float = _array_heading_deg()

	var bb: PackedFloat32Array = PackedFloat32Array()
	bb.resize(BB_BINS)
	bb.fill(NOISE_FLOOR_DB)
	var nb: PackedFloat32Array = PackedFloat32Array()
	nb.resize(NB_BINS)
	nb.fill(NOISE_FLOOR_DB)
	var demon: PackedFloat32Array = PackedFloat32Array()
	demon.resize(DEMON_BINS)
	demon.fill(NOISE_FLOOR_DB)
	var bb_peaks: Array = []
	var nb_tonals: Array = []
	var tonal_count: int = 0
	var total_se: float = -INF
	# TOWED 硬件门槛（S1-03）：无硬件 = 阵不存在，不产生任何 TOWED 接触
	var tow: TowedArray = null
	if active_array_id == "TOWED" and _own_ref != null:
		tow = _own_ref.get("towed")
	var mirror_lr: bool = bool(def.get("mirror_lr", false))

	for tgt in targets:
		var ac: RefCounted = acs.get(tgt.id, null)
		if ac == null:
			continue
		if active_array_id == "TOWED" and tow == null:
			continue  # 未安装拖曳硬件：严格无 TOWED 测量
		var d: Vector2 = Vector2(
			tgt.position_east_m - own.position_east_m, tgt.position_north_m - own.position_north_m
		)
		var rng_m: float = d.length()
		var true_brg: float = rad_to_deg(atan2(d.x, d.y))
		# 阵列相对方位决定覆盖/方向增益（问题2/3）；BB 显示相对方位用于瀑布/mark。
		var array_rel: float = NavUtils.true_to_array(array_heading, true_brg)
		if not in_array_coverage(array_rel, def):
			continue
		var dir_gain: float = _array_direction_gain_db(array_rel, def)
		# 拖曳阵可用度（孔径×沉降）缩放增益；BOW/FLANK 恒 1；
		# 弯曲/高速损失另计（不与孔径重复相乘，S1-03）
		dir_gain += 10.0 * log(maxf(_towed_usable_factor(), 1e-3)) / log(10.0)
		if tow != null:
			dir_gain += tow.bend_speed_loss_db()
		var speed_kn: float = float(tgt.speed_kn)
		var tl: float = maxf(0.0, 20.0 * log(maxf(rng_m, 1.0)) / log(10.0) * 1.2)
		var noise: float = _env.effective_noise_db(500.0, own_speed)
		var level_db: float = ac.broadband_sl_db(speed_kn, float(tgt.depth_m)) - tl
		var se_db: float = level_db + gain + dir_gain - noise
		total_se = maxf(total_se, se_db)
		if se_db <= 0.0:
			continue
		detection_count += 1
		# BB 行：高斯波束峰（幅度∝SE），叠加每行随机方位噪声
		var beamw: float = float(def["beamwidth_deg"])
		var brg_noise: float = (
			_randn() * maxf(float(def["sigma_min"]) * pow(2.0, -se_db / 6.0), 0.2)
		)
		var amp: float = minf(se_db * 0.6, 30.0)
		# TOWED 单线阵：对阵轴两侧等角响应 → 生成共享证据的 A/B 镜像候选
		# （S1-03A：pair 同 ID/同 SE/同噪声样本，消歧前对玩家等价，不标真假）。
		var pair_id: String = ""
		var disp_brgs: Array = []  # [{bearing_deg, branch}]
		if mirror_lr and active_array_id == "TOWED":
			_ambiguity_counter += 1
			pair_id = "AMB%04d" % _ambiguity_counter
			var theta_a: float = NavUtils.wrap360(array_heading + array_rel)
			var theta_b: float = NavUtils.wrap360(array_heading - array_rel)
			disp_brgs.append(
				{
					"bearing_deg": NavUtils.true_to_display(own_course, theta_a) + brg_noise,
					"branch": 1
				}
			)
			disp_brgs.append(
				{
					"bearing_deg": NavUtils.true_to_display(own_course, theta_b) + brg_noise,
					"branch": -1
				}
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
				"bearing_deg": brg_disp,
				"level_db": amp,
				"se_db": se_db,
				"snr_db": se_db,
				"ambiguous_pair_id": pair_id,
				"ambiguity_branch": int(pb["branch"]),
			}
			bb_peaks.append(peak)
		# NB 行：目标音线（只显示 SE>0 的）
		for line_v in ac.tonal_lines:
			var f_hz: float = float(line_v["freq_hz"])
			if f_hz <= 0.0 or f_hz >= NB_FMAX_HZ:
				continue
			var lvl: float = float(line_v["level_db"]) + gain - tl - noise
			if lvl <= 0.0:
				continue
			var bi: int = clampi(int(f_hz / NB_FMAX_HZ * NB_BINS), 0, NB_BINS - 1)
			nb[bi] = maxf(nb[bi], NOISE_FLOOR_DB + minf(lvl * 0.5, 28.0))
			nb_tonals.append({"freq_hz": f_hz, "level_db": lvl})
			tonal_count += 1
		# DEMON：桨叶率谐波（blades × 轴转速）
		var rpm_hz: float = speed_kn * float(ac.turns_per_knot) / 60.0
		var blade_rate: float = rpm_hz * float(ac.blade_count)
		if blade_rate > 0.5 and blade_rate < DEMON_FMAX_HZ:
			var d_amp: float = minf(se_db * 0.5, 24.0)
			for k in range(1, 6):
				var fh: float = blade_rate * k
				if fh >= DEMON_FMAX_HZ:
					break
				var di: int = clampi(int(fh / DEMON_FMAX_HZ * DEMON_BINS), 0, DEMON_BINS - 1)
				demon[di] = maxf(demon[di], NOISE_FLOOR_DB + d_amp * pow(0.7, k - 1))
		_update_demon_estimate(speed_kn * 0.0 + rpm_hz, float(ac.blade_count), se_db)

	# 每行固化自身观测上下文（S1-01/S1-03）：历史行点击时 Mark 必须用
	# 那一行的时刻/艏向/阵轴/站位，而不是当前仿真状态。
	var tow_center_m: float = tow.array_center_offset_m() if tow != null else 0.0
	var tow_len_m: float = tow.actual_tow_length_m if tow != null else 0.0
	(
		bb_rows
		. append(
			{
				"t": sim_time,
				"values": bb,
				"peaks": bb_peaks,
				"course": own_course,
				"array_heading": array_heading,
				"own_e": float(own.position_east_m),
				"own_n": float(own.position_north_m),
				"tow_center_m": tow_center_m,
				"tow_length_m": tow_len_m,
			}
		)
	)
	nb_rows.append({"t": sim_time, "values": nb, "tonals": nb_tonals})
	demon_rows.append({"t": sim_time, "values": demon})
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
	var speed_kn_est: float = rpm_meas * 60.0 * PROP_PITCH_M / 1852.0
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
	# 用最佳匹配模板重估航速（操作员情报库先验，非目标真值）
	var best_name: String = str(probs["best"])
	if best_name != "" and blade_rate_obs > 0.0:
		var tpl2: Dictionary = CLASS_TEMPLATES[best_name]
		var spd: float = blade_rate_obs * float(tpl2["kn_per_br_hz"])
		demon_estimate["speed_kn"] = spd
		demon_estimate["speed_sigma_kn"] = maxf(1.5, 0.3 * spd)


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
## 峰匹配用 canonical frame（S1-01）：峰方位存的是显示 frame（相对该行艏向），
##   TRUE 输入先转成该行显示 frame 再比较，不得混用。
## 这是 Measurement 的合法来源之一（玩家手动）。
func create_mark(
	bearing_deg: float,
	sim_time: float,
	target_id: String = "",
	as_true: bool = false,
	row: Dictionary = {}
) -> Measurement:
	var def := _array_def()
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
	for pk in peaks:
		if absf(NavUtils.angle_diff(float(pk["bearing_deg"]), input_disp)) < 6.0:
			se_db = float(pk["se_db"])
			matched = pk
			break
	var sigma: float = float(def["sigma_min"])
	if se_db > 0.0:
		sigma = maxf(sigma * pow(2.0, -se_db / 6.0), 0.2)
	var m: Measurement = Measurement.new()
	m.timestamp = r_t
	m.sensor_id = "OP_" + active_array_id
	m.target_id = target_id  # 仅测试统计；玩家流程不使用
	# TOWED：观察站位 = 测量时刻阵列声学中心（不是本艇中心，S1-03）
	var tow_center_m: float = float(row.get("tow_center_m", 0.0))
	var tow_len_m: float = float(row.get("tow_length_m", 0.0))
	if active_array_id == "TOWED" and tow_center_m > 0.0:
		var rad: float = arr_hdg * NavUtils.DEG_TO_RAD
		m.observer_east_m = own_e - tow_center_m * sin(rad)
		m.observer_north_m = own_n - tow_center_m * cos(rad)
	else:
		m.observer_east_m = own_e
		m.observer_north_m = own_n
	if as_true:
		m.measured_bearing_deg = NavUtils.wrap360(bearing_deg + _randn() * sigma)
	else:
		m.measured_bearing_deg = NavUtils.rel_to_true(own_course, bearing_deg + _randn() * sigma)
	m.bearing_sigma_deg = sigma
	m.signal_excess_db = se_db
	m.snr_db = se_db
	m.detection_probability = clampf(se_db / 12.0, 0.0, 1.0)
	# 拖曳镜像歧义字段随 Measurement 固化（S1-03A）
	if not matched.is_empty() and str(matched.get("ambiguous_pair_id", "")) != "":
		m.ambiguous_pair_id = str(matched["ambiguous_pair_id"])
		m.ambiguity_branch = int(matched.get("ambiguity_branch", 0))
		m.array_heading_at_measurement_deg = arr_hdg
		m.array_center_east_m = m.observer_east_m
		m.array_center_north_m = m.observer_north_m
		m.actual_tow_length_m = tow_len_m
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
	sibling.target_id = primary.target_id
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
	out.append(sibling)
	return out


## Autocrew（默认关闭）：对强检测自动 Mark。
## 返回本时刻自动产生的测量（调用方负责 feed tracker）。
func autocrew_step(sim_time: float) -> Array:
	var out: Array = []
	if sim_time - _last_autocrew_t < AUTOCREW_INTERVAL_S:
		return out
	_last_autocrew_t = sim_time
	for pk in latest_peaks():
		if float(pk.get("snr_db", 0.0)) >= 9.0:
			var pd: float = clampf(float(pk["snr_db"]) / 12.0, 0.0, 1.0)
			if pd >= AUTOCREW_PD_MIN:
				out.append(create_mark(float(pk["bearing_deg"]), sim_time))
	return out
