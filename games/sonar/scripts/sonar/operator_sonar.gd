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
##   TOWED 拖曳阵：尾部扇区（120..240）°，低频增益最高
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


## 当前阵列的物理航向(deg)：BOW/FLANK = own.course；TOWED 用拖曳阵自身航向
## （批次2 拖曳阵状态机将注入带转向滞后的 array_heading，此处先回退 own.course）。
func _array_heading_deg() -> float:
	if active_array_id == "TOWED" and _own_ref != null and _own_ref.get("array_heading_deg") != null:
		return float(_own_ref.array_heading_deg)
	if _own_ref == null:
		return 0.0
	return float(_own_ref.course_deg)


## 该目标(阵列相对方位)是否落在当前阵列的覆盖内。
## 覆盖结构：sectors(被覆盖) 或 full_circle+sectors_excluded(除盲区外全向)。
static func in_array_coverage(array_rel_deg: float, def: Dictionary) -> bool:
	if bool(def.get("full_circle", false)):
		var excl: Array = def.get("sectors_excluded", [])
		return not NavUtils.in_sectors(array_rel_deg, excl)
	return NavUtils.in_sectors(array_rel_deg, def.get("sectors", []))


## 方向性增益(dB)：目标位于某覆盖扇区内→0(扇区中心)，偏离→连续衰减；
## 完全不在覆盖内→极弱(调用方应直接跳过该接触)。
## 用每个扇区中心估算；full_circle(全向)阵列无方向性，恒 0。
static func _array_direction_gain_db(array_rel_deg: float, def: Dictionary) -> float:
	if bool(def.get("full_circle", false)):
		return 0.0
	var sectors: Array = def.get("sectors", [])
	if sectors.is_empty():
		return 0.0
	var worst: float = 0.0
	for s in sectors:
		var c: float = NavUtils.wrap180((float(s.x) + float(s.y)) * 0.5)
		worst = minf(worst, NavUtils.sector_gain_db(array_rel_deg, c, 40.0))
	return worst


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

	for tgt in targets:
		var ac: RefCounted = acs.get(tgt.id, null)
		if ac == null:
			continue
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
		# 瀑布/玩家看到的方位 = 艇艏相对方位（问题2）
		var disp_rel: float = NavUtils.true_to_display(own_course, true_brg)
		var brg_disp: float = disp_rel + brg_noise
		var amp: float = minf(se_db * 0.6, 30.0)
		for i in range(BB_BINS):
			var bin_brg: float = -180.0 + 2.0 * i
			var db: float = absf(NavUtils.angle_diff(bin_brg, brg_disp))
			if db < 12.0:
				bb[i] = maxf(bb[i], NOISE_FLOOR_DB + amp * exp(-0.5 * pow(db / beamw, 2.0)))
		bb_peaks.append({"bearing_deg": brg_disp, "level_db": amp, "se_db": se_db, "snr_db": se_db})
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

	bb_rows.append({"t": sim_time, "values": bb, "peaks": bb_peaks})
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
## bearing_deg 为操作员在艇艏相对瀑布上点选的相对方位(display)；内部反算成真方位
## (βtrue=wrap360(ψown+βdisplay)，问题2) 才写入 Measurement——绝不让相对方位直入 TMA。
## 这是 Measurement 的合法来源之一（玩家手动）。
func create_mark(bearing_deg: float, sim_time: float, target_id: String = "") -> Measurement:
	var def := _array_def()
	var se_db: float = -1.0
	for pk in latest_peaks():
		if absf(NavUtils.angle_diff(float(pk["bearing_deg"]), bearing_deg)) < 6.0:
			se_db = float(pk["se_db"])
	var sigma: float = float(def["sigma_min"])
	if se_db > 0.0:
		sigma = maxf(sigma * pow(2.0, -se_db / 6.0), 0.2)
	var m: Measurement = Measurement.new()
	m.timestamp = sim_time
	m.sensor_id = "OP_" + active_array_id
	m.target_id = target_id  # 仅测试统计；玩家流程不使用
	m.observer_east_m = float(_own_ref.position_east_m)
	m.observer_north_m = float(_own_ref.position_north_m)
	var own_course: float = float(_own_ref.course_deg)
	m.measured_bearing_deg = NavUtils.rel_to_true(own_course, bearing_deg + _randn() * sigma)
	m.bearing_sigma_deg = sigma
	m.signal_excess_db = se_db
	m.snr_db = se_db
	m.detection_probability = clampf(se_db / 12.0, 0.0, 1.0)
	return m


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
