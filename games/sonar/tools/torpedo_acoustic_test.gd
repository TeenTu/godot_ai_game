extends SceneTree
## torpedo_acoustic_test.gd — S1-07 Commit 5 鱼雷声学画像 + EmissionBus 无头验收
## （§14.3 WPN-ACOU + §6.1/§6.2/§9.1/§9.2）。
##
## 覆盖：
##   WPN-ACOU-01  速度模式同时改速度/噪声/续航（§6.2）：profile 的 QUIET/
##                CRUISE/HIGH 三档速度、续航、自噪声源级单调；鱼雷切模式按
##                续航比等比折算剩余燃料（HIGH 更快烧完）、运行噪声源级随
##                模式上升。
##   WPN-ACOU-02  出管瞬态 + 动力启动瞬态事件（§9.2）：fire 记录
##                TORPEDO_TUBE_TRANSIENT（平台位置/深度），WIRE_RUN 记录
##                TORPEDO_MOTOR_START；截获 SE/Pd 用同一 AcousticService 公式，
##                Pd 随距离单调下降、严格在 (0,1)——不是二值硬门限，可被探测
##                也可 miss；事件绝不携带 target_id。
##   WPN-ACOU-03  鱼雷主动 Ping 事件（TORPEDO_ACTIVE_PING，源级/频率来自
##                profile）可被被动阵按同一公式概率截获；主动按 profile 节拍
##                周期 Ping（冷却后可再次 Ping）；运行噪声持续广播。
##
## 全部确定性，可无头运行：
##   godot --headless --path games/sonar --script res://tools/torpedo_acoustic_test.gd

const DT: float = 0.5


func _initialize() -> void:
	var fails: Array = []
	var sim_t: float = 100.0
	_acou_01_profile_and_modes(fails, sim_t)
	_acou_02_launch_transients(fails, sim_t)
	_acou_03_active_ping_and_noise(fails, sim_t)
	_finish(fails)


## ---- WPN-ACOU-01：模式同时改速度/噪声/续航 ----
func _acou_01_profile_and_modes(fails: Array, sim_t0: float) -> void:
	var prof := TorpedoAcousticProfile.make_default()
	var q: String = WeaponProgram.speed_mode_name(WeaponProgram.SpeedMode.QUIET)
	var c: String = WeaponProgram.speed_mode_name(WeaponProgram.SpeedMode.CRUISE)
	var h: String = WeaponProgram.speed_mode_name(WeaponProgram.SpeedMode.HIGH)
	# 速度单调：QUIET < CRUISE < HIGH
	if not (prof.speed_kn(q) < prof.speed_kn(c) and prof.speed_kn(c) < prof.speed_kn(h)):
		fails.append("ACOU-01a speed not monotonic by mode")
	# 续航单调：QUIET > CRUISE > HIGH（HIGH 更快烧完）
	if not (
		prof.endurance_s(q) > prof.endurance_s(c) and prof.endurance_s(c) > prof.endurance_s(h)
	):
		fails.append("ACOU-01b endurance not monotonic by mode")
	# 自噪声源级单调：QUIET < CRUISE < HIGH（越高越易被探测）
	if not (
		prof.own_noise_sl_db(q) < prof.own_noise_sl_db(c)
		and prof.own_noise_sl_db(c) < prof.own_noise_sl_db(h)
	):
		fails.append("ACOU-01c own noise not monotonic by mode")

	# 鱼雷实机：切模式按续航比等比折算剩余燃料 + 更新速度（不单改地图速度）
	var sim_t: float = sim_t0
	var tp := Torpedo.new()
	tp.launch("A1", _mk_program(WeaponProgram.SpeedMode.CRUISE), 0.0, 0.0, 50.0, sim_t)
	for i in range(3):
		tp.step(DT, sim_t, null)
		sim_t += DT
	_assert_float(fails, "ACOU-01d launch speed", tp.speed_kn, prof.speed_kn(c), 1e-6)
	# 3 tick=1.5s 已烧 → fuel=1200-1.5=1198.5；切 HIGH → *800/1200 = 799.0
	var fuel_before: float = tp.fuel_left_s
	if absf(fuel_before - 1198.5) > 0.01:
		fails.append("ACOU-01e fuel burn wrong (%.2f)" % fuel_before)
	_assert_bool(
		fails, "ACOU-01f cmd HIGH", tp.command_speed_mode(WeaponProgram.SpeedMode.HIGH), true
	)
	_assert_float(fails, "ACOU-01g speed HIGH", tp.speed_kn, prof.speed_kn(h), 1e-6)
	_assert_float(fails, "ACOU-01h fuel rebudget HIGH", tp.fuel_left_s, 799.0, 0.01)
	_assert_bool(
		fails, "ACOU-01i cmd QUIET", tp.command_speed_mode(WeaponProgram.SpeedMode.QUIET), true
	)
	_assert_float(fails, "ACOU-01j speed QUIET", tp.speed_kn, prof.speed_kn(q), 1e-6)
	_assert_float(fails, "ACOU-01k fuel rebudget QUIET", tp.fuel_left_s, 1797.75, 0.01)


