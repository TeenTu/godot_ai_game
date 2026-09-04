extends SceneTree
## torpedo_seeker_test.gd — S1-07 Commit 6 TorpedoSensorAdapter + SeekerReturn 无头验收
## （§6.3/§6.4/§6.5/§6.7 + §14.2 WPN-SEEK-01/02/04/05 + SEEK-12 净化）。
##
## 覆盖：
##   SEEK-01/02  发射并安全出管后被动接收机默认 ON、active TX 默认 OFF；在
##               附近强声源下能收到被动 SeekerReturn（概率探测）。
##   SEEK-05     被动 Return 绝不自带真实 range（range_m<0）；返回对象/序列化
##               不含 target_id / Truth 字段（净化，WPN-SEEK-12 方向）。
##   SEEK-miss   弱/远声源按连续 Pd（≈0）确定性 miss——无 return 进玩法链。
##   SEEK-cross  跨温跃层同条件 SE/Pd 下降（depth_relation=CROSS_LAYER，
##               非硬置零：跨层仍可能探测）。
##   SEEK-speed  鱼雷自身高速 → N_eff 升高 → 被动 SE 下降（§6.2，自噪入自身
##               接收方程；QUIET > CRUISE > HIGH）。
##   SEEK-04     主动回波按 tau=2R/c 延迟到达（绝不同 tick 瞬时返回），
##               detected 后带测量距离 R_meas=c·tau/2+noise。
##   FA          误报由独立生成器产生（false_alarm_rate），不绑定任何 target。
##
## 全部确定性（固定 seed RNG），可无头运行：
##   godot --headless --path games/sonar --script res://tools/torpedo_seeker_test.gd

const DT: float = 0.5
const SEED: int = 20260904


func _initialize() -> void:
	var fails: Array = []
	_seek_01_02_defaults_and_passive(fails)
	_seek_05_passive_no_range(fails)
	_seek_miss_weak_far(fails)
	_seek_cross_layer(fails)
	_seek_speed_self_noise(fails)
	_seek_04_active_tof(fails)
	_fa_false_alarm(fails)
	_finish(fails)


