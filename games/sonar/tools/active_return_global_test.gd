extends SceneTree
## active_return_global_test.gd — P1-A（PG-05）全局一次归属验收。
##
##   T16 潜艇 + 两枚鱼雷 + 诱饵同一次 Ping：全部有效回波都被裁决（可见），
##       最优/次优接近的回波保留未归属（歧义保留），归属不串（每条回波唯一归属、
##       每个目标最多吸收一条回波）。
##   T17 交换回波到达/输入顺序，最终归属不变；不同实体不能共吃同一观测。
##   T18 ASSIST/AUTO 自动更新**全部**已关联接触，而不只更新当前选中/最高优先者。
##   T19 普通 Tracker 与 TT 共享观测身份：信息只融合一次（不双计），
##       地图不画重复物体（TT 归属的回波不另建普通航迹）。
##   T16b PG-05 台账容量：8 行 UI 显示窗口 ≠ 证据库容量（全部正式记录可查询）。
##
## 运行：godot --headless --path games/sonar --script res://tools/active_return_global_test.gd

const DT: float = 0.5
const CYCLE_STEPS: int = 40  # 监听窗 15 s + 余量
const COOLDOWN_STEPS: int = 40


func _initialize() -> void:
	var fails: Array = []
	_g01_multibody_attribution(fails)
	_g02_order_independence(fails)
	_g03_all_contacts_refreshed(fails)
	_g04_shared_identity_fuse_once(fails)
	_g06_tt_contact_coexist(fails)
	_g05_ledger_capacity(fails)
	if fails.is_empty():
		print("ACTIVE-RETURN-GLOBAL TEST PASS")
		quit(0)
	else:
		for f in fails:
			print("  FAIL: " + str(f))
		print("ACTIVE-RETURN-GLOBAL TEST FAIL: %d problem(s)" % fails.size())
		quit(1)


# ---------------- T16：多体混合归属（潜艇 + 两枚鱼雷 + 诱饵） ----------------
func _g01_multibody_attribution(fails: Array) -> void:
	var targets: Array = [
		_tgt("P01", ActiveReturnAttribution.KIND_CONTACT, 10.0, 1.5, 3000.0, 120.0),
		_tgt("P02", ActiveReturnAttribution.KIND_CONTACT, 200.0, 3.0, 800.0, 200.0),
		_tgt("TT001", ActiveReturnAttribution.KIND_THREAT, 85.0, 1.0, 1200.0, 60.0),
		_tgt("TT002", ActiveReturnAttribution.KIND_THREAT, 88.5, 1.0, 1500.0, 60.0),
	]
	var returns: Array = [
		_ret("R1", 10.2, 1.5, 3020.0, 120.0),
		_ret("R2", 85.1, 1.0, 1190.0, 60.0),
		_ret("R3", 88.6, 1.0, 1510.0, 60.0),
		_ret("R4", 201.5, 3.0, 830.0, 200.0),
		_ret("R5", 86.70, 2.0, 1340.0, 80.0),
		_ret("R6", 86.80, 2.0, 1360.0, 80.0),
	]
	var res: Dictionary = ActiveReturnAttribution.attribute(returns, targets)
	var owners: Dictionary = res["owners"]
	var counts: Dictionary = res["counts"]
	# 全部有效回波都拿到唯一裁决（没有静默丢弃、没有重复条目）。
	_assert_eq(fails, "T16 every return judged once", str(owners.size()), "6")
	_assert_eq(
		fails, "T16 threat-owned count", str(int(counts[ActiveReturnAttribution.KIND_THREAT])), "2"
	)
	_assert_eq(
		fails,
		"T16 contact-owned count",
		str(int(counts[ActiveReturnAttribution.KIND_CONTACT])),
		"2"
	)
	_assert_eq(fails, "T16 unassigned kept", str(int(counts["UNASSIGNED"])), "2")
	# 归属不串：每条回波各自唯一，且每个目标最多吸收一条回波。
	var assigns: Dictionary = res["assignments"]
	_assert_eq(fails, "T16 assignments", str(assigns.size()), "4")
	var used: Dictionary = {}
	var dup_target: bool = false
	for rid in assigns.keys():
		var tid: String = str(assigns[rid])
		if used.has(tid):
			dup_target = true
		used[tid] = true
	_assert_true(fails, "T16 no target eats two returns", not dup_target)
	# 逐条归属正确（含两类候选在同一矩阵里互不串台）。
	_assert_owner(
		fails, "T16 sub echo -> contact", owners, "R1", ActiveReturnAttribution.KIND_CONTACT, "P01"
	)
	_assert_owner(
		fails,
		"T16 decoy echo -> contact",
		owners,
		"R4",
		ActiveReturnAttribution.KIND_CONTACT,
		"P02"
	)
	_assert_owner(
		fails, "T16 torp1 echo -> TT", owners, "R2", ActiveReturnAttribution.KIND_THREAT, "TT001"
	)
	_assert_owner(
		fails, "T16 torp2 echo -> TT", owners, "R3", ActiveReturnAttribution.KIND_THREAT, "TT002"
	)
	# 歧义保留：两枚近方位/近距鱼雷之间的回波不得按到达顺序强塞。
	var ambiguous: Array = res["ambiguous"]
	_assert_true(
		fails,
		"T16 near-pair echoes stay ambiguous (%s)" % str(ambiguous),
		(
			ambiguous.size() == 2
			and str(ambiguous[0]) in ["R5", "R6"]
			and str(ambiguous[1]) in ["R5", "R6"]
		)
	)
	_assert_owner(
		fails,
		"T16 ambiguous R5 unassigned",
		owners,
		"R5",
		ActiveReturnAttribution.KIND_UNASSIGNED,
		""
	)
	_assert_owner(
		fails,
		"T16 ambiguous R6 unassigned",
		owners,
		"R6",
		ActiveReturnAttribution.KIND_UNASSIGNED,
		""
	)


