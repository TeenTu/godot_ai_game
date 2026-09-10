extends SceneTree
## s1_11_batch2_test.gd — S1-11 Batch 2 验收：ASSIST 默认 + 来袭鱼雷强制自动化。
##
##   B2-56 (AT-56) ASSIST 为默认模式，连续自动 Mark/关联/分类/增量 Fit；
##   B2-57 (AT-57) 自动 Fit 只在 evidence_revision 变化时请求，切换/无新证据不重算；
##   B2-59 (AT-59) TT 监视在 MANUAL/ASSIST/FULL_AUTO 三模式都运行，不可用户关闭；
##   B2-65 (AT-65) 自动化可漏检/保持歧义，绝不伪造确定答案；
##   B2-安全     自动化只给建议：不自动提交 System Solution、不自动释放武器（除 ROE）。


func _initialize() -> void:
	var fails: Array = []
	_b2_56_default(fails)
	_b2_56_chain(fails)
	_b2_57_refit(fails)
	_b2_59_threat_all_modes(fails)
	_b2_65_no_fake_certainty(fails)
	_b2_no_autofire(fails)
	_finish(fails)


# ---------------- AT-56：默认 ASSISTED ----------------
func _b2_56_default(fails: Array) -> void:
	var c := AutomationController.new()
	_assert(
		fails,
		c.mode == AutomationController.Mode.ASSISTED,
		"B2-56 AutomationController defaults to ASSISTED"
	)
	_assert(
		fails,
		c.mode_name() == "ASSISTED",
		"B2-56 default mode name is ASSISTED (%s)" % c.mode_name()
	)


# ---------------- AT-56：ASSIST 自动 Mark/关联/分类 ----------------
func _b2_56_chain(fails: Array) -> void:
	var tr := Tracker.new()
	var rt := AssistRuntime.new(tr)
	var meas: Array = [
		_mk_passive("p1", 20.0, 0.0),
		_mk_passive("p2", 21.0, 30.0),
		_mk_passive("p3", 22.0, 60.0),
		_mk_passive("p4", 23.0, 90.0),
	]
	var n: int = rt.consume_passive(meas, AutomationController.Mode.ASSISTED, 90.0)
	_assert(fails, n > 0, "B2-56 ASSIST auto-consumes passive detections (marks=%d)" % n)
	_assert(fails, tr.count() == 1, "B2-56 cross-frame association keeps one track")
	rt.classify_tracks(tr.all_tracks(), 90.0)
	var t: Track = tr.all_tracks()[0]
	_assert(
		fails,
		not t.classification_assessment.is_empty(),
		"B2-56 ASSIST refreshes classification assessment"
	)
	_assert(
		fails,
		t.classification_assessment.has("evidence_summary"),
		"B2-56 classification carries an evidence summary"
	)
	# MANUAL：不自动 Mark（游标仍推进，不丢测量）。
	var tr2 := Tracker.new()
	var rt2 := AssistRuntime.new(tr2)
	var stream: Array = [_mk_passive("q1", 10.0, 0.0)]
	var m2: int = rt2.consume_passive(stream, AutomationController.Mode.MANUAL, 0.0)
	_assert(fails, m2 == 0 and tr2.count() == 0, "B2-56 MANUAL never auto-marks")
	stream.append(_mk_passive("q2", 11.0, 10.0))
	var m3: int = rt2.consume_passive(stream, AutomationController.Mode.ASSISTED, 10.0)
	_assert(fails, m3 > 0, "B2-56 same runtime resumes auto-marking after switching to ASSIST")
	# 主动回波不由本运行器消费（避免与 ActivePingController 双喂）。
	var tr3 := Tracker.new()
	var rt3 := AssistRuntime.new(tr3)
	var active := _mk_passive("act1", 5.0, 0.0)
	active.measurement_type = "ACTIVE_RANGE_BEARING"
	rt3.consume_passive([active], AutomationController.Mode.ASSISTED, 0.0)
	_assert(fails, tr3.count() == 0, "B2-56 assist runtime ignores active returns (no double feed)")


# ---------------- AT-57：自动 Fit 只在 revision 变化时请求 ----------------
func _b2_57_refit(fails: Array) -> void:
	var tr := Tracker.new()
	var t: Track = tr.mark(_mk_passive("r1", 30.0, 0.0), "S")
	for i in range(2, 5):
		t.add_measurement(_mk_passive("r%d" % i, 30.0 + float(i), float(i) * 30.0))
	var rt := AssistRuntime.new(tr)
	var reqs: Array = rt.refit_requests(tr.all_tracks())
	_assert(fails, reqs.has(t.track_id), "B2-57 track with enough evidence requests a fit")
	rt.mark_fitted(t)
	_assert(
		fails,
		rt.refit_requests(tr.all_tracks()).is_empty(),
		"B2-57 after fitting, no repeat request for same revision (no resample)"
	)
	t.add_measurement(_mk_passive("r5", 36.0, 150.0))
	_assert(
		fails,
		rt.refit_requests(tr.all_tracks()).has(t.track_id),
		"B2-57 new evidence increments revision -> refit requested again"
	)
	# 证据不足的航迹不请求。
	var thin := Track.create("S", 10, _mk_passive("t1", 10.0, 0.0))
	var rt2 := AssistRuntime.new(Tracker.new())
	var reqs2: Array = rt2.refit_requests([thin])
	_assert(fails, reqs2.is_empty(), "B2-57 track below evidence gate never requests fit")


