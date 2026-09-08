class_name WaterfallView
extends Control
## waterfall_view.gd — 通用瀑布图控件（Sonar Operator Layer）。
##
## 三种用法（由 axis_mode 决定）：
##   "bearing"  方位-时间（Broadband，x: -180..180°）
##   "freq"     频率-时间（Narrowband/LOFAR，x: 0..500 Hz）
##   "envelope" DEMON 包络谱（x: 0..32 Hz）
##
## 数据由 main_ui 在 OperatorSonar 产生新行时注入（rows），
## 图像缓存 + 脏标记，不每帧重建。
##
## 交互：鼠标悬停显示游标（与其它视图联动），点击 → mark_requested。

signal cursor_moved(x_value: float)
## 点击某行某列：x_value 为显示轴坐标，row 为被点行的完整上下文
## （t/course/array_heading/own_e/own_n/tow_center_m/tow_length_m/peaks）。
## S1-01：历史行点击必须携带那一行的时刻/艏向/站位，不得用 rows[-1]。
signal mark_requested(x_value: float, time_s: float, row: Dictionary)

const COLORMAP_HOT: Array = [
	Color(0.05, 0.05, 0.12),
	Color(0.15, 0.1, 0.3),
	Color(0.5, 0.15, 0.3),
	Color(0.9, 0.45, 0.1),
	Color(1.0, 0.85, 0.3),
	Color(1.0, 1.0, 0.9),
]

# REQ-B6-03：调色板（色阶单调；HOT 保留但不再唯一）。
const COLORMAP_GRAYSCALE: Array = [
	Color(0.02, 0.02, 0.02),
	Color(0.25, 0.25, 0.25),
	Color(0.5, 0.5, 0.5),
	Color(0.72, 0.72, 0.72),
	Color(0.88, 0.88, 0.88),
	Color(1.0, 1.0, 1.0),
]

const COLORMAP_BLUE: Array = [
	Color(0.0, 0.0, 0.05),
	Color(0.0, 0.12, 0.28),
	Color(0.0, 0.35, 0.5),
	Color(0.1, 0.6, 0.6),
	Color(0.5, 0.82, 0.75),
	Color(0.92, 1.0, 0.95),
]

const COLORMAP_AMBER: Array = [
	Color(0.05, 0.03, 0.0),
	Color(0.3, 0.15, 0.02),
	Color(0.6, 0.35, 0.05),
	Color(0.85, 0.58, 0.1),
	Color(1.0, 0.8, 0.35),
	Color(1.0, 0.96, 0.82),
]

const AGC_SMOOTH := {"SLOW": 0.05, "FAST": 0.35}

const PALETTES: Dictionary = {
	"HOT": COLORMAP_HOT,
	"GRAYSCALE": COLORMAP_GRAYSCALE,
	"BLUE": COLORMAP_BLUE,
	"AMBER": COLORMAP_AMBER,
}

var axis_mode: String = "bearing"
var x_min: float = -180.0
var x_max: float = 180.0
var db_min: float = -28.0
var db_max: float = 8.0
# 方位-时间瀑布的显示基准（需求§一.2）：
#   "rel"   RELATIVE 艇艏相对（默认，艇艏=0，x=-180..180）
#   "true"  TRUE STABILIZED 真北稳定（x=0..360，逐行按 own course 平移）
var bearing_mode: String = "rel"
var rows: Array = []  # [{t, values: PackedFloat32Array, course?(仅bearing)}]
var cursor_value: float = NAN
var cursor_time: float = -1.0
var markers: Array = []  # [{x, color, label}] 竖线标记（谐波/转向）

# REQ-B6-02：噪声底跟踪 + 固定动态范围（只影响显示，不改波形/P_d/证据/TMA）。
#   floor = smooth(robust background = 滚动窗中位数，峰被稳健统计排除)
#   black = floor - black_offset_db；display = clamp((x-black)/dynamic_range, 0, 1)
#   OFF  固定 black/white level（manual_black_db + dynamic_range_db）
#   SLOW 缓慢跟踪背景（正常值守）  FAST 快速恢复（强干扰场景）
# 显示状态按 display_key 隔离（BB/NB/DEMON 为独立实例天然隔离；同阵列视图
# 经 set_display_key 换键，阵列间增益互不污染）。
var palette_name: String = "HOT"
var agc_mode: String = "SLOW"
var black_offset_db: float = 6.0
var dynamic_range_db: float = 24.0
var manual_black_db: float = -20.0
var display_key: String = "default"
var agc_window_rows: int = 24

