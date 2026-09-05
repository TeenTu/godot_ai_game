extends SceneTree
## cm2_test.gd — 阶段一收尾 v2.0 P0-A 诱饵底层修复 无头验收（REQ-CM-01..04）。
##
## 对应文档验收 CM-1..4：
##   R3-CM1  同平台先后发 MOBILE/JAMMER：ID 各异；MOBILE 保留 240/480 谱线，
##           JAMMER 保留其配置谱；激活前无源；过期后各路径均无该源。
##   R3-CM2  覆盖内且 SE 足够的 MOBILE 进入 BB/NB（走 OperatorSonar 同一声场），
##           与敌方 AI 是否开启无关（本组用无 AI 场景）。
##   R3-CM3  完整 World（s1_combat）敌雷采样链真实处理玩家 MOBILE：
##           感知集含诱饵、画像已注册、source_token=""（不因 Truth 归属豁免）。
##   R3-CM4  诱饵从本艇实际深度出舱；命令深度生效且限垂速；过期清理注册。

const DT: float = 0.5


func _initialize() -> void:
	var fails: Array = []
	_r3_cm1_identity_profile(fails)
	_r3_cm2_bb_nb_visibility(fails)
	_r3_cm3_enemy_seek_path(fails)
	_r3_cm4_depth_egress_cleanup(fails)
	if fails.is_empty():
		print("CM2_TEST result=PASS")
	else:
		for f in fails:
			print("CM2_FAIL " + str(f))
		print("CM2_TEST result=FAIL (%d)" % fails.size())
	quit(1 if not fails.is_empty() else 0)


func _ok(fails: Array, name: String, got, want = true) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])


func _mk_prog(type: String = DecoyProgram.TYPE_MOBILE) -> DecoyProgram:
	var p := DecoyProgram.new()
	p.decoy_type = type
	p.launch_bearing_deg = 0.0
	p.course_deg = 0.0
	p.speed_kn = 8.0 if type == DecoyProgram.TYPE_MOBILE else 0.5
	p.activation_delay_s = 2.0
	p.lifetime_s = 40.0
	var sig := AcousticProfile.new()
	sig.broadband_base_level_db = 165.0
	sig.tonal_lines = [
		{"freq_hz": 240.0, "level_db": 128.0},
		{"freq_hz": 480.0, "level_db": 122.0},
	]
	if type == DecoyProgram.TYPE_JAMMER:
		sig.broadband_base_level_db = 185.0
		sig.tonal_lines = [{"freq_hz": 900.0, "level_db": 150.0}]
	p.signature = sig
	return p


func _mk_world(scenario: String) -> World:
	var w := World.new()
	w.load_scenario(ConfigLoader.load_scenario(scenario))
	return w


## ---- R3-CM1：唯一身份与画像 ----
func _r3_cm1_identity_profile(fails: Array) -> void:
	var w := _mk_world("stage1_basic_passive")
	var prog_m := _mk_prog()
	_ok(fails, "CM1a launch mobile", w._launch_decoy(prog_m), true)
	var id_m: String = str(w.decoys[0].id)
	# 激活前（2s 延时）统一声场无该源。
	_ok(fails, "CM1b silent before activation", w._acoustic_scene_emitters().size() == 0, true)
	_ok(fails, "CM1c silent acs", w._acoustic_scene_acs().is_empty(), true)
	w.run_steps(1)  # 冷却 10s 未过 → JAMMER 应被拒
	var prog_j := _mk_prog(DecoyProgram.TYPE_JAMMER)
	_ok(fails, "CM1d cooldown reject", w._launch_decoy(prog_j), false)
	_ok(fails, "CM1e reject reason", w.last_decoy_reject_reason == "cooldown", true)
	# 推进过冷却 + 激活。
	for i in range(24):
		w.run_steps(1)
	_ok(fails, "CM1f launch jammer", w._launch_decoy(prog_j), true)
	var id_j: String = str(w.decoys[1].id)
	_ok(fails, "CM1g ids differ", id_m != id_j, true)
	for i in range(4):
		w.run_steps(1)
	_ok(fails, "CM1h both activated in scene", w._acoustic_scene_emitters().size() == 2, true)
	var acs: Dictionary = w._acoustic_scene_acs()
	_ok(fails, "CM1i both acs registered", acs.has(id_m) and acs.has(id_j), true)
	# 画像互不覆盖：MOBILE 仍保留 240/480，JAMMER 保留 900（各为独立副本）。
	var lm: Array = acs[id_m].tonal_lines
	var lj: Array = acs[id_j].tonal_lines
	_ok(fails, "CM1j mobile tonals", lm.size() == 2 and float(lm[0]["freq_hz"]) == 240.0, true)
	_ok(fails, "CM1k jammer tonal", lj.size() == 1 and float(lj[0]["freq_hz"]) == 900.0, true)
	# 推进到两枚都过期：各路径均无该源（场景/采样集/画像注册全清）。
	for i in range(200):
		if w.decoys.is_empty():
			break
		w.run_steps(1)
	_ok(fails, "CM1l expired removed", w.decoys.is_empty(), true)
	_ok(fails, "CM1m scene empty", w._acoustic_scene_emitters().is_empty(), true)
	_ok(fails, "CM1n acs cleaned", w._acoustic_scene_acs().is_empty(), true)


