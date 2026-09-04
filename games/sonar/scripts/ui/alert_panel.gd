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

var _world: World = null
var _get_track_bearings: Callable = Callable()
var _lbl: Label = null
var _rendered: int = 0


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
		_rendered = 0
		return
	if evs.size() == _rendered:
		return  # 无新证据不重排
	_rendered = evs.size()
	var track_brgs: Array = []
	if _get_track_bearings.is_valid():
		track_brgs = _get_track_bearings.call()
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
		var line: String = "T+%ds %s" % [int(float(e.get("timestamp", 0.0))), tag]
		if e.has("bearing_deg"):
			line += " brg %03.0f°" % float(e["bearing_deg"])
		line += " conf %d%%" % int(100.0 * float(e.get("confidence", 0.0)))
		lines.append(line)
	_lbl.text = "\n".join(lines)
