class_name TorpedoSensorAdapter
extends RefCounted
## torpedo_sensor_adapter.gd — 鱼雷传感器采样适配器（S1-07 §6.5，Commit 6）。
##
## 仿真内核边界（§2.2）：本类是武器侧唯一允许接触 Truth targets/decoys 的
## 对象（声源级生成 / 声学采样 / 主动回波目标强度）。它向鱼雷输出的只有净化
## 后的 SeekerReturn——无 target_id、无真实位置、被动 Return 无真实 range，
## 普通 UI / Seeker / Guidance 层绝不直接拿到 Truth（§2.1）。
##
## 采样方程与玩家声呐同源（§6.3/§6.4，统一 AcousticService/DepthLayerModel）：
##   SE_passive = SL_contact - TL_layer(f,R,z_contact,z_torpedo)
##                - N_eff(torpedo_speed) + AG - DT
##   SE_active  = SL_ping - TL_out - TL_ret + TS - N_eff + AG - DT
## 探测为连续概率 Pd = 1/(1+exp(-SE/k_d))，无硬门限；miss 帧不产生 return。
## 方位按 SE 加噪（sigma_theta(SE)，弱接触抖动大）。
## 主动回波按 tau = 2R/c 延迟到达（绝不在发出 Ping 的同 tick 瞬时返回，
## §6.4），R_meas = c*tau/2 + noise（测距即测时，与玩家 PingSession 同纪律）。
## 误报由独立生成器产生（false_alarm_rate），绝不绑定真实 target_id（§6.6）。
##
## 本类不实现目标选择 / 捕获 / 跟踪（Commit 7 起 SeekerTrack）；只用注入 RNG，
## 固定 seed + 相同输入命令产出完全相同的结果（§2.3）。

var env: RefCounted = null  # EnvironmentModel（TL / N_eff 统一实现）
var depth_model: RefCounted = null  # DepthLayerModel（可为 null=旧二维）
var rng: RandomNumberGenerator = null  # 注入 RNG（无 rng 时采样视为全 miss）
## Truth 声源（TruthEntity 数组；潜艇/水面舰/诱饵同接口，Seeker 不得按类型
## 区分诱饵——§6.6/§8.4）。仿真内核持有，绝不下发玩法层。
var contacts: Array = []
var contact_acs: Dictionary = {}  # id -> AcousticProfile
# P1-12：id -> source token（OWN/HOSTILE/FRIENDLY）。内核边界安全过滤数据；
# 缺省 ""= 未分类（旧场景无 token，行为不变）。
var contact_tokens: Dictionary = {}
## 每次被动采样产生一条虚假 return 的概率（独立生成器；默认 0）。
var false_alarm_rate: float = 0.0
var max_active_listen_range_m: float = 15000.0
var active_listen_window_s: float = 30.0

var _pending_echoes: Array = []  # [{torpedo_id, arrive_t, contact, range_ref_m}]
var _next_return_id: int = 1


func set_rng(r: RandomNumberGenerator) -> void:
	rng = r


## 绑定服务与 Truth 声源（由 World 注入；也可测试直接构造）。
func bind(env_ref: RefCounted, depth_ref: RefCounted, contacts_arr: Array, acs: Dictionary) -> void:
	env = env_ref
	depth_model = depth_ref
	contacts = contacts_arr
	contact_acs = acs


func clear() -> void:
	_pending_echoes.clear()
	_next_return_id = 1


