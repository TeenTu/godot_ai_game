extends SceneTree
## S109 Batch 2 — 分类器无 Truth 验收（AT-01）+ 分类线索单元校验。
##
## AT-01：给分类器输入两份数值完全相同、（假装）内核 emission_kind 不同的
## 观测，结果完全一致——证明它不读取事件枚举（结构上观测 DTO 也不允许
## 携带枚举字段）。


func _initialize() -> void:
	var fails: Array = []
	var cls := TorpedoClassifier.new()
	# 观测 A：鱼雷航行噪声的接收特征（宽带 + 双谱线）。
	var a := _obs(1550.0, 2900.0, 1.0, 2)
	# 观测 B：与 A 数值完全相同，但额外塞一个（非法的）枚举字段——
	# 分类器必须视而不见，结果逐字段一致。
	var b: Dictionary = a.duplicate()
	b["emission_kind"] = "TORPEDO_RUNNING_NOISE"
	b["target_id"] = "ET999"
	var ra: Dictionary = cls.classify(a)
	var rb: Dictionary = cls.classify(b)
	_same(fails, ra, rb, "AT-01 classification identical regardless of enum fields")
	# 禁止字段不得出现在结果中。
	for k in ["emission_kind", "target_id"]:
		if ra.has(k):
			fails.append("AT-01 result carries %s" % k)
	# 线索校验：高频短脉冲 → PROBABLE / ACTIVE_PING；宽带瞬态 → SUSPECTED；
	# 爆炸特征 → BLAST_LIKE（非鱼雷）。
	var ping := cls.classify(_obs(12000.0, 4000.0, 0.02, 0))
	_assert(
		fails,
		(
			str(ping["classification_state"]) == "PROBABLE_TORPEDO"
			and TorpedoClassifier.evidence_kind_for(ping) == "ACTIVE_PING"
		),
		"cue HF pulse → PROBABLE/ACTIVE_PING",
	)
	var transient := cls.classify(_obs(1500.0, 8000.0, 0.5, 0))
	_assert(
		fails,
		(
			str(transient["classification_state"]) == "SUSPECTED_TORPEDO"
			and TorpedoClassifier.evidence_kind_for(transient) == "LAUNCH_TRANSIENT"
		),
		"cue wideband transient → SUSPECTED/LAUNCH_TRANSIENT",
	)
	var blast := cls.classify(_obs(500.0, 4000.0, 2.0, 0))
	_assert(
		fails,
		TorpedoClassifier.evidence_kind_for(blast) == "DETONATION",
		"cue blast → DETONATION (not torpedo)",
	)
	var quiet := cls.classify(_obs(3000.0, 1000.0, 1.0, 0))
	_assert(
		fails,
		str(quiet["classification_state"]) == "UNCLASSIFIED",
		"ambiguous features → UNCLASSIFIED",
	)
	_finish(fails)


func _obs(center: float, bw: float, dur: float, tonals: int) -> Dictionary:
	var o := (
		AcousticObservation
		. from_event_features(
			1,
			10.0,
			"t",
			0.0,
			0.0,
			45.0,
			2.0,
			15.0,
			0.9,
			{
				"center_frequency_hz": center,
				"bandwidth_hz": bw,
				"duration_s": dur,
				"tonal_peaks": [] if tonals == 0 else [{"freq_hz": 660.0}, {"freq_hz": 1320.0}],
			},
			"EMISSION_INTERCEPT"
		)
	)
	return o.to_dict()


func _same(fails: Array, ra: Dictionary, rb: Dictionary, name: String) -> void:
	var keys: Array = [
		"p_torpedo", "p_decoy", "p_blast", "p_unknown", "classification_state", "cues", "confidence"
	]
	for k in keys:
		if str(ra.get(k)) != str(rb.get(k)):
			fails.append("%s (differ at %s)" % [name, k])
			print("FAIL ", name, " (differ at ", k, ")")
			return
	print("ok   ", name)


func _assert(fails: Array, cond: bool, name: String) -> void:
	if not cond:
		fails.append(name)
		print("FAIL ", name)
	else:
		print("ok   ", name)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("THREAT-CLASSIFIER-NO-TRUTH TEST PASS")
		quit(0)
	else:
		print("THREAT-CLASSIFIER-NO-TRUTH TEST FAIL (%d)" % fails.size())
		quit(1)