# ---------------- T17：顺序无关 + 不共吃同一观测 ----------------
func _g02_order_independence(fails: Array) -> void:
	var targets: Array = [
		_tgt("P01", ActiveReturnAttribution.KIND_CONTACT, 10.0, 1.5, 3000.0, 120.0),
		_tgt("TT001", ActiveReturnAttribution.KIND_THREAT, 85.0, 1.0, 1200.0, 60.0),
	]
	var returns: Array = [
		_ret("R1", 10.2, 1.5, 3020.0, 120.0),
		_ret("R2", 85.1, 1.0, 1190.0, 60.0),
	]
	var fwd: Dictionary = ActiveReturnAttribution.attribute(returns, targets)["owners"]
	var rev_r: Array = returns.duplicate()
	rev_r.reverse()
	var rev_returns: Dictionary = ActiveReturnAttribution.attribute(rev_r, targets)["owners"]
	var rev_t: Array = targets.duplicate()
	rev_t.reverse()
	var rev_both: Dictionary = ActiveReturnAttribution.attribute(rev_r, rev_t)["owners"]
	var stable: bool = true
	for rid in ["R1", "R2"]:
		var a: Dictionary = fwd.get(rid, {})
		var b: Dictionary = rev_returns.get(rid, {})
		var c: Dictionary = rev_both.get(rid, {})
		if (
			str(a.get("id", "")) != str(b.get("id", ""))
			or str(a.get("id", "")) != str(c.get("id", ""))
		):
			stable = false
	_assert_true(fails, "T17 ownership stable under return/target reorder", stable)
	_assert_owner(fails, "T17 R1 -> P01", fwd, "R1", ActiveReturnAttribution.KIND_CONTACT, "P01")
	_assert_owner(fails, "T17 R2 -> TT001", fwd, "R2", ActiveReturnAttribution.KIND_THREAT, "TT001")
	# 不同实体不能共吃同一观测：2 条回波 + 1 个候选 → 只允许 1 条被吸收。
	var one_t: Array = [targets[0]]
	var squeezed: Dictionary = ActiveReturnAttribution.attribute(returns, one_t)
	_assert_eq(fails, "T17 one observation per entity", str(squeezed["assignments"].size()), "1")
	_assert_eq(fails, "T17 loser stays unassigned", str(squeezed["unassigned"].size()), "1")