## ---- 被动采样（§6.3）----
## 对一艘鱼雷做一次被动采样。observer 为其自身状态快照（非 Truth），profile 为
## TorpedoAcousticProfile。仅返回 detected 的净化 SeekerReturn（miss 帧不产生
## return）；探测、方位噪声与误报全部经注入 RNG，确定性可复现。
func sample_passive(
	tp_e: float,
	tp_n: float,
	tp_depth: float,
	tp_speed_kn: float,
	tp_course_deg: float,
	profile: TorpedoAcousticProfile,
	sim_time: float
) -> Array:
	var out: Array = []
	if rng == null or profile == null or env == null:
		return out
	var f_min: float = profile.passive_frequency_min_hz
	var f_max: float = profile.passive_frequency_max_hz
	var freq: float = 0.5 * (f_min + f_max)
	var ag: float = profile.receiver_array_gain_db
	var dt_db: float = profile.detection_threshold_db
	var k_d: float = profile.detection_k_d
	var beam_half: float = (
		profile.passive_fov_half_deg
		if profile.passive_fov_half_deg > 0.0
		else 0.5 * profile.horizontal_beamwidth_deg
	)
	for c in contacts:
		var cid: String = str(c.id)
		if not contact_acs.has(cid):
			continue
		var ac: RefCounted = contact_acs[cid]
		var tb: float = NavUtils.bearing_to_true(
			tp_e, tp_n, float(c.position_east_m), float(c.position_north_m)
		)
		# 接收扇区门（beamwidth，相对鱼雷艏向）；扇区外不采样（确定性，不耗 RNG）。
		if not _in_fov(tb, tp_course_deg, beam_half):
			continue
		var range_m: float = NavUtils.distance(
			tp_e, tp_n, float(c.position_east_m), float(c.position_north_m)
		)
		var sl: float = ac.broadband_sl_db(float(c.speed_kn), float(c.depth_m))
		# P1-05：鱼雷专用接收自噪（与辐射噪声/潜艇级 own_noise 分离）。
		var se: float = (
			AcousticService
			. passive_se_layer(
				sl,
				range_m,
				freq,
				env,
				tp_speed_kn,
				float(c.depth_m),
				tp_depth,
				ag,
				dt_db,
				profile.receiver_self_noise_db(tp_speed_kn),
			)
		)
		var pd: float = AcousticService.detection_probability(se, k_d)
		if rng.randf() >= pd:
			continue  # miss：本帧无 return（不带未加噪真方位进玩法链）
		(
			out
			. append(
				_build_return(
					"PASSIVE",
					sim_time,
					sim_time,
					tb,
					se,
					pd,
					profile,
					{
						"ac": ac,
						"contact_depth": float(c.depth_m),
						"receiver_depth": tp_depth,
						"receiver_speed_kn": tp_speed_kn,
						"truth_range_m": range_m,  # 仅内核谱线声学用，绝不入 return
						"range_m": -1.0,
						"range_sigma_m": -1.0,
						"source_token": str(contact_tokens.get(cid, "")),
					},
				)
			)
		)
	# 误报（§6.6）：独立生成器，绝不绑定真实 target_id。
	if false_alarm_rate > 0.0 and rng.randf() < false_alarm_rate:
		out.append(_make_false_alarm(sim_time, profile))
	return out


## ---- 主动 Ping 回波（§6.4）----
## 鱼雷发出一次主动 Ping（emit_time）时登记各接触回波：tau=2R/c、R 以 Ping
## 时刻几何为基准（测距同源，REQ-19 纪律）；超出监听窗/最大距离的不登记。
## 回波按各自 arrive_t 延迟到达，绝不瞬时返回。
func schedule_active_echoes(
	tp_id: String,
	tp_e: float,
	tp_n: float,
	tp_course_deg: float,
	profile: TorpedoAcousticProfile,
	emit_time: float,
	ping_id: String = "",
	tp_depth: float = 0.0,
	tp_speed_kn: float = 0.0,
) -> void:
	if profile == null or env == null:
		return
	# P0-09/P0-10：主动发射门 = 独立 active FOV 半角（REQ-06：被动/主动
	# 分开管理；扇区外目标不排程回波——UI 画的扇区与物理一致）。
	var beam_half: float = (
		profile.active_fov_half_deg
		if profile.active_fov_half_deg > 0.0
		else 0.5 * profile.horizontal_beamwidth_deg
	)
	for c in contacts:
		var range_m: float = NavUtils.distance(
			tp_e, tp_n, float(c.position_east_m), float(c.position_north_m)
		)
		if range_m > max_active_listen_range_m:
			continue
		var tb: float = NavUtils.bearing_to_true(
			tp_e, tp_n, float(c.position_east_m), float(c.position_north_m)
		)
		if not _in_fov(tb, tp_course_deg, beam_half):
			continue
		var tau: float = AcousticService.echo_travel_time_s(range_m)
		if tau > active_listen_window_s:
			continue
		(
			_pending_echoes
			. append(
				{
					"torpedo_id": tp_id,
					"arrive_t": emit_time + tau,
					"emit_time": emit_time,
					"contact": c,
					"range_ref_m": range_m,
					# P1-07：发射/反射历元几何快照——方位与 SE 全用同一历元，
					# 绝不与到达时当前几何混用。
					"tp_e": tp_e,
					"tp_n": tp_n,
					"tp_depth": tp_depth,
					"tp_course_deg": tp_course_deg,
					"tp_speed_kn": tp_speed_kn,
					"c_e": float(c.position_east_m),
					"c_n": float(c.position_north_m),
					"c_depth": float(c.depth_m),
					"ping_id": ping_id,
					"source_token": str(contact_tokens.get(str(c.id), "")),
				}
			)
		)


