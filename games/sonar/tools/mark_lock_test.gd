extends SceneTree
## P0-A 回归：Mark 锁定唯一状态源与主动回波频谱类型契约。
##
## 对应需求文档 §3（MK-01..MK-06）与 §5 PG-02，验收 T01..T06：
##   MK-01 唯一状态源（MarkFlow 持有，面板只渲染快照，业务 ID 走 metadata）
##   MK-02 锁定目的组优先于去重分支与自动关联；不抢走当前查看接触
##   MK-03 同一物理证据重复点击不增加 evidence，不悄悄切组；可显式改绑并撤销
##   MK-04 数据区任意落点都记录（不查峰值/SE/Pd/8° 门）；A/B 同 evidence
##   MK-05 LOCKED 无组时首点即建组；原组失效保留待处理点，不静默转投
##   MK-06 SUGGEST 先纯计算候选，接受前不改动任何其他航迹
##   PG-02 混合数值/字典频谱归一化；空谱线合法；主动谱线不带 Truth 电平
##
## 纪律：断言打在"证据条数 / 归属 / 修订号"这些可观测事实上，并做负向对照
## （见各用例注释）。

const OP_SCRIPT := "res://scripts/sonar/operator_sonar.gd"


func _initialize() -> void:
	var fails: Array = []
	_mk01_single_source(fails)
	_mk02_lock_priority(fails)
	_mk03_duplicate_and_move(fails)
	_mk04_free_click_and_pair(fails)
	_mk05_pending_and_autogroup(fails)
	_mk06_suggest_pure(fails)
	_pg02_spectral_dto(fails)
	_finish(fails)


# ---------------------------------------------------------------- MK-01
func _mk01_single_source(fails: Array) -> void:
	var env: Dictionary = _mk_env("BOW")
	var flow: MarkFlow = env["flow"]
	var panel: MarkGroupPanel = MarkGroupPanel.new()
	panel.flow = flow
	flow.select_group(str((env["tb"] as Track).track_id))
	panel.set_groups([str((env["ta"] as Track).track_id), str((env["tb"] as Track).track_id)])
	var snap: Dictionary = flow.status_snapshot("M02")
	_assert(fails, str(snap["view_id"]) == "M02", "MK-01 snapshot keeps 当前查看 separate")
	_assert(
		fails,
		str(snap["write_id"]) == str((env["tb"] as Track).track_id) and bool(snap["locked"]),
		"MK-01 snapshot reports locked write group",
	)
	# 面板下拉必须用 metadata 保存业务 ID：显示文本改了也不会认错组。
	var md_ok: bool = true
	for i in range(1, panel._opt_group.get_item_count()):
		if str(panel._opt_group.get_item_metadata(i)) != str(panel._opt_group.get_item_text(i)):
			md_ok = false
	_assert(fails, md_ok, "MK-01 dropdown carries business id in metadata, not display text")
	_assert(
		fails,
		panel._opt_group.get_item_metadata(0) == "",
		"MK-01 auto item has empty id metadata",
	)
	# 地图菜单改组 → 面板渲染同一状态（旧实现各存一份会互相覆盖）。
	flow.select_group(str((env["ta"] as Track).track_id))
	panel.set_groups([str((env["ta"] as Track).track_id), str((env["tb"] as Track).track_id)])
	_assert(
		fails,
		(
			str(panel._opt_group.get_item_metadata(panel._opt_group.selected))
			== str((env["ta"] as Track).track_id)
		),
		"MK-01 panel renders flow state after external group change",
	)
	# 源码护栏：面板不得自持这两个业务状态。
	var panel_src: String = (load("res://scripts/ui/mark_group_panel.gd") as Script).source_code
	_assert(
		fails,
		(
			panel_src.find("var active_group_id: String") < 0
			and panel_src.find("var association_mode: String") < 0
		),
		"MK-01 panel keeps no second copy of active_group_id / association_mode",
	)
	var ui_src: String = (load("res://scripts/ui/main_ui.gd") as Script).source_code
	_assert(
		fails,
		ui_src.find("mark_flow.select_group(") >= 0 and ui_src.find("_lbl_mark_lock") >= 0,
		"MK-01 lock destination is routed through flow and shown on every page",
	)
	panel.free()