## ---- R3-CM2：覆盖内 MOBILE 进入 BB/NB（同一声场，无敌方 AI）----
func _r3_cm2_bb_nb_visibility(fails: Array) -> void:
	var w := _mk_world("stage1_basic_passive")
	# 本艇静止：避免 4kn 北航把初速为 0 的诱饵甩进艉部盲区（盲区本身由
	# R3-CM2d 单独验证）。REQ-CM-04：盲区/静默/掩蔽是合法不可见原因。
	var own: TruthEntity = w.world["own"]
	own.speed_kn = 0.0
	own.commanded_speed_kn = 0.0
	var prog := _mk_prog()
	prog.launch_bearing_deg = 0.0  # 死艏向（BOW 覆盖内）
	prog.course_deg = 0.0
	_ok(fails, "CM2a launch", w._launch_decoy(prog), true)
	for i in range(6):
		w.run_steps(1)  # 越过激活延时
	_ok(fails, "CM2b activated", w.decoys.size() == 1 and w.decoys[0].activated, true)
	var op := OperatorSonar.new()
	op.setup(w.world)
	op.active_array_id = "BOW"  # 显式选艏阵（默认 TOWED 未展开不采样）
	for i in range(10):
		var scene: Array = w._acoustic_scene_emitters()
		var scene_acs: Dictionary = w.world["target_acs"].duplicate()
		scene_acs.merge(w._acoustic_scene_acs())
		op.update(w.sim_time, w.world["targets"] + scene, scene_acs)
		w.run_steps(1)
	var found: bool = false
	for pk in op.latest_peaks():
		var rel: float = absf(NavUtils.wrap180(float(pk.get("bearing_deg", 999.0))))
		if rel <= 10.0:
			found = true
	_ok(fails, "CM2c mobile in BB peaks", found, true)
	# 对照：艉部盲区（150~210）内不可见（覆盖门正确工作，不删盲区）。
	var w2 := _mk_world("stage1_basic_passive")
	var own2: TruthEntity = w2.world["own"]
	own2.speed_kn = 0.0
	own2.commanded_speed_kn = 0.0
	var prog2 := _mk_prog()
	prog2.launch_bearing_deg = 180.0
	prog2.course_deg = 180.0
	_ok(fails, "CM2d-1 launch stern", w2._launch_decoy(prog2), true)
	for i in range(6):
		w2.run_steps(1)
	var op2 := OperatorSonar.new()
	op2.setup(w2.world)
	op2.active_array_id = "BOW"
	var scene2: Array = w2._acoustic_scene_emitters()
	var acs2: Dictionary = w2.world["target_acs"].duplicate()
	acs2.merge(w2._acoustic_scene_acs())
	for i in range(10):
		op2.update(w2.sim_time, w2.world["targets"] + scene2, acs2)
		w2.run_steps(1)
	var found2: bool = false
	for pk2 in op2.latest_peaks():
		var rel2: float = absf(NavUtils.wrap180(float(pk2.get("bearing_deg", 999.0))))
		if rel2 >= 150.0 and rel2 <= 210.0:
			found2 = true
	_ok(fails, "CM2d-2 stern blind zone silent", found2, false)


