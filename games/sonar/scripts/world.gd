class_name World
extends RefCounted
## world.gd — 固定步长仿真主循环（阶段一，无 UI）。 职责：持有 Truth 实体/环境/传感器/测量生成器；固定步长推进运动学；
##   按 update_interval 触发测量并收集测量流。Truth 隔离：只产出 Measurement， 绝不把 Truth 位置直接暴露给上层 UI。

signal mission_ended(result: Dictionary)
enum MissionState { RUNNING, PLAYER_DEFEATED }

const ACTIVE_SENSOR_ID: String = "hull_active"

var world: Dictionary = {}
var sim_time: float = 0.0
var measurements: Array = []  # 全部生成的 Measurement

var mission_state: int = MissionState.RUNNING
var mission_end_reason: String = ""
var mission_end_time: float = -1.0
var auto_measurements: bool = true
var weapons: WeaponSystem = null  # 阶段四：发射管与在水鱼雷
var torpedo_ctx: TorpedoContext = null

# ---- 主动声呐 Ping（S1-04B PingSession）：单在途 τ=2R/c 状态机 ----
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
var ping_coverage_sector: Vector2 = Vector2(0, 360)
var ping_baffle_sector: Vector2 = Vector2(0, 0)
# ---- S1-04C-REQ-05 / §9.1 声学事件：emission_bus 统一落事件 ----
# 每次显式发射记一条 AcousticEmissionEvent；敌方感知层只消费净化后样本。
var emission_bus: AcousticEmissionBus = null
var active_emissions: Array = []

# ---- S1-07 §8（Commit 8）：诱饵与反制（玩家发射器；敌方发射器同用 CountermeasureSystem）----
var countermeasures: CountermeasureSystem = null
var decoys: Array = []  # 活动诱饵（Truth 实体，随 tick 推进/寿命到期移除）
var last_decoy_reject_reason: String = ""

var emission_sanitizer: EmissionSanitizer = null
var player_evidence: Array = []  # 净化证据（告警/爆炸/本艇武器事实，可进 UI）
# 评审 P1-11：威胁航迹关联（LAUNCH_TRANSIENT→RUNNING_NOISE→ACTIVE_PING
# 同一威胁卡升级，抑制每秒一条告警的洪泛）。load_scenario 重置。
var threat_tracks := ThreatTrackManager.new()
var own_assets := OwnAssetRegistry.new()  # S109 §2.4 己方合法事实登记表
var threat_automation := ThreatAutomationController.new()  # §3.1 始终运行

var enemy_ai: EnemyDoctrineController = null
var enemy_weapons: WeaponSystem = null
var enemy_torpedo_ctx: TorpedoContext = null
var enemy_countermeasures: CountermeasureSystem = null
var _weapon_contacts: Array = []

var _sensor_timers: Dictionary = {}  # sensor_id -> 下次触发时间
var _paused: bool = false
var _time_scale: float = 1.0
# 单在途 PingSession（S1-04B-REQ-16/17）；{} = 无在途（READY）。结构：
var _ping_session: Dictionary = {}
# 已结算回波摘要缓冲（take_arrived_echoes 排空）。独立于会话存活：远目标回波 τ 可能远超冷却期，会话提前清空也不得丢已结算结果。
var _ping_results: Array = []
var _next_ping_id: int = 1
# S1-11 §3.5：最近一次监听窗关闭的 ping_id（-1=无）。驱动 UI 侧回波批次结算。
var _last_closed_ping_id: int = -1

# ---- S1-07 §9（Commit 9）：敌方出生/感知/Doctrine；同一声学服务+净化证据 ----
var _player_torpedo_shadows: Array = []
var _player_shadow_acs: Dictionary = {}
var _enemy_torpedo_shadows: Array = []
var _enemy_shadow_acs: Dictionary = {}
# 敌方感知/敌方鱼雷 seeker 的采样声源（每 tick 重建内容，数组实例稳定）。
var _enemy_perception_contacts: Array = []
var _enemy_perception_acs: Dictionary = {}