## 收集该鱼雷已到点的主动回波（到点即结算：SE/Pd 用到达时刻几何，R_meas 用
## 登记 range_ref + 噪声）。返回净化 SeekerReturn（ACTIVE，带测量距离）。
func collect_due_active_returns(
	tp_id: String,
	tp_e: float,
	tp_n: float,
	tp_depth: float,
	tp_speed_kn: float,
	profile: TorpedoAcousticProfile,
	sim_time: float
) -> Array:
	var out: Array = []
	if profile == null or env == null:
		return out
	var ag: float = profile.receiver_array_gain_db
	var dt_db: float = profile.detection_threshold_db
	var k_d: float = profile.detection_k_d
	var keep: Array = []
	for e in _pending_echoes:
		if str(e.get("torpedo_id", "")) != tp_id:
			keep.append(e)
			continue
		if float(e["arrive_t"]) > sim_time + 1e-9:
			keep.append(e)
			continue
		# 到点：结算（RNG null 时按 miss 处理——只清 pending，不出 return）。
		# P1-07：方位/SE/测距全部使用发射历元快照（e["tp_e"] 等），绝不与
		# 到达时当前几何混用（旧实现 tb/range_at 用当前几何 = 历元混用）。
		var c: RefCounted = e["contact"]
		var cid: String = str(c.id)
		if rng != null and contact_acs.has(cid):
			var ac: RefCounted = contact_acs[cid]
			var tp_e0: float = float(e.get("tp_e", tp_e))
			var tp_n0: float = float(e.get("tp_n", tp_n))
			var tp_d0: float = float(e.get("tp_depth", tp_depth))
			var c_e0: float = float(e.get("c_e", float(c.position_east_m)))
			var c_n0: float = float(e.get("c_n", float(c.position_north_m)))
			var c_d0: float = float(e.get("c_depth", float(c.depth_m)))
			# P1-07 反射历元：反射发生在 emit + R/c（tau 的一半）。鱼雷位置按
			# 发射时航向/航速外推到反射时刻——绝不用到达时当前几何。
			var r0: float = float(e.get("range_ref_m", 0.0))
			var half_leg_s: float = 0.5 * AcousticService.echo_travel_time_s(r0)
			var v_ms: float = float(e.get("tp_speed_kn", 0.0)) * 0.5144
			var cr: float = deg_to_rad(float(e.get("tp_course_deg", 0.0)))
			var tp_er: float = tp_e0 + sin(cr) * v_ms * half_leg_s
			var tp_nr: float = tp_n0 + cos(cr) * v_ms * half_leg_s
			var range_at: float = NavUtils.distance(tp_er, tp_nr, c_e0, c_n0)
			var tb: float = NavUtils.bearing_to_true(tp_er, tp_nr, c_e0, c_n0)
			var se: float = (
				AcousticService
				. active_se_layer(
					profile.active_source_level_db,
					float(ac.active_target_strength_db),
					range_at,
					profile.active_center_frequency_hz,
					env,
					tp_speed_kn,
					tp_d0,
					tp_d0,
					c_d0,
					ag,
					dt_db,
					profile.receiver_self_noise_db(tp_speed_kn),
				)
			)
			var pd: float = AcousticService.detection_probability(se, k_d)
			if rng.randf() < pd:
				var sigma: float = AcousticService.bearing_sigma_deg(
					se, profile.bearing_sigma_min_deg, profile.bearing_sigma_max_deg
				)
				var range_sigma: float = (
					float(e["range_ref_m"]) * 0.02 + (1.0 / maxf(se, 0.1)) * 30.0
				)
				(
					out
					. append(
						_build_return(
							"ACTIVE",
							float(e.get("emit_time", sim_time)),
							float(e["arrive_t"]),
							tb,
							se,
							pd,
							profile,
							{
								"ac": ac,
								"contact_depth": c_d0,
								"receiver_depth": tp_d0,
								"source_token": str(e.get("source_token", "")),
								"range_m":
								(
									float(e["range_ref_m"])
									+ (rng.randfn(0.0, range_sigma) if rng != null else 0.0)
								),
								"range_sigma_m": range_sigma,
								"ping_id": str(e.get("ping_id", "")),
							},
						)
					)
				)
	# 已到点回波从 pending 移除（结算或 miss 都不再保留）。
	_pending_echoes = keep
	return out


