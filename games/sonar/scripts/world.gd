class_name World
extends RefCounted
## world.gd — 固定步长仿真主循环（阶段一，无 UI）。
## 职责：持有 Truth 实体/环境/传感器/测量生成器；固定步长推进运动学；
##   按 update_interval 触发测量并收集测量流。Truth 隔离：只产出 Measurement，
##   绝不把 Truth 位置直接暴露给上层 UI。

# 艇首主动阵 id（REQ-20）：仅当场景显式配置 own_ship.active_sonar 或 sensors
# 含 array_type=="active" 才有主动能力；无硬件绝不自动构造。
const ACTIVE_SENSOR_ID: String = "hull_active"

var world: Dictionary = {}
var sim_time: float = 0.0
var measurements: Array = []  # 全部生成的 Measurement
# Operator Layer：false 时传感器不自动产生 Measurement，测量只能由玩家 Mark / 已分配 Tracker / Autocrew 产生。
var auto_measurements: bool = true
var weapons: WeaponSystem = null  # 阶段四：发射管与在水鱼雷
# S1-07 §12.1：鱼雷 step 上下文（只含服务接口，绝不含 Truth targets）。
var torpedo_ctx: TorpedoContext = null

# ---- 主动声呐 Ping（S1-04B PingSession）：单在途 τ=2R/c 状态机 ----
# 铁律 REQ-16/17/19/20：单在途不清空未返回回波；测距即测时（R_meas 以发
# 射时刻登记距离为准，不回填 Truth）；无显式硬件 → UNAVAILABLE 禁用。
var ping_sl_db: float = 210.0
var ping_cooldown_s: float = 15.0
var ping_freq_min_hz: float = 2000.0
var ping_freq_max_hz: float = 4000.0
var ping_array_gain_db: float = 24.0
var ping_sound_speed_m_s: float = AcousticService.SOUND_SPEED_M_S
var ping_listen_window_s: float = 15.0  # 监听窗口：发射后等待回波的最长秒数
var ping_pulse_duration_s: float = 0.25  # 脉冲时长（ActiveEmissionEvent/暴露刻画，REQ-05）
var ping_hardware: bool = false  # 场景显式配置主动阵才为 true
# S1-03C-P1-03/REQ-08：主动阵发射扇区（相对本艇艏向）。场景 own_ship.active_sonar
# 可声明 coverage_start_deg/coverage_end_deg/baffle_start_deg/baffle_end_deg；
# 未声明 = 全向 (0..360) 无盲区（旧行为）。issue_ping 只在发射时刻扇区内登记回波。
var ping_coverage_sector: Vector2 = Vector2(0, 360)
var ping_baffle_sector: Vector2 = Vector2(0, 0)
# ---- S1-04C-REQ-05 / §9.1 声学事件：emission_bus 统一落事件 ----
# 每次显式发射记一条 AcousticEmissionEvent（本艇发射事实，非 Truth）；
# active_emissions 为总线兼容视图；敌方感知层只消费净化后样本。
var emission_bus: AcousticEmissionBus = null
var active_emissions: Array = []

# ---- S1-07 §8（Commit 8）：诱饵与反制（玩家发射器；敌方发射器同用 CountermeasureSystem）----
var countermeasures: CountermeasureSystem = null
var decoys: Array = []  # 活动诱饵（Truth 实体，随 tick 推进/寿命到期移除）
## REQ-CM-04：最近一次诱饵发射拒绝原因（UI 展示；来自 CountermeasureSystem）。
var last_decoy_reject_reason: String = ""

var emission_sanitizer: EmissionSanitizer = null
var player_evidence: Array = []  # 净化证据（告警/爆炸/本艇武器事实，可进 UI）
# 评审 P1-11：威胁航迹关联（LAUNCH_TRANSIENT→RUNNING_NOISE→ACTIVE_PING
# 同一威胁卡升级，抑制每秒一条告警的洪泛）。load_scenario 重置。
var threat_tracks := ThreatTrackManager.new()

var enemy_ai: EnemyDoctrineController = null
var enemy_weapons: WeaponSystem = null
var enemy_torpedo_ctx: TorpedoContext = null
var enemy_countermeasures: CountermeasureSystem = null
# 武器侧采样声源 = targets + 活动诱饵（同一 AcousticContact 接口；独立数组，
# 不污染玩家测量循环用的 world["targets"]）。
var _weapon_contacts: Array = []

var _sensor_timers: Dictionary = {}  # sensor_id -> 下次触发时间
var _paused: bool = false
var _time_scale: float = 1.0
# 单在途 PingSession（S1-04B-REQ-16/17）；{} = 无在途（READY）。结构：
# {state, ping_id, emit_t, listen_end_t, cooldown_until, echoes:[
#   {target_id, arrive_t, range_ref_m, range_ref_time_s, settled, detected,
#    se_db, pd, bearing_deg, range_m, range_sigma_m}], returned_count, sensor}
var _ping_session: Dictionary = {}
# 已结算回波摘要缓冲（take_arrived_echoes 排空）。独立于会话存活：远目标回波 τ 可能远超冷却期，会话提前清空也不得丢已结算结果。
var _ping_results: Array = []
var _next_ping_id: int = 1

# ---- S1-07 §9（Commit 9）：敌方出生/感知/Doctrine；同一声学服务+净化证据 ----
# AI 只拿延迟方位证据，绝不拿玩家 TruthEntity；AI 鱼雷独立 WeaponSystem。
# 内核影子：_player/_enemy_torpedo_shadows = 双方在水鱼雷（统一声学接触面）。
var _player_torpedo_shadows: Array = []
var _player_shadow_acs: Dictionary = {}
var _enemy_torpedo_shadows: Array = []
var _enemy_shadow_acs: Dictionary = {}
# 敌方感知/敌方鱼雷 seeker 的采样声源（每 tick 重建内容，数组实例稳定）。
var _enemy_perception_contacts: Array = []
var _enemy_perception_acs: Dictionary = {}

# ---- S1-07 §10（Commit 10）：引信引擎 / 净化战果证据 / Debrief ----
# 普通玩法层只收净化 EvidenceEvent（player_evidence）；Truth 命中对象与
# 最近通过距离只留在 _detonations（Debrief/调试通道），UI 绝不即时显示
# CONFIRMED KILL（§10.4）。
var _detonations: Array = []  # 内核 Debrief 记录（含 internal target 引用）
var _fuze_min_pass: Dictionary = {}  # torpedo_id -> 最近通过距离（内核台账）
var _fuze_alive: Dictionary = {}
## REQ-11：引信调试台账（内核侧，仅 Debrief/调试面板）。
var _fuze_debug: Dictionary = {}  # torpedo_id -> {h_m, v_m, d3_m, t, ...}
# P1-08：上一 tick 位置快照（swept 用）。id → Vector3(e,n,depth)。
var _fuze_prev_tp: Dictionary = {}
var _fuze_prev_contact: Dictionary = {}
# P1-12.4：引信安全保险闩（每雷一次）。
var _fuze_safety_latched: Dictionary = {}  # torpedo_id -> bool（本 tick 曾在水的记号）


