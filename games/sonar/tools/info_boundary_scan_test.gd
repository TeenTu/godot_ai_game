extends SceneTree
## S109 Batch 1 — 信息边界静态扫描 + DTO 序列化断言（AT-02 / AT-03）。
##
## AT-03：正常运行目录静态扫描禁止读取 Measurement.target_id、ET/PT 前缀或
##        事件枚举分类；白名单仅 SensorAdapter 内部 / 内核事件 schema / 调试。
## AT-02：AcousticObservation / 分类结果 / ThreatTrack 序列化不含 §2.3 禁止字段。

const FORBIDDEN_KEYS := [
	"target_id",
	"internal_token",
	"emitter_internal_ref",
	"emission_kind",
	"true_bearing_deg",
	"true_range_m",
	"position_east_m",
	"position_north_m",
]

# 静态扫描白名单（相对 scripts/ 的路径）：内核事件 schema / 总线 / 净化器
# （己方事实转录与战果判定）/ 禁止字段清单本身。
const EMISSION_KIND_WHITELIST := [
	"scripts/acoustic/acoustic_emission_event.gd",
	"scripts/acoustic/acoustic_emission_bus.gd",
	"scripts/acoustic/emission_sanitizer.gd",
	"scripts/threat/acoustic_observation.gd",
]
# internal_token 仅允许在内核反射体快照与 World 内部结算出现。
const INTERNAL_TOKEN_WHITELIST := [
	"scripts/sonar/active_reflector_snapshot.gd",
	"scripts/world.gd",
	"scripts/threat/acoustic_observation.gd",
]


func _initialize() -> void:
	var fails: Array = []
	_scan_scripts(fails)
	_at02_serialization(fails)
	_finish(fails)


func _scan_scripts(fails: Array) -> void:
	var files: Array = []
	_collect_gd("res://scripts", files)
	for path in files:
		var rel: String = path.replace("res://", "")
		var text: String = _read_text(path)
		if text.is_empty():
			continue
		var lines: Array = text.split("\n")
		for i in range(lines.size()):
			var ln: String = lines[i]
			# 跳过纯注释行。
			var code: String = ln.lstrip(" \t")
			if code.begins_with("#") or code.begins_with("##"):
				continue
			if code.find(".target_id") >= 0:
				fails.append("AT-03 %s:%d reads .target_id" % [rel, i + 1])
			if code.find('begins_with("ET")') >= 0 or code.find('begins_with("PT")') >= 0:
				fails.append("AT-03 %s:%d id-prefix faction guessing" % [rel, i + 1])
			if code.find("emission_kind") >= 0 and not EMISSION_KIND_WHITELIST.has(rel):
				fails.append("AT-03 %s:%d uses emission_kind outside whitelist" % [rel, i + 1])
			if code.find("internal_token") >= 0 and not INTERNAL_TOKEN_WHITELIST.has(rel):
				fails.append("AT-03 %s:%d uses internal_token outside kernel" % [rel, i + 1])
	# DTO 禁止字段常量必须与 §2.3 对齐。
	for k in FORBIDDEN_KEYS:
		if not AcousticObservation.FORBIDDEN_KEYS.has(k):
			fails.append("AT-02 AcousticObservation.FORBIDDEN_KEYS missing %s" % k)


func _collect_gd(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		var full: String = dir_path + "/" + name
		if dir.current_is_dir():
			_collect_gd(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _at02_serialization(fails: Array) -> void:
	# AcousticObservation.to_dict() 结构性无禁止字段。
	var obs := AcousticObservation.from_event_features(
		1,
		10.0,
		"t",
		0.0,
		0.0,
		45.0,
		2.0,
		12.0,
		0.8,
		{
			"center_frequency_hz": 800.0,
			"bandwidth_hz": 4000.0,
			"duration_s": 1.5,
			"tonal_peaks": []
		},
		"EMISSION_INTERCEPT"
	)
	var od: Dictionary = obs.to_dict()
	for k in FORBIDDEN_KEYS:
		if od.has(k):
			fails.append("AT-02 AcousticObservation.to_dict carries %s" % k)
	# 分类结果 / evidence_kind 派生不携带身份。
	var cls := TorpedoClassifier.new()
	var res: Dictionary = cls.classify(od)
	for k in FORBIDDEN_KEYS:
		if res.has(k):
			fails.append("AT-02 ClassificationResult carries %s" % k)
	var kind: String = TorpedoClassifier.evidence_kind_for(res)
	if kind == "":
		fails.append("AT-02 evidence_kind_for returned empty")
	# ThreatTrack（经 ingest）无禁止字段（手工构造净化证据）。
	var ev: Dictionary = od.duplicate()
	ev["bearing_deg"] = float(ev.get("measured_bearing_deg", 0.0))
	ev["evidence_kind"] = "RUNNING_NOISE"
	ev["class_state"] = "PROBABLE_TORPEDO"
	ev["p_torpedo"] = 0.8
	var mgr := ThreatTrackManager.new()
	var tid: String = mgr.ingest(ev, 10.0)
	if tid == "":
		fails.append("AT-02 ThreatTrackManager rejected sanitized torpedo evidence")
	for tr in mgr.tracks():
		for k in FORBIDDEN_KEYS:
			if tr.has(k):
				fails.append("AT-02 ThreatTrack carries %s" % k)
	# UNCLASSIFIED 证据不得建卡（§3.2 状态纪律）。
	var ev2: Dictionary = ev.duplicate()
	ev2["evidence_id"] = 99
	ev2["class_state"] = "UNCLASSIFIED"
	ev2["p_torpedo"] = 0.1
	var mgr2 := ThreatTrackManager.new()
	var tid2: String = mgr2.ingest(ev2, 10.0)
	if tid2 != "":
		fails.append("AT-02 UNCLASSIFIED evidence must not create threat track")
	_finish(fails)


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("INFO-BOUNDARY-SCAN TEST PASS")
		quit(0)
	else:
		for f in fails:
			print("FAIL ", f)
		print("INFO-BOUNDARY-SCAN TEST FAIL (%d)" % fails.size())
		quit(1)
