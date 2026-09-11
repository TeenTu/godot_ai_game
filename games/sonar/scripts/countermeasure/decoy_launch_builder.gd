class_name DecoyLaunchBuilder
extends RefCounted
## decoy_launch_builder.gd — 统一的诱饵发射程序构建（P1-C DC-02/DC-03/DC-05）。
##
## 面板按钮（CountermeasurePanel）与地图右键菜单（DecoyMapControl）走**同一处**
## 构建：方向、分离阶段、激活延时/寿命、声学画像都只在这里成形，不复制第二套
## 物理/声学参数（DC-05）。参数来源 = CountermeasureSystem 的配置（场景
## own_ship.countermeasures 可覆盖），本类不持有任何状态。

## 深度层带（照 own 实际深度选最近层带；hold 深度由 World 解析）。
const LOWER_FROM_DEPTH_M: float = 120.0
## DC-05：鼠标世界点离本艇近于此距离 → "方向不明确"，不默认偷偷发射。
const MIN_DECOY_RANGE_M: float = 200.0


static func band_for_depth(depth_m: float) -> String:
	return "LOWER" if depth_m >= LOWER_FROM_DEPTH_M else "UPPER"


## DC-05：地图右键投放可用性（纯函数；菜单只展示，不发射、不消耗库存）。
## 鼠标位置先转世界点 p，方向 = bearing_to_true(own, p)——**只**用来定义方向；
## 诱饵仍从本艇当前实际位置出管（World._launch_decoy 从 own 实际位置/深度出发）。
## reason 是稳定**代码**（"" = 可用），中文文案由 UI 层翻译（本层不依赖 UiText）。
## 返回 {bearing_deg, range_m, too_close, types: {type: {enabled, reason, ready, spare}}}。
static func offer(
	cm: CountermeasureSystem,
	own: TruthEntity,
	world_point: Vector2,
	now: float,
	mission_running: bool
) -> Dictionary:
	var oe: float = float(own.position_east_m) if own != null else 0.0
	var on: float = float(own.position_north_m) if own != null else 0.0
	var range_m: float = NavUtils.distance(oe, on, world_point.x, world_point.y)
	var too_close: bool = range_m < MIN_DECOY_RANGE_M
	var types: Dictionary = {}
	for t in [DecoyProgram.TYPE_MOBILE, DecoyProgram.TYPE_JAMMER]:
		types[t] = _offer_one(cm, str(t), now, mission_running, too_close)
	return {
		"bearing_deg": NavUtils.bearing_to_true(oe, on, world_point.x, world_point.y),
		"range_m": range_m,
		"too_close": too_close,
		"types": types,
	}


## 单一类型可用性 + 原因代码（UI 层翻中文；禁用原因不静默）。
static func _offer_one(
	cm: CountermeasureSystem, decoy_type: String, now: float, mission_running: bool, too_close: bool
) -> Dictionary:
	var ready: int = int(cm.ready_rounds) if cm != null else 0
	var spare: int = maxi(int(cm.inventory) - ready, 0) if cm != null else 0
	var cd: float = cm.cooldown_left(now) if cm != null else 0.0
	var reason: String = ""
	if not mission_running:
		reason = "MISSION_ENDED"
	elif cm == null or not cm.supported_types.has(decoy_type):
		reason = "DECOY_TYPE_UNSUPPORTED"
	elif too_close:
		reason = "DECOY_DIR_UNCLEAR"
	elif ready <= 0:
		reason = "DECOY_NO_ROUNDS"
	elif cd > 0.0:
		reason = "DECOY_COOLDOWN"
	return {
		"enabled": reason == "",
		"reason": reason,
		"ready": ready,
		"spare": spare,
		"cooldown_left_s": cd,
	}


## 类型画像：优先场景配置（cm.profiles[type]），否则内建默认。
## MOBILE 模拟目标谱；JAMMER 宽带干扰主体（频段可配置）+ 900 Hz 附加假峰。
static func signature_for(cm: CountermeasureSystem, decoy_type: String) -> AcousticProfile:
	var sig := AcousticProfile.new()
	var cfg: Dictionary = cm.profile_for(decoy_type) if cm != null else {}
	if not cfg.is_empty():
		sig.from_dict(cfg)
		return sig
	sig.broadband_base_level_db = 165.0
	sig.tonal_lines = [
		{"freq_hz": 240.0, "level_db": 128.0},
		{"freq_hz": 480.0, "level_db": 122.0},
	]
	if decoy_type == DecoyProgram.TYPE_JAMMER:
		# REQ-AC-03：宽带干扰主体 185 dB / 800–1200 Hz + 900 Hz 附加假峰。
		sig.broadband_base_level_db = 185.0
		sig.band_min_hz = 800.0
		sig.band_max_hz = 1200.0
		sig.tonal_lines = [{"freq_hz": 900.0, "level_db": 150.0}]
	return sig


## 构建发射程序。course_override < 0 → 未设置独立巡航方向（跟随投放方向，DC-02）。
static func build(
	cm: CountermeasureSystem,
	decoy_type: String,
	bearing_deg: float,
	own: TruthEntity,
	course_override: float = DecoyProgram.COURSE_FOLLOW_LAUNCH
) -> DecoyProgram:
	var prog := DecoyProgram.new()
	prog.decoy_type = decoy_type
	prog.launch_bearing_deg = clampf(bearing_deg, 0.0, 359.9)
	prog.course_deg = course_override
	prog.initial_depth_band = band_for_depth(float(own.depth_m) if own != null else 0.0)
	prog.commanded_depth_band = prog.initial_depth_band
	prog.activation_delay_s = 2.0
	prog.lifetime_s = 120.0
	var mobile_speed: float = cm.mobile_speed_kn if cm != null else 8.0
	var jam_drift: float = cm.jammer_drift_speed_kn if cm != null else 0.2
	if decoy_type == DecoyProgram.TYPE_MOBILE:
		prog.speed_kn = mobile_speed
		# MOBILE：分离速度 = 巡航速度（无分离阶段差异），方向即投放方向。
		prog.separation_speed_kn = DecoyProgram.SEPARATION_UNSET
		prog.separation_duration_s = 0.0
	else:
		# DC-03：JAMMER 有真实有限分离阶段，之后低速漂浮（不再全程 0 节）。
		prog.speed_kn = jam_drift
		prog.separation_speed_kn = cm.jammer_separation_speed_kn if cm != null else 6.0
		prog.separation_duration_s = cm.jammer_separation_duration_s if cm != null else 20.0
	prog.signature = signature_for(cm, decoy_type)
	return prog