# ---------------- AT-59：TT 监视三模式强制运行 ----------------
func _b2_59_threat_all_modes(fails: Array) -> void:
	var tac := ThreatAutomationController.new()
	var store := ThreatTrackManager.new()
	tac.bind_store(store)
	_assert(fails, tac.always_enabled, "B2-59 threat automation is always enabled")
	_assert(fails, not tac.user_can_disable, "B2-59 threat automation cannot be user-disabled")
	_assert(
		fails,
		not tac.auto_fire and not tac.auto_ping and not tac.auto_decoy,
		"B2-59 threat automation never performs tactical actions"
	)
	var c := AutomationController.new()
	var modes: Array = [
		AutomationController.Mode.MANUAL,
		AutomationController.Mode.ASSISTED,
		AutomationController.Mode.FULL_AUTO,
	]
	var created: int = 0
	for i in range(modes.size()):
		c.set_mode(modes[i], float(i))
		var touched: Array = tac.process_evidence(
			[_torp_ev("t%d" % i, 20.0 + float(i) * 40.0)], float(i)
		)
		created += touched.size()
	_assert(
		fails,
		created == 3 and store.tracks().size() == 3,
		"B2-59 threat tracks built in all three modes (%d / %d)" % [created, store.tracks().size()]
	)
	# 关闭普通自动化的开关不影响 TT：本类不引用 AutomationController 的模式/开关。
	var src := FileAccess.open(
		"res://scripts/threat/threat_automation_controller.gd", FileAccess.READ
	)
	var txt: String = src.get_as_text() if src != null else ""
	_assert(
		fails,
		txt.find("AutomationController.Mode") < 0 and txt.find("set_mode") < 0,
		"B2-59 threat automation is decoupled from the normal autonomy switch"
	)


# ---------------- AT-65：不伪造确定答案 ----------------
func _b2_65_no_fake_certainty(fails: Array) -> void:
	var tr := Tracker.new()
	var rt := AssistRuntime.new(tr)
	# 单次弱检测：分类不得给出高可信身份。
	rt.consume_passive([_mk_passive("w1", 50.0, 0.0)], AutomationController.Mode.ASSISTED, 0.0)
	rt.classify_tracks(tr.all_tracks(), 0.0)
	var t: Track = tr.all_tracks()[0]
	_assert(
		fails,
		str(t.classification_assessment.get("state", "")) != TrackClassification.STATE_CLASSIFIED,
		"B2-65 single noisy detection never becomes high-confidence"
	)
	# miss 样本不建航迹（Pd 数值不算已探测）。
	var tr2 := Tracker.new()
	var rt2 := AssistRuntime.new(tr2)
	var miss := _mk_passive("m1", 30.0, 0.0)
	miss.detected = false
	rt2.consume_passive([miss], AutomationController.Mode.ASSISTED, 0.0)
	_assert(fails, tr2.count() == 0, "B2-65 undetected samples never create a track")


# ---------------- 自动化只给建议 ----------------
func _b2_no_autofire(fails: Array) -> void:
	var c := AutomationController.new()
	_assert(fails, not bool(c.roe.get("auto_fire", false)), "B2-roe auto_fire is off by default")
	c.set_mode(AutomationController.Mode.FULL_AUTO, 0.0)
	var tr := Tracker.new()
	var t := Track.create("S", 11, _mk_passive("x1", 25.0, 0.0))
	for i in range(2, 5):
		t.add_measurement(_mk_passive("x%d" % i, 25.0 + float(i), float(i) * 30.0))
	var r: Dictionary = c.update(0.0, [t])
	for a in r.get("actions", []):
		var act: String = str(a.get("action", ""))
		_assert(fails, act == "REFIT", "B2-safe automation action is only REFIT (got %s)" % act)
	# ASSIST 模式只提案，不执行。
	c.set_mode(AutomationController.Mode.ASSISTED, 1.0)
	var r2: Dictionary = c.update(2.0, [t])
	_assert(
		fails,
		r2.get("actions", []).is_empty(),
		"B2-safe ASSIST produces proposals, never executes actions"
	)


# ---------------- helpers ----------------
func _mk_passive(eid: String, brg: float, t: float) -> Measurement:
	var m := Measurement.new()
	m.evidence_id = eid
	m.measured_bearing_deg = brg
	m.bearing_sigma_deg = 1.5
	m.timestamp = t
	m.detected = true
	return m


func _torp_ev(eid: String, brg: float) -> Dictionary:
	return {
		"side_hint": "INTERCEPT",
		"evidence_id": eid,
		"evidence_kind": "RUNNING_NOISE",
		"class_state": "PROBABLE_TORPEDO",
		"bearing_deg": brg,
		"bearing_sigma_deg": 3.0,
		"p_torpedo": 0.7,
		"confidence": 0.7,
	}


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("S1-11 BATCH2 TEST PASS")
		quit(0)
	else:
		print("S1-11 BATCH2 TEST FAIL (%d)" % fails.size())
		quit(1)