# ---------------------------------------------------------------- MK-02
func _mk02_lock_priority(fails: Array) -> void:
	var env: Dictionary = _mk_env("BOW")
	var flow: MarkFlow = env["flow"]
	var ta: Track = env["ta"]
	var tb: Track = env["tb"]
	flow.select_group(ta.track_id)
	var ta_n: int = ta.evidence_count()
	var tr_n: int = int(env["tracker"].count())
	# 当前"查看"的是 M02；锁定目的组是 M01。
	# ① 新点：落到 M01，且**不能**抢走查看（select 必须为空）。
	var r1: Dictionary = flow.handle_mark(140.0, false, _row(140.0, "r1"), tb.track_id)
	_assert(
		fails,
		r1.get("track") == ta and str(r1.get("select", "")) == "",
		"MK-02 locked destination wins over auto association and does not steal the view",
	)
	_assert(fails, ta.evidence_count() == ta_n + 1, "MK-02 new point lands on the locked group")
	# ② 再点同一个物理证据：不新建证据、不夺查看、给出原归属。
	var r2: Dictionary = flow.handle_mark(140.0, false, _row(140.0, "r1"), tb.track_id)
	_assert(
		fails,
		str(r2.get("select", "")) == "" and str(r2.get("existing_owner", "")) == ta.track_id,
		"MK-02 duplicate click reports owner instead of switching view",
	)
	_assert(fails, ta.evidence_count() == ta_n + 1, "MK-02 duplicate click adds no evidence")
	# ③ 噪声点（无峰）：仍落到锁定组，仍是人工假设。
	var r3: Dictionary = flow.handle_mark(200.0, false, _row(200.0, "r3", false), "")
	_assert(
		fails,
		r3.get("track") == ta and str(r3.get("select", "")) == "",
		"MK-02 noise click still writes the locked group",
	)
	_assert(fails, int(env["tracker"].count()) == tr_n, "MK-02 lock keeps track count stable")
	# ④ 锁定组失效（MERGED）→ 不静默转投别的组。
	ta.state = Track.TrackState.MERGED
	var r4: Dictionary = flow.handle_mark(220.0, false, _row(220.0, "r4", false), "")
	_assert(
		fails,
		bool(r4.get("pending", false)) and r4.get("track") == null,
		"MK-02 dead lock group keeps the mark pending instead of rerouting",
	)
	_assert(
		fails, tb.evidence_count() == 0, "MK-02 pending mark never silently joins another group"
	)
	ta.state = Track.TrackState.ACTIVE
	flow.attach_pending(tb.track_id)
	_assert(fails, tb.evidence_count() == 1, "MK-02 pending mark attaches to the player's group")