# ---- S1-07 §10（Commit 10）：引信引擎 / 净化战果证据 / Debrief ----
var _detonations: Array = []  # 内核 Debrief 记录（含 internal target 引用）
## 引信引擎（REQ-08/REQ-11/S109 AT-41）状态与推进抽到 FuzeEngine；下方属性
## 转发保持 `world._fuze_min_pass/_fuze_debug` 既有读点（UI 面板/测试）不变。
var _fuze_engine: FuzeEngine = FuzeEngine.new()
var _fuze_min_pass: Dictionary:
	get:
		return _fuze_engine.min_pass
var _fuze_alive: Dictionary:
	get:
		return _fuze_engine.alive
## REQ-11：引信调试台账（内核侧，仅 Debrief/调试面板）。
var _fuze_debug: Dictionary:
	get:
		return _fuze_engine.debug
var _fuze_prev_tp: Dictionary:
	get:
		return _fuze_engine._prev_tp
var _fuze_prev_contact: Dictionary:
	get:
		return _fuze_engine._prev_contact
var _fuze_safety_latched: Dictionary:
	get:
		return _fuze_engine._safety_latched


## 从场景 JSON 构建并初始化世界。
func load_scenario(scenario: Dictionary) -> void:
	world = ScenarioLoader.build(scenario)
	sim_time = 0.0
	measurements.clear()
	weapons = WeaponSystem.new()
	# S109 AT-40：玩家鱼雷线导命令接 World 任务门（终局后 MISSION_ENDED）。
	weapons.mission_gate = command_reject_reason
	torpedo_ctx = TorpedoContext.new()
	torpedo_ctx.env = world.get("env", null)
	torpedo_ctx.depth_model = world.get("depth_model", null)
	emission_bus = AcousticEmissionBus.new()
	active_emissions = emission_bus.events
	weapons.emission_bus = emission_bus
	torpedo_ctx.emission_bus = emission_bus
	var adapter := TorpedoSensorAdapter.new()
	adapter.env = world.get("env", null)
	adapter.depth_model = world.get("depth_model", null)
	adapter.rng = world.get("rng", null)
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
	# S1-07 §9（Commit 9）：敌方随机出生 + 感知 + Doctrine（有 enemy_spawn 块才启用；旧场景零行为变化）。
	_setup_enemy_ai(scenario)
	# S1-07 §10（Commit 10）：事件净化器（独立派生 RNG，确定性且不扰动玩家 测量流随机序列）+ 证据/Debrief 台账清空。
	emission_sanitizer = EmissionSanitizer.new()
	emission_sanitizer.bind(
		world.get("env", null),
		world.get("depth_model", null),
		_derived_rng(int(scenario.get("seed", 12345)) + 5000)
	)
	player_evidence.clear()
	threat_tracks.reset()
	own_assets.reset()
	threat_automation.reset()
	threat_automation.bind_store(threat_tracks)
	_detonations.clear()
	_fuze_engine.reset()
	_sensor_timers.clear()
	for s in world["sensors"]:
		_sensor_timers[s.sensor_id] = 0.0
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
	_last_closed_ping_id = -1
	if emission_bus != null:
		emission_bus.clear()


## 推进内部仿真时间 dt（秒）。dt 已由上层按 time_scale 折算。# 固定步长：world.dt 是每 tick 的物理步长。
func tick() -> void:
	if _paused:
		return
	# REQ-B5-03：已终局 → 下一仿真 tick 不再推进（UI 可完成当前事件显示）。
	if mission_state != MissionState.RUNNING:
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
	# 5b) REQ-09：统一声场无条件同步——无敌方 AI 场景玩家鱼雷也须进声场
	# （旧实现藏在 _advance_enemy_ai 末尾，enemy_ai==null 时永不产生影子）。
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


## 推进活动诱饵：激活记 DECOY_ACTIVATION/到期移除（§8.6）；REQ-CM-01/03：同步
## 注册 seeker 画像；token 按接收方：己方=FRIENDLY，敌方=""（须声学竞争）。
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