## 从场景 JSON 构建并初始化世界。
func load_scenario(scenario: Dictionary) -> void:
	world = ScenarioLoader.build(scenario)
	sim_time = 0.0
	measurements.clear()
	weapons = WeaponSystem.new()
	torpedo_ctx = TorpedoContext.new()
	torpedo_ctx.env = world.get("env", null)
	torpedo_ctx.depth_model = world.get("depth_model", null)
	# S1-07 §9.1（Commit 5）：通用声学事件总线。active_emissions 是该总线事件
	# 数组的兼容视图（同一数组实例），S1-04C 读方（R22 等）无需改动。
	emission_bus = AcousticEmissionBus.new()
	active_emissions = emission_bus.events
	weapons.emission_bus = emission_bus
	torpedo_ctx.emission_bus = emission_bus
	# S1-07 §6.5（Commit 6）：鱼雷传感器采样适配器——仿真内核唯一可触 Truth
	# 的武器侧对象。采样经统一 AcousticService/DepthLayerModel，输出净化
	# SeekerReturn（无 target_id / 被动无 range）；本艇主动 Ping/鱼雷发射声等
	# 事件仍走 emission_bus，两路互不混淆（§15.3）。
	var adapter := TorpedoSensorAdapter.new()
	adapter.env = world.get("env", null)
	adapter.depth_model = world.get("depth_model", null)
	adapter.rng = world.get("rng", null)
	# Commit 8：武器侧采样声源 = 本艇 + targets + 活动诱饵（合成数组，独立
	# 实例）。P0-06/P1-12：本艇是真实声源（seeker 可采样到 OWN return，由
	# torpedo 侧资格过滤拒绝）；contact_tokens 为内核边界安全过滤数据。
	var own_ref: TruthEntity = world["own"]
	_weapon_contacts = [own_ref]
	for t in world.get("targets", []):
		_weapon_contacts.append(t)
	adapter.contacts = _weapon_contacts
	adapter.contact_acs = world.get("target_acs", {})
	adapter.contact_tokens = {str(own_ref.id): "OWN"}
	for t2 in world.get("targets", []):
		adapter.contact_tokens[str(t2.id)] = "HOSTILE"
	torpedo_ctx.sensor_adapter = adapter
	# Commit 8（§8.1）：玩家反制发射器（场景 own_ship.countermeasures 可覆盖）。
	countermeasures = CountermeasureSystem.new()
	var cm_cfg: Dictionary = scenario.get("own_ship", {}).get("countermeasures", {})
	countermeasures.configure(cm_cfg)
	decoys.clear()
	# S1-07 §9（Commit 9）：敌方随机出生 + 感知 + Doctrine（有 enemy_spawn
	# 块才启用；旧场景零行为变化）。
	_setup_enemy_ai(scenario)
	# S1-07 §10（Commit 10）：事件净化器（独立派生 RNG，确定性且不扰动玩家
	# 测量流随机序列）+ 证据/Debrief 台账清空。
	emission_sanitizer = EmissionSanitizer.new()
	emission_sanitizer.bind(
		world.get("env", null),
		world.get("depth_model", null),
		_derived_rng(int(scenario.get("seed", 12345)) + 5000)
	)
	player_evidence.clear()
	threat_tracks.reset()
	_detonations.clear()
	_fuze_min_pass.clear()
	_fuze_alive.clear()
	_fuze_prev_tp.clear()
	_fuze_prev_contact.clear()
	_sensor_timers.clear()
	for s in world["sensors"]:
		_sensor_timers[s.sensor_id] = 0.0
	# 主动声呐配置（S1-04B-REQ-20）：own_ship.active_sonar 块存在 = 平台
	# 装有艇首主动阵硬件（显式声明）；sensors 含 array_type=="active" 也视为
	# 硬件。两者皆无 → ping_hardware=false：Ping 显示 UNAVAILABLE 并禁用，
	# 绝不自动构造缺省主动阵（Truth/硬件隔离）。
	var as_cfg: Dictionary = scenario.get("own_ship", {}).get("active_sonar", {})
	ping_hardware = not as_cfg.is_empty()
	for s in world["sensors"]:
		if str(s.array_type) == "active":
			ping_hardware = true
	ping_sl_db = float(as_cfg.get("ping_sl_db", ping_sl_db))
	ping_cooldown_s = float(as_cfg.get("cooldown_s", ping_cooldown_s))
	ping_freq_min_hz = float(as_cfg.get("freq_min_hz", ping_freq_min_hz))
	ping_freq_max_hz = float(as_cfg.get("freq_max_hz", ping_freq_max_hz))
	ping_array_gain_db = float(as_cfg.get("array_gain_db", ping_array_gain_db))
	ping_sound_speed_m_s = float(as_cfg.get("sound_speed_m_s", ping_sound_speed_m_s))
	ping_listen_window_s = maxf(float(as_cfg.get("listen_window_s", ping_listen_window_s)), 0.5)
	ping_pulse_duration_s = maxf(float(as_cfg.get("pulse_duration_s", ping_pulse_duration_s)), 0.05)
	ping_coverage_sector = Vector2(
		float(as_cfg.get("coverage_start_deg", ping_coverage_sector.x)),
		float(as_cfg.get("coverage_end_deg", ping_coverage_sector.y)),
	)
	ping_baffle_sector = Vector2(
		float(as_cfg.get("baffle_start_deg", ping_baffle_sector.x)),
		float(as_cfg.get("baffle_end_deg", ping_baffle_sector.y)),
	)
	_ping_session = {}
	_ping_results.clear()
	_next_ping_id = 1
	if emission_bus != null:
		emission_bus.clear()


## 推进内部仿真时间 dt（秒）。dt 已由上层按 time_scale 折算。
## 固定步长：world.dt 是每 tick 的物理步长。
func tick() -> void:
	if _paused:
		return
	if not auto_measurements:
		_advance_only()
		return
	var dt: float = world["dt"]
	sim_time += dt

	# 1) 推进所有 Truth 实体
	world["own"].advance(dt)
	for t in world["targets"]:
		t.advance(dt)
	_sync_interferers()  # REQ-AC-03：激活 JAMMER → 环境干扰源（每 tick 同步）

	# 2) 按传感器更新间隔触发测量
	for sensor in world["sensors"]:
		var next_t: float = _sensor_timers.get(sensor.sensor_id, 0.0)
		if sim_time >= next_t:
			_emit_for_sensor(sensor)
			_sensor_timers[sensor.sensor_id] = sim_time + sensor.update_interval_s

	# 3) 推进在水鱼雷（S1-07：ctx 只含服务接口；自导由 Commit 6+ Seeker 链驱动）
	if weapons != null and not weapons.torpedoes.is_empty():
		weapons.step(dt, sim_time, torpedo_ctx)
	# 3b) 推进活动诱饵（Commit 8 §8：激活/寿命/JAMMER 抖动；到期移出采样集）
	_advance_decoys(dt)
	# 4) 推进 PingSession（结算到点回波 + 状态转移，与自动测量无关）
	_advance_ping_session()
	# 5) 敌方感知/Doctrine（Commit 9）：证据 → 航迹 → 状态机 → 动作。
	_advance_enemy_ai(dt)
	# 5b) REQ-09：统一声场无条件同步——无敌方 AI 场景中玩家鱼雷也必须进入
	# 声场（旧实现 _sync_torpedo_shadows 藏在 _advance_enemy_ai 末尾，
	# enemy_ai == null 提前返回导致玩家鱼雷声学影子永不产生）。
	_sync_torpedo_shadows()
	# 6) 引信引擎（Commit 10）：几何触发 → 起爆 → Truth 伤害 → 净化证据。
	_advance_fuze_engine(dt)
	_advance_player_evidence()