# ---------------------------------------------------------------- MK-03
func _mk03_duplicate_and_move(fails: Array) -> void:
	var env: Dictionary = _mk_env("BOW")
	var flow: MarkFlow = env["flow"]
	var ta: Track = env["ta"]
	var tb: Track = env["tb"]
	var world: World = env["world"]
	# 先让 M02 拥有一条证据（点一点、锁 M02）。
	flow.select_group(tb.track_id)
	flow.handle_mark(200.0, false, _row(200.0, "dup1"), "")
	_assert(fails, tb.evidence_count() == 1, "MK-03 setup: evidence owned by M02")
	var meas_n: int = world.measurements.size()
	var ev_id: String = (tb.measurement_history[0] as Measurement).evidence_id
	# 切到 M01 后点同一点：不跳 M02、不新增证据、给"移入当前组"入口。
	flow.select_group(ta.track_id)
	var dup: Dictionary = flow.handle_mark(200.0, false, _row(200.0, "dup1"), "")
	_assert(fails, str(dup.get("select", "")) == "", "MK-03 duplicate click does not jump to owner")
	_assert(fails, tb.evidence_count() == 1, "MK-03 duplicate click adds no independent evidence")
	_assert(fails, world.measurements.size() == meas_n, "MK-03 world measurement stream unchanged")
	_assert(fails, bool(dup.get("can_move_to_lock", false)), "MK-03 explicit move entry offered")
	# 显式改绑：同一 evidence_id 换组，条数守恒。
	var mv: Dictionary = flow.move_last_clicked_to_lock()
	_assert(
		fails,
		bool(mv.get("dirty", false)) and tb.evidence_count() == 0 and ta.evidence_count() == 1,
		"MK-03 explicit move rebinds to the locked group",
	)
	_assert(
		fails,
		(ta.measurement_history[0] as Measurement).evidence_id == ev_id,
		"MK-03 rebind keeps the same evidence_id (not a new observation)",
	)
	_assert(fails, world.measurements.size() == meas_n, "MK-03 rebind adds no new measurement")
	# 可撤销：整组回原组。
	var un: Dictionary = flow.undo_last_edit()
	_assert(
		fails,
		bool(un.get("dirty", false)) and tb.evidence_count() == 1 and ta.evidence_count() == 0,
		"MK-03 rebind is undoable",
	)
	# 纯人工点不冒充探测成功：不给分类升级提供依据。
	var man: Dictionary = flow.handle_mark(250.0, false, _row(250.0, "noise_only", false), "")
	var t_manual: Track = man.get("track", null)
	_assert(
		fails,
		t_manual != null and (t_manual.measurement_history[-1] as Measurement).manual_hypothesis,
		"MK-03 free click is flagged as a manual hypothesis",
	)
	var cls: Dictionary = TrackClassification.assess(t_manual, 10.0, [])
	_assert(
		fails,
		(
			(
				str(cls.get("state", TrackClassification.STATE_UNKNOWN))
				== TrackClassification.STATE_UNKNOWN
			)
			and int(cls.get("evidence_count", -1)) == 0
		),
		"MK-03 manual-only evidence does not feed classification (evidence_count=0)",
	)


# ---------------------------------------------------------------- MK-04
func _mk04_free_click_and_pair(fails: Array) -> void:
	var env: Dictionary = _mk_env("TOWED")
	var flow: MarkFlow = env["flow"]
	var ta: Track = env["ta"]
	flow.select_group(ta.track_id)
	# 与组内最新方位差 140°：远超 8° 自动关联门，仍必须记录（门只给自动关联评分）。
	var far: Dictionary = flow.handle_mark(330.0, false, _row(330.0, "far", false), "")
	_assert(
		fails,
		far.get("track") == ta and ta.evidence_count() == 1,
		"MK-04 far-bearing manual mark is recorded (8-deg gate is auto-only)",
	)
	# A/B 镜像：一次点击产生同一 evidence_id 的两支，整体进同一组；
	# 物理证据只算一条（不能因画面画了两支就双计）。
	var pair_row: Dictionary = _row(60.0, "pair", false)
	pair_row["array_id"] = "TOWED"
	pair_row["array_heading"] = 0.0
	pair_row["peaks"] = [_pair_peak(60.0)]
	var pair_res: Dictionary = flow.handle_mark(60.0, false, pair_row, "")
	var t: Track = pair_res.get("track", null)
	_assert(fails, t == ta, "MK-04 A/B pair lands on the locked group")
	_assert(
		fails,
		ta.measurement_history.size() == 3 and ta.evidence_count() == 2,
		"MK-04 A/B pair keeps both branches in one group as a single physical evidence",
	)
	# 改绑必须整组原子：不能只搬走 A 支、把 B 支留在原组。
	var tb: Track = env["tb"]
	var pair_ev: String = (ta.measurement_history[1] as Measurement).evidence_id
	flow.select_group(tb.track_id)
	var dup: Dictionary = flow.handle_mark(60.0, false, pair_row, "")
	_assert(
		fails,
		bool(dup.get("can_move_to_lock", false)) and str(dup.get("select", "")) == "",
		"MK-04 re-clicking the pair offers an explicit move without stealing the view",
	)
	var mv: Dictionary = flow.move_last_clicked_to_lock()
	_assert(
		fails,
		(
			bool(mv.get("dirty", false))
			and tb.measurement_history.size() == 2
			and ta.measurement_history.size() == 1
		),
		"MK-04 rebinding an A/B pair moves both branches atomically",
	)
	_assert(
		fails,
		tb.evidence_count() == 1,
		"MK-04 moved pair still counts as one physical evidence",
	)
	_assert(
		fails,
		(
			(tb.measurement_history[0] as Measurement).evidence_id == pair_ev
			and (tb.measurement_history[1] as Measurement).evidence_id == pair_ev
		),
		"MK-04 moved branches keep the same shared evidence_id",
	)