## 玩家发射诱饵（§8.5）：发射器库存/冷却/程序合法性校验；诱饵先进入活动 列表随 tick 推进，激活瞬间才进入武器采样集（激活前静默）。
## enemy 侧（Commit 9）用同一 CountermeasureSystem 流程。
func _launch_decoy(prog: DecoyProgram) -> bool:
	if not is_mission_running():  # REQ-B5-05：终局后命令门
		last_decoy_reject_reason = "MISSION_ENDED"
		return false
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


## REQ-AC-03：把激活且未过期的 JAMMER 诱饵同步为环境宽带干扰源。 频带/总功率来自其画像（band_min_hz/band_max_hz/sl_band_db）；玩家声呐、
## 敌方感知、双方鱼雷自导共用同一 env 干扰表（统一声场，各接收器再按# 位置/波束响应独立计算贡献）。
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


# S1-07 §9：出生=EnemySpawnGenerator；感知=EnemySensorAdapter；航迹=
# EnemyTrackManager；Doctrine=延迟+概率状态机；AI 鱼雷绝不读 Truth（§9.8）。


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
		# REQ-AI-01：出生/校验失败显式报告，绝不静默无敌人。
		printerr("[enemy_spawn] failed: %s" % gen.last_error)
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
	ai.configure(
		spawned,
		s_adapter,
		mgr,
		cfg.get("doctrine", {}),
		_derived_rng(base_seed + 4000),
		Callable(self, "_hold_depth_for")
	)
	enemy_ai = ai


func _derived_rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


## REQ-AI-02：敌方"可确知为己方来源"的发射引用集合（自身平台 id、己方在水 鱼雷 id、己方诱饵 id）。这些来源的事件对敌方感知层一律过滤——己方发射
## 不构成敌情，也绝不经事件通道识别玩家诱饵身份。
func _enemy_owned_emitter_refs() -> Dictionary:
	var refs: Dictionary = {}
	if enemy_ai != null and enemy_ai.entity != null:
		refs[str(enemy_ai.entity.id)] = true
	if enemy_weapons != null:
		for t in enemy_weapons.torpedoes:
			refs[str(t.torpedo_id)] = true
	if enemy_countermeasures != null:
		for d in enemy_countermeasures.deployed_decoys():
			refs[str(d.id)] = true
	return refs


## 每步推进敌方 AI：重建采样声源 → Doctrine update → 执行动作（发射鱼雷 / 放诱饵）；敌方鱼雷经独立 ctx 推进；死亡后归还并发余量。
func _advance_enemy_ai(dt: float) -> void:
	if enemy_ai == null:
		return
	_rebuild_enemy_contacts()
	# REQ-AI-02：来源过滤——敌方自身/己方在水武器/己方诱饵的发射事件不进
	# 截获（己方鱼雷噪声绝不触发自身敌情告警；也不经事件识别玩家诱饵身份）。
	var events: Array = enemy_ai.filter_interceptable(
		emission_bus.events if emission_bus != null else [], _enemy_owned_emitter_refs()
	)
	var actions: Array = enemy_ai.update(sim_time, dt, events)
	_apply_enemy_actions(actions)
	if enemy_weapons != null and not enemy_weapons.torpedoes.is_empty():
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


## 同步双方在水鱼雷的内核影子： - 玩家鱼雷影子 → 敌方感知（§9.6 来袭鱼雷运行噪声证据源）； - 敌方鱼雷影子 → 玩家声呐被动链（听到来袭鱼雷；告警 UI 属 Commit 11）。
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


## 鱼雷影子声学画像：运行噪声源级按速度模式直接刻画（不再叠速度斜率），# 窄带谱线随模式（Commit 8 谱线细节同源）。
func _torpedo_shadow_ac(tp: RefCounted) -> AcousticProfile:
	var ac := AcousticProfile.new()
	var sm: String = WeaponProgram.speed_mode_name(tp.speed_mode)
	ac.broadband_base_level_db = tp.acoustic_profile.own_noise_sl_db(sm)
	ac.speed_noise_a = 0.0
	ac.tonal_lines = tp.acoustic_profile.tonal_lines(sm)
	return ac