func _advance_only() -> void:
	var dt: float = world["dt"]
	sim_time += dt
	world["own"].advance(dt)
	for t in world["targets"]:
		t.advance(dt)
	_sync_interferers()
	if weapons != null and not weapons.torpedoes.is_empty():
		weapons.step(dt, sim_time, torpedo_ctx)
	_advance_decoys(dt)
	_advance_ping_session()
	_advance_enemy_ai(dt)
	_sync_torpedo_shadows()  # REQ-09：同 tick()——无条件同步统一声场
	_advance_fuze_engine(dt)
	_advance_player_evidence()


## 推进活动诱饵：激活记 DECOY_ACTIVATION 并进入武器采样集（激活前静默），
## 到期移除（§8.6）。REQ-CM-01/03：同步注册/注销 seeker contact_acs 画像；
## token 按接收方：己方诱饵=FRIENDLY，敌方诱饵=""（须声学竞争，无豁免）。
func _advance_decoys(dt: float) -> void:
	var rng: RandomNumberGenerator = world.get("rng", null)
	var expired: Array = []
	var p_adapter: TorpedoSensorAdapter = (
		torpedo_ctx.sensor_adapter if torpedo_ctx != null else null
	)
	for d in decoys:
		var just_activated: bool = d.step(dt)
		if just_activated:
			_weapon_contacts.append(d)
			if p_adapter != null:
				# REQ-CM-01：player seeker 此前未注册诱饵画像 → 采样直接跳过。
				p_adapter.contact_acs[str(d.id)] = d.signature_ac
				p_adapter.contact_tokens[str(d.id)] = "FRIENDLY" if str(d.side) == "blue" else ""
			if emission_bus != null:
				var ac: RefCounted = d.signature_ac
				var sl: float = 160.0
				if ac != null and ac.has_method("broadband_sl_db"):
					sl = float(ac.call("broadband_sl_db", d.speed_kn, d.depth_m))
				(
					emission_bus
					. record(
						AcousticEmissionEvent.DECOY_ACTIVATION,
						d.id,
						sim_time,
						Vector3(d.position_east_m, d.position_north_m, d.depth_m),
						1000.0,
						3000.0,
						sl,
						1.0,
					)
				)
		if d.expired:
			expired.append(d)
	for d in expired:
		decoys.erase(d)
		_weapon_contacts.erase(d)
		if torpedo_ctx != null and torpedo_ctx.sensor_adapter != null:
			torpedo_ctx.sensor_adapter.contact_tokens.erase(str(d.id))
			# REQ-CM-02：注销画像注册（历史瀑布/Track 自然计龄，不删玩家接触）。
			torpedo_ctx.sensor_adapter.contact_acs.erase(str(d.id))


## 玩家发射诱饵（§8.5）：发射器库存/冷却/程序合法性校验；诱饵先进入活动
## 列表随 tick 推进，激活瞬间才进入武器采样集（激活前静默）。
## enemy 侧（Commit 9）用同一 CountermeasureSystem 流程。
func _launch_decoy(prog: DecoyProgram) -> bool:
	if countermeasures == null or prog == null or world.get("own") == null:
		last_decoy_reject_reason = "no_launcher"
		return false
	# REQ-CM-02：从发射平台当前实际深度出发（不再瞬移到层带 hold）；
	# 命令深度按程序层带 hold 解析，限垂速爬降由 TruthEntity.advance 执行。
	var own: TruthEntity = world["own"]
	var initial_depth: float = float(own.depth_m)
	var commanded_depth: float = _hold_depth_for(prog.commanded_depth_band)
	var d: Decoy = countermeasures.launch(
		prog, own, sim_time, world.get("rng", null), initial_depth, commanded_depth
	)
	last_decoy_reject_reason = countermeasures.last_reject_reason
	if d == null:
		return false
	decoys.append(d)
	return true


## REQ-AC-03：把激活且未过期的 JAMMER 诱饵同步为环境宽带干扰源。
## 频带/总功率来自其画像（band_min_hz/band_max_hz/sl_band_db）；玩家声呐、
## 敌方感知、双方鱼雷自导共用同一 env 干扰表（统一声场，各接收器再按
## 位置/波束响应独立计算贡献）。
func _sync_interferers() -> void:
	var env: RefCounted = world.get("env", null)
	if env == null:
		return
	var ints: Array = []
	for d in decoys:
		if not (d.activated and not d.expired):
			continue
		if d.decoy_type != DecoyProgram.TYPE_JAMMER or d.signature_ac == null:
			continue
		var ac: RefCounted = d.signature_ac
		(
			ints
			. append(
				{
					"e": float(d.position_east_m),
					"n": float(d.position_north_m),
					"z": float(d.depth_m),
					"sl_band_db": float(ac.get("broadband_base_level_db")),
					"band_min_hz": float(ac.get("band_min_hz")),
					"band_max_hz": float(ac.get("band_max_hz")),
				}
			)
		)
	env.interferers = ints


## 深度带 → hold 深度（DepthLayerModel 注入时用模型；否则默认 70/180）。
func _hold_depth_for(band: String) -> float:
	var dm: RefCounted = world.get("depth_model", null)
	if dm != null and dm.has_method("hold_depth_for_band"):
		return float(dm.call("hold_depth_for_band", band))
	if band == WeaponProgram.DEPTH_BAND_LOWER:
		return 180.0
	return 70.0


# S1-07 §9（Commit 9）：出生=EnemySpawnGenerator（独立 RNG+校验）；感知=
# EnemySensorAdapter；航迹=EnemyTrackManager；Doctrine=延迟+概率状态机。
# AI 鱼雷独立 WeaponSystem（BEARING_ONLY 宽扇区）；绝不读 Truth（§9.8）。