# ---------------------------------------------------------------- MK-05
func _mk05_pending_and_autogroup(fails: Array) -> void:
	var env: Dictionary = _mk_env("BOW")
	var flow: MarkFlow = env["flow"]
	flow.association_mode = MarkFlow.ASSOC_LOCKED
	flow.active_group_id = ""
	var before: int = int(env["tracker"].count())
	var r: Dictionary = flow.handle_mark(70.0, false, _row(70.0, "auto1", false), "")
	_assert(
		fails,
		flow.active_group_id != "" and r.get("track") != null,
		"MK-05 first locked click creates and locks a group",
	)
	_assert(
		fails,
		int(env["tracker"].count()) == before + 1,
		"MK-05 auto-created group is exactly one track",
	)
	var ag: String = flow.active_group_id
	var t: Track = r.get("track", null)
	# 后续点击不再换组（旧实现"显示锁定却逐次自动换组"）。
	flow.handle_mark(75.0, false, _row(75.0, "auto2", false), "")
	_assert(fails, flow.active_group_id == ag, "MK-05 lock destination stays put across clicks")
	_assert(fails, t.evidence_count() == 2, "MK-05 both clicks landed on the same locked group")
	_assert(fails, int(env["tracker"].count()) == before + 1, "MK-05 no per-click auto group churn")
	# 组不可用 → 待处理点 + 玩家显式恢复。
	flow.active_group_id = "M99"
	var pend: Dictionary = flow.handle_mark(80.0, false, _row(80.0, "auto3", false), "")
	_assert(fails, bool(pend.get("pending", false)), "MK-05 missing group keeps the mark pending")
	_assert(fails, flow.has_pending(), "MK-05 pending mark is queryable for the UI entry")
	var rec: Dictionary = flow.new_group_from_pending()
	_assert(
		fails,
		bool(rec.get("dirty", false)) and not flow.has_pending(),
		"MK-05 pending mark can be recovered into a fresh group",
	)