# ---------------- T18：ASSIST/AUTO 更新全部已关联接触 ----------------
func _g03_all_contacts_refreshed(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_two_target_scenario())
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.automation = AutomationController.new()
	# 第一个 Ping 建立两条接触（两条回波都还没有可归属对象）。
	_cycle(w, c)
	_assert_eq(fails, "T18 first ping creates two contacts", str(c.tracker.count()), "2")
	if c.tracker.count() != 2:
		return
	var ids: Array = []
	for t in c.tracker.all_tracks():
		ids.append(t.track_id)
	ids.sort()
	var favoured: String = str(ids[0])
	var other: String = str(ids[1])
	w.run_steps(COOLDOWN_STEPS)
	# AUTO 模式 + 只"选中"其中一条接触：另一条也必须被自动更新。
	c.automation.set_mode(AutomationController.Mode.FULL_AUTO, w.sim_time)
	c.preferred_track_id = favoured
	var t_ref: float = _cycle_t(w, c)
	# 每条 ACTIVE 接触都有系统位置估计条目（不是只算选中/最高优先者）。
	var covered: bool = true
	for t in c.tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE and not c.position_estimates.has(t.track_id):
			covered = false
	_assert_true(fails, "T18 every active contact has an estimate entry", covered)
	var est_a: Dictionary = c.position_estimate_for(favoured)
	var est_b: Dictionary = c.position_estimate_for(other)
	_assert_true(
		fails,
		"T18 selected contact refreshed by this ping",
		absf(float(est_a.get("time", -1.0)) - t_ref) < 1e-6
	)
	_assert_true(
		fails,
		(
			"T18 unselected contact also refreshed (%.2f vs %.2f)"
			% [float(est_b.get("time", -1.0)), t_ref]
		),
		absf(float(est_b.get("time", -1.0)) - t_ref) < 1e-6
	)
	_assert_true(
		fails,
		"T18 both contacts got a position from the same ping",
		bool(est_a.get("has_position", false)) and bool(est_b.get("has_position", false))
	)
	# MANUAL 模式下同样不锁死：手动模式只是不自动拟合，接触集合仍然一致。
	c.automation.set_mode(AutomationController.Mode.MANUAL, w.sim_time)
	w.run_steps(COOLDOWN_STEPS)
	_cycle(w, c)
	var manual_covered: bool = true
	for t in c.tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE and not c.position_estimates.has(t.track_id):
			manual_covered = false
	_assert_true(fails, "T18 manual mode still refreshes every contact", manual_covered)


# ---------------- T19：共享观测身份 / 只融合一次 / 不画重复物体 ----------------
func _g04_shared_identity_fuse_once(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_two_target_scenario())
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.automation = AutomationController.new()
	_cycle(w, c)
	var before: Dictionary = _evidence_counts(c)
	w.run_steps(COOLDOWN_STEPS)
	_cycle(w, c)
	var after: Dictionary = _evidence_counts(c)
	# 每条接触的主动测距证据在本次 Ping 中最多增加 1 条（信息只融合一次，不双计）。
	var deltas_ok: bool = true
	for tid in after.keys():
		var d: int = int(after[tid]) - int(before.get(tid, 0))
		if d < 0 or d > 1:
			deltas_ok = false
	_assert_true(
		fails, "T19 each contact absorbs at most one echo per ping (%s)" % str(after), deltas_ok
	)
	# 本 Ping 的记录里：每条回波一个归属，同一个普通航迹不会出现两次。
	var last_pid: int = -1
	var rows: Array = c.records_snapshot()
	if not rows.is_empty():
		last_pid = int(rows[rows.size() - 1]["ping_id"])
	var seen: Dictionary = {}
	var dup: bool = false
	var tt_dupes: int = 0
	var contact_rows: int = 0
	for r in rows:
		if int(r["ping_id"]) != last_pid:
			continue
		var kind: String = str(r.get("owner_kind", ""))
		var tid: String = str(r["track_id"])
		if seen.has(kind + ":" + tid):
			dup = true
		seen[kind + ":" + tid] = true
		if kind == ActiveReturnAttribution.KIND_THREAT:
			# TT 归属回波绝不另建普通航迹（地图上同一物体只画一份）。
			if c.tracker.track_by_id(tid) != null:
				tt_dupes += 1
		elif kind == ActiveReturnAttribution.KIND_CONTACT:
			contact_rows += 1
	_assert_true(fails, "T19 one owner per echo in a ping", not dup)
	_assert_true(fails, "T19 threat echo builds no duplicate object (%d)" % tt_dupes, tt_dupes == 0)
	_assert_true(fails, "T19 contacts received the returns (%d)" % contact_rows, contact_rows >= 2)
	# 临时点全部被最终归属替换（不残留"待关联"幽灵物体）。
	var unresolved: int = 0
	for tmp in c.temp_contacts_snapshot():
		if bool(tmp["awaiting"]):
			unresolved += 1
	_assert_true(fails, "T19 no ghost awaiting temp contact (%d)" % unresolved, unresolved == 0)
	# World 侧：本 Ping 的归属结论与 UI 台账口径一致（同一份观测身份）。
	_assert_true(
		fails, "T19 world attribution consumed exactly once", w.take_attribution().is_empty()
	)