var _img: Image = null
var _tex: ImageTexture = null
var _img_dirty: bool = true
var _font: Font = null


func _ready() -> void:
	custom_minimum_size = Vector2(0, 96)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = get_theme_default_font()


func set_rows(new_rows: Array) -> void:
	rows = new_rows
	_img_dirty = true
	queue_redraw()


func set_cursor(v: float) -> void:
	cursor_value = v
	queue_redraw()


## REQ-B6-03：AGC 模式（OFF/SLOW/FAST）。切换不触碰 rows（纯显示）。
func set_agc_mode(mode: String) -> void:
	if not (mode == "OFF" or mode == "SLOW" or mode == "FAST"):
		return
	agc_mode = mode
	_img_dirty = true
	queue_redraw()


## REQ-B6-03：调色板切换（HOT/GRAYSCALE/BLUE/AMBER）。纯显示。
func set_palette(name: String) -> void:
	if not PALETTES.has(name):
		return
	palette_name = name
	_img_dirty = true
	queue_redraw()


## REQ-B6-02：动态范围（12~36 dB 可配置）。
func set_dynamic_range_db(v: float) -> void:
	dynamic_range_db = clampf(v, 12.0, 36.0)
	_img_dirty = true
	queue_redraw()


func set_black_offset_db(v: float) -> void:
	black_offset_db = clampf(v, 0.0, 24.0)
	_img_dirty = true
	queue_redraw()


## REQ-B6-03：Reset Display——恢复默认显示参数。
func reset_display() -> void:
	palette_name = "HOT"
	agc_mode = "SLOW"
	black_offset_db = 6.0
	dynamic_range_db = 24.0
	_img_dirty = true
	queue_redraw()


## 阵列切换时换显示状态键（BOW→TOWED→BOW 各自独立噪声底跟踪）。
func set_display_key(key: String) -> void:
	display_key = key
	_img_dirty = true
	queue_redraw()


func _x_to_px(v: float) -> float:
	var w: float = size.x
	return (v - x_min) / (x_max - x_min) * w


func _px_to_x(px: float) -> float:
	return x_min + px / size.x * (x_max - x_min)


func _rebuild_image() -> void:
	_img_dirty = false
	_tex = null
	if rows.is_empty():
		_img = null
		return
	var w: int = maxi(int(rows[0]["values"].size()), 1)
	var h: int = maxi(rows.size(), 2)
	_img = Image.create(w, h, false, Image.FORMAT_RGB8)
	var true_mode: bool = axis_mode == "bearing" and bearing_mode == "true"
	# 每次重建从最旧可见行重算噪声底（确定性：同 rows 重建像素完全一致，
	# 阵列/键间天然无状态污染）。
	var floor_v: float = NAN
	var smooth_k: float = float(AGC_SMOOTH.get(agc_mode, 0.05))
	for r in range(rows.size()):
		var vals: PackedFloat32Array = rows[r]["values"]
		var lo: float = db_min
		var hi_span: float = db_max - db_min
		if agc_mode == "OFF":
			lo = manual_black_db
			hi_span = dynamic_range_db
		else:
			# REQ-B6-02：滚动窗稳健背景估计（中位数——峰被排除）→ 逐行平滑
			# 噪声底（同 rows 重建结果一致，不消耗仿真 RNG）。
			var w0: int = maxi(r - agc_window_rows + 1, 0)
			var pool: PackedFloat32Array = PackedFloat32Array()
			for rr in range(w0, r + 1):
				pool.append_array(rows[rr]["values"])
			pool.sort()
			var bg: float = pool[int(pool.size() / 2.0)]
			floor_v = bg if is_nan(floor_v) else lerpf(floor_v, bg, smooth_k)
			lo = floor_v - black_offset_db
			hi_span = dynamic_range_db
		if true_mode:
			# TRUE STABILIZED 重排（S1-01）：源列恒为 -180..180（每格 2°，
			# 与显示轴 x_min/x_max 无关！），目标列才是 0..360 真北方位。
			# 不得用已切换的 x_min=0 反推源相对方位（0.2 回归 #2）。
			var course: float = float(rows[r].get("course", 0.0))
			var src_deg_per_col: float = 360.0 / float(w)
			for c in range(vals.size()):
				var rel: float = -180.0 + float(c) * src_deg_per_col
				var true_deg: float = fposmod(course + rel, 360.0)
				var tc: int = clampi(int(floor(true_deg / 360.0 * float(w))), 0, w - 1)
				var db: float = float(vals[c])
				var t: float = clampf((db - lo) / hi_span, 0.0, 1.0)
				_img.set_pixel(tc, h - 1 - r, _cmap(t))
		else:
			for c in range(w):
				var db: float = float(vals[c]) if c < vals.size() else lo
				var t: float = clampf((db - lo) / hi_span, 0.0, 1.0)
				_img.set_pixel(c, h - 1 - r, _cmap(t))
	_tex = ImageTexture.create_from_image(_img)


