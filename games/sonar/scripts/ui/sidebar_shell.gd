class_name SidebarShell
extends Control
## sidebar_shell.gd — UI-01：侧栏**固定宽外壳**（P1-B）。
##
## 问题：旧实现把 `RightSidebarPager` 直接塞进 HBoxContainer，宽度 =
## max(契约钳制, 页面内容固有宽)，再用「每帧 size.x 钳制」兜底。但钳制不是
## 最大宽度机制：只要任一页出现一条长文案 / 一个按最长项撑宽的 OptionButton，
## 分页器的最小宽就被顶上去，侧栏变宽 → 海图被挤（T22 宽度抖动）。
##
## 本类的机制：
##   - 继承 `Control`（**不是 Container**）。Control 的 combined_minimum_size
##     只来自 custom_minimum_size，**不聚合子节点**——尺寸传播链在这里断开；
##   - `custom_minimum_size.x` = 目标宽（只按窗口宽度分档，见
##     UiContract.sidebar_width_for），HBox 因此给它**恰好**这么宽；
##   - 宽度只随窗口变化：文字变化 / 切页 / 命令 ETA 更新 / 告警增加都不影响；
##   - 内容只改变高度（页面纵向滚动）；超宽子控件被 clip_contents 拦在外壳内，
##     并由 `audit()` 逐页定位（T22 要求"用实际 rect 与 combined_minimum_size
##     定位超宽子控件"，而不是靠裁掉按钮过日子）。

var content: Control = null
## UI-01：apply_text_policy() 实际改过的 Label 数（>0 说明策略跑到了）。
var policy_wrapped: int = 0

var _width: float = UiContract.SIDEBAR_PREF_W


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(_width, 0.0)
	resized.connect(_apply)


## 装内容（唯一子节点）：填满外壳宽，纵向可滚动由内容自己负责。
func set_content(c: Control) -> void:
	content = c
	if c.get_parent() != self:
		add_child(c)
	c.position = Vector2.ZERO
	_apply()


## 设置目标宽（按 UI-01 契约范围钳制）。同值调用直接返回，便于每帧刷新档位。
func set_width(w: float) -> void:
	var nw: float = UiContract.sidebar_clamp_x(w)
	if is_equal_approx(nw, _width):
		return
	_width = nw
	custom_minimum_size = Vector2(_width, custom_minimum_size.y)
	_apply()


func target_width() -> float:
	return _width


## 按窗口尺寸刷新档位宽度（只依赖窗口像素宽，与内容无关），再压内容尺寸。
func refresh() -> void:
	set_width(UiContract.sidebar_width_for(_window_width()))
	_apply()


## 窗口**像素**宽。注意 canvas_items 拉伸下 get_viewport_rect() 恒等于设计分辨率
## （1280×720），只有 Window.size 反映真实窗口尺寸——UI-01 要按窗口分档。
func _window_width() -> float:
	var w: Window = get_window()
	if w != null and w.size.x >= 200:
		return float(w.size.x)
	if is_inside_tree():
		return get_viewport_rect().size.x
	return UiContract.SIDEBAR_PREF_W


## 内容实际占用宽（超宽时 > target_width；正常应相等）。
func content_width() -> float:
	return content.size.x if content != null else 0.0


## UI-01 调试输出：实际 rect / combined_minimum_size / 最宽子控件。
## 用于定位"还在撑宽侧栏"的子控件（T22；测试失败时打印本报告）。
static func audit(shell: SidebarShell) -> Dictionary:
	var out: Dictionary = {
		"target": shell.target_width(),
		"rect": Rect2(shell.global_position, shell.size),
		"actual": shell.content_width(),
		"top_bar_min": 0.0,
		"pages": {},
	}
	if shell.content == null:
		return out
	out["top_bar_min"] = (
		(shell.content as RightSidebarPager).top_bar.get_combined_minimum_size().x
		if shell.content is RightSidebarPager
		else 0.0
	)
	if not (shell.content is RightSidebarPager):
		return out
	var pager: RightSidebarPager = shell.content
	var pages: Dictionary = {}
	for pid in pager.page_ids():
		var body: Control = pager.page_body(pid)
		var info: Dictionary = _audit_one(body, str(pid))
		info["min"] = body.get_combined_minimum_size().x
		info["overflow"] = maxf(info["min"] - shell.target_width(), 0.0)
		pages[str(pid)] = info
	out["pages"] = pages
	return out


## 单页报告：最宽**可辨认**子控件 + 其位置（便于直接定位到装配代码）。
static func _audit_one(body: Control, pid: String) -> Dictionary:
	var ctx: Dictionary = {"best": -1.0, "path": pid, "leaf": ""}
	_walk(body, body.get_path(), ctx)
	return {"widest": ctx["leaf"], "path": ctx["path"], "width": ctx["best"]}


static func _walk(n: Control, root: NodePath, ctx: Dictionary) -> void:
	for c in n.get_children():
		if not (c is Control):
			continue
		var cc: Control = c as Control
		# 只记"可辨认"的控件（带文本）或叶子控件：容器只是传导，不是根因。
		var desc: String = _describe(cc)
		if desc != "" or not _has_control_child(cc):
			var w: float = cc.get_combined_minimum_size().x
			if w > float(ctx["best"]):
				ctx["best"] = w
				ctx["path"] = str(root).simplify_path() + ":" + str(cc.get_path()).split("/")[-1]
				ctx["leaf"] = "%s = %.1f" % [desc if desc != "" else cc.get_class(), w]
		_walk(cc, root, ctx)


static func _has_control_child(c: Control) -> bool:
	for ch in c.get_children():
		if ch is Control:
			return true
	return false


static func _describe(c: Control) -> String:
	var txt: String = ""
	if c is Label:
		txt = str((c as Label).text).substr(0, 40)
	elif c is Button:
		txt = str((c as Button).text).substr(0, 30)
	elif c is OptionButton:
		txt = str((c as OptionButton).get_item_text(0)).substr(0, 24)
	if txt == "":
		return ""
	return "%s[%s] %s" % [c.get_class(), c.name, txt]


## UI-01 文本策略：侧栏内**所有** Label 允许换行 → 内容只改变高度。
## 逐条给新控件补 autowrap 一定会漏（漏一条就撑宽侧栏），所以在整棵侧栏装配
## **完成后**统一施加，并让 sidebar_width_test W-07（把每个 Label 都灌成超长
## 文案，断言分页器不宽于外壳）守住这条策略。返回被改动的 Label 数（供测试断言，
## 避免"策略没跑到"却静默通过）。
## 注意：运行期**动态新建**的行不在本策略范围内（装配期已过），它们必须自己设
## autowrap（例：ThreatHud._row），由 W-04/W-03 的"注入后复检"守住。
func apply_text_policy() -> int:
	policy_wrapped = _wrap_labels_all(self, 0)
	_apply()
	return policy_wrapped


static func _wrap_labels_all(node: Node, count: int) -> int:
	for c in node.get_children():
		if c is Label:
			var l: Label = c as Label
			if l.autowrap_mode == TextServer.AUTOWRAP_OFF:
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				count += 1
		count = _wrap_labels_all(c, count)
	return count


func _apply() -> void:
	if content == null:
		return
	content.position = Vector2.ZERO
	content.size = Vector2(_width, maxf(size.y, 0.0))