## 场景含 enemy_spawn 块时启用敌方 AI（旧场景零行为变化）。
func _setup_enemy_ai(scenario: Dictionary) -> void:
	enemy_ai = null
	enemy_weapons = null
	enemy_torpedo_ctx = null
	enemy_countermeasures = null
	_enemy_torpedo_shadows = []
	_enemy_shadow_acs = {}
	_enemy_perception_contacts = []
	_enemy_perception_acs = {}
	var cfg: Dictionary = scenario.get("enemy_spawn", {})
	if cfg.is_empty() or world.get("own") == null:
		return
	var base_seed: int = int(scenario.get("seed", 12345))
	var gen := EnemySpawnGenerator.new()
	gen.configure(cfg, base_seed + 1000)
	var spawned: TruthEntity = gen.spawn(
		world["own"], world["targets"], Callable(self, "_hold_depth_for")
	)
	if spawned == null:
		return
	world["targets"].append(spawned)
	_weapon_contacts.append(spawned)
	var ac := AcousticProfile.new()
	ac.from_dict(cfg.get("acoustic", {}))
	world["target_acs"][spawned.id] = ac
	# 敌方鱼雷武器链（独立 ctx；seeker 声源 = 本艇 + 蓝方诱饵，_rebuild 时刷新）。
	enemy_weapons = WeaponSystem.new()
	enemy_weapons.emission_bus = emission_bus
	enemy_weapons.id_prefix = "ET"  # 敌方鱼雷 id 前缀（净化器判别本艇事实）
	enemy_torpedo_ctx = TorpedoContext.new()
	enemy_torpedo_ctx.env = world.get("env", null)
	enemy_torpedo_ctx.depth_model = world.get("depth_model", null)
	enemy_torpedo_ctx.emission_bus = emission_bus
	var e_adapter := TorpedoSensorAdapter.new()
	e_adapter.env = world.get("env", null)
	e_adapter.depth_model = world.get("depth_model", null)
	e_adapter.rng = _derived_rng(base_seed + 2000)
	e_adapter.contacts = _enemy_perception_contacts
	e_adapter.contact_acs = _enemy_perception_acs
	enemy_torpedo_ctx.sensor_adapter = e_adapter
	# 敌方诱饵发射器（同一 CountermeasureSystem 类）。
	enemy_countermeasures = CountermeasureSystem.new()
	enemy_countermeasures.configure(cfg.get("countermeasures", {}))
	# 感知 + 航迹 + Doctrine（各自独立派生 RNG，确定性）。
	var s_adapter := EnemySensorAdapter.new()
	s_adapter.bind(
		world.get("env", null),
		world.get("depth_model", null),
		_enemy_perception_contacts,
		_enemy_perception_acs
	)
	s_adapter.set_rng(_derived_rng(base_seed + 3000))
	s_adapter.false_alarm_rate = float(
		cfg.get("doctrine", {}).get("sensor_false_alarm_rate", 0.005)
	)
	var mgr := EnemyTrackManager.new()
	var ai := EnemyDoctrineController.new()
	ai.configure(spawned, s_adapter, mgr, cfg.get("doctrine", {}), _derived_rng(base_seed + 4000))
	enemy_ai = ai


func _derived_rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


## 每步推进敌方 AI：重建采样声源 → Doctrine update → 执行动作（发射鱼雷 /
## 放诱饵）；敌方鱼雷经独立 ctx 推进；死亡后归还并发余量。
func _advance_enemy_ai(dt: float) -> void:
	if enemy_ai == null:
		return
	_rebuild_enemy_contacts()
	var events: Array = emission_bus.events if emission_bus != null else []
	var actions: Array = enemy_ai.update(sim_time, dt, events)
	_apply_enemy_actions(actions)
	if enemy_weapons != null and not enemy_weapons.torpedoes.is_empty():
		# P1-09：step 前后按稳定 ID 求差——本步内消失（DEAD/DETONATED/EXPIRED）
		# 的鱼雷恰好一次 notify_torpedo_resolved，doctrine 在水计数正确释放
		# （旧实现在 step 已过滤后的数组里找 dead，永远找不到 → 计数不释放）。
		var before_ids: Dictionary = {}
		for t in enemy_weapons.torpedoes:
			before_ids[str(t.torpedo_id)] = true
		enemy_weapons.step(dt, sim_time, enemy_torpedo_ctx)
		for t in enemy_weapons.torpedoes:
			before_ids.erase(str(t.torpedo_id))
		if enemy_ai != null:
			for _id in before_ids:
				enemy_ai.notify_torpedo_resolved()


## 同步双方在水鱼雷的内核影子：
##   - 玩家鱼雷影子 → 敌方感知（§9.6 来袭鱼雷运行噪声证据源）；
##   - 敌方鱼雷影子 → 玩家声呐被动链（听到来袭鱼雷；告警 UI 属 Commit 11）。
## 影子只在对应鱼雷存在时产生采样，旧场景零行为变化。
func _sync_torpedo_shadows() -> void:
	_player_torpedo_shadows.clear()
	_player_shadow_acs.clear()
	if weapons != null:
		for tp in weapons.torpedoes:
			if tp.is_dead():
				continue
			var sh := _make_torpedo_shadow(tp, "blue")
			_player_torpedo_shadows.append(sh)
			_player_shadow_acs[str(tp.torpedo_id)] = _torpedo_shadow_ac(tp)
	_enemy_torpedo_shadows.clear()
	_enemy_shadow_acs.clear()
	if enemy_weapons != null:
		for tp in enemy_weapons.torpedoes:
			if tp.is_dead():
				continue
			var sh := _make_torpedo_shadow(tp, "red")
			_enemy_torpedo_shadows.append(sh)
			_enemy_shadow_acs[str(tp.torpedo_id)] = _torpedo_shadow_ac(tp)


func _make_torpedo_shadow(tp: RefCounted, side: String) -> TruthEntity:
	var sh := TruthEntity.new()
	sh.id = str(tp.torpedo_id)
	sh.side = side
	sh.platform_type = "torpedo"
	sh.position_east_m = tp.pos_east_m
	sh.position_north_m = tp.pos_north_m
	sh.depth_m = tp.actual_depth_m
	sh.speed_kn = tp.speed_kn
	sh.course_deg = tp.course_deg
	return sh


## 鱼雷影子声学画像：运行噪声源级按速度模式直接刻画（不再叠速度斜率），
## 窄带谱线随模式（Commit 8 谱线细节同源）。
func _torpedo_shadow_ac(tp: RefCounted) -> AcousticProfile:
	var ac := AcousticProfile.new()
	var sm: String = WeaponProgram.speed_mode_name(tp.speed_mode)
	ac.broadband_base_level_db = tp.acoustic_profile.own_noise_sl_db(sm)
	ac.speed_noise_a = 0.0
	ac.tonal_lines = tp.acoustic_profile.tonal_lines(sm)
	return ac


## 重建敌方感知/敌方鱼雷 seeker 的采样声源（内核边界内；数组实例稳定）：
## 本艇 + 玩家在水鱼雷影子 + 蓝方活动诱饵。绝不把玩家 TruthEntity 交给
## Doctrine 层（适配器是唯一边界）。
func _rebuild_enemy_contacts() -> void:
	_enemy_perception_contacts.clear()
	_enemy_perception_acs.clear()
	var enemy_side: String = (
		str(enemy_ai.entity.side) if enemy_ai != null and enemy_ai.entity != null else "red"
	)
	var own: TruthEntity = world["own"]
	_enemy_perception_contacts.append(own)
	_enemy_perception_acs[str(own.id)] = world.get("own_ac", null)
	var e_tokens: Dictionary = {str(own.id): "HOSTILE"}
	for s in _player_torpedo_shadows:
		_enemy_perception_contacts.append(s)
		e_tokens[str(s.id)] = "HOSTILE"
		if _player_shadow_acs.has(str(s.id)):
			_enemy_perception_acs[str(s.id)] = _player_shadow_acs[str(s.id)]
	for d in decoys:
		if str(d.side) == enemy_side:
			continue  # 己方诱饵：确知己方来源，不入敌方感知竞争集
		# REQ-CM-02：激活前静默；REQ-CM-03：玩家诱饵对敌方 = 未知声源，
		# token="" 绝不标 FRIENDLY（否则敌雷自动识破反制）。
		if d.activated and not d.expired:
			_enemy_perception_contacts.append(d)
			e_tokens[str(d.id)] = ""
			if d.signature_ac != null:
				_enemy_perception_acs[str(d.id)] = d.signature_ac
	if enemy_torpedo_ctx != null and enemy_torpedo_ctx.sensor_adapter != null:
		enemy_torpedo_ctx.sensor_adapter.contact_tokens = e_tokens


