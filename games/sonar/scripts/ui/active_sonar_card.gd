class_name ActiveSonarCard
extends VBoxContainer
## active_sonar_card.gd — S1-04C-REQ-01 主动声呐结构化卡片（固定布局）。
##
## 替代旧"Ping 按钮 + 一条自动换行长字符串"的唯一主动界面：
##   Active Sonar
##     [State Badge]             (UNAVAILABLE/READY/TRANSMITTING/LISTENING/
##                                RETURN/NO RETURN/COOLDOWN，彩色徽标)
##     [PING]
##     Mode         Single pulse
##     Frequency    3.0 kHz
##     Source Level 210 dB
##     Listen Win   15 s / max range 11.3 km
##     Exposure     HIGH — enemy may intercept
##     Latest Returns  （表头 + 逐行可点）
##       Ping | T | Brg | Range | ±σ | SE | Assoc
##     TMA Link
##       Track / Evidence / Fit   + [Undo last association]
##
## 布局纪律：
##   - 标签/列宽固定，数字变化不得推挤整行/面板跳动（Label 固定最小宽 +
##     固定字符数文本）；
##   - LISTENING 动画只基于本艇发射时钟/配置监听窗（数据由调用方保证，
##     本卡片不读任何目标 Truth / 回波倒计时）；
##   - RETURN/NO RETURN 后进入 COOLDOWN，再回 READY——状态不瞬间消失。

signal ping_requested  # 玩家按 [PING]
signal return_selected(return_index: int)  # 点击 Latest Returns 某行
signal undo_requested  # 撤销最近一次自动关联（改绑入口）

const COL_STATE := {
	"UNAVAILABLE": Color(0.45, 0.45, 0.48),
	"READY": Color(0.35, 0.9, 0.5),
	"TRANSMITTING": Color(1.0, 0.96, 0.7),
	"LISTENING": Color(0.4, 0.75, 1.0),
	"RETURN": Color(0.35, 0.95, 0.9),
	"NO RETURN": Color(1.0, 0.7, 0.25),
	"COOLDOWN": Color(0.95, 0.9, 0.35),
}
const COL_EXPOSURE := Color(1.0, 0.5, 0.3)
const MAX_RETURNS: int = 8

var _badge: Label = null
var _btn_ping: Button = null
var _lbl_mode: Label = null
var _lbl_freq: Label = null
var _lbl_sl: Label = null
var _lbl_listen: Label = null
var _lbl_exposure: Label = null
var _returns_box: VBoxContainer = null
var _return_rows: Array = []  # [Button]（与 set_data 的 returns 顺序一致）
var _lbl_tma_track: Label = null
var _lbl_tma_evidence: Label = null
var _lbl_tma_fit: Label = null
var _btn_undo: Button = null
var _ping_cd: float = 0.0  # 冷却剩余（本艇事实，可显示）