## ---- R3-CM3：完整 World 敌雷采样链处理玩家 MOBILE（真实过滤路径）----
func _r3_cm3_enemy_seek_path(fails: Array) -> void:
	var w := _mk_world("s1_combat")
	_ok(fails, "CM3a enemy ai active", w.enemy_ai != null, true)
	var prog := _mk_prog()
	# CM3 用高电平谱线（近源级）：保证谱线检测概率≈1，隔离 RNG 抖动，
	# 本组只验收"真实过滤路径 + 画像注册"，不考远距离弱线检测。
	var sig3: AcousticProfile = prog.signature
	sig3.tonal_lines = [
		{"freq_hz": 240.0, "level_db": 168.0},
		{"freq_hz": 480.0, "level_db": 168.0},
	]
	_ok(fails, "CM3b launch", w._launch_decoy(prog), true)
	for i in range(8):
		w.run_steps(1)  # 激活 + 敌方感知重建
	var did: String = str(w.decoys[0].id)
	var in_perception: bool = false
	for c in w._enemy_perception_contacts:
		if str(c.id) == did:
			in_perception = true
	_ok(fails, "CM3c decoy in enemy perception", in_perception, true)
	_ok(fails, "CM3d acs registered", w._enemy_perception_acs.has(did), true)
	# REQ-CM-03：token=""（未知声源），绝不 FRIENDLY（否则敌雷自动识破反制）。
	var tok: String = str(w.enemy_torpedo_ctx.sensor_adapter.contact_tokens.get(did, "MISS"))
	_ok(fails, "CM3e token unknown", tok == "", true)
	# 敌方 seeker 真实采样能对该诱饵出 return（谱特征来自其画像）。
	var sa: TorpedoSensorAdapter = w.enemy_torpedo_ctx.sensor_adapter
	var e: TruthEntity = w.enemy_ai.entity
	# 采样朝向对准诱饵（保证落在其被动 FOV 内；本验收只考过滤链与画像注册）。
	var brg_ed: float = NavUtils.bearing_to_true(
		float(e.position_east_m),
		float(e.position_north_m),
		float(w.decoys[0].position_east_m),
		float(w.decoys[0].position_north_m)
	)
	var rets: Array = sa.sample_passive(
		float(e.position_east_m),
		float(e.position_north_m),
		float(e.depth_m),
		6.0,
		brg_ed,
		TorpedoAcousticProfile.make_default(),
		w.sim_time
	)
	var got_return: bool = false
	for r in rets:
		if not (r as SeekerReturn).spectral_features.get("tonal_hz", []).is_empty():
			got_return = true
	_ok(fails, "CM3f seeker returns spectral return", got_return, true)


## ---- R3-CM4：实际深度出舱 / 限垂速 / 过期清理 ----
func _r3_cm4_depth_egress_cleanup(fails: Array) -> void:
	var w := _mk_world("stage1_basic_passive")
	var own: TruthEntity = w.world["own"]
	own.depth_m = 100.0  # TRANSITION 层附近：旧实现会瞬移到 70/180 hold
	var prog := _mk_prog()
	prog.commanded_depth_band = "LOWER"  # 命令 180m：应限速下潜
	_ok(fails, "CM4a launch", w._launch_decoy(prog), true)
	var d: RefCounted = w.decoys[0]
	_ok(fails, "CM4b departs at own depth", absf(float(d.depth_m) - 100.0) < 0.5, true)
	w.run_steps(4)  # 2s：垂速 2m/s → 下潜 <5m（绝不瞬移 80m）
	var dz: float = float(d.depth_m) - 100.0
	_ok(fails, "CM4c limited descent", dz > 0.0 and dz <= 5.0, true)
	_ok(fails, "CM4d command depth set", absf(float(d.commanded_depth_m) - 180.0) < 1.0, true)
	# JAMMER 抖动不穿透独立副本：另一枚同程序 MOBILE 的谱线不受影响。
	# （过期清理已在 R3-CM1 覆盖；此处断言注销注册。）
	for i in range(200):
		if w.decoys.is_empty():
			break
		w.run_steps(1)
	var acs: Dictionary = (
		w.enemy_torpedo_ctx.sensor_adapter.contact_acs if w.enemy_torpedo_ctx != null else {}
	)
	_ok(fails, "CM4e decoys expired", w.decoys.is_empty(), true)
	_ok(
		fails,
		"CM4f player acs cleaned",
		not w.torpedo_ctx.sensor_adapter.contact_acs.has(str(d.id)),
		true
	)
	_ok(fails, "CM4g enemy acs clean", not acs.has(str(d.id)), true)