## P0-06 统一声场（内核侧注册表快照）：双方在水鱼雷影子 + 活动诱饵。
## Truth 几何只在本边界内；OperatorSonar/UI 仅消费净化派生（峰/证据）。
func _acoustic_scene_emitters() -> Array:
	var out: Array = []
	for sh in _enemy_torpedo_shadows:
		out.append(sh)
	for sh in _player_torpedo_shadows:
		out.append(sh)
	for d in decoys:
		# REQ-CM-02：统一发声条件 activated && !expired（激活前静默）。
		if d.activated and not d.expired:
			out.append(d)
	return out


func _acoustic_scene_acs() -> Dictionary:
	var out: Dictionary = {}
	for k in _enemy_shadow_acs:
		out[k] = _enemy_shadow_acs[k]
	for k in _player_shadow_acs:
		out[k] = _player_shadow_acs[k]
	for d in decoys:
		if d.signature_ac != null and d.activated and not d.expired:
			out[str(d.id)] = d.signature_ac
	return out


## 执行 Doctrine 动作（World 是执行者；AI 本体只写命令值与返回动作）。
func _apply_enemy_actions(actions: Array) -> void:
	for a in actions:
		match str(a.get("action", "")):
			"FIRE_TORPEDO":
				_enemy_fire(a)
			"LAUNCH_DECOY":
				_enemy_launch_decoy(float(a.get("bearing_deg", 0.0)))
			_:
				pass


## 敌方反击（§9.7 ATTACKING）：BEARING_ONLY 宽扇区（无隐藏距离）；程序预设
## 距离授权自主 + 时间开主动（fallback 同源），绝不指向玩家真实位置。
func _enemy_fire(a: Dictionary) -> void:
	if enemy_weapons == null or enemy_ai == null or enemy_ai.entity == null:
		return
	var e: TruthEntity = enemy_ai.entity
	var prog := WeaponProgram.make_bearing_only(float(a.get("bearing_deg", 0.0)))
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	prog.active_enable_mode = WeaponProgram.ActiveEnableMode.TIME
	prog.active_enable_time_s = float(enemy_ai.doctrine.get("torpedo_active_enable_time_s", 60.0))
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = float(
		enemy_ai.doctrine.get("torpedo_autonomy_distance_m", 800.0)
	)
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	enemy_weapons.fire_program(prog, e.position_east_m, e.position_north_m, sim_time, e.depth_m)


## 敌方诱饵（§8.5/§9.7 EVADING）：同一 CountermeasureSystem 流程；MOBILE
## 假目标谱（模拟潜艇），背离告警方位出舱。
func _enemy_launch_decoy(launch_bearing_deg: float) -> void:
	if enemy_countermeasures == null or enemy_ai == null or enemy_ai.entity == null:
		return
	var e: TruthEntity = enemy_ai.entity
	var prog := DecoyProgram.new()
	prog.decoy_type = DecoyProgram.TYPE_MOBILE
	prog.launch_bearing_deg = clampf(launch_bearing_deg, 0.0, 359.9)
	prog.initial_depth_band = "UPPER" if e.depth_m < 120.0 else "LOWER"
	prog.commanded_depth_band = prog.initial_depth_band
	prog.course_deg = NavUtils.wrap360(launch_bearing_deg + 180.0)
	prog.speed_kn = 8.0
	prog.activation_delay_s = 2.0
	prog.lifetime_s = 120.0
	var sig := AcousticProfile.new()
	sig.broadband_base_level_db = float(enemy_ai.doctrine.get("decoy_sl_db", 168.0))
	sig.tonal_lines = [
		{"freq_hz": 240.0, "level_db": 128.0},
		{"freq_hz": 480.0, "level_db": 122.0},
	]
	prog.signature = sig
	var initial_depth: float = float(e.depth_m)  # REQ-CM-02：从实际深度出舱
	var d: Decoy = enemy_countermeasures.launch(
		prog, e, sim_time, enemy_ai._rng, initial_depth, _hold_depth_for(prog.commanded_depth_band)
	)
	if d != null:
		decoys.append(d)


## 为某个传感器生成一次测量（针对所有目标）。S1-00（GAP-DATA-01/02）：
## 主动阵绝不在本函数自动产测量（唯一路径 issue_ping → PingSession → 回波
## → generate_active，REQ-03）；未探测样本绝不进 measurements（miss 不携带
## 未加噪真方位进玩家链）。
func _emit_for_sensor(sensor: RefCounted) -> void:
	if str(sensor.array_type) == "active":
		return  # 主动阵只由 PingSession 驱动（REQ-03），跳过自动旁路
	var gen: RefCounted = world["generator"]
	for t in world["targets"]:
		var ac: RefCounted = world["target_acs"][t.id]
		var m: Measurement = gen.generate_passive(world["own"], t, ac, sensor, sim_time)
		if m.detected:
			measurements.append(m)
	# 来袭鱼雷（Commit 9）：存在敌方在水鱼雷影子时才额外采样（玩家声呐
	# 听到敌方鱼雷 → 告警，Commit 11 消费）；旧场景影子恒空，零行为变化。
	for t in _enemy_torpedo_shadows:
		var tac: RefCounted = _enemy_shadow_acs.get(str(t.id), null)
		if tac == null:
			continue
		var tm: Measurement = gen.generate_passive(world["own"], t, tac, sensor, sim_time)
		if tm.detected:
			measurements.append(tm)


## 推进 n 个固定步长。
func run_steps(n: int) -> void:
	for i in range(n):
		tick()


func set_paused(p: bool) -> void:
	_paused = p


func is_paused() -> bool:
	return _paused


func set_time_scale(scale: float) -> void:
	_time_scale = maxf(scale, 1.0)


func time_scale() -> float:
	return _time_scale


## 当前所有测量（只读）。调试时可按需过滤。
func measurement_count() -> int:
	return measurements.size()


# 主动声呐 Ping（S1-04B）单在途：READY→(issue_ping) LISTENING→(回波全结
# 算/监听窗结束)→(冷却到) READY；铁律 REQ-16/17/19/20，无显式硬件不自动
# 构造缺省主动阵。


## 是否有主动阵硬件（REQ-20）。无硬件 → UNAVAILABLE 并禁用 Ping。
func ping_available() -> bool:
	return ping_hardware