## ---- SEEK-01/02：被动默认 ON + active 默认 OFF；附近强声源能收到被动 return ----
func _seek_01_02_defaults_and_passive(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var bus := AcousticEmissionBus.new()
	var contact: Dictionary = _contact("TG1", 0.0, 800.0, 50.0, 6.0, 170.0)
	var adapter := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
	adapter.set_rng(_rng(SEED + 1))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = bus
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	tp.launch("S1", _mk_program(WeaponProgram.SpeedMode.CRUISE), 0.0, 0.0, 50.0, sim_t)
	# 出管（LAUNCHING 1s）后进入 WIRE_RUN：被动 ON、主动 OFF、PASSIVE_LISTEN。
	for i in range(3):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	_assert_bool(fails, "SEEK-01a passive receiver on", tp.passive_receiver_on, true)
	if tp.seeker_state_name() != "PASSIVE_LISTEN":
		fails.append("SEEK-01b seeker state=%s" % tp.seeker_state_name())
	_assert_bool(fails, "SEEK-02a active tx off", tp.active_tx_state_name() == "OFF", true)
	# 继续跑 5s（周期 1s 采样），应能收到被动 return（强声源高 Pd）。
	for i in range(10):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var passives: Array = _passive_of(tp.seeker_returns)
	if passives.is_empty():
		fails.append("SEEK-01c no passive returns from loud contact")
	else:
		var sr: RefCounted = passives[0]
		if not bool(sr.detected):
			fails.append("SEEK-01d passive return not detected")
		# 目标在鱼雷正北（course 0）：带噪方位应接近 0°（强接触 sigma 很小）。
		var err: float = absf(NavUtils.wrap180(float(sr.bearing_deg)))
		if err > 6.0:
			fails.append("SEEK-01e passive bearing err=%.2f" % err)


## ---- SEEK-05：被动 return 无真实 range + 净化（无 target_id/Truth）----
func _seek_05_passive_no_range(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var contact: Dictionary = _contact("TG1", 0.0, 800.0, 50.0, 6.0, 170.0)
	var adapter := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
	adapter.set_rng(_rng(SEED + 2))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	tp.launch("S5", _mk_program(WeaponProgram.SpeedMode.CRUISE), 0.0, 0.0, 50.0, sim_t)
	for i in range(8):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	var passives: Array = _passive_of(tp.seeker_returns)
	if passives.is_empty():
		fails.append("SEEK-05a no passive returns")
		return
	for sr in passives:
		if float(sr.range_m) >= 0.0 or float(sr.range_sigma_m) >= 0.0:
			fails.append("SEEK-05b passive leaked range_m=%.1f" % float(sr.range_m))
		var d: Dictionary = sr.to_dict()
		if (
			d.has("target_id")
			or d.has("position_east_m")
			or d.has("position_north_m")
			or d.has("damage_state")
			or d.has("debug_truth_ref")
		):
			fails.append("SEEK-05c return dict leaked truth keys")
		if str(sr.debug_truth_ref) != "":
			fails.append("SEEK-05d debug_truth_ref leaked")


## ---- miss：弱/远声源确定性无 return（连续 Pd，非硬门限硬给）----
func _seek_miss_weak_far(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	# 弱 SL + 远距 → SE 深负 → Pd≈0：多次采样都不出 return。
	var contact: Dictionary = _contact("TG2", 0.0, 12000.0, 50.0, 6.0, 90.0)
	var adapter := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
	adapter.set_rng(_rng(SEED + 3))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	tp.launch("S6", _mk_program(WeaponProgram.SpeedMode.CRUISE), 0.0, 0.0, 50.0, sim_t)
	for i in range(14):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	if not tp.seeker_returns.is_empty():
		fails.append("SEEK-miss unexpected return count=%d" % tp.seeker_returns.size())


## ---- cross-layer：跨温跃层同条件 SE 下降、非硬置零；depth_relation 标注 ----
func _seek_cross_layer(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var obs := {"e": 0.0, "n": 0.0, "z": 50.0, "kn": 40.0, "c": 0.0}
	var same: Dictionary = _contact("S", 0.0, 800.0, 50.0, 6.0, 170.0)
	var cross: Dictionary = _contact("C", 0.0, 800.0, 200.0, 6.0, 170.0)
	var ad_same := _mk_adapter(env, dm, [same["entity"]], {same["id"]: same["ac"]})
	ad_same.set_rng(_rng(SEED + 4))
	var ad_cross := _mk_adapter(env, dm, [cross["entity"]], {cross["id"]: cross["ac"]})
	ad_cross.set_rng(_rng(SEED + 5))
	var prof := TorpedoAcousticProfile.make_default()
	var r_same: Array = ad_same.sample_passive(obs.e, obs.n, obs.z, obs.kn, obs.c, prof, 200.0)
	var r_cross: Array = ad_cross.sample_passive(obs.e, obs.n, obs.z, obs.kn, obs.c, prof, 200.0)
	if r_same.is_empty() or r_cross.is_empty():
		fails.append("SEEK-cross no returns (same=%d cross=%d)" % [r_same.size(), r_cross.size()])
		return
	var se_same: float = float(r_same[0].signal_excess_db)
	var se_cross: float = float(r_cross[0].signal_excess_db)
	if not (se_cross < se_same):
		fails.append("SEEK-cross SE not lower (%.1f vs %.1f)" % [se_cross, se_same])
	if str(r_same[0].depth_relation) != "SAME_LAYER":
		fails.append("SEEK-cross same rel=%s" % str(r_same[0].depth_relation))
	if str(r_cross[0].depth_relation) != "CROSS_LAYER":
		fails.append("SEEK-cross rel=%s" % str(r_cross[0].depth_relation))


## ---- speed：自身高速 → N_eff 高 → 被动 SE 低（QUIET > CRUISE > HIGH）----
func _seek_speed_self_noise(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var contact: Dictionary = _contact("S", 0.0, 800.0, 50.0, 6.0, 170.0)
	var prof := TorpedoAcousticProfile.make_default()
	var se_at := {}
	for mode in ["QUIET", "CRUISE", "HIGH"]:
		var kn: float = prof.speed_kn(mode)
		var ad := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
		ad.set_rng(_rng(SEED + 10 + int(kn)))
		var rs: Array = ad.sample_passive(0.0, 0.0, 50.0, kn, 0.0, prof, 200.0)
		if rs.is_empty():
			fails.append("SEEK-speed no return at %s" % mode)
			continue
		se_at[mode] = float(rs[0].signal_excess_db)
	if se_at.has("QUIET") and se_at.has("CRUISE") and se_at.has("HIGH"):
		if not (se_at["QUIET"] > se_at["CRUISE"] and se_at["CRUISE"] > se_at["HIGH"]):
			fails.append(
				(
					"SEEK-speed not monotonic Q=%.1f C=%.1f H=%.1f"
					% [se_at["QUIET"], se_at["CRUISE"], se_at["HIGH"]]
				)
			)
		if not (se_at["QUIET"] - se_at["HIGH"] > 5.0):
			fails.append(
				"SEEK-speed self-noise delta too small (%.1f)" % (se_at["QUIET"] - se_at["HIGH"])
			)


## ---- SEEK-04：主动回波按 tau=2R/c 延迟到达，带测量距离 ----
func _seek_04_active_tof(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var bus := AcousticEmissionBus.new()
	# 接触正北 1000m（强 TS），鱼雷 QUIET 低速以降低自噪、保证高 Pd。
	var contact: Dictionary = _contact("T4", 0.0, 1000.0, 50.0, 6.0, 170.0)
	var adapter := _mk_adapter(env, dm, [contact["entity"]], {contact["id"]: contact["ac"]})
	adapter.set_rng(_rng(SEED + 6))
	var ctx := TorpedoContext.new()
	ctx.env = env
	ctx.depth_model = dm
	ctx.emission_bus = bus
	ctx.sensor_adapter = adapter
	var sim_t: float = 100.0
	var tp := Torpedo.new()
	tp.launch("S4", _mk_program(WeaponProgram.SpeedMode.QUIET), 0.0, 0.0, 50.0, sim_t)
	tp.acoustic_profile.active_source_level_db = 210.0  # 测试用强主动源级（游戏标定外）
	for i in range(3):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
	_assert_bool(fails, "SEEK-04a manual tx on", tp.set_active_tx(true), true)
	var ping_t: float = -1.0
	var got_ping: bool = false
	var arrived: bool = false
	for i in range(12):
		tp.step(DT, sim_t, ctx)
		sim_t += DT
		if not got_ping:
			var pings: Array = bus.events_of_kind(AcousticEmissionEvent.TORPEDO_ACTIVE_PING)
			if not pings.is_empty():
				got_ping = true
				ping_t = float(pings[pings.size() - 1]["emit_time"])
				# 刚 Ping 完（同一步内）绝不应有 ACTIVE return（TOF 未到）。
				if not _active_of(tp.seeker_returns).is_empty():
					fails.append("SEEK-04b echo returned same tick as ping")
			continue
		var actives: Array = _active_of(tp.seeker_returns)
		if actives.is_empty():
			continue
		arrived = true
		var sr: RefCounted = actives[actives.size() - 1]
		if str(sr.sensor_mode) != "ACTIVE":
			fails.append("SEEK-04c not ACTIVE")
		if not bool(sr.detected):
			fails.append("SEEK-04d active not detected")
		var tau: float = AcousticService.echo_travel_time_s(1000.0)
		var want_arrive: float = ping_t + tau
		if absf(float(sr.available_time) - want_arrive) > 0.05:
			fails.append(
				(
					"SEEK-04e arrive mismatch got=%.3f want=%.3f"
					% [float(sr.available_time), want_arrive]
				)
			)
		if float(sr.range_m) < 0.0:
			fails.append("SEEK-04f no measured range")
		elif absf(float(sr.range_m) - 1000.0) > 150.0:
			fails.append("SEEK-04g measured range bad %.1f" % float(sr.range_m))
		var err: float = absf(NavUtils.wrap180(float(sr.bearing_deg)))
		if err > 6.0:
			fails.append("SEEK-04h active bearing err=%.2f" % err)
		break
	if not got_ping:
		fails.append("SEEK-04i never pinged")
	elif not arrived:
		fails.append("SEEK-04j active echo never arrived")
	# 事件净化：ACTIVE return 同样不得携带 target_id/Truth。
	for sr in _active_of(tp.seeker_returns):
		var d: Dictionary = sr.to_dict()
		if d.has("target_id") or str(sr.debug_truth_ref) != "":
			fails.append("SEEK-04k active return leaked truth")


## ---- FA：误报独立生成，不绑定任何真实声源 ----
func _fa_false_alarm(fails: Array) -> void:
	var env: RefCounted = _env()
	var dm: RefCounted = _depth_model()
	var adapter := _mk_adapter(env, dm, [], {})
	adapter.set_rng(_rng(SEED + 7))
	adapter.false_alarm_rate = 1.0
	var prof := TorpedoAcousticProfile.make_default()
	var n_returns: int = 0
	for i in range(5):
		var rs: Array = adapter.sample_passive(0.0, 0.0, 50.0, 40.0, 0.0, prof, 300.0 + i)
		n_returns += rs.size()
		for sr in rs:
			if str(sr.sensor_mode) != "PASSIVE" or not bool(sr.detected):
				fails.append("FA-a false alarm malformed")
			if float(sr.range_m) >= 0.0:
				fails.append("FA-b false alarm with range")
			var d: Dictionary = sr.to_dict()
			if d.has("target_id") or str(sr.debug_truth_ref) != "":
				fails.append("FA-c false alarm leaked truth")
			var b: float = float(sr.bearing_deg)
			if b < 0.0 or b >= 360.0:
				fails.append("FA-d bearing out of range")
	if n_returns != 5:
		fails.append("FA-e expected 5 false alarms got %d" % n_returns)


## ---- helpers ----
func _env() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world["env"]


func _depth_model() -> RefCounted:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario("stage1_basic_passive"))
	return w.world.get("depth_model", null)


func _mk_adapter(
	env_ref: RefCounted, dm: RefCounted, contacts_arr: Array, acs: Dictionary
) -> TorpedoSensorAdapter:
	var ad := TorpedoSensorAdapter.new()
	ad.bind(env_ref, dm, contacts_arr, acs)
	return ad


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


## 构造一个 Truth 声源 + 其声学画像（只供 adapter 采样边界用，绝不进玩法链）。
func _contact(
	id: String, e: float, n: float, depth: float, kn: float, base_sl: float
) -> Dictionary:
	var t := TruthEntity.new()
	t.id = id
	t.side = "red"
	t.platform_type = "submarine"
	t.position_east_m = e
	t.position_north_m = n
	t.depth_m = depth
	t.course_deg = 0.0
	t.speed_kn = kn
	var ac := AcousticProfile.new()
	ac.broadband_base_level_db = base_sl
	ac.tonal_lines = [{"freq_hz": 1500.0, "level_db": base_sl - 12.0}]
	return {"id": id, "entity": t, "ac": ac}


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


func _passive_of(returns: Array) -> Array:
	var out: Array = []
	for r in returns:
		if str(r.sensor_mode) == "PASSIVE":
			out.append(r)
	return out


func _active_of(returns: Array) -> Array:
	var out: Array = []
	for r in returns:
		if str(r.sensor_mode) == "ACTIVE":
			out.append(r)
	return out


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	for f in fails:
		print("SEEK_FAIL ", f)
	if fails.is_empty():
		print("TORPEDO_SEEKER_TEST result=PASS")
	else:
		print("TORPEDO_SEEKER_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