## 重建敌方感知/敌方鱼雷 seeker 的采样声源（内核边界内；数组实例稳定）：
## 本艇 + 玩家在水鱼雷影子 + 蓝方活动诱饵。绝不把玩家 TruthEntity 交给# Doctrine 层（适配器是唯一边界）。
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
		# REQ-CM-02：激活前静默；REQ-CM-03：玩家诱饵对敌方 = 未知声源， token="" 绝不标 FRIENDLY（否则敌雷自动识破反制）。
		if d.activated and not d.expired:
			_enemy_perception_contacts.append(d)
			e_tokens[str(d.id)] = ""
			if d.signature_ac != null:
				_enemy_perception_acs[str(d.id)] = d.signature_ac
	if enemy_torpedo_ctx != null and enemy_torpedo_ctx.sensor_adapter != null:
		enemy_torpedo_ctx.sensor_adapter.contact_tokens = e_tokens


## P0-06 统一声场（内核侧注册表快照）：双方在水鱼雷影子 + 活动诱饵。 Truth 几何只在本边界内；OperatorSonar/UI 仅消费净化派生（峰/证据）。
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


## 敌方反击（§9.7 ATTACKING）：BEARING_ONLY 宽扇区（无隐藏距离）；程序预设 距离授权自主 + 时间开主动（fallback 同源），绝不指向玩家真实位置。
func _enemy_fire(a: Dictionary) -> void:
	if enemy_weapons == null or enemy_ai == null or enemy_ai.entity == null:
		return
	var e: TruthEntity = enemy_ai.entity
	var prog := WeaponProgram.make_bearing_only(float(a.get("bearing_deg", 0.0)))
	# D-01：敌方 AI 为独立体系。该弹无线（wire_guidance_enabled=false），发射即自主
	# 制导，不经过玩家侧「线导授权」链（旧代码曾隐式依赖 WIRE_ONLY 门控缺失才接线）。
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.AUTONOMOUS
	prog.wire_guidance_enabled = false
	prog.active_enable_mode = WeaponProgram.ActiveEnableMode.TIME
	prog.active_enable_time_s = float(enemy_ai.doctrine.get("torpedo_active_enable_time_s", 60.0))
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = float(
		enemy_ai.doctrine.get("torpedo_autonomy_distance_m", 800.0)
	)
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	# REQ-AI-02：FIRE 请求→执行结果回执。拒发（无空管/程序非法）归还名额， 空管绝不占死在水武器计数。
	var fired: Torpedo = enemy_weapons.fire_program(
		prog, e.position_east_m, e.position_north_m, sim_time, e.depth_m
	)
	if fired == null and enemy_ai != null:
		enemy_ai.notify_fire_rejected()


## 敌方诱饵（§8.5/§9.7 EVADING）：同一 CountermeasureSystem 流程；MOBILE# 假目标谱（模拟潜艇），背离告警方位出舱。
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


## 为某个传感器生成一次测量（针对所有目标）。S1-00（GAP-DATA-01/02）： 主动阵绝不在本函数自动产测量（唯一路径 issue_ping → PingSession → 回波
## → generate_active，REQ-03）；未探测样本绝不进 measurements（miss 不携带# 未加噪真方位进玩家链）。
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


## REQ-B5-01：终局判定与拒绝原因（命令门共用）。
func is_mission_running() -> bool:
	return mission_state == MissionState.RUNNING


## REQ-B5-05：终局后所有操作命令的统一拒绝原因。
func command_reject_reason() -> String:
	return "" if is_mission_running() else "MISSION_ENDED"