func pending_echo_count() -> int:
	return _pending_echoes.size()


## ---- 内部构造 ----
## extra：{ac, contact_depth, receiver_depth, range_m, range_sigma_m}（打包超参，
## 避免长参数表）。return 只承载净化字段，绝不含 target_id/Truth。
func _build_return(
	mode: String,
	timestamp: float,
	available_time: float,
	true_bearing_deg: float,
	se: float,
	pd: float,
	profile: TorpedoAcousticProfile,
	extra: Dictionary
) -> SeekerReturn:
	var sr := SeekerReturn.new()
	sr.return_id = _next_return_id
	_next_return_id += 1
	sr.timestamp = timestamp
	sr.available_time = available_time
	sr.sensor_mode = mode
	sr.detected = true
	var sigma: float = AcousticService.bearing_sigma_deg(
		se, profile.bearing_sigma_min_deg, profile.bearing_sigma_max_deg
	)
	sr.bearing_sigma_deg = sigma
	sr.bearing_deg = (
		NavUtils.wrap360(true_bearing_deg + rng.randfn(0.0, sigma))
		if rng != null
		else true_bearing_deg
	)
	sr.range_m = float(extra.get("range_m", -1.0))
	sr.range_sigma_m = float(extra.get("range_sigma_m", -1.0))
	sr.signal_excess_db = se
	sr.detection_probability = pd
	sr.source_token = str(extra.get("source_token", ""))
	sr.spectral_features = _spectral_features(extra.get("ac", null), profile, extra)
	sr.depth_relation = _depth_relation(
		float(extra.get("contact_depth", 0.0)), float(extra.get("receiver_depth", 0.0))
	)
	sr.depth_band_hint = _band_hint_for(float(extra.get("contact_depth", 0.0)))
	sr.ping_id = str(extra.get("ping_id", ""))
	return sr


## 深度带粗分类（P1-08 配套）：接触深度 → 最近的层带 hold（UPPER/LOWER）。
## 只输出层带标签，不携带精确 Truth 深度；深度模型缺失时无提示。
func _band_hint_for(contact_depth: float) -> String:
	if depth_model == null:
		return ""
	var upper: float = float(depth_model.get("upper_hold_depth_m"))
	var lower: float = float(depth_model.get("lower_hold_depth_m"))
	return "UPPER" if contact_depth < 0.5 * (upper + lower) else "LOWER"


