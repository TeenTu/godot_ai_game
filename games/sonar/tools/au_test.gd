extends SceneTree
## au_test.gd — S1-05 三态自动化 无头验收（REQ-AU-01..04，AU-1..5）。
##
## AU-1  MANUAL：绝不产生动作/提案（只有被动槽位簿记）。
## AU-2  ASSISTED：只提案不执行；同一 evidence_id 只提案一次（去重），
##       新证据到来才再提案。
## AU-3  FULL_AUTO：质量门通过即执行 REFIT；ROE auto_refit=false 时拒绝
##       （动作绝不出现在结果里，ROE_DENIED 只记一次）。
## AU-4  槽位去重/计龄：重复 evidence 不推进状态；证据陈旧超时槽位释放
##       （STALE），航迹消失同样释放。
## AU-5  Take Control（PLAYER OVERRIDE）：一 tick 生效——被接管航迹立即
##       停止簿记与动作；模式/ROE/命令全部进 command_log 审计。
##
## godot --headless --path games/sonar --script res://tools/au_test.gd


func _initialize() -> void:
	var fails: Array = []
	_au_1_manual_noop(fails)
	_au_2_assisted_proposals(fails)
	_au_3_full_auto_roe(fails)
	_au_4_dedup_aging(fails)
	_au_5_take_control_audit(fails)
	_finish(fails)


## ---- AU-1：MANUAL 模式绝不自动动作 ----
func _au_1_manual_noop(fails: Array) -> void:
	var c := AutomationController.new()
	c.set_mode(AutomationController.MODE_MANUAL, 0.0)
	var t := _mk_track(1, 5)  # 5 条独立证据（超过质量门）
	var r: Dictionary = c.update(10.0, [t])
	_assert_bool(fails, "AU-1a no actions", r["actions"].is_empty(), true)
	_assert_bool(fails, "AU-1b no proposals", r["proposals"].is_empty(), true)
	_assert_bool(
		fails,
		"AU-1c no auto/propose log",
		not _has_kind(c, "AUTO_REFIT") and not _has_kind(c, "PROPOSE_REFIT"),
		true
	)
	# 被动簿记仍在（槽位分配便于 ASSISTED/FULL_AUTO 接手时去重）。
	_assert_bool(fails, "AU-1d slot still tracked", c.slots.has(t.track_id), true)


## ---- AU-2：ASSISTED 只提案 + 证据去重 ----
func _au_2_assisted_proposals(fails: Array) -> void:
	var c := AutomationController.new()
	c.set_mode(AutomationController.MODE_ASSISTED, 0.0)
	var t := _mk_track(1, 5)
	var r1: Dictionary = c.update(10.0, [t])
	_assert_bool(fails, "AU-2a proposal emitted", r1["proposals"].size() == 1, true)
	_assert_bool(fails, "AU-2b not executed", r1["actions"].is_empty(), true)
	var r2: Dictionary = c.update(20.0, [t])
	_assert_bool(fails, "AU-2c same evidence no re-propose", r2["proposals"].is_empty(), true)
	# 操作员采纳后（mark_fitted）→ FITTED；新证据才再次提案。
	c.mark_fitted(t.track_id, 20.0)
	t.add_measurement(_mk_meas(6, 25.0))
	var r3: Dictionary = c.update(26.0, [t])
	_assert_bool(fails, "AU-2d new evidence re-proposes", r3["proposals"].size() == 1, true)
	# 重复 evidence（镜像共享 id）：不计新证据、不重复提案。
	t.add_measurement(_mk_meas(7, 27.0, "ev6"))
	var r4: Dictionary = c.update(28.0, [t])
	_assert_bool(fails, "AU-2e duplicate evidence ignored", r4["proposals"].is_empty(), true)


## ---- AU-3：FULL_AUTO 执行受 ROE 约束 ----
func _au_3_full_auto_roe(fails: Array) -> void:
	# a) 默认 ROE（auto_refit=true）→ REFIT 执行一次。
	var c := AutomationController.new()
	c.set_mode(AutomationController.MODE_FULL_AUTO, 0.0)
	var t := _mk_track(1, 5)
	var r: Dictionary = c.update(10.0, [t])
	_assert_bool(
		fails,
		"AU-3a refit action emitted",
		r["actions"].size() == 1 and str(r["actions"][0]["action"]) == "REFIT",
		true
	)
	var r2: Dictionary = c.update(12.0, [t])
	_assert_bool(fails, "AU-3a executed once only", r2["actions"].is_empty(), true)
	# b) ROE 关闭自动重拟合 → 拒绝且不执行；拒绝只记一次。
	var c2 := AutomationController.new()
	c2.set_mode(AutomationController.MODE_FULL_AUTO, 0.0)
	c2.set_roe("auto_refit", false, 0.0)
	var t2 := _mk_track(2, 5)
	var r3: Dictionary = c2.update(10.0, [t2])
	_assert_bool(fails, "AU-3b ROE denies refit", r3["actions"].is_empty(), true)
	var denials: int = 0
	for e in c2.command_log:
		if str(e["kind"]) == "ROE_DENIED":
			denials += 1
	c2.update(12.0, [t2])
	var denials2: int = 0
	for e in c2.command_log:
		if str(e["kind"]) == "ROE_DENIED":
			denials2 += 1
	_assert_bool(
		fails, "AU-3b denial logged once (%d)" % denials, denials == 1 and denials2 == 1, true
	)
	# c) 质量门：证据不足（3 < 4）绝不执行。
	var c3 := AutomationController.new()
	c3.set_mode(AutomationController.MODE_FULL_AUTO, 0.0)
	var t3 := _mk_track(3, 3)
	var r4: Dictionary = c3.update(10.0, [t3])
	_assert_bool(fails, "AU-3c gate blocks low evidence", r4["actions"].is_empty(), true)
	# d) fit_gate 直接验证：拟合状态/残差参与质量门（无两腿一刀切条件）。
	var ok: bool = c3.fit_gate(t, 10.0, {"status": "CONVERGED", "rms_deg": 0.3})
	_assert_bool(fails, "AU-3d gate accepts good fit", ok, true)
	_assert_bool(
		fails,
		"AU-3d gate rejects bad status",
		c3.fit_gate(t, 10.0, {"status": "MULTIMODAL"}) == false,
		true
	)
	_assert_bool(
		fails, "AU-3d gate rejects high rms", c3.fit_gate(t, 10.0, {"rms_deg": 2.0}) == false, true
	)