## 当前 PingSession 状态：UNAVAILABLE / READY / LISTENING / RETURN / NO_RETURN。
func ping_state_name() -> String:
	if not ping_hardware:
		return "UNAVAILABLE"
	if _ping_session.is_empty():
		return "READY"
	return str(_ping_session.get("state", "READY"))


## 当前在途 PingSession id（无在途返回 -1）。主动测量用 ping_id 溯源。
func ping_session_id() -> int:
	if _ping_session.is_empty():
		return -1
	return int(_ping_session.get("ping_id", -1))


## 本艇最近一次发射时刻（无在途返回 -1）。本艇事实，供 UI 显示
## TRANSMITTING→LISTENING 相位（S1-04C-REQ-01 徽标，非目标 Truth）。
func ping_emit_time() -> float:
	if _ping_session.is_empty():
		return -1.0
	return float(_ping_session.get("emit_t", -1.0))


## 当前是否可发起 Ping：有硬件 + 无在途 PingSession（单在途，REQ-16/17）。
func can_ping() -> bool:
	return ping_hardware and _ping_session.is_empty()


## 距下一次可 Ping 的剩余冷却秒数（READY/UNAVAILABLE 返回 0）。
func ping_cooldown_remaining() -> float:
	if _ping_session.is_empty():
		return 0.0
	return maxf(float(_ping_session.get("cooldown_until", sim_time)) - sim_time, 0.0)


## 主动脉冲中心频率（Hz，参数展示用，S1-04C-REQ-01 卡片）。
func ping_center_freq_hz() -> float:
	return 0.5 * (ping_freq_min_hz + ping_freq_max_hz)


## 主动脉冲带宽（Hz）。
func _ping_bandwidth_hz() -> float:
	return maxf(ping_freq_max_hz - ping_freq_min_hz, 1.0)


## 配置监听窗对应的最大可测距（m）：R_max = c·T_listen/2（REQ-04）。
## 监听窗固定来自本艇配置，绝不随场景目标/Truth 距离变化。
func ping_max_range_m() -> float:
	return 0.5 * ping_sound_speed_m_s * ping_listen_window_s


## 玩家发起主动脉冲（S1-04B/C）：发射瞬间按当前几何距离登记在途回波
## （arrive_t=emit+2R/c）。REQ-04 固定监听窗（不用最远 Truth τ 延长，超窗
## 丢弃）；REQ-05 发射成功记一条事件；无硬件/在途未清/冷却中返回 false。
func issue_ping() -> bool:
	if not can_ping():
		return false
	var own: TruthEntity = world["own"]
	var sensor: SensorArray = _ping_sensor()
	var echoes: Array = []
	for t in world["targets"]:
		# S1-03C-P1-03/REQ-08：发射扇区——发射时刻固化方位，仅登记扇区内目标回波。
		# 与被动链同源（SensorArray.in_coverage，覆盖/挡板盲区相对本艇艏向）；
		# 扇区外目标不登记回波（窗口到期 NO_RETURN，绝不在到达时刻补判）。
		# 未声明覆盖 = 全向 (0..360)，行为与旧实现一致。
		var tgt_b: float = (
			NavUtils
			. bearing_to_true(
				own.position_east_m,
				own.position_north_m,
				t.position_east_m,
				t.position_north_m,
			)
		)
		var rel_b: float = NavUtils.wrap360(tgt_b - own.course_deg)
		if not sensor.in_coverage(rel_b):
			continue
		var rng_m: float = NavUtils.distance(
			own.position_east_m, own.position_north_m, t.position_east_m, t.position_north_m
		)
		var tau_s: float = AcousticService.echo_travel_time_s(rng_m, ping_sound_speed_m_s)
		(
			echoes
			. append(
				{
					"target_id": str(t.id),
					"arrive_t": sim_time + tau_s,
					"range_ref_m": rng_m,  # 发射时刻登记距离（测距同源基准）
					"range_ref_time_s": sim_time,
					"settled": false,
					"dropped": false,  # 超出监听窗被丢弃（REQ-04，不可接收）
					"detected": false,
					"se_db": 0.0,
					"pd": 0.0,
					"bearing_deg": 0.0,
					"range_m": -1.0,
					"range_sigma_m": -1.0,
				}
			)
		)
	var listen_end: float = sim_time + ping_listen_window_s
	_ping_session = {
		"state": "LISTENING",
		"ping_id": _next_ping_id,
		"emit_t": sim_time,
		# REQ-04 固定监听窗：只由本艇配置决定，不读任何目标 Truth。
		"listen_end_t": listen_end,
		"cooldown_until": sim_time + ping_cooldown_s,
		"echoes": echoes,
		"returned_count": 0,
		"sensor": sensor,
	}
	_next_ping_id += 1
	# REQ-05 / §9.1：发射成功记录声学事件（PLATFORM_ACTIVE_PING，含深度）。
	(
		emission_bus
		. record_platform_active_ping(
			sim_time,
			Vector3(own.position_east_m, own.position_north_m, own.depth_m),
			ping_center_freq_hz(),
			_ping_bandwidth_hz(),
			ping_sl_db,
			ping_pulse_duration_s,
		)
	)
	return true


## 未返回（未结算）回波数。Truth 钩子：仅供无头测试/统计，
## 禁止 UI 据此显示目标存在或回波倒计时（Truth 隔离，ISSUE-06）。
func pending_echo_count() -> int:
	if _ping_session.is_empty():
		return 0
	var n: int = 0
	for e in _ping_session["echoes"]:
		if not bool(e["settled"]):
			n += 1
	return n


## 距最早未返回回波到达的剩余秒数；无在途返回 INF。
## Truth 钩子：仅供无头测试/统计，禁止 UI 使用（ISSUE-06）。
func next_echo_in() -> float:
	if _ping_session.is_empty():
		return INF
	var earliest: float = INF
	for e in _ping_session["echoes"]:
		if not bool(e["settled"]):
			earliest = minf(earliest, float(e["arrive_t"]))
	if earliest == INF:
		return INF
	return maxf(earliest - sim_time, 0.0)


## 结算所有已到达回波并取走新结果摘要（UI 每帧轮询即可，无需信号）。
## 返回 [{target_id, ping_id, detected, se_db, pd, bearing_deg, range_m,
##        range_sigma_m, measurement}]；测量时刻=回波到达时刻；结算在
## tick()/本函数幂等触发（settled 去重）；结果缓冲独立于会话存活。
func take_arrived_echoes() -> Array:
	if not _ping_session.is_empty():
		_settle_due_echoes()
	var out: Array = _ping_results
	_ping_results = []
	return out


## 推进 PingSession（tick 每步调用）：结算到点回波 + 状态转移。
func _advance_ping_session() -> void:
	if _ping_session.is_empty():
		return
	_settle_due_echoes()
	var st: String = str(_ping_session["state"])
	if st == "LISTENING":
		if _ping_listen_done():
			# 监听窗结束：丢弃仍未到达/超出窗口的回波（REQ-04，不可接收），
			# 再按已返回 detected 数判 RETURN/NO_RETURN。窗口不因远目标延长。
			_drop_unsettled_echoes()
			_ping_session["state"] = (
				"RETURN" if int(_ping_session["returned_count"]) > 0 else "NO_RETURN"
			)
	elif st == "RETURN" or st == "NO_RETURN":
		# 冷却结束 → 回到 READY（会话清空，单在途释放）
		if sim_time >= float(_ping_session["cooldown_until"]) - 1e-9:
			_ping_session = {}