## ---- WPN-ACOU-02：出管/动力启动瞬态 + 截获 SE/Pd 单调 ----
func _acou_02_launch_transients(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var bus := AcousticEmissionBus.new()
	var ws := WeaponSystem.new()
	ws.emission_bus = bus
	var tp: Torpedo = ws.fire_manual(45.0, 0.0, 0.0, sim_t, 50.0)
	if tp == null:
		fails.append("ACOU-02a manual fire null")
		_finish(fails)
		return
	var tubes: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_TUBE_TRANSIENT)
	if tubes.size() != 1:
		fails.append("ACOU-02b tube transient count=%d" % tubes.size())
	else:
		var ev: Dictionary = tubes[0]
		if str(ev.get("emitter_internal_ref", "")) != tp.torpedo_id:
			fails.append("ACOU-02c tube emitter not torpedo id")
		var prof: TorpedoAcousticProfile = tp.acoustic_profile
		_assert_float(
			fails,
			"ACOU-02d tube SL",
			float(ev.get("source_level_db", -1.0)),
			float(prof.tube_launch_transient["sl_db"]),
			1e-6,
		)
		var pos: Dictionary = ev.get("source_position_internal", {})
		_assert_float(fails, "ACOU-02e tube at launch e", float(pos.get("e", 1e9)), 0.0, 1e-6)
		_assert_float(
			fails, "ACOU-02f tube depth", float(ev.get("source_depth_internal", -1e9)), 50.0, 1e-6
		)
		if ev.has("target_id"):
			fails.append("ACOU-02g tube event leaked target_id")

	# 出管后跑到 WIRE_RUN → 动力启动瞬态一次
	var env: RefCounted = _load_env()
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.emission_bus = bus
	for i in range(3):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var motors: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_MOTOR_START)
	if motors.size() != 1:
		fails.append("ACOU-02h motor start count=%d" % motors.size())

	# 截获方程与玩家声呐同源：SE=SL-TL-N_eff+AG-DT；Pd 随距离单调、非二值
	var prof2: TorpedoAcousticProfile = tp.acoustic_profile
	var sl: float = float(prof2.tube_launch_transient["sl_db"])
	var freq: float = float(prof2.tube_launch_transient["center_frequency_hz"])
	var se_near: float = AcousticService.passive_se_layer(sl, 1500.0, freq, env, 0.0, 50.0, 0.0)
	var se_far: float = AcousticService.passive_se_layer(sl, 12000.0, freq, env, 0.0, 50.0, 0.0)
	var pd_near: float = AcousticService.detection_probability(se_near)
	var pd_far: float = AcousticService.detection_probability(se_far)
	if not (pd_near > 0.0 and pd_near < 1.0):
		fails.append("ACOU-02i pd_near not probabilistic (%.3f)" % pd_near)
	if not (pd_far > 0.0 and pd_far < 1.0):
		fails.append("ACOU-02j pd_far not probabilistic (%.3f)" % pd_far)
	if not (pd_near > pd_far):
		fails.append("ACOU-02k Pd not monotonic vs range (%.3f vs %.3f)" % [pd_near, pd_far])
	# 弱源级（如远距离弱小目标）比强瞬态更难探测——证明探测是连续概率不是硬门限
	var pd_weak: float = AcousticService.detection_probability(
		AcousticService.passive_se_layer(sl - 40.0, 1500.0, freq, env, 0.0, 50.0, 0.0)
	)
	if not (pd_weak < pd_near):
		fails.append("ACOU-02l weaker source not less detectable")