# ---------------- T19b：TT 与普通接触同 Ping 共存、不重复画/不双计 ----------------
func _g06_tt_contact_coexist(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_torpedo_scenario())
	w.auto_measurements = false
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	c.automation = AutomationController.new()
	w.run_steps(30)
	if _fire_enemy_torpedo(w) == null:
		fails.append("T19b enemy torpedo launched")
		return
	_approach_torpedo(w, 1500.0)
	# 第一轮：鱼雷回波归 TT，潜艇/远目标回波保留未归属（同一个矩阵裁决）。
	# 同时把 preferred 指向**威胁航迹**（TT 没有普通航迹可拟合）：待 Apply 必须
	# 落到可拟合的普通接触回波上，绝不能指向 TT 归属的回波。
	c.automation.set_mode(AutomationController.Mode.ASSISTED, w.sim_time)
	var tt_id: String = ""
	var tt_list: Array = w.threat_tracks.tracks()
	if not tt_list.is_empty():
		tt_id = str((tt_list[0] as Dictionary).get("track_id", ""))
	c.preferred_track_id = tt_id
	var ev1: int = _active_return_evidence(w)
	_cycle(w, c)
	var p1: int = w.last_closed_ping_id()
	var tt1: int = _owner_kind_count(c, p1, ActiveReturnAttribution.KIND_THREAT)
	var un1: int = _owner_kind_count(c, p1, ActiveReturnAttribution.KIND_UNASSIGNED)
	_assert_true(
		fails, "T19b ping1 TT + unassigned coexist (TT%d U%d)" % [tt1, un1], tt1 >= 1 and un1 >= 1
	)
	_assert_true(
		fails,
		"T19b threat echo builds no ordinary duplicate (%d)" % _threat_dupes(c, p1),
		_threat_dupes(c, p1) == 0
	)
	_assert_true(
		fails,
		(
			"T19b ping1 fusion exactly once (%d for TT%d+U%d)"
			% [_active_return_evidence(w) - ev1, tt1, un1]
		),
		_active_return_evidence(w) - ev1 == tt1 + un1
	)
	# preferred 命中威胁航迹时，待 Apply 绝不落在无普通航迹的 TT 回波上
	# （否则卡片显示"待 Apply"而 Apply 静默无效 = 把已融合的观测当普通证据）。
	var pend: String = c.pending_track_id()
	_assert_true(fails, "T19b preferred pointed at a TT id (%s)" % tt_id, tt_id.begins_with("TT"))
	_assert_true(
		fails,
		"T19b pending Apply skips the threat-owned echo (%s)" % pend,
		pend != "" and c.tracker.track_by_id(pend) != null
	)
	# 第二轮：普通接触开始吸收回波（TT 候选仍在同一矩阵里参与竞争、不串台）。
	w.run_steps(COOLDOWN_STEPS)
	var ev2: int = _active_return_evidence(w)
	_cycle(w, c)
	var p2: int = w.last_closed_ping_id()
	var ct2: int = _owner_kind_count(c, p2, ActiveReturnAttribution.KIND_CONTACT)
	var tt2: int = _owner_kind_count(c, p2, ActiveReturnAttribution.KIND_THREAT)
	var un2: int = _owner_kind_count(c, p2, ActiveReturnAttribution.KIND_UNASSIGNED)
	_assert_true(fails, "T19b ping2 contacts absorb the returns (M%d)" % ct2, ct2 >= 2)
	_assert_true(fails, "T19b ping2 no entity owned twice", not _owner_dup(c, p2))
	_assert_true(
		fails,
		(
			"T19b ping2 fusion exactly once (%d for TT%d+U%d)"
			% [_active_return_evidence(w) - ev2, tt2, un2]
		),
		_active_return_evidence(w) - ev2 == tt2 + un2
	)
	# 两类候选必须在同一个矩阵里同时可见（PG-05 的核心接线）。
	var kinds: Dictionary = {}
	for dto in w._attribution_targets(w.sim_time, null):
		kinds[str((dto as Dictionary).get("kind", ""))] = true
	_assert_true(
		fails,
		"T19b one matrix holds TT + contact candidates",
		(
			kinds.has(ActiveReturnAttribution.KIND_THREAT)
			and kinds.has(ActiveReturnAttribution.KIND_CONTACT)
		)
	)
	# 台账里 TT 归属行始终携带 TT 标签（不冒充普通接触）。
	var tt_label_ok: bool = true
	for r in c.records_snapshot():
		if str(r.get("owner_kind", "")) == ActiveReturnAttribution.KIND_THREAT:
			if not str(r["track_id"]).begins_with("TT"):
				tt_label_ok = false
	_assert_true(fails, "T19b threat-owned rows keep their TT label", tt_label_ok)