## 监听是否结束（REQ-04 固定监听窗）：
##   - 窗口（configured_listen_window_s）到期即结束——与登记了多少/多远回波
##     无关，绝不因最远 Truth 目标 τ 拉长 LISTENING；
##   - 窗口内若全部登记回波已提前结算（无超窗残留）也可提前结束。
func _ping_listen_done() -> bool:
	var echoes: Array = _ping_session["echoes"]
	if sim_time >= float(_ping_session["listen_end_t"]) - 1e-9:
		return true
	if echoes.is_empty():
		return false
	for e in echoes:
		if not bool(e["settled"]):
			return false
	return true


## 监听窗到期：把仍未结算（未到达/超窗）的回波标记为 dropped（不可接收）。
## 它们不得再被结算（settled=true 拦截），也不进入 returned_count/测量流。
func _drop_unsettled_echoes() -> void:
	var echoes: Array = _ping_session["echoes"]
	for e in echoes:
		if bool(e["settled"]):
			continue
		e["settled"] = true
		e["dropped"] = true
		e["detected"] = false


## 结算已到点（sim_time >= arrive_t）的登记回波。测距以发射时刻登记的
## range_ref_m 为基准（REQ-19 往返测距同源），到达时刻只做检测/测距噪声
## 注入，绝不读当前 Truth 距离回填。未探测到也产出 summary（detected=false）。
func _settle_due_echoes() -> void:
	if _ping_session.is_empty():
		return
	if str(_ping_session["state"]) != "LISTENING":
		return
	var echoes: Array = _ping_session["echoes"]
	var sensor: SensorArray = _ping_session.get("sensor", null)
	var gen: MeasurementGenerator = world["generator"]
	var own: TruthEntity = world["own"]
	var ping_id: int = int(_ping_session["ping_id"])
	for e in echoes:
		if bool(e["settled"]):
			continue
		# REQ-04：超出固定监听窗的回波不可接收——即使 tick 恰好越过窗口也不结算。
		if float(e["arrive_t"]) > float(_ping_session["listen_end_t"]) + 1e-9:
			continue
		if sim_time < float(e["arrive_t"]) - 1e-9:
			continue
		e["settled"] = true
		var target: TruthEntity = null
		for t in world["targets"]:
			if str(t.id) == str(e["target_id"]):
				target = t
				break
		if target == null:
			continue
		var ac: AcousticProfile = world["target_acs"][target.id]
		var m: Measurement = (
			gen
			. generate_active(
				own,
				target,
				ac,
				sensor,
				ping_sl_db,
				sim_time,
				ping_id,
				float(e["range_ref_m"]),
				float(e["range_ref_time_s"]),
			)
		)
		var detected: bool = m.detected
		e["detected"] = detected
		e["se_db"] = m.signal_excess_db
		e["pd"] = m.detection_probability
		e["bearing_deg"] = m.measured_bearing_deg
		e["range_m"] = m.measured_range_m
		e["range_sigma_m"] = m.range_sigma_m
		var summary := {
			"target_id": str(target.id),
			"ping_id": ping_id,
			"detected": detected,
			"se_db": m.signal_excess_db,
			"pd": m.detection_probability,
			"bearing_deg": m.measured_bearing_deg,
			"range_m": m.measured_range_m,
			"range_sigma_m": m.range_sigma_m,
			"measurement": m,
		}
		_ping_results.append(summary)
		if detected:
			_ping_session["returned_count"] = int(_ping_session["returned_count"]) + 1
			measurements.append(m)


## 本次 ping 使用的主动阵：场景 sensors 含 array_type=="active" 则复用它；
## 否则按 own_ship.active_sonar 显式配置物化艇首主动阵。仅在 ping_hardware
## 为真时可到达——无硬件绝不自动构造（REQ-20）。
func _ping_sensor() -> SensorArray:
	for s in world["sensors"]:
		if str(s.array_type) == "active":
			return s
	var s := SensorArray.new()
	(
		s
		. from_dict(
			{
				"sensor_id": ACTIVE_SENSOR_ID,
				"array_type": "active",
				"owner_id": str(world["own"].id),
				"freq_min_hz": ping_freq_min_hz,
				"freq_max_hz": ping_freq_max_hz,
				"array_gain_db": ping_array_gain_db,
				"coverage_start_deg": ping_coverage_sector.x,
				"coverage_end_deg": ping_coverage_sector.y,
				"baffle_start_deg": ping_baffle_sector.x,
				"baffle_end_deg": ping_baffle_sector.y,
				"detection_threshold_db": 0.0,
			}
		)
	)
	s.set_rng(world["rng"])
	return s


# S1-07 §10（Commit 10）：FuzeController 纯几何触发；爆炸结算在本引擎
# （敌=sunk/本艇=damaged）；玩法层只收净化 EvidenceEvent；CONFIRMED_KILL
# 只经 debrief_summary()（调试通道）。


## 引信引擎（每 tick）。REQ-08：tick 起始对 prev 位置做不可变快照，全部雷
## 检查完后统一提交缓存（不受遍历顺序影响）。
func _advance_fuze_engine(dt: float = 0.0) -> void:
	var prev_contact: Dictionary = _fuze_prev_contact.duplicate()
	var prev_tp: Dictionary = _fuze_prev_tp.duplicate()
	var new_prev_tp: Dictionary = {}
	var touched_contact: Dictionary = {}
	if weapons != null:
		for tp in weapons.torpedoes:
			_fuze_step_torpedo(
				tp, world["targets"], true, prev_contact, prev_tp, new_prev_tp, touched_contact, dt
			)
	if enemy_weapons != null:
		for tp in enemy_weapons.torpedoes:
			_fuze_step_torpedo(
				tp, [world["own"]], false, prev_contact, prev_tp, new_prev_tp, touched_contact, dt
			)
	# 全部检查完成后统一更新缓存（REQ-08：不在检查中途覆写 prev）。
	for cid in touched_contact:
		_fuze_prev_contact[cid] = touched_contact[cid]
	for tid in new_prev_tp:
		_fuze_prev_tp[tid] = new_prev_tp[tid]