func _init() -> void:
	add_theme_constant_override("separation", 3)
	var title := Label.new()
	title.text = "Active Sonar"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	add_child(title)

	# State Badge + PING（同一行：徽标在左，按钮在右）
	var badge_row := HBoxContainer.new()
	badge_row.add_theme_constant_override("separation", 6)
	add_child(badge_row)
	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 14)
	_badge.custom_minimum_size = Vector2(118, 0)
	_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge_row.add_child(_badge)
	_btn_ping = Button.new()
	_btn_ping.text = "PING"
	_btn_ping.add_theme_font_size_override("font_size", 13)
	_btn_ping.custom_minimum_size = Vector2(76, 30)
	_btn_ping.pressed.connect(func(): ping_requested.emit())
	badge_row.add_child(_btn_ping)

	# 固定参数区（标签固定宽度，值不变宽推挤）
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 1)
	add_child(grid)
	_lbl_mode = _add_param_row(grid, "Mode")
	_lbl_freq = _add_param_row(grid, "Frequency")
	_lbl_sl = _add_param_row(grid, "Source Level")
	_lbl_listen = _add_param_row(grid, "Listen Window")
	_lbl_exposure = _add_param_row(grid, "Exposure")

	# Latest Returns 表
	var ret_title := Label.new()
	ret_title.text = "Latest Returns"
	ret_title.add_theme_font_size_override("font_size", 14)
	add_child(ret_title)
	var head := Label.new()
	head.text = "#  time   brg   range    ±σ     SE   assoc"
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", Color(0.6, 0.75, 0.8))
	add_child(head)
	_returns_box = VBoxContainer.new()
	_returns_box.add_theme_constant_override("separation", 1)
	add_child(_returns_box)

	# TMA Link
	var tma_title := Label.new()
	tma_title.text = "TMA Link"
	tma_title.add_theme_font_size_override("font_size", 14)
	add_child(tma_title)
	var tma_grid := GridContainer.new()
	tma_grid.columns = 2
	tma_grid.add_theme_constant_override("h_separation", 6)
	tma_grid.add_theme_constant_override("v_separation", 1)
	add_child(tma_grid)
	_lbl_tma_track = _add_param_row(tma_grid, "Track")
	_lbl_tma_evidence = _add_param_row(tma_grid, "Evidence")
	_lbl_tma_fit = _add_param_row(tma_grid, "Fit")
	_btn_undo = Button.new()
	_btn_undo.text = "Undo last association"
	_btn_undo.add_theme_font_size_override("font_size", 12)
	_btn_undo.flat = true
	_btn_undo.pressed.connect(func(): undo_requested.emit())
	add_child(_btn_undo)


