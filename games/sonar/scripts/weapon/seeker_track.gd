class_name SeekerTrack
extends RefCounted

## SeekerTrack（S1-07 §7.1/§7.3，Commit 7）：SeekerReturn 不直接成为"锁定对象"，
## 而是经关联后更新到内部航迹上。只承载净化测量（带噪方位/可选测距/SE/深度层
## 关系），绝不包含 target_id / Truth 位置 / damage_state——本类是玩法链对象，
## 由 TorpedoSeeker 持有，供 TargetSelection 与 Guidance 消费（§2.1 信息链）。
##
## lock quality 更新（§7.3 示例模型，参数全部配置化）：
##   hit:  q += alpha_hit * measurement_quality - gamma_innovation * innovation
##   miss: q -= beta_miss
## 滞回阈值（acquire/stable/drop）由 TorpedoSeeker 统一配置，本类只维护 q。

const MAX_SOURCE_HISTORY: int = 32

static var _next_id: int = 1

var seeker_track_id: int = 0
var bearing_estimate_deg: float = 0.0
var bearing_rate_deg_s: float = 0.0
var range_estimate_m: float = -1.0  # <0 = 纯被动无测距（绝不补 Truth 距离）
var bearing_var_deg2: float = 100.0  # 简化协方差：方位方差（§7.1 covariance）
var last_update_time: float = -1.0
var last_miss_time: float = -1.0
var consecutive_hits: int = 0
var consecutive_misses: int = 0
var total_hits: int = 0
var total_misses: int = 0
var mean_signal_excess_db: float = -999.0
var track_quality: float = 0.0
var lock_quality: float = 0.0
var depth_relation: String = ""
var classification_match: float = 0.0  # 谱一致性 EMA（1=与首次捕获谱稳定一致）
var source_history: Array = []  # SeekerReturn.return_id 时间线（封顶）

var _spectral_ref: Array = []  # 首次捕获的谱线频率基准（分类锚点）


static func create() -> SeekerTrack:
	var t := SeekerTrack.new()
	t.seeker_track_id = _next_id
	_next_id += 1
	return t


## 用一条净化 return 更新航迹（§7.2 关联后的测量更新）。cfg 键：
##   bearing_smoothing(0.45) rate_smoothing(0.30) alpha_hit(0.22)
##   gamma_innovation(0.15) meas_se_ref_db(15.0)
func update_with_return(r: SeekerReturn, now: float, cfg: Dictionary) -> void:
	var smoothing: float = float(cfg.get("bearing_smoothing", 0.45))
	var rate_smoothing: float = float(cfg.get("rate_smoothing", 0.30))
	var alpha: float = float(cfg.get("alpha_hit", 0.22))
	var gamma: float = float(cfg.get("gamma_innovation", 0.15))
	var meas_ref: float = float(cfg.get("meas_se_ref_db", 15.0))

	var innov: float = 0.0
	if last_update_time >= 0.0:
		var dt: float = maxf(now - last_update_time, 0.001)
		var predicted: float = bearing_estimate_deg + bearing_rate_deg_s * dt
		innov = NavUtils.wrap180(r.bearing_deg - predicted)
		if dt > 0.05:
			bearing_rate_deg_s = lerp(bearing_rate_deg_s, innov / dt, rate_smoothing)
		else:
			bearing_rate_deg_s = lerp(bearing_rate_deg_s, 0.0, rate_smoothing)
		bearing_estimate_deg = NavUtils.wrap360(bearing_estimate_deg + innov * smoothing)
	else:
		bearing_estimate_deg = r.bearing_deg
	var sigma: float = maxf(r.bearing_sigma_deg, 0.5)
	bearing_var_deg2 = lerp(bearing_var_deg2, sigma * sigma, 0.30)
	if r.range_m >= 0.0:
		range_estimate_m = (
			r.range_m if range_estimate_m < 0.0 else lerp(range_estimate_m, r.range_m, 0.5)
		)
	mean_signal_excess_db = (
		r.signal_excess_db
		if total_hits == 0
		else lerp(mean_signal_excess_db, r.signal_excess_db, 0.35)
	)
	depth_relation = str(r.depth_relation)

	# 分类一致性（Commit 8，§7.4 w_c / §8.4）：return 谱线与锚点谱的相似度
	# EMA。稳定谱（真实目标/移动诱饵模拟谱）→ 高；抖动假峰（JAMMER）→ 低。
	var tonals: Array = []
	if r.spectral_features != null and r.spectral_features.has("tonal_hz"):
		tonals = r.spectral_features["tonal_hz"]
	var freqs: Array = []
	for tl in tonals:
		freqs.append(float(tl.get("freq_hz", 0.0)))
	if _spectral_ref.is_empty() and not freqs.is_empty():
		_spectral_ref = freqs
		classification_match = 1.0
	elif not freqs.is_empty() and not _spectral_ref.is_empty():
		var sim: float = tonal_similarity(_spectral_ref, freqs, 25.0)
		classification_match = lerp(classification_match, sim, 0.4)

	consecutive_hits += 1
	consecutive_misses = 0
	total_hits += 1
	var meas_q: float = clampf(r.signal_excess_db / maxf(meas_ref, 1.0), 0.0, 1.0)
	var innov_n: float = clampf(absf(innov) / sigma, 0.0, 1.0)
	lock_quality = clampf(lock_quality + alpha * meas_q - gamma * innov_n, 0.0, 1.0)
	_recompute_track_quality()
	last_update_time = now
	source_history.append(r.return_id)
	if source_history.size() > MAX_SOURCE_HISTORY:
		source_history.pop_front()