## 频带 + 落在带内的窄带谱线（不含任何 Truth 身份）。
## P1-06：谱线观测绝不复制 Truth 声纹——每条谱线独立经 TL(f)、跨层附加、
## N_eff(f)（含鱼雷接收自噪）、P_d（丢线），再叠频率/幅度噪声。仅把观测特征
## 送入 SeekerTrack。无 RNG/无距离（旧路径兼容）时退化为带通过滤（不产噪声）。
func _spectral_features(
	ac: RefCounted, profile: TorpedoAcousticProfile, extra: Dictionary = {}
) -> Dictionary:
	var f_min: float = profile.passive_frequency_min_hz
	var f_max: float = profile.passive_frequency_max_hz
	var tonals: Array = []
	if ac != null:
		var tls: Variant = ac.get("tonal_lines")
		if tls != null:
			var range_m: float = float(extra.get("truth_range_m", -1.0))
			var z_s: float = float(extra.get("contact_depth", 0.0))
			var z_r: float = float(extra.get("receiver_depth", 0.0))
			var recv_kn: float = float(extra.get("receiver_speed_kn", 0.0))
			var full: bool = rng != null and env != null and range_m >= 0.0
			for tl in tls:
				var f: float = float(tl.get("freq_hz", 0.0))
				if f < f_min or f > f_max:
					continue
				var lvl: float = float(tl.get("level_db", 0.0))
				if not full:
					tonals.append({"freq_hz": f, "level_db": lvl})
					continue
				var tl_db: float = AcousticService.propagation_loss(range_m, f, env)
				tl_db += env.cross_layer_extra_db(f, z_s, z_r)
				var n_eff: float = env.effective_noise_db_with_self(
					f, profile.receiver_self_noise_db(recv_kn)
				)
				var se_line: float = lvl - tl_db - n_eff
				var pd_line: float = AcousticService.detection_probability(
					se_line, profile.detection_k_d
				)
				if rng.randf() >= pd_line:
					continue  # 丢线（dropout）
				var f_jitter: float = maxf(f * 0.0015, 0.5)
				var f_obs: float = maxf(f + rng.randfn(0.0, f_jitter), 1.0)
				var lvl_obs: float = se_line + rng.randfn(0.0, 1.5)
				tonals.append({"freq_hz": f_obs, "level_db": lvl_obs})
	return {"band_min_hz": f_min, "band_max_hz": f_max, "tonal_hz": tonals}


## 深度层关系（无 depth_model / disabled = 旧二维 → 恒 SAME_LAYER）。
func _depth_relation(contact_depth: float, receiver_depth: float) -> String:
	var dm: RefCounted = depth_model
	if dm == null and env != null:
		dm = env.get("depth_model")
	if dm == null or not bool(dm.get("enabled")):
		return "SAME_LAYER"
	var band_c: String = str(dm.call("depth_band", contact_depth))
	var band_r: String = str(dm.call("depth_band", receiver_depth))
	if band_c == "TRANSITION" or band_r == "TRANSITION":
		return "TRANSITION"
	return "SAME_LAYER" if band_c == band_r else "CROSS_LAYER"


func _in_fov(true_bearing_deg: float, course_deg: float, beam_half_deg: float) -> bool:
	if beam_half_deg >= 180.0:
		return true
	var rel: float = NavUtils.wrap180(true_bearing_deg - course_deg)
	return absf(rel) <= beam_half_deg


## 误报 return：随机方位、阈值附近 SE，不绑定任何真实声源。
func _make_false_alarm(sim_time: float, profile: TorpedoAcousticProfile) -> SeekerReturn:
	var sr := SeekerReturn.new()
	sr.return_id = _next_return_id
	_next_return_id += 1
	sr.timestamp = sim_time
	sr.available_time = sim_time
	sr.sensor_mode = "PASSIVE"
	sr.detected = true
	sr.bearing_deg = NavUtils.wrap360(rng.randf() * 360.0)
	sr.bearing_sigma_deg = AcousticService.bearing_sigma_deg(
		0.0, profile.bearing_sigma_min_deg, profile.bearing_sigma_max_deg
	)
	sr.range_m = -1.0
	sr.range_sigma_m = -1.0
	sr.signal_excess_db = 0.0
	sr.detection_probability = 0.5
	sr.spectral_features = _spectral_features(null, profile)
	sr.depth_relation = "SAME_LAYER"
	return sr