func _add_param_row(grid: GridContainer, key: String) -> Label:
	var k := Label.new()
	k.text = key
	k.add_theme_font_size_override("font_size", 12)
	k.custom_minimum_size = Vector2(96, 0)
	k.add_theme_color_override("font_color", Color(0.7, 0.8, 0.85))
	grid.add_child(k)
	var v := Label.new()
	v.text = "-"
	v.add_theme_font_size_override("font_size", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(v)
	return v


## 由调用方（ActivePingController）每帧/事件后刷新整卡。
## d = {
##   state: String, cooldown: float,
##   params: {mode, freq_khz, sl_db, listen_s, max_range_km, exposure},
##   returns: [{ping_id:int, time:float, bearing_deg:float, range_m:float,
##              range_sigma_m:float, se_db:float, track_id:String, detected:bool}],
##   tma: {track:String, evidence:String, fit:String},
##   undo_enabled: bool, ping_disabled_reason: String
## }
func set_data(d: Dictionary) -> void:
	var state: String = str(d.get("state", "UNAVAILABLE"))
	_ping_cd = float(d.get("cooldown", 0.0))
	var params: Dictionary = d.get("params", {})
	var returns: Array = d.get("returns", [])
	var tma: Dictionary = d.get("tma", {})
	# State badge：颜色 + 文字双编码（色盲安全）。冷却附在本艇事实徽标内。
	var badge_txt: String = state
	if state == "RETURN" or state == "NO RETURN" or state == "COOLDOWN":
		badge_txt = "COOLDOWN"
	_badge.text = badge_txt
	var col: Color = COL_STATE.get(state, COL_STATE["UNAVAILABLE"])
	if (state == "RETURN" or state == "NO RETURN") and _ping_cd > 0.0:
		col = COL_STATE["COOLDOWN"]
	_badge.add_theme_color_override("font_color", col)
	_badge.tooltip_text = _badge_tooltip(state)
	# PING 按钮：READY 才可发；UNAVAILABLE/LISTENING/冷却硬禁并给原因。
	var ready: bool = state == "READY"
	_btn_ping.disabled = not ready
	_btn_ping.modulate = Color(1.0, 0.7, 0.3) if ready else Color(0.55, 0.55, 0.58)
	_btn_ping.tooltip_text = str(d.get("ping_disabled_reason", ""))
	# 固定参数
	_lbl_mode.text = str(params.get("mode", "-"))
	_lbl_freq.text = "%.1f kHz" % float(params.get("freq_khz", 0.0))
	_lbl_sl.text = "%.0f dB" % float(params.get("sl_db", 0.0))
	_lbl_listen.text = (
		"%.0f s / max %.1f km"
		% [float(params.get("listen_s", 0.0)), float(params.get("max_range_km", 0.0))]
	)
	_lbl_exposure.text = str(params.get("exposure", "-"))
	_lbl_exposure.add_theme_color_override(
		"font_color",
		(
			COL_EXPOSURE
			if str(params.get("exposure", "")).begins_with("HIGH")
			else Color(0.85, 0.9, 0.9)
		)
	)
	# Latest Returns：行数变化重建，文本每次刷新（列固定宽度不推挤）
	if returns.size() != _return_rows.size():
		_rebuild_return_rows(returns)
	for i in range(_return_rows.size()):
		var r: Dictionary = returns[i]
		(_return_rows[i] as Button).text = _fmt_return(r)
		(_return_rows[i] as Button).tooltip_text = (
			"Ping %d @ %.0fs — click to select associated contact"
			% [int(r.get("ping_id", -1)), float(r.get("time", 0.0))]
		)
	# TMA Link
	_lbl_tma_track.text = str(tma.get("track", "-"))
	_lbl_tma_evidence.text = str(tma.get("evidence", "-"))
	var fit_txt: String = str(tma.get("fit", "-"))
	_lbl_tma_fit.text = fit_txt
	var fit_col := Color(0.85, 0.9, 0.9)
	if fit_txt == "REFIT REQUIRED":
		fit_col = Color(1.0, 0.8, 0.3)
	elif fit_txt == "RANGE AIDED":
		fit_col = Color(0.35, 1.0, 0.6)
	elif fit_txt == "REJECTED":
		fit_col = Color(1.0, 0.4, 0.35)
	_lbl_tma_fit.add_theme_color_override("font_color", fit_col)
	_btn_undo.disabled = not bool(d.get("undo_enabled", false))


func _badge_tooltip(state: String) -> String:
	if state == "COOLDOWN":
		return "Recharging %.0f s" % _ping_cd
	var tips := {
		"READY": "Active sonar ready — single pulse",
		"TRANSMITTING": "Pulse emitted — listening for echoes",
		"LISTENING": "Listening — fixed echo window open",
		"RETURN": "Echo(es) returned — recharging",
		"NO RETURN": "No echo returned — recharging",
	}
	return str(tips.get(state, "No active sonar fitted on this platform"))


func _rebuild_return_rows(returns: Array) -> void:
	for b in _return_rows:
		(b as Button).queue_free()
	_return_rows.clear()
	for i in range(mini(returns.size(), MAX_RETURNS)):
		var b := Button.new()
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 11)
		b.custom_minimum_size = Vector2(0, 18)
		b.pressed.connect(func(): return_selected.emit(i))
		_returns_box.add_child(b)
		_return_rows.append(b)


## 单行固定列宽文本（rpad 占位防跳动）。无测距行 range 显示 "—"。
func _fmt_return(r: Dictionary) -> String:
	var range_txt: String = "—"
	var sig_txt: String = ""
	var range_m: float = float(r.get("range_m", -1.0))
	if range_m >= 0.0:
		range_txt = "%.1fkm" % (range_m / 1000.0)
		sig_txt = "±%.0fm" % float(r.get("range_sigma_m", 0.0))
	var se_txt: String = ""
	if r.has("se_db"):
		se_txt = "SE%+d" % int(float(r["se_db"]))
	var assoc: String = str(r.get("track_id", "-"))
	var line := (
		"%s %s %s %s %s %s %s"
		% [
			("#%d" % int(r.get("ping_id", 0))).lpad(4),
			("%.0fs" % float(r.get("time", 0.0))).lpad(5),
			("%.0f°" % float(r.get("bearing_deg", 0.0))).lpad(5),
			range_txt.lpad(6),
			sig_txt.lpad(6),
			se_txt.lpad(5),
			assoc.rpad(4),
		]
	)
	return line