# ---------------------------------------------------------------- MK-06
func _mk06_suggest_pure(fails: Array) -> void:
	var env: Dictionary = _mk_env("BOW")
	var flow: MarkFlow = env["flow"]
	var ta: Track = env["ta"]
	var tb: Track = env["tb"]
	flow.set_mode(MarkFlow.ASSOC_SUGGEST)
	flow.select_group(tb.track_id)
	# ta 有一条 200° 证据（充当"建议候选"），tb 有一条 200° 证据（目的地）。
	flow.set_mode(MarkFlow.ASSOC_LOCKED)
	flow.handle_mark(200.0, false, _row(200.0, "sug_a"), "")
	flow.select_group(ta.track_id)
	flow.handle_mark(200.0, false, _row(200.0, "sug_b"), "")
	flow.select_group(tb.track_id)
	var ta_n: int = ta.evidence_count()
	var ta_rev: int = int(ta.get("evidence_revision"))
	flow.set_mode(MarkFlow.ASSOC_SUGGEST)
	var sug: Dictionary = flow.handle_mark(202.0, false, _row(202.0, "sug_c"), "")
	var cand: String = flow.pending_suggestion_track_id()
	_assert(fails, cand != "" and cand != tb.track_id, "MK-06 SUGGEST proposes another group")
	_assert(
		fails,
		str(sug.get("status", "")).find("Apply") >= 0,
		"MK-06 SUGGEST asks for Apply before rebinding",
	)
	_assert(
		fails,
		ta.evidence_count() == ta_n and int(ta.get("evidence_revision")) == ta_rev,
		"MK-06 suggestion does not touch the candidate track before Apply",
	)
	# 拒绝：只清建议，落点留在目的地。
	var rej: Dictionary = flow.reject_suggestion()
	_assert(
		fails, not bool(rej.get("dirty", false)), "MK-06 rejecting a suggestion changes nothing"
	)
	_assert(
		fails,
		ta.evidence_count() == ta_n and tb.evidence_count() == 2,
		"MK-06 rejected suggestion leaves every group exactly as it was",
	)
	_assert(
		fails, flow.pending_suggestion_track_id() == "", "MK-06 rejection clears the suggestion"
	)


# ---------------------------------------------------------------- PG-02
func _pg02_spectral_dto(fails: Array) -> void:
	# 空谱线合法：不是"确定不匹配"。
	_assert(
		fails,
		ActiveReturnBatch.spectral_penalty([], [300.0]) == 0.0,
		"PG-02 empty spectrum is legal (no mismatch penalty)",
	)
	_assert(
		fails,
		ActiveReturnBatch.spectral_penalty([{"freq_hz": 300.0}], []) == 0.0,
		"PG-02 one-sided spectrum is legal",
	)
	# 混合类型：字典 + 纯数值，不得抛错，且同型可比。
	_assert(
		fails,
		ActiveReturnBatch.spectral_penalty([{"freq_hz": 300.0, "level_db": 40.0}], [300.0]) == 0.0,
		"PG-02 dictionary vs numeric spectrum compares without type error",
	)
	_assert(
		fails,
		ActiveReturnBatch.spectral_penalty([{"freq_hz": 300.0}], [900.0]) > 0.0,
		"PG-02 genuinely disjoint spectra still get the mismatch penalty",
	)
	var norm: Array = Measurement.spectral_freqs(
		[{"freq_hz": 300.0}, 500.0, {"bogus": 1}, "x", null]
	)
	_assert(
		fails,
		norm.size() == 2 and float(norm[0]) == 300.0 and float(norm[1]) == 500.0,
		"PG-02 normalizer keeps only finite freq_hz (%s)" % str(norm),
	)
	# 真跑一次混合输入的一对一分配：旧实现会在 float(Dictionary) 上炸掉整条链。
	var returns: Array = [
		{
			"id": "e1",
			"bearing": 10.0,
			"sigma": 1.0,
			"range": 1000.0,
			"range_sigma": 50.0,
			"time": 10.0,
			"freqs": [{"freq_hz": 300.0, "level_db": 40.0, "snr_db": 12.0}]
		},
	]
	var targets: Array = [
		{
			"id": "T1",
			"bearing": 11.0,
			"sigma": 1.0,
			"range": 1010.0,
			"range_sigma": 60.0,
			"time": 10.2,
			"freqs": [300.0]
		},
	]
	var res: Dictionary = ActiveReturnBatch.assign(returns, targets)
	_assert(
		fails,
		str(res.get("assignments", {}).get("e1", "")) == "T1",
		"PG-02 mixed-type batch association still assigns (no float(Dictionary))",
	)
	# 主动谱线不得携带 Truth 画像电平（接收端带噪估计）。
	var env: Dictionary = _mk_env("BOW")
	var gen: RefCounted = load("res://scripts/measurement_generator.gd").new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	gen.setup(rng, env["env_model"])
	var own: TruthEntity = env["own"]
	var tgt: TruthEntity = env["tgt"]
	tgt.position_east_m = 400.0
	tgt.position_north_m = 0.0
	var ac: RefCounted = load("res://scripts/acoustic_profile.gd").new()
	ac.broadband_base_level_db = 150.0
	ac.active_target_strength_db = 12.0
	ac.tonal_lines = [{"freq_hz": 300.0, "level_db": 200.0}]
	var any_detected: bool = false
	var carries_truth: bool = false
	for i in range(40):
		var m: Measurement = gen.generate_active(
			own, tgt, ac, env["sensor"], 240.0, 10.0 + float(i) * 0.5
		)
		if not m.detected:
			continue
		any_detected = true
		for line in m.detected_frequencies:
			if not (line is Dictionary):
				continue
			if float((line as Dictionary).get("level_db", 0.0)) == 200.0:
				carries_truth = true
	_assert(fails, any_detected, "PG-02 active echo produced at short range")
	_assert(
		fails,
		not carries_truth,
		"PG-02 active tonal lines carry a received estimate, not the truth level"
	)