# ---------------- T16b：8 行 UI 窗口 ≠ 证据库容量 ----------------
func _g05_ledger_capacity(fails: Array) -> void:
	var w := World.new()
	w.load_scenario(_mk_two_target_scenario())
	var c := ActivePingController.new()
	c.world = w
	c.tracker = Tracker.new()
	for i in range(20):
		c._append_record(_synthetic_return(i), null, ActiveReturnAttribution.KIND_CONTACT, "P99")
	var rows: Array = c.records_snapshot()
	_assert_eq(fails, "T16b ledger keeps every formal record", str(rows.size()), "20")
	_assert_eq(fails, "T16b panel window is capped at 8", str(c.panel_records().size()), "8")
	# 窗口里是最新的 8 条（不是最早的 8 条）。
	var panel: Array = c.panel_records()
	_assert_eq(
		fails,
		"T16b window shows the newest rows",
		str(panel[panel.size() - 1]["local_return_id"]),
		str(rows[rows.size() - 1]["local_return_id"])
	)
	_assert_true(
		fails,
		"T16b window does not truncate the evidence ledger",
		str(panel[0]["local_return_id"]) != str(rows[0]["local_return_id"])
	)


# ---------------- helpers ----------------
func _tgt(id: String, kind: String, b: float, sb: float, r: float, sr: float) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"bearing_deg": b,
		"bearing_sigma_deg": sb,
		"range_m": r,
		"range_sigma_m": sr,
		"time": 0.0,
	}


func _ret(id: String, b: float, sb: float, r: float, sr: float) -> Dictionary:
	return {
		"id": id,
		"bearing_deg": b,
		"bearing_sigma_deg": sb,
		"range_m": r,
		"range_sigma_m": sr,
		"time": 0.0,
	}


func _assert_owner(
	fails: Array, name: String, owners: Dictionary, rid: String, kind: String, oid: String
) -> void:
	var got: Dictionary = owners.get(rid, {})
	_assert_true(
		fails,
		"%s (got %s/%s)" % [name, str(got.get("kind", "-")), str(got.get("id", "-"))],
		str(got.get("kind", "")) == kind and str(got.get("id", "")) == oid
	)


