class_name ThreatHud
extends VBoxContainer
## threat_hud.gd — S109 §4.5/§8.3 固定威胁告警条 + 威胁列表。
##
## Batch 5 形态：banner-only 实例挂右栏固定顶栏；list-only 实例挂"航迹"页
## （want_banner/want_list 开关）。§8.3：告警条不随分页消失、新威胁闪烁、
## 不强制切页/抢选择。
##
## 输入只允许 ThreatTrackManager.ui_snapshots() 净化 DTO；本类零玩法写入，
## "View" 只居中相机到该威胁估计中心（§5.3 不得改普通选择）。
## 文案暂英文（Batch 7 统一中文 + 字体 cmap 校验）。

const STATE_RANK := {"RANGE_AIDED": 0, "TRACKING": 1, "TENTATIVE": 2, "COASTING": 3, "LOST": 4}
const FLASH_S: float = 6.0

var _chart: ChartView = null
var _banner: PanelContainer = null
var _banner_lbl: Label = null
var _rows: VBoxContainer = null
var _flash_until: float = -1.0
var _seen: Dictionary = {}
var _want_banner: bool = true
var _want_list: bool = true


static func install(
	parent: Control, chart: ChartView, want_banner: bool = true, want_list: bool = true
) -> ThreatHud:
	var h := ThreatHud.new()
	h._chart = chart
	h._want_banner = want_banner
	h._want_list = want_list
	parent.add_child(h)
	h._build()
	return h


## 测试/联动断言（AT-28..30）：告警条文本与列表行数。
func banner_text() -> String:
	return _banner_lbl.text if _banner_lbl != null else ""


func row_count() -> int:
	return _rows.get_child_count() if _rows != null else 0


func _build() -> void:
	if _want_banner:
		_banner = PanelContainer.new()
		_banner_lbl = Label.new()
		_banner_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_banner_lbl.custom_minimum_size = Vector2(260, 0)
		_banner.add_child(_banner_lbl)
		add_child(_banner)
	if _want_list:
		_rows = VBoxContainer.new()
		add_child(_rows)


## 每次 UI 刷新调用：告警条取优先级最高 TT（状态等级→置信度），列表逐条。
func refresh(snaps: Array, sim_now: float) -> void:
	var top: Dictionary = {}
	for s in snaps:
		if not _seen.has(str(s["track_id"])):
			if not _seen.is_empty():
				_flash_until = sim_now + FLASH_S
			_seen[str(s["track_id"])] = true
		if top.is_empty() or _rank(s) < _rank(top):
			top = s
	if _banner != null:
		_banner.visible = not top.is_empty()
		if not top.is_empty():
			_banner_lbl.text = str(UiText.t("torpedo_alert")) + " — " + _line(top, sim_now)
			var hot: bool = sim_now < _flash_until
			_banner.modulate = Color(1.0, 0.5, 0.45) if hot else Color(0.85, 0.85, 0.85)
	if _rows != null:
		for c in _rows.get_children():
			_rows.remove_child(c)
			c.queue_free()
		for s in snaps:
			_rows.add_child(_row(s, sim_now))


func _row(s: Dictionary, sim_now: float) -> Control:
	var hb := HBoxContainer.new()
	var lb := Label.new()
	lb.text = _line(s, sim_now)
	hb.add_child(lb)
	var b := Button.new()
	b.text = UiText.t("btn_view_threat")
	b.pressed.connect(_on_view.bind(str(s["track_id"])))
	hb.add_child(b)
	return hb


func _on_view(tid: String) -> void:
	if _chart == null:
		return
	for s in _chart.threat_snapshots:
		if str(s.get("track_id", "")) == tid and s.get("draw_center_e_m") != null:
			_chart.cam_center = Vector2(float(s["draw_center_e_m"]), float(s["draw_center_n_m"]))
			_chart.queue_redraw()
			return


func _rank(s: Dictionary) -> float:
	return float(int(STATE_RANK.get(str(s["state"]), 5)) * 100 - float(s["confidence"]) * 99.0)


func _line(s: Dictionary, sim_now: float) -> String:
	var parts: Array = [
		str(s["track_id"]),
		UiText.threat(str(s["state"])),
		"方位 %.0f°±%.0f" % [float(s["bearing_est_deg"]), float(s["bearing_sigma_deg"])],
	]
	if s.get("range_est_m") != null:
		parts.append(
			"距离 %.0f±%.0fm" % [float(s["range_est_m"]), float(s.get("range_sigma_m", 0.0))]
		)
	if s.get("ellipse_a_m") != null:
		parts.append(
			"95%% 椭圆 %.0fx%.0fm" % [float(s["ellipse_a_m"]), float(s.get("ellipse_b_m", 0.0))]
		)
	(
		parts
		. append(
			(
				"p=%.2f ev=%d %ds"
				% [
					float(s["p_torpedo"]),
					int(s["evidence_count"]),
					int(sim_now - float(s["last_update_time"])),
				]
			)
		)
	)
	return "  ".join(parts)
