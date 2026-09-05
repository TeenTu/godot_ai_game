class_name AlertPanel
extends VBoxContainer
## alert_panel.gd — 鱼雷告警/战果证据面板（S1-07 §11.5/§10.4，Commit 11）。
##
## 数据源：world.player_evidence（EmissionSanitizer 净化后的证据队列——
## POSSIBLE_LAUNCH_TRANSIENT / POSSIBLE_TORPEDO / TORPEDO_ACTIVE_PING /
## DECOY_DEPLOYED / DETONATION_HEARD / 本艇武器事实）。每条显示时间、方位、
## 置信度；绝不把"可能"提示成确定事实（UI-06），绝无 target_id（UI-07）。
## 己方武器爆炸 → 经 classify_detonation（证据 + 玩家航迹方位）标注
## PROBABLE_HIT / PROBABLE_KILL；本面板绝不显示 CONFIRMED KILL。

const MAX_ROWS: int = 6

var highlight_evidence_id: int = -1  # P0-07.4：地图 LOB 点击 → 同 id 高亮

var _world: World = null
var _get_track_bearings: Callable = Callable()
var _lbl: Label = null
var _last_newest_id: int = -1  # P1-10：封顶后 size 恒定，按最新 evidence_id 判定
var _last_highlight: int = -2


func _init() -> void:
	var title := Label.new()
	title.text = "Weapon Alerts"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_lbl = Label.new()
	_lbl.text = "No alerts"
	_lbl.add_theme_font_size_override("font_size", 11)
	add_child(_lbl)


func bind(w: World, get_track_bearings: Callable) -> void:
	_world = w
	_get_track_bearings = get_track_bearings


func sync() -> void:
	if _world == null:
		return
	var evs: Array = _world.player_evidence
	if evs.is_empty():
		_lbl.text = "No alerts"
		_last_newest_id = -1
		return
	var newest: int = int(evs[evs.size() - 1].get("evidence_id", -1))
	if newest == _last_newest_id and highlight_evidence_id == _last_highlight:
		return  # 无新证据且高亮未变不重排（封顶后 size 恒定，比较最新 id）
	_last_newest_id = newest
	_last_highlight = highlight_evidence_id
	var track_brgs: Array = []
	if _get_track_bearings.is_valid():
		track_brgs = _get_track_bearings.call()
	# REQ-UI-04 告警分组 + REQ-UI-03 战果分级汇总：
	#   THREAT（来袭）/ CM（反制）/ BDA（战果）/ INFO，行首缀组标签；
	#   BDA 有分级时顶部先给一行汇总（PROBABLE_HIT/KILL 计数）。
	var bda_counts: Dictionary = {}
	var lines: Array = []
	var start: int = maxi(evs.size() - MAX_ROWS, 0)
	for i in range(evs.size() - 1, start - 1, -1):
		var e: Dictionary = evs[i]
		var tag: String = str(e.get("alert", "?"))
		# §10.4：己方武器爆炸 + 航迹一致 → 战果评估（仍非 Truth）。
		if (
			str(e.get("emission_kind", "")) == AcousticEmissionEvent.EXPLOSION
			and str(e.get("side_hint")) == "OWN_FACT"
		):
			var level: String = EmissionSanitizer.classify_detonation(e, track_brgs, true)
			if level != "":
				tag = level
		var group: String = _group_for(tag)
		if group == "BDA":
			bda_counts[tag] = int(bda_counts.get(tag, 0)) + 1
		var line: String = "%s T+%ds %s" % [group, int(float(e.get("timestamp", 0.0))), tag]
		if e.has("bearing_deg"):
			line += " brg %03.0f°" % float(e["bearing_deg"])
		line += " conf %d%%" % int(100.0 * float(e.get("confidence", 0.0)))
		# P0-07.4：地图选中的证据行加前缀高亮。
		if int(e.get("evidence_id", -1)) == highlight_evidence_id:
			line = "> " + line + " <"
		lines.append(line)
	if not bda_counts.is_empty():
		var parts: Array = []
		for k in bda_counts:
			parts.append("%d×%s" % [int(bda_counts[k]), k])
		lines.push_front("BDA summary: " + " ".join(parts))
	_lbl.text = "\n".join(lines)


## 告警分组（REQ-UI-04）：威胁 / 反制 / 战果 / 其他。
func _group_for(tag: String) -> String:
	if tag.begins_with("PROBABLE_"):
		return "BDA"
	if tag.contains("TORPEDO") or tag.begins_with("POSSIBLE"):
		return "THREAT"
	if tag.contains("DECOY"):
		return "CM"
	if tag.contains("DETONATION"):
		return "BDA"
	return "INFO"
