class_name EnemySpawnGenerator
extends RefCounted
## enemy_spawn_generator.gd — 敌方随机出生（S1-07 §9.4，Commit 9）。
##
## 随机但受约束（REQ-DECISION-07）：
##   - bearing ~ Uniform(bearing_min, bearing_max)；
##   - range   ~ Triangular(range_min, range_mode, range_max)；
##   - course  ~ UNIFORM(0,360) 或 PATROL_BIASED（巡逻轴 ± spread）；
##   - speed   ~ Uniform(speed_min, speed_max)；
##   - depth_band ~ WeightedChoice(UPPER, LOWER)（连续 hold 深度）。
## 生成后验证：与本体/既有实体保持 min_separation_m、不越界；attempts 上限
## 后用显式 fallback_spawn（禁止无限循环）。
##
## 确定性（§2.3）：使用独立派生 RNG（scenario seed + seed_offset），不消耗
## 世界主 RNG——敌方存在与否绝不改变玩家测量流的随机消耗序列。

var profile: Dictionary = {}
## REQ-AI-01：最近一次出生失败原因（空 = 成功/未尝试）；fallback 非法时
## 必须显式报告失败而非静默接受或无限重抽。
var last_error: String = ""

var _rng: RandomNumberGenerator = null


func configure(cfg: Dictionary, base_seed: int) -> void:
	profile = cfg.duplicate(true)
	_rng = RandomNumberGenerator.new()
	_rng.seed = base_seed + int(cfg.get("seed_offset", 0))


## 抽样并验证一个敌方实体（Truth）。失败重试至 max_generation_attempts 后
## 用 fallback_spawn（无 fallback 配置时返回 null，由调用方决定是否报错）。
func spawn(own: TruthEntity, existing: Array, hold_depth_for_band: Callable) -> TruthEntity:
	if _rng == null:
		return null
	var attempts: int = maxi(int(profile.get("max_generation_attempts", 50)), 1)
	for i in range(attempts):
		var t := _sample(own, hold_depth_for_band)
		if _validate(t, own, existing):
			last_error = ""
			return t
	var fb: Dictionary = profile.get("fallback_spawn", {})
	if fb.is_empty():
		last_error = "no fallback_spawn configured"
		return null
	var fbt := _from_fallback(fb)
	# REQ-AI-01：fallback 同样校验；失败显式报告（不能带病出生）。
	if not _validate(fbt, own, existing):
		last_error = "fallback_spawn failed validation (bounds/depth/separation)"
		return null
	last_error = ""
	return fbt


func _sample(own: TruthEntity, hold_depth_for_band: Callable) -> TruthEntity:
	var brg_min: float = float(profile.get("bearing_min_deg", 0.0))
	var brg_max: float = float(profile.get("bearing_max_deg", 360.0))
	var bearing: float = _rng.randf_range(brg_min, brg_max) if brg_max > brg_min else brg_min
	var r_min: float = float(profile.get("range_min_m", 3000.0))
	var r_mode: float = float(profile.get("range_mode_m", 8000.0))
	var r_max: float = float(profile.get("range_max_m", 12000.0))
	var range_m: float = _triangular(r_min, r_mode, r_max)
	var b_rad: float = deg_to_rad(bearing)
	var t := TruthEntity.new()
	t.id = str(profile.get("id_prefix", "E")) + "-S1"
	t.class_id = str(profile.get("class_id", "enemy_sub"))
	t.side = "red"
	t.platform_type = str(profile.get("platform_type", "submarine"))
	t.position_east_m = own.position_east_m + sin(b_rad) * range_m
	t.position_north_m = own.position_north_m + cos(b_rad) * range_m
	var course: float = _sample_course()
	t.course_deg = course
	t.turn_rate_deg_s = float(profile.get("turn_rate_deg_s", 1.5))
	var v_min: float = float(profile.get("speed_min_kn", 4.0))
	var v_max: float = float(profile.get("speed_max_kn", 12.0))
	t.speed_kn = _rng.randf_range(v_min, v_max) if v_max > v_min else v_min
	var band: String = _weighted_depth_band()
	t.depth_m = (
		float(hold_depth_for_band.call(band))
		if hold_depth_for_band.is_valid()
		else (70.0 if band == "UPPER" else 180.0)
	)
	t.max_vertical_speed_m_s = float(profile.get("max_vertical_speed_m_s", 2.0))
	return t


func _sample_course() -> float:
	if str(profile.get("course_distribution", "UNIFORM")) == "PATROL_BIASED":
		var axis: float = float(profile.get("patrol_axis_deg", 0.0))
		var spread: float = float(profile.get("patrol_spread_deg", 60.0))
		return NavUtils.wrap360(axis + _rng.randf_range(-spread, spread))
	return _rng.randf() * 360.0


func _weighted_depth_band() -> String:
	var w: Dictionary = profile.get("depth_band_weights", {"UPPER": 0.6, "LOWER": 0.4})
	var p_upper: float = float(w.get("UPPER", 0.5))
	return "UPPER" if _rng.randf() < p_upper else "LOWER"


## 三角分布抽样（mode 为主峰值）。
func _triangular(a: float, c: float, b: float) -> float:
	if b <= a:
		return a
	c = clampf(c, a, b)
	var u: float = _rng.randf()
	var fc: float = (c - a) / (b - a)
	if u < fc:
		return a + sqrt(u * (b - a) * (c - a))
	return b - sqrt((1.0 - u) * (b - a) * (b - c))


func _validate(t: TruthEntity, own: TruthEntity, existing: Array) -> bool:
	var min_sep: float = float(profile.get("min_separation_m", 1000.0))
	# REQ-AI-01：深度合法性（非负、有限、不超过包线）与世界边界（距本艇
	# 最大距离，默认 30 km；场景可经 max_range_from_own_m / max_depth_m 收紧）。
	if (
		not is_finite(t.depth_m)
		or t.depth_m < 0.0
		or t.depth_m > float(profile.get("max_depth_m", 400.0))
	):
		return false
	if (
		NavUtils.distance(
			own.position_east_m, own.position_north_m, t.position_east_m, t.position_north_m
		)
		> float(profile.get("max_range_from_own_m", 30000.0))
	):
		return false
	if (
		NavUtils.distance(
			own.position_east_m, own.position_north_m, t.position_east_m, t.position_north_m
		)
		< min_sep
	):
		return false
	for e in existing:
		if (
			NavUtils.distance(
				float(e.position_east_m),
				float(e.position_north_m),
				t.position_east_m,
				t.position_north_m
			)
			< min_sep
		):
			return false
	return true


func _from_fallback(fb: Dictionary) -> TruthEntity:
	var t := TruthEntity.new()
	t.id = str(profile.get("id_prefix", "E")) + "-S1"
	t.class_id = str(profile.get("class_id", "enemy_sub"))
	t.side = "red"
	t.platform_type = str(profile.get("platform_type", "submarine"))
	t.position_east_m = float(fb.get("position_east_m", 8000.0))
	t.position_north_m = float(fb.get("position_north_m", 0.0))
	t.depth_m = float(fb.get("depth_m", 70.0))
	t.course_deg = float(fb.get("course_deg", 270.0))
	t.speed_kn = float(fb.get("speed_kn", 6.0))
	t.turn_rate_deg_s = float(profile.get("turn_rate_deg_s", 1.5))
	t.max_vertical_speed_m_s = float(profile.get("max_vertical_speed_m_s", 2.0))
	return t