## REQ-B5-03：幂等终局。多枚敌雷同 tick 命中只触发一次；首个终局时间/原因
## 不可被后续事件覆盖；已终局后调用直接拒绝（返回 false）。
func end_mission(state: int, reason: String) -> bool:
	if mission_state != MissionState.RUNNING:
		return false
	mission_state = state
	mission_end_reason = reason
	mission_end_time = sim_time
	(
		mission_ended
		. emit(
			{
				"state": state,
				"reason": reason,
				"time": sim_time,
				"own_damage_state": str(world["own"].damage_state),
			}
		)
	)
	# 终局 tick 完成爆炸证据结算：爆炸距接收端仅引信量级（R/c<下一 tick），
	# 属本次命中事实，允许 UI 终局层显示（REQ-B5-03）；下一 tick 仍冻结。
	_advance_player_evidence(sim_time + maxf(float(world.get("dt", 0.5)), 0.01))
	return true


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
# 算/监听窗结束)→(冷却到) READY；铁律 REQ-16/17/19/20，无显式硬件不自动 构造缺省主动阵。


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


## 本艇最近一次发射时刻（无在途返回 -1）。本艇事实，供 UI 显示 TRANSMITTING→LISTENING 相位（S1-04C-REQ-01 徽标，非目标 Truth）。
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


## 配置监听窗对应的最大可测距（m）：R_max = c·T_listen/2（REQ-04）。 监听窗固定来自本艇配置，绝不随场景目标/Truth 距离变化。
func ping_max_range_m() -> float:
	return 0.5 * ping_sound_speed_m_s * ping_listen_window_s