func _fuze_step_torpedo(
	tp: RefCounted,
	contacts: Array,
	from_player: bool,
	prev_contact: Dictionary,
	prev_tp: Dictionary,
	new_prev_tp: Dictionary,
	touched_contact: Dictionary,
	dt: float,
) -> void:
	if tp.is_dead() or not tp._in_water():
		_fuze_alive.erase(str(tp.torpedo_id))
		_fuze_prev_tp.erase(str(tp.torpedo_id))
		return
	# P1-08/REQ-08：prev 从 tick 起始不可变快照读，末态写暂存，检查完统一提交。
	var tid: String = str(tp.torpedo_id)
	var tp_now := Vector3(float(tp.pos_east_m), float(tp.pos_north_m), float(tp.actual_depth_m))
	var tp_prev: Vector3 = tp_now
	if prev_tp.has(tid):
		tp_prev = prev_tp[tid]
	new_prev_tp[tid] = tp_now
	_fuze_alive[tid] = true
	# 引信解保（§10.2 双保险；REQ-08 与 Torpedo 侧统一）。
	var since_launch: float = sim_time - float(tp._launch_t)
	var fc := FuzeController.new()
	var prog: WeaponProgram = tp.program
	fc.configure(prog.fuze_mode, prog.warhead_arm_distance_m)
	if not fc.is_armed(tp.traveled_m, since_launch):
		if (
			tp.fuze_state == tp.FuzeState.SAFE
			and tp.traveled_m >= prog.warhead_arm_distance_m
			and since_launch >= FuzeController.FUZE_MIN_ARM_TIME_S
		):
			tp.fuze_state = tp.FuzeState.ARMED
			tp.event_occurred.emit(tp.torpedo_id, "FUZE_ARMED", {"traveled_m": tp.traveled_m})
		return
	var dbg: Dictionary = _fuze_debug.get(tid, {})  # REQ-11 调试台账
	dbg["fuze_mode"] = fc.fuze_mode
	dbg["armed"] = true
	dbg["sat_time_s"] = float(dbg.get("sat_time_s", 0.0)) + (dt if bool(tp.turn_saturated) else 0.0)
	# 最近通过距离台账（Debrief 用）——swept 连续最近通过。
	var min_d: float = INF
	var min_v: float = INF
	var min_d3: float = INF
	for c in contacts:
		if str(c.damage_state) == "sunk":
			continue
		var c_now := Vector3(float(c.position_east_m), float(c.position_north_m), float(c.depth_m))
		var c_prev: Vector3 = c_now
		if prev_contact.has(str(c.id)):
			c_prev = prev_contact[str(c.id)]
		touched_contact[str(c.id)] = c_now
		var rel0 := c_prev - tp_prev
		var rel1 := c_now - tp_now
		var h0 := Vector2(rel0.x, rel0.y)
		var h1 := Vector2(rel1.x, rel1.y)
		var hd: float = FuzeController.swept_min_distance_h_m(h0, h1)
		min_d = minf(min_d, hd)
		min_d3 = minf(min_d3, FuzeController.swept_min_distance_m(rel0, rel1))
		var t_ca: float = FuzeController.swept_closest_t(h0, h1)
		min_v = minf(min_v, absf(lerpf(rel0.z, rel1.z, t_ca)))
	if min_d < float(_fuze_min_pass.get(str(tp.torpedo_id), INF)):
		_fuze_min_pass[str(tp.torpedo_id)] = min_d
	if min_d3 < float(dbg.get("d3_m", INF)):
		dbg["d3_m"] = min_d3
		dbg["h_m"] = min_d
		dbg["v_m"] = min_v
		dbg["t"] = sim_time
	_fuze_debug[tid] = dbg
	# P1-12.4：引信独立安全保险——对发射方本侧平台绝不起爆。
	var safety_c: RefCounted = null
	if from_player:
		safety_c = world["own"]
	elif enemy_ai != null:
		safety_c = enemy_ai.entity
	if safety_c != null:
		var s_now := Vector3(
			float(safety_c.position_east_m),
			float(safety_c.position_north_m),
			float(safety_c.depth_m),
		)
		var s_prev: Vector3 = s_now
		if prev_contact.has(str(safety_c.id)):
			s_prev = prev_contact[str(safety_c.id)]
		var sh0 := Vector2(s_prev.x - tp_prev.x, s_prev.y - tp_prev.y)
		var sh1 := Vector2(s_now.x - tp_now.x, s_now.y - tp_now.y)
		var sd: float = FuzeController.swept_min_distance_h_m(sh0, sh1)
		var sv: float = absf(s_now.z - tp_now.z)
		if sd <= fc.trigger_radius_m() and sv <= FuzeController.FUZE_VERTICAL_GATE_M:
			if not _fuze_safety_latched.has(tid):
				_fuze_safety_latched[tid] = true
				tp.event_occurred.emit(tid, "FUZE_SAFETY_INHIBIT", {"reason": "OWN_SIDE"})
			return
	# 几何触发判定（swept 连续碰撞；REQ-08：同一时刻水平+垂直同判）。
	var res: Dictionary = fc.check_trigger_swept(
		tp_now, tp_prev, contacts, prev_contact, fc.trigger_radius_m()
	)
	if not bool(res["triggered"]):
		return
	var contact: RefCounted = res["contact"]
	# REQ-08：起爆成功后才结算伤害/战果（detonate 二次查 ARMED，双保险）。
	if not tp.detonate({"min_distance_m": float(res["min_distance_m"])}):
		return
	# 爆炸结算：EXPLOSION 声学事件 + Truth 伤害。
	(
		emission_bus
		. record(
			AcousticEmissionEvent.EXPLOSION,
			str(tp.torpedo_id),
			sim_time,
			Vector3(tp.pos_east_m, tp.pos_north_m, tp.actual_depth_m),
			500.0,
			4000.0,
			180.0,
			2.0,
		)
	)
	if not from_player:
		# 敌方鱼雷命中本艇（Truth 侧；普通 UI 只会收到 DETONATION_HEARD 证据）。
		world["own"].damage_state = "damaged"
	else:
		contact.damage_state = "sunk"
	(
		_detonations
		. append(
			{
				"time": sim_time,
				"torpedo_id": str(tp.torpedo_id),
				"target_internal_ref": contact,
				"target_id_internal": str(contact.id),  # 仅 Debrief/调试通道
				"min_pass_distance_m": float(_fuze_min_pass.get(str(tp.torpedo_id), min_d)),
				"detonated": true,
				"from_player": from_player,
			}
		)
	)
	_fuze_alive.erase(tid)
	_fuze_prev_tp.erase(tid)


## 消费新声学事件 → 净化证据（DETONATION_HEARD/鱼雷告警/本艇武器事实）。
func _advance_player_evidence() -> void:
	if emission_sanitizer == null:
		return
	var refs := {"own": true}
	if weapons != null:
		for tp in weapons.torpedoes:
			refs[str(tp.torpedo_id)] = true
	for d in decoys:
		if str(d.side) == "blue":
			refs[str(d.id)] = true
	var evs: Array = emission_sanitizer.consume_events(
		emission_bus.events, world["own"], sim_time, refs
	)
	for e in evs:
		player_evidence.append(e)
		# P1-11：INTERCEPT 威胁证据关联到 ThreatTrack（写回 threat_track_id）。
		if str(e.get("side_hint", "")) == "INTERCEPT":
			threat_tracks.ingest(e, sim_time)
	while player_evidence.size() > 256:
		player_evidence.pop_front()


## Debrief（§10.4/§10.5 内部调试通道）：Truth 命中/最近通过对照——普通 UI 禁用。
func _debrief_summary() -> Array:
	return _detonations.duplicate(true)