## 切换方位瀑布的显示基准（RELATIVE / TRUE STABILIZED），并同步 x 轴范围。
func set_bearing_mode(mode: String) -> void:
	if mode != "rel" and mode != "true":
		return
	if bearing_mode == mode:
		return
	bearing_mode = mode
	if mode == "true":
		x_min = 0.0
		x_max = 360.0
	else:
		x_min = -180.0
		x_max = 180.0
	_img_dirty = true
	queue_redraw()


func _cmap(t: float) -> Color:
	var cmap: Array = PALETTES.get(palette_name, COLORMAP_HOT)
	var f: float = t * float(cmap.size() - 1)
	var i: int = clampi(int(f), 0, cmap.size() - 2)
	return cmap[i].lerp(cmap[i + 1], f - float(i))


func _draw() -> void:
	if _img_dirty:
		_rebuild_image()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.03, 0.06))
	if _tex != null:
		draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)
	_draw_axis_labels()
	# 游标（垂直亮线）
	if not is_nan(cursor_value):
		var cx: float = _x_to_px(cursor_value)
		draw_line(Vector2(cx, 0), Vector2(cx, size.y), Color(0.2, 1.0, 0.9, 0.9), 1.5)
		if _font != null:
			draw_string(
				_font,
				Vector2(cx + 3, 12),
				_x_label(cursor_value),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				12,
				Color(0.2, 1.0, 0.9)
			)
	# 标记线（谐波 / 事件）
	for mk in markers:
		var mx: float = _x_to_px(float(mk["x"]))
		draw_line(Vector2(mx, 0), Vector2(mx, size.y), mk.get("color", Color(1, 1, 1, 0.4)), 1.0)


func _x_label(v: float) -> String:
	if axis_mode == "bearing":
		return "%d°" % int(v)
	return "%.0f Hz" % v


func _draw_axis_labels() -> void:
	if _font == null:
		return
	var col := Color(0.8, 0.8, 0.8, 0.85)
	var n: int = 4
	for i in range(n + 1):
		var v: float = x_min + (x_max - x_min) * float(i) / float(n)
		var px: float = _x_to_px(v)
		draw_line(Vector2(px, size.y - 12), Vector2(px, size.y), col, 1.0)
		var txt: String = _x_label(v)
		draw_string(_font, Vector2(px + 2, size.y - 2), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


## 由鼠标 y 反算被点行索引（最新行在底部）。可无头单测（0.2 回归 #3）。
func row_index_from_y(y_px: float) -> int:
	if rows.is_empty():
		return -1
	var h: float = maxf(size.y, 1.0)
	var idx: int = rows.size() - 1 - int(floor(y_px / h * float(rows.size())))
	return clampi(idx, 0, rows.size() - 1)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var v: float = _px_to_x(event.position.x)
		cursor_value = v
		cursor_moved.emit(v)
		queue_redraw()
	elif (
		event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	):
		var v2: float = _px_to_x(event.position.x)
		# 按鼠标 y 选择实际行，携带那一行的完整上下文（S1-01 回归 #3）
		var ri: int = row_index_from_y(event.position.y)
		var row: Dictionary = rows[ri] if ri >= 0 and ri < rows.size() else {}
		var t: float = float(row.get("t", rows[-1]["t"])) if not rows.is_empty() else 0.0
		# REQ-09：Shift+左键 = 锁定关联（强制追加到当前选中接触）。
		row = row.duplicate()
		row["shift"] = event.shift_pressed
		mark_requested.emit(v2, t, row)
		accept_event()