## ---- WPN-ACOU-03：主动 Ping 可截获 + 周期 + 运行噪声随模式 ----
func _acou_03_active_ping_and_noise(fails: Array, sim_t0: float) -> void:
	var sim_t: float = sim_t0
	var bus := AcousticEmissionBus.new()
	var ctx := TorpedoContext.new()
	ctx.emission_bus = bus
	var env: RefCounted = _load_env()
	ctx.env = env
	var tp := Torpedo.new()
	tp.launch("A3", _mk_program(WeaponProgram.SpeedMode.CRUISE), 0.0, 0.0, 50.0, sim_t)
	var prof: TorpedoAcousticProfile = tp.acoustic_profile
	for i in range(3):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	# 手动开主动（WIRE 连接态）→ 下一次 step 进入 PINGING 并广播
	_assert_bool(fails, "ACOU-03a tx on", tp.set_active_tx(true), true)
	var pings: Array = []
	for i in range(40):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		var now: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_ACTIVE_PING)
		pings = now
		if now.size() >= 2:
			break
	if pings.size() < 2:
		fails.append("ACOU-03b active pings count=%d (<2 in 20s)" % pings.size())
	else:
		var p0: Dictionary = pings[0]
		_assert_float(
			fails,
			"ACOU-03c ping SL from profile",
			float(p0.get("source_level_db", -1.0)),
			prof.active_source_level_db,
			1e-6,
		)
		_assert_float(
			fails,
			"ACOU-03d ping freq from profile",
			float(p0.get("center_frequency_hz", -1.0)),
			prof.active_center_frequency_hz,
			1e-6,
		)
		if p0.has("target_id"):
			fails.append("ACOU-03e ping event leaked target_id")
		# 截获：敌方只拿到单程 SE（§9.3），无真实距离；Pd 在 (0,1)
		var se: float = (
			AcousticService
			. passive_se_layer(
				float(p0.get("source_level_db", 0.0)),
				4000.0,
				float(p0.get("center_frequency_hz", 0.0)),
				env,
				0.0,
				float(p0.get("source_depth_internal", 50.0)),
				0.0,
			)
		)
		var pd: float = AcousticService.detection_probability(se)
		if not (pd > 0.0 and pd < 1.0):
			fails.append("ACOU-03f intercept pd not probabilistic (%.3f)" % pd)

	# 运行噪声持续广播且源级随速度模式上升（切 HIGH 后更响）
	var noise_first: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_RUNNING_NOISE)
	if noise_first.is_empty():
		fails.append("ACOU-03g no running noise emitted")
		return
	var sl_first: float = float(noise_first[0]["source_level_db"])
	_assert_bool(
		fails, "ACOU-03h cmd HIGH", tp.command_speed_mode(WeaponProgram.SpeedMode.HIGH), true
	)
	for i in range(8):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var noise_all: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_RUNNING_NOISE)
	if noise_all.size() <= noise_first.size():
		fails.append("ACOU-03i running noise not periodic")
		return
	var sl_last: float = float(noise_all[noise_all.size() - 1]["source_level_db"])
	if not (sl_last > sl_first):
		fails.append("ACOU-03j HIGH noise not louder (%.1f vs %.1f)" % [sl_last, sl_first])


func _load_env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


func _mk_program(speed: int) -> WeaponProgram:
	var p := WeaponProgram.new()
	p.fire_mode = WeaponProgram.FireMode.MANUAL
	p.initial_course_deg = 0.0
	p.speed_mode = speed
	p.initial_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_depth_band = WeaponProgram.DEPTH_BAND_UPPER
	p.search_center_deg = 0.0
	p.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	p.wire_guidance_enabled = true
	p.active_enable_mode = WeaponProgram.ActiveEnableMode.MANUAL
	p.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.MANUAL
	p.warhead_arm_distance_m = 300.0
	p.fallback_program = p.make_default_fallback()
	return p


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _assert_float(fails: Array, name: String, got: float, want: float, tol: float) -> void:
	if absf(got - want) > tol:
		fails.append("%s: got=%.4f want=%.4f" % [name, got, want])


func _finish(fails: Array) -> void:
	for f in fails:
		print("ACOU_FAIL ", f)
	if fails.is_empty():
		print("TORPEDO_ACOUSTIC_TEST result=PASS")
	else:
		print("TORPEDO_ACOUSTIC_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