func _evidence_counts(c: ActivePingController) -> Dictionary:
	var out: Dictionary = {}
	for t in c.tracker.all_tracks():
		out[t.track_id] = t.evidence_count()
	return out


## 某次 Ping（ping_id < 0 = 全部）里按归属类别统计回波台账行数。
func _owner_kind_count(c: ActivePingController, ping_id: int, kind: String) -> int:
	var n: int = 0
	for r in c.records_snapshot():
		if ping_id >= 0 and int(r["ping_id"]) != ping_id:
			continue
		if str(r.get("owner_kind", "")) == kind:
			n += 1
	return n


## 同一次 Ping 里被两个归属条目共用的实体数（应为 0：一对一，绝不共吃同一观测）。
func _owner_dup(c: ActivePingController, ping_id: int) -> bool:
	var seen: Dictionary = {}
	for r in c.records_snapshot():
		if int(r["ping_id"]) != ping_id:
			continue
		var key: String = str(r.get("owner_kind", "")) + ":" + str(r["track_id"])
		if seen.has(key):
			return true
		seen[key] = true
	return false


## TT 归属的回波若又建了同名普通航迹 = 同一物体被画了两份（应为 0）。
func _threat_dupes(c: ActivePingController, ping_id: int) -> int:
	var n: int = 0
	for r in c.records_snapshot():
		if int(r["ping_id"]) != ping_id:
			continue
		if str(r.get("owner_kind", "")) != ActiveReturnAttribution.KIND_THREAT:
			continue
		if c.tracker.track_by_id(str(r["track_id"])) != null:
			n += 1
	return n


## 净化证据流中"主动回波"条目数（World 只为 THREAT 归属 + 未归属回波各写一条）。
func _active_return_evidence(w: World) -> int:
	var n: int = 0
	for e in w.player_evidence:
		if str((e as Dictionary).get("source_mode", "")) == "ACTIVE_RETURN":
			n += 1
	return n


func _fire_enemy_torpedo(w: World) -> Torpedo:
	var e: TruthEntity = w.enemy_ai.entity
	if e == null:
		return null
	var brg: float = (
		NavUtils
		. bearing_to_true(
			float(e.position_east_m),
			float(e.position_north_m),
			float(w.world["own"].position_east_m),
			float(w.world["own"].position_north_m),
		)
	)
	var prog := WeaponProgram.make_bearing_only(brg)
	prog.guidance_authority = WeaponProgram.GuidanceAuthority.WIRE_ONLY
	prog.wire_guidance_enabled = false
	prog.autonomy_enable_mode = WeaponProgram.AutonomyEnableMode.DISTANCE
	prog.autonomy_enable_distance_m = 100.0
	prog.warhead_arm_distance_m = 300.0
	prog.fallback_program = prog.make_default_fallback()
	return w.enemy_weapons.fire_program(
		prog, float(e.position_east_m), float(e.position_north_m), w.sim_time, float(e.depth_m)
	)


func _approach_torpedo(w: World, max_rng: float) -> void:
	for i in range(300):
		w.run_steps(1)
		if w.enemy_weapons.torpedoes.is_empty():
			continue
		var t0: Torpedo = w.enemy_weapons.torpedoes[0]
		var d: float = (
			NavUtils
			. distance(
				float(t0.pos_east_m),
				float(t0.pos_north_m),
				float(w.world["own"].position_east_m),
				float(w.world["own"].position_north_m),
			)
		)
		if d <= max_rng:
			return


## 敌潜艇（被动可探测，用于建立 TT 威胁航迹）+ 本艇的被动阵。
func _mk_torpedo_scenario() -> Dictionary:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = 90811
	sc["enemy_spawn"] = {
		"bearing_min_deg": 0.0,
		"bearing_max_deg": 0.0,
		"range_min_m": 3000.0,
		"range_mode_m": 3000.0,
		"range_max_m": 3000.0,
		"speed_min_kn": 6.0,
		"speed_max_kn": 6.0,
		"min_separation_m": 1000.0,
		"max_generation_attempts": 10,
		"fallback_spawn":
		{
			"position_east_m": 0.0,
			"position_north_m": 3000.0,
			"course_deg": 180.0,
			"speed_kn": 6.0,
			"depth_m": 60.0,
		},
		"doctrine": {"sensor_false_alarm_rate": 0.0},
	}
	return sc


