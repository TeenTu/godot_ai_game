class_name RightSidebarPager
extends VBoxContainer
## right_sidebar_pager.gd — S109 §8 右栏：固定顶栏 + 四页容器。
##
## 固定顶栏 = 任务时间/暂停/倍速（time_row 由 main_ui 注入控件）+ 当前选中
## 摘要（selection_slot）+ 来袭鱼雷固定告警条（alert_slot）+ 分页按钮。
## 每页独立 ScrollContainer（横向禁用）；切页只切 visible：不销毁/重建业务
## 对象，并保留各页滚动位置（§8.4；AT-28/29/31）。实际宽度 = max(契约钳制,
## 页面内容固有宽)——横向禁用滚动保证永不出现水平滚动条（与旧单列侧栏一致）。
## 文案暂英文（Batch 7 统一中文 + 字体 cmap 校验）。

const PAGE_SPECS: Array = [["sonar", "Sonar"], ["tactics", "Tactics"], ["weapons", "Weapons"]]
const WIDE_COLS_X: float = 440.0  # 宽于此四按钮一行；窄（含 1280×720）2×2，§8.4

var top_bar: VBoxContainer = null
var time_row: HBoxContainer = null
var selection_slot: VBoxContainer = null
var alert_slot: VBoxContainer = null

var _group: ButtonGroup = null
var _btn_grid: GridContainer = null
var _pages_box: VBoxContainer = null
var _pages: Dictionary = {}  # page_id -> ScrollContainer
var _bodies: Dictionary = {}  # page_id -> VBoxContainer（页面内容根）
var _btns: Dictionary = {}  # page_id -> Button
var _titles: Dictionary = {}  # page_id -> String
var _badges: Dictionary = {}  # page_id -> int
var _scroll_mem: Dictionary = {}  # page_id -> v 滚动值
var _current: String = ""


func _init() -> void:
	top_bar = VBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 3)
	add_child(top_bar)
	time_row = HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 6)
	top_bar.add_child(time_row)
	selection_slot = VBoxContainer.new()
	top_bar.add_child(selection_slot)
	alert_slot = VBoxContainer.new()
	top_bar.add_child(alert_slot)
	_group = ButtonGroup.new()
	_btn_grid = GridContainer.new()
	_btn_grid.columns = 2
	_btn_grid.add_theme_constant_override("h_separation", 4)
	top_bar.add_child(_btn_grid)
	_pages_box = VBoxContainer.new()
	_pages_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_pages_box)
	resized.connect(_relayout)


## 新增一页：分页按钮（ButtonGroup 互斥）+ 独立 ScrollContainer；返回页面正文容器。
func add_page(page_id: String, title: String) -> VBoxContainer:
	var btn := Button.new()
	btn.text = title
	btn.toggle_mode = true
	btn.button_group = _group
	btn.pressed.connect(select.bind(page_id))
	_btn_grid.add_child(btn)
	_btns[page_id] = btn
	_titles[page_id] = title
	_badges[page_id] = 0
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.visible = false
	_pages_box.add_child(sc)
	var body := VBoxContainer.new()
	body.custom_minimum_size = Vector2(UiContract.SIDEBAR_MIN_W, 0)
	body.size_flags_horizontal = Control.SIZE_FILL  # 不 EXPAND：不撑宽侧栏（P1-03.1）
	body.add_theme_constant_override("separation", 5)
	sc.add_child(body)
	_pages[page_id] = sc
	_bodies[page_id] = body
	return body


func page_body(page_id: String) -> VBoxContainer:
	return _bodies.get(page_id, null)


func page_scroll(page_id: String) -> ScrollContainer:
	return _pages.get(page_id, null)


func page_ids() -> Array:
	return Array(_pages.keys())


func current_page() -> String:
	return _current


## 切页：保存/恢复各页滚动位置；只切 visible，不动任何业务节点（§8.4）。
func select(page_id: String) -> void:
	if not _pages.has(page_id) or page_id == _current:
		return
	if _current != "":
		_scroll_mem[_current] = (_pages[_current] as ScrollContainer).get_v_scroll_bar().value
	_current = page_id
	for pid in _pages.keys():
		(_pages[pid] as ScrollContainer).visible = pid == page_id
		(_btns[pid] as Button).set_pressed_no_signal(pid == page_id)
	# 页面隐藏期间滚动条 range 可能是旧值，直接赋值会被钳制——补一次 deferred。
	var sb: VScrollBar = (_pages[page_id] as ScrollContainer).get_v_scroll_bar()
	var want: float = float(_scroll_mem.get(page_id, 0.0))
	sb.value = want
	sb.set_deferred("value", want)


## AT-28：任意时刻恰好一个页面内容可见。
func visible_page_count() -> int:
	var n: int = 0
	for pid in _pages.keys():
		if (_pages[pid] as ScrollContainer).visible:
			n += 1
	return n


## §8.3：页面按钮红点/数量徽标；页面隐藏期间同样更新（AT-30）。
func set_badge(page_id: String, count: int) -> void:
	if not _btns.has(page_id):
		return
	_badges[page_id] = count
	(_btns[page_id] as Button).text = (
		str(_titles[page_id]) + (" \u25cf%d" % count if count > 0 else "")
	)


func badge(page_id: String) -> int:
	return int(_badges.get(page_id, 0))


## §8.4：1280×720 等窄宽度 2×2（不产生横向滚动）；宽窗保持一行/自适应。
func _relayout() -> void:
	_btn_grid.columns = 4 if size.x >= WIDE_COLS_X else 2