## 玩家发起主动脉冲（S1-04B/C）：发射瞬间按当前几何距离登记在途回波 （arrive_t=emit+2R/c）。REQ-04 固定监听窗（不用最远 Truth τ 延长，超窗
## 丢弃）；REQ-05 发射成功记一条事件；无硬件/在途未清/冷却中返回 false。
func issue_ping() -> bool:
	if not is_mission_running():  # REQ-B5-05：终局后命令门
		return false
	if not can_ping():
		return false
	var own: TruthEntity = world["own"]
	var sensor: SensorArray = _ping_sensor()
	var echoes: Array = []
	# REQ-B2-01：统一反射体快照回波登记（排除规则见 collector/静态采集）。
	for snap in _collect_active_reflectors(sensor):
		snap.emitted_ping_id = _next_ping_id
		snap.reflection_reference_time = sim_time
		(
			echoes
			. append(
				{
					"target_id": snap.internal_token,  # 内部结算用，不进玩家信息流
					"snapshot": snap,
					"arrive_t":
					(  # REQ-B2-02：发射时刻固化，结算只读快照
						sim_time
						+ AcousticService.echo_travel_time_s(
							snap.reflection_range_ref_m, ping_sound_speed_m_s
						)
					),
					"range_ref_m": snap.reflection_range_ref_m,  # 测距同源基准
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
		# S1-11 §3.5：本 Ping 的净化回波批次（到达顺序无关的一对一分配输入）。
		"batch": [],
		"batch_processed": false,
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


## REQ-B2-01：统一主动反射体条目集（发射时刻）——来源/排除规则与覆盖/监听窗
## 裁决见 ActiveReflectorCollector / ActiveReflectorSnapshot.collect。
func _collect_active_reflectors(sensor: SensorArray) -> Array:
	var entries: Array = (
		ActiveReflectorCollector
		. build_entries(
			world["targets"],
			world["target_acs"],
			enemy_weapons,
			decoys,
			str(world["own"].id),
			_torpedo_shadow_ac,
		)
	)
	return ActiveReflectorSnapshot.collect(world["own"], sensor, ping_max_range_m(), entries)


## 未返回（未结算）回波数。Truth 钩子：仅供无头测试/统计， 禁止 UI 据此显示目标存在或回波倒计时（Truth 隔离，ISSUE-06）。
func pending_echo_count() -> int:
	if _ping_session.is_empty():
		return 0
	var n: int = 0
	for e in _ping_session["echoes"]:
		if not bool(e["settled"]):
			n += 1
	return n


## 距最早未返回回波到达的剩余秒数；无在途返回 INF。# Truth 钩子：仅供无头测试/统计，禁止 UI 使用（ISSUE-06）。
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
## 返回 [{ping_id,detected,se,pd,bearing,range,range_sigma,measurement}]（S109：无身份；幂等）。
func take_arrived_echoes() -> Array:
	if not _ping_session.is_empty():
		_settle_due_echoes()
	var out: Array = _ping_results
	_ping_results = []
	return out


## S1-11 §3.5：监听窗关闭后的本 Ping 回波批次结算。先构造 Return×TT 航迹代价
## 矩阵做一对一分配（ActiveReturnBatch，顺序无关 + 歧义保留），再把已归属回波
## 融合进对应威胁航迹；未归属回波仍作为净化证据保留在 player_evidence，绝不
## 按到达顺序强塞（AT-51..54）。批次只结算一次（幂等）。
func _process_active_return_batch() -> void:
	if bool(_ping_session.get("batch_processed", false)):
		return
	_ping_session["batch_processed"] = true
	var batch: Array = _ping_session.get("batch", [])
	if batch.is_empty():
		return
	var targets: Array = []
	for tr in threat_tracks.tracks():
		var snap: Dictionary = threat_tracks.estimate_snapshot(tr)
		var rng: float = -1.0
		var rng_sig: float = 100.0
		if snap.get("range_est_m") != null:
			rng = float(snap["range_est_m"])
			if snap.get("range_sigma_m") != null:
				rng_sig = float(snap["range_sigma_m"])
		(
			targets
			. append(
				{
					"id": str(snap.get("track_id", "")),
					"bearing_deg": float(snap.get("bearing_est_deg", 0.0)),
					"bearing_sigma_deg": float(snap.get("bearing_sigma_deg", 2.0)),
					"range_m": rng,
					"range_sigma_m": rng_sig,
					"time": float(snap.get("last_update_time", 0.0)),
					"freqs": [],
				}
			)
		)
	var returns: Array = []
	for i in range(batch.size()):
		var e: Dictionary = batch[i]
		(
			returns
			. append(
				{
					"id": _batch_return_id(i),
					"bearing_deg": float(e.get("bearing_deg", 0.0)),
					"bearing_sigma_deg": float(e.get("bearing_sigma_deg", 2.0)),
					"range_m": float(e.get("measured_range_m", -1.0)),
					"range_sigma_m": float(e.get("range_sigma_m", 100.0)),
					"time": float(e.get("available_time", sim_time)),
					"freqs": [],
				}
			)
		)
	var res: Dictionary = ActiveReturnBatch.assign(returns, targets)
	var assigns: Dictionary = res.get("assignments", {})
	for i in range(batch.size()):
		var rid: String = _batch_return_id(i)
		if assigns.has(rid):
			# 已归属：融合进对应 TT 航迹（带 batch_key 防止同 Ping 二次占用，
			# preferred_track_id 让融合层尊重批次的一对一决定）。写入 player_evidence
			# 的必须是净化回波 DTO（含融合到的威胁 id），绝不是内部分配字符串。
			var dto: Dictionary = batch[i].duplicate()
			dto["batch_key"] = str(_ping_session.get("ping_id", -1))
			dto["preferred_track_id"] = str(assigns[rid])
			dto["threat_track_id"] = threat_tracks.fuse_active_return(dto, sim_time)
			player_evidence.append(dto)
		else:
			# 未归属/关联不确定：证据保留，供 UI 建立临时主动接触（不偷用身份）。
			player_evidence.append(batch[i])


## 批次内回波稳定 id（顺序无关，仅用于分配索引）。
func _batch_return_id(idx: int) -> String:
	return "P%d-R%03d" % [int(_ping_session.get("ping_id", -1)), idx]


## S1-11 §3.5：最近关闭监听窗的 ping_id（-1=无）。UI 侧据此结算普通接触批次。
func last_closed_ping_id() -> int:
	return _last_closed_ping_id


## 推进 PingSession（tick 每步调用）：结算到点回波 + 状态转移。
func _advance_ping_session() -> void:
	if _ping_session.is_empty():
		return
	_settle_due_echoes()
	var st: String = str(_ping_session["state"])
	if st == "LISTENING":
		if PingSessionRules.listen_done(_ping_session, sim_time):
			# 监听窗结束：丢弃仍未到达/超出窗口的回波（REQ-04，不可接收），
			# 再按已返回 detected 数判 RETURN/NO_RETURN。窗口不因远目标延长。
			PingSessionRules.drop_unsettled(_ping_session)
			_process_active_return_batch()
			_last_closed_ping_id = int(_ping_session.get("ping_id", -1))
			_ping_session["state"] = (
				"RETURN" if int(_ping_session["returned_count"]) > 0 else "NO_RETURN"
			)
	elif st == "RETURN" or st == "NO_RETURN":
		# 冷却结束 → 回到 READY（会话清空，单在途释放）
		if sim_time >= float(_ping_session["cooldown_until"]) - 1e-9:
			_ping_session = {}


## 结算已到点（sim_time >= arrive_t）的登记回波。测距以发射时刻登记的 range_ref_m 为基准（REQ-19 往返测距同源），到达时刻只做检测/测距噪声
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
		# REQ-B2-02：结算只读发射时刻快照——不再遍历 world["targets"]，
		# 绝不用当前 Truth 距离/方位回填；回波在途实体死亡仍按快照到达。
		var snap = e.get("snapshot", null)
		if snap == null:
			continue
		var target: RefCounted = snap
		var ac: RefCounted = snap.acoustic_profile
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
		# S109 P0-06：摘要 DTO 结构性不含 target_id（内核身份仅在会话 echoes 内部）。
		var summary := {
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
			# S1-11 §3.5：回波先入本 Ping 批次，监听窗关闭后统一做一对一分配再融合，
			# 保证同一 Ping 内每条 Return 只被消费一次、每条航迹只吸收一条回波
			# （AT-51..54；与回波到达/遍历顺序无关）。
			_ping_session["batch"].append(
				threat_tracks.active_return_dto(
					m, float(own.position_east_m), float(own.position_north_m)
				)
			)


## 本次 ping 使用的主动阵：场景 sensors 含 array_type=="active" 则复用它；
## 否则按 own_ship.active_sonar 显式配置物化艇首主动阵。仅在 ping_hardware 为真时可到达——无硬件绝不自动构造（REQ-20）。
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
# （敌=sunk/本艇=damaged）；玩法层只收净化 EvidenceEvent；CONFIRMED_KILL 只经 debrief_summary()（调试通道）。


## 引信引擎（每 tick）：状态与推进在 FuzeEngine（REQ-08 快照提交、AT-41 诱饵吸雷）。
func _advance_fuze_engine(dt: float = 0.0) -> void:
	_fuze_engine.bind_world(self)  # 幂等
	_fuze_engine.advance(sim_time, dt)


## 消费新声学事件 → 净化证据（DETONATION_HEARD/鱼雷告警/本艇武器事实）。
## now_override < 0 时用当前 sim_time（终局最终结算用 sim_time+dt，见 end_mission）。
func _advance_player_evidence(now_override: float = -1.0) -> void:
	if emission_sanitizer == null:
		return
	var now: float = sim_time if now_override < 0.0 else now_override
	own_assets.sync_from_world(weapons, decoys)  # S109 §2.4（非 id 前缀猜测）
	var evs: Array = emission_sanitizer.consume_events(
		emission_bus.events, world["own"], now, own_assets.refs_dict()
	)
	for e in evs:
		player_evidence.append(e)
	threat_automation.process_evidence(evs, sim_time)  # S109 §3.1（始终运行）
	threat_tracks.advance(sim_time)
	while player_evidence.size() > 256:
		player_evidence.pop_front()


## Debrief（§10.4/§10.5 内部调试通道）：Truth 命中/最近通过对照——普通 UI 禁用。
func _debrief_summary() -> Array:
	return _detonations.duplicate(true)