## ---- AU-4：槽位去重与计龄 ----
func _au_4_dedup_aging(fails: Array) -> void:
	var c := AutomationController.new()
	c.set_mode(AutomationController.MODE_FULL_AUTO, 0.0)
	c.slot_timeout_s = 10.0
	c.roe["auto_refit"] = false  # 只考察簿记
	var t := _mk_track(1, 5)
	c.update(5.0, [t])
	_assert_bool(fails, "AU-4a slot assigned", c.slots.has(t.track_id), true)
	# 重复同 evidence 更新不重置计龄时钟（last_new_t 仍为 5）。
	c.update(8.0, [t])
	_assert_bool(
		fails,
		"AU-4b dedup keeps aging clock",
		float(c.slots[t.track_id]["last_new_t"]) == 5.0,
		true
	)
	# 超时 → STALE → 释放。
	c.update(20.0, [t])
	_assert_bool(fails, "AU-4c stale slot released", not c.slots.has(t.track_id), true)
	# 新证据到达重新建槽（STALE 后恢复跟踪）。
	t.add_measurement(_mk_meas(6, 21.0))
	c.update(22.0, [t])
	_assert_bool(fails, "AU-4d fresh evidence re-assigns", c.slots.has(t.track_id), true)
	# 航迹消失 → 释放。
	var r: Dictionary = c.update(30.0, [])
	_assert_bool(fails, "AU-4e vanished track released", not c.slots.has(t.track_id), true)
	_assert_bool(fails, "AU-4e no action on empty tracks", r["actions"].is_empty(), true)


## ---- AU-5：Take Control 一 tick 生效 + 审计 ----
func _au_5_take_control_audit(fails: Array) -> void:
	var c := AutomationController.new()
	c.set_mode(AutomationController.MODE_FULL_AUTO, 0.0)
	var t := _mk_track(1, 5)
	# 接管发生在第一次 update 之前：自动化绝不触碰该航迹（一 tick 生效）。
	c.take_control(t.track_id, 5.0)
	var r: Dictionary = c.update(6.0, [t])
	_assert_bool(fails, "AU-5a override blocks actions", r["actions"].is_empty(), true)
	_assert_bool(fails, "AU-5b override blocks slot", not c.slots.has(t.track_id), true)
	# 释放控制后恢复自动化。
	c.release_control(t.track_id, 7.0)
	var r2: Dictionary = c.update(8.0, [t])
	_assert_bool(fails, "AU-5c release restores automation", r2["actions"].size() == 1, true)
	# 审计：模式切换/接管/释放/自动重拟合全部留痕。
	_assert_bool(fails, "AU-5d mode change audited", _has_kind(c, "MODE"), true)
	_assert_bool(fails, "AU-5d override audited", _has_kind(c, "OVERRIDE"), true)
	_assert_bool(fails, "AU-5d release audited", _has_kind(c, "RELEASE"), true)
	_assert_bool(fails, "AU-5d auto refit audited", _has_kind(c, "AUTO_REFIT"), true)
	_assert_bool(fails, "AU-5d slot assign audited", _has_kind(c, "ASSIGN_SLOT"), true)


## ---- 构造工具 ----


## 建带 n 条独立证据的航迹（evidence_id = ev1..evN，时间 1..n 秒）。
func _mk_track(counter: int, n: int) -> Track:
	var t := Track.create("S", counter, _mk_meas(1, 1.0))
	for i in range(2, n + 1):
		t.add_measurement(_mk_meas(i, float(i)))
	return t


func _mk_meas(mid: int, ts: float, ev: String = "") -> Measurement:
	var m := Measurement.new()
	m.measurement_id = mid
	m.timestamp = ts
	m.evidence_id = ev if ev != "" else "ev%d" % mid
	m.detected = true
	return m


func _has_kind(c: AutomationController, kind: String) -> bool:
	for e in c.command_log:
		if str(e["kind"]) == kind:
			return true
	return false


func _assert_bool(fails: Array, name: String, got: bool, want: bool) -> void:
	if got != want:
		fails.append("%s: got=%s want=%s" % [name, str(got), str(want)])
	else:
		print("  [ok] %s" % name)


func _finish(fails: Array) -> void:
	for f in fails:
		print("AU_FAIL ", f)
	if fails.is_empty():
		print("AU_TEST result=PASS")
	else:
		print("AU_TEST result=FAIL (%d)" % fails.size())
	quit(0 if fails.is_empty() else 1)