## 采样窗内无 return → miss 计龄（β_miss 惩罚，§7.3）。
func age_miss(now: float, beta_miss: float) -> void:
	consecutive_misses += 1
	total_misses += 1
	lock_quality = clampf(lock_quality - beta_miss, 0.0, 1.0)
	_recompute_track_quality()
	last_miss_time = now


## 航迹质量 = 命中占比（连续性），与 lock_quality（含测量质量/创新惩罚）分离。
func _recompute_track_quality() -> void:
	var n: int = total_hits + total_misses
	track_quality = clampf(float(total_hits) / float(maxi(n, 1)), 0.0, 1.0)


## 预测方位（供关联门限，§7.2 预测方位差）。
func predicted_bearing_deg(now: float) -> float:
	if last_update_time < 0.0:
		return bearing_estimate_deg
	return NavUtils.wrap360(
		bearing_estimate_deg + bearing_rate_deg_s * maxf(now - last_update_time, 0.0)
	)


## 标准化创新（0..1）：方位差/方位 σ。供 score 的 w_i 项与关联门限。
func normalized_innovation(r: SeekerReturn, now: float) -> float:
	var innov: float = NavUtils.wrap180(r.bearing_deg - predicted_bearing_deg(now))
	var sigma: float = maxf(r.bearing_sigma_deg, 0.5)
	return clampf(absf(innov) / sigma, 0.0, 1.0)


## 距离创新（仅 ACTIVE 有测距时参与关联；纯被动恒 0）。
func normalized_range_innovation(r: SeekerReturn) -> float:
	if range_estimate_m < 0.0 or r.range_m < 0.0:
		return 0.0
	var sigma: float = maxf(r.range_sigma_m, 10.0)
	return clampf(absf(r.range_m - range_estimate_m) / sigma, 0.0, 1.0)


## 两个谱线频率集合的相似度（0..1）：双向命中率均值，tol_hz 内视为同一条。
static func tonal_similarity(ref_freqs: Array, got_freqs: Array, tol_hz: float) -> float:
	if ref_freqs.is_empty() or got_freqs.is_empty():
		return 0.0
	var matched_ref: int = 0
	for f in ref_freqs:
		for g in got_freqs:
			if absf(float(f) - float(g)) <= tol_hz:
				matched_ref += 1
				break
	var matched_got: int = 0
	for g in got_freqs:
		for f in ref_freqs:
			if absf(float(g) - float(f)) <= tol_hz:
				matched_got += 1
				break
	var pr: float = float(matched_ref) / float(ref_freqs.size())
	var rc: float = float(matched_got) / float(got_freqs.size())
	return 0.5 * (pr + rc)


## 候选评分（§7.4）：score = w_q*q + w_se*SE + w_c*分类 + w_k*运动一致 - w_i*创新
## + 连续性 bonus。真实目标、诱饵、误报同公式竞争——不选最近、不选最响、
## 不读类型；分类项只看谱一致性（稳定谱高、抖动假峰被稀释，§8.4）。
func score(cfg: Dictionary, selected: bool) -> float:
	var w_q: float = float(cfg.get("w_quality", 1.0))
	var w_se: float = float(cfg.get("w_se", 0.5))
	var w_c: float = float(cfg.get("w_classification", 0.5))
	var w_k: float = float(cfg.get("w_kinematic", 0.25))
	var w_i: float = float(cfg.get("w_innovation", 0.5))
	var bonus: float = float(cfg.get("continuity_bonus", 0.15))
	var se_ref: float = float(cfg.get("score_se_ref_db", 20.0))
	var kine_ref_rate: float = float(cfg.get("kine_ref_rate_deg_s", 5.0))
	var innov_ref_var: float = float(cfg.get("innov_ref_var_deg2", 100.0))

	var se_term: float = (
		0.0
		if mean_signal_excess_db <= -900.0
		else clampf(mean_signal_excess_db / maxf(se_ref, 1.0), 0.0, 1.0)
	)
	# 运动一致性：方位率越大越不一致（真实目标切向运动有限）。
	var kine: float = clampf(1.0 - absf(bearing_rate_deg_s) / maxf(kine_ref_rate, 0.1), 0.0, 1.0)
	# 创新惩罚：方位方差大 → 关联不稳。
	var innov: float = clampf(bearing_var_deg2 / maxf(innov_ref_var, 1.0), 0.0, 1.0)
	var continuity: float = bonus if (selected and lock_quality >= 0.5) else 0.0
	return (
		w_q * track_quality
		+ w_se * se_term
		+ w_c * classification_match
		+ w_k * kine
		- w_i * innov
		+ continuity
	)


## 净化摘要（供 WIRE_TELEMETRY 回传母艇，§5.4；绝不含 Truth）。
func to_summary() -> Dictionary:
	return {
		"track_id": seeker_track_id,
		"bearing_est_deg": snappedf(bearing_estimate_deg, 0.1),
		"bearing_rate_deg_s": snappedf(bearing_rate_deg_s, 0.01),
		"has_range": range_estimate_m >= 0.0,
		"lock_quality": snappedf(lock_quality, 0.01),
		"track_quality": snappedf(track_quality, 0.01),
		"mean_se_db": snappedf(mean_signal_excess_db, 0.1),
		"classification_match": snappedf(classification_match, 0.01),
		"depth_relation": depth_relation,
		"hits": total_hits,
		"misses": total_misses,
	}