# ---------------------------------------------------------------- 工具
func _mk_env(array_id: String) -> Dictionary:
	var own := TruthEntity.new()
	own.position_east_m = 0.0
	own.position_north_m = 0.0
	own.course_deg = 0.0
	own.depth_m = 50.0
	own.speed_kn = 4.0
	var tgt := TruthEntity.new()
	tgt.position_east_m = 8000.0
	tgt.position_north_m = 0.0
	tgt.depth_m = 50.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260911
	var op: RefCounted = load(OP_SCRIPT).new()
	op.setup({"own": own, "rng": rng})
	var tr := Tracker.new()
	var world := World.new()
	var ta: Track = tr.create_empty_track()
	var tb: Track = tr.create_empty_track()
	var flow := MarkFlow.new()
	flow.tracker = tr
	flow.op = op
	flow.world = world
	var env_model: RefCounted = load("res://scripts/environment_model.gd").new()
	var sensor: RefCounted = load("res://scripts/sensor_array.gd").new()
	sensor.set_rng(rng)
	return {
		"own": own,
		"tgt": tgt,
		"op": op,
		"tracker": tr,
		"world": world,
		"flow": flow,
		"ta": ta,
		"tb": tb,
		"array_id": array_id,
		"env_model": env_model,
		"sensor": sensor,
	}


## 构造一次"瀑布行点击"上下文。with_peak=false 表示玩家在数据区自由落点
## （无实测峰）——MK-04 要求这种点击同样成立。
func _row(brg: float, tag: String, with_peak: bool = true) -> Dictionary:
	var row: Dictionary = {
		"array_id": "BOW",
		"t": 20.0,
		"course": 0.0,
		"own_e": 0.0,
		"own_n": 0.0,
		"row_id": "row_%s" % tag,
	}
	if with_peak:
		row["peaks"] = [
			{
				"bearing_deg": brg,
				"peak_id": "p00",
				"se_db": 14.0,
				"snr_db": 14.0,
				"freqs_hz": [300.0]
			}
		]
	else:
		row["peaks"] = []
	return row


## 带左右舷镜像歧义的谱图峰（拖曳阵一次物理到达的 A/B 两支）。
func _pair_peak(brg: float) -> Dictionary:
	return {
		"bearing_deg": brg,
		"peak_id": "p00",
		"se_db": 14.0,
		"snr_db": 14.0,
		"freqs_hz": [300.0],
		"ambiguous_pair_id": "pair_0001",
		"ambiguity_branch": 1,
	}


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("MARK-LOCK P0-A TEST PASS")
		quit(0)
	else:
		print("MARK-LOCK P0-A TEST FAIL (%d)" % fails.size())
		quit(1)