func _synthetic_return(i: int) -> Measurement:
	var m := Measurement.new()
	m.measured_bearing_deg = float(i)
	m.bearing_sigma_deg = 1.0
	m.measured_range_m = 1000.0 + float(i)
	m.range_sigma_m = 50.0
	m.timestamp = float(i)
	m.ping_id = 1
	return m


func _cycle(w: World, c: ActivePingController) -> void:
	_cycle_t(w, c)


## 一个完整 Ping 周期；返回发射时刻（= 观测参考时刻，冷却清空会话后不可再取）。
func _cycle_t(w: World, c: ActivePingController) -> float:
	c.request_ping()
	var t_ref: float = w.ping_emit_time()
	w.run_steps(CYCLE_STEPS)
	c.refresh_panel(null)
	return t_ref


## 两个水面目标（方位/距离分离），共用一个主动阵与同一套声学口径。
func _mk_two_target_scenario() -> Dictionary:
	return {
		"name": "active_return_global",
		"seed": 20260911,
		"dt": DT,
		"duration": 600.0,
		"environment":
		{
			"environment_type": "shallow",
			"sea_state": 2,
			"ambient_noise_by_frequency": {"500": 58.0, "1000": 52.0},
			"own_noise_base_db": 38.0,
			"own_noise_speed_coeff": 1.6,
			"tl_spreading_k": 20.0,
			"tl_absorption_alpha": 0.5,
			"tl_environment_loss": 2.0,
		},
		"own_ship":
		{
			"id": "own",
			"class_id": "attack_sub",
			"side": "blue",
			"platform_type": "submarine",
			"position_east_m": 0.0,
			"position_north_m": 0.0,
			"depth_m": 50.0,
			"course_deg": 0.0,
			"speed_kn": 0.0,
			"turn_rate_deg_s": 0.0,
			"acceleration_kn_s": 0.0,
			"active_sonar":
			{
				"ping_sl_db": 210.0,
				"cooldown_s": 15.0,
				"freq_min_hz": 2000.0,
				"freq_max_hz": 4000.0,
				"array_gain_db": 24.0,
				"sound_speed_m_s": 1500.0,
				"listen_window_s": 15.0,
			},
		},
		"own_acoustic":
		{
			"broadband_base_level_db": 45.0,
			"speed_noise_a": 15.0,
			"speed_noise_n": 2.0,
			"speed_noise_vref_kn": 5.0,
			"cavitation_speed_kn_at_surface": 12.0,
			"cavitation_depth_slope": 1.2,
			"cavitation_extra_db": 12.0,
		},
		"targets": [_mk_target("tgt_a", 20.0, 6000.0), _mk_target("tgt_b", 70.0, 6500.0)],
		"sensors": [],
	}


func _mk_target(id: String, bearing_deg: float, range_m: float) -> Dictionary:
	var b: float = deg_to_rad(bearing_deg)
	return {
		"id": id,
		"class_id": "frigate",
		"side": "red",
		"platform_type": "surface",
		"position_east_m": sin(b) * range_m,
		"position_north_m": cos(b) * range_m,
		"depth_m": 0.0,
		"course_deg": 90.0,
		"speed_kn": 0.0,
		"turn_rate_deg_s": 0.0,
		"acceleration_kn_s": 0.0,
		"acoustic":
		{
			"broadband_base_level_db": 150.0,
			"speed_noise_a": 18.0,
			"speed_noise_n": 2.5,
			"speed_noise_vref_kn": 8.0,
			"active_target_strength_db": 25.0,
		},
	}


func _assert_true(fails: Array, name: String, cond: bool) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _assert_eq(fails: Array, name: String, got: String, want: String) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, got, want])
		print("FAIL %s: got=%s want=%s" % [name, got, want])
	else:
		print("ok   ", name)
