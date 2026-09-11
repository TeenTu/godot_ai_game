extends SceneTree
## sidebar_width_test.gd — P1-B UI-01：侧栏宽度由窗口布局决定，内容只改变高度（T22）。
##
## 运行：godot --headless --path games/sonar --script res://tools/sidebar_width_test.gd
## 必须输出 "SIDEBAR_WIDTH_TEST result=PASS"。
##
## 本测试故意**不**只断言"钳制函数返回 420"（那种断言对真实故障零辨别力）：
##   W-01 机制：宽度源是 SidebarShell（非 Container）的自定义最小宽——尺寸传播链
##        在它这里断开；分页器与每页正文的最小宽都不再参与外壳宽度；
##   W-02 分档：宽度只随窗口尺寸（1280→320 / 1440→340 / 1920→340 / 2200→380），
##        全部落在 300–420 契约内；
##   W-03 不变量：同一窗口下注入**超长**中文文案（选中摘要/机动 ACT-CMD/锁定组/
##        告警条）、切页、加威胁告警，外壳与分页器宽度一字不变（≤1 逻辑像素）；
##   W-04 内容不裁剪：逐页正文实际宽 ≤ ScrollContainer 可用宽（无横向溢出），
##        且横向滚动条始终不可见（关键控件靠纵向滚动可达）；
##   W-05 OptionButton 不按最长项撑宽：注入超长组名并选中后，行/页/外壳宽度不变；
##   W-06 不靠裁掉按钮换布局：接触卡四动作与分页按钮仍在，且都藏在侧栏矩形内。
## headless --script 不自动调 _process：显式 ui._process()；布局需 await 帧。


func _init() -> void:
	await _run()


func _run() -> void:
	var fails: Array = []
	# 窗口像素宽 → 期望档位（canvas_items 拉伸下 viewport_rect 恒为 1280×720，
	# 只有真实窗口尺寸才能区分分档）。
	for cfg in [[1280, 720, 320.0], [1440, 900, 340.0], [1920, 1080, 340.0], [2200, 1200, 380.0]]:
		await _one_resolution(fails, int(cfg[0]), int(cfg[1]), float(cfg[2]))
	_finish(fails)


func _one_resolution(fails: Array, w: int, h: int, want_w: float) -> void:
	var ui: Control = await _mk_ui(w, h)
	var tag: String = "%dx%d" % [w, h]
	_t_mechanism(fails, ui, tag)
	_t_width_band(fails, ui, tag, want_w)
	_t_content_fits(fails, ui, tag)
	await _t_long_text_invariance(fails, ui, tag)
	await _t_option_button_no_push(fails, ui, tag)
	_t_key_controls_reachable(fails, ui, tag)
	await _t_every_label_wrapable(fails, ui, tag)
	ui.queue_free()
	await process_frame


func _mk_ui(w: int, h: int) -> Control:
	root.size = Vector2i(w, h)
	await process_frame
	await process_frame
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	await process_frame
	ui._process(0.01)
	await process_frame
	return ui


# ---------------------------------------------------------------- W-01 机制
## 宽度源必须是"非 Container 外壳"：只有它才能既不聚合子节点最小宽，又能
## 由窗口布局决定宽度。custom_minimum_size / 每帧 size.x 钳制都不具备该性质。
func _t_mechanism(fails: Array, ui: Control, tag: String) -> void:
	var sh: SidebarShell = ui._sidebar
	_assert_bool(fails, "W-01 %s shell exists" % tag, sh != null and ui._pager != null, true)
	if sh == null:
		return
	var as_node: Node = sh
	_assert_bool(fails, "W-01 %s shell is not a Container" % tag, as_node is Container, false)
	_assert_bool(fails, "W-01 %s shell hosts pager" % tag, sh.content == ui._pager, true)
	_assert_bool(fails, "W-01 %s pager not in HBox" % tag, ui._pager.get_parent() == sh, true)
	# 页面正文不再自带 SIDEBAR_MIN_W 下限（宽度由外壳给，不由内容给）。
	var body: Control = ui._pager.page_body("sonar")
	_assert_bool(fails, "W-01 %s body no width floor" % tag, body.custom_minimum_size.x, 0.0)
	_assert_bool(
		fails,
		"W-01 %s shell min == target" % tag,
		is_equal_approx(sh.get_combined_minimum_size().x, sh.target_width()),
		true
	)


# ---------------------------------------------------------------- W-02 分档
func _t_width_band(fails: Array, ui: Control, tag: String, want_w: float) -> void:
	var sh: SidebarShell = ui._sidebar
	_assert_bool(
		fails, "W-02 %s band width" % tag, is_equal_approx(sh.target_width(), want_w), true
	)
	_assert_bool(
		fails,
		"W-02 %s in contract range" % tag,
		(
			sh.target_width() >= UiContract.SIDEBAR_MIN_W
			and sh.target_width() <= UiContract.SIDEBAR_MAX_W
		),
		true
	)
	# 外壳拿到**恰好**目标宽（SHRINK_BEGIN → 等于自身最小宽），内容也正好铺满。
	_assert_bool(
		fails, "W-02 %s shell actual == target" % tag, is_equal_approx(sh.size.x, want_w), true
	)
	_assert_bool(
		fails,
		"W-02 %s pager actual == target" % tag,
		is_equal_approx(ui._pager.size.x, want_w),
		true
	)
	_assert_bool(
		fails,
		"W-02 %s content fills shell" % tag,
		is_equal_approx(sh.content_width(), want_w),
		true
	)
	_assert_bool(fails, "W-02 %s chart kept" % tag, ui._chart.size.x > 100.0, true)


# ---------------------------------------------------------------- W-04 不裁剪
## 逐页：正文实际宽 ≤ 滚动可用宽；无横向滚动条。失败时打印 audit（实际 rect /
## combined_minimum_size / 最宽可辨认子控件）用于定位超宽来源。
func _t_content_fits(fails: Array, ui: Control, tag: String) -> void:
	var sh: SidebarShell = ui._sidebar
	var rep: Dictionary = SidebarShell.audit(sh)
	# 最强不变量：分页器（外壳唯一子节点）任何时刻不得宽于外壳——宽了就是被裁掉。
	if ui._pager.size.x > sh.target_width() + 1.0:
		_dump(rep, tag, "pager", "pager wider than shell")
	_assert_bool(
		fails,
		"W-04 %s pager not wider than shell" % tag,
		ui._pager.size.x <= sh.target_width() + 1.0,
		true
	)
	for pid in ui._pager.page_ids():
		var sc: ScrollContainer = ui._pager.page_scroll(pid)
		var body: Control = ui._pager.page_body(pid)
		var info: Dictionary = (rep["pages"] as Dictionary)[str(pid)]
		var avail: float = sc.size.x
		if sc.get_v_scroll_bar() != null and sc.get_v_scroll_bar().visible:
			avail -= sc.get_v_scroll_bar().size.x
		if not bool(body.size.x <= avail + 1.0):
			_dump(rep, tag, pid, "page overflow")
		_assert_bool(
			fails, "W-04 %s body not clipped %s" % [tag, pid], body.size.x <= avail + 1.0, true
		)
		_assert_bool(
			fails, "W-04 %s no h-scroll %s" % [tag, pid], not sc.get_h_scroll_bar().visible, true
		)
		# 内容本身的最小宽（未裁剪前的需求）也必须 ≤ 外壳目标宽——否则一旦
		# 子控件再多一点就会被裁掉；这正是"定位超宽子控件"的硬门槛。
		if float(info["min"]) > sh.target_width() - 16.0:
			_dump(rep, tag, pid, "min width too close")
		_assert_bool(
			fails,
			"W-04 %s page min under target %s" % [tag, pid],
			float(info["min"]) <= sh.target_width() - 16.0,
			true
		)
	# 顶栏（不在滚动容器内）同样不得超宽。
	_assert_bool(
		fails,
		"W-04 %s top bar fits" % tag,
		float(rep["top_bar_min"]) <= sh.target_width() - 8.0,
		true
	)


# ---------------------------------------------------------------- W-03 不变量
## 注入超长中文文案 + 切页 + 加威胁告警：宽度必须一字不变，海图宽度也稳定。
func _t_long_text_invariance(fails: Array, ui: Control, tag: String) -> void:
	var sh: SidebarShell = ui._sidebar
	var w0: float = sh.target_width()
	var p0: float = ui._pager.size.x
	var chart0: float = ui._chart.size.x
	var long_txt: String = "超长接触摘要与机动命令文案用于撑宽测试"
	# ① 顶栏固定区：选中摘要 + 锁定目的组。
	ui._lbl_selected.text = "选中：" + long_txt + long_txt + long_txt
	ui._lbl_mark_lock.text = "锁定：" + long_txt + long_txt
	# ② 本艇机动 ACT/CMD/ETA 长串。
	var mp: OwnManeuverPanel = ui._own_panel
	var cmd_txt: String = "实际 航向 359° 航速 30.0 节 | 命令 0° 预计 42s | 深度 400 米 下层"
	mp._lbl_cmd.text = cmd_txt + " | " + cmd_txt
	# ③ 告警条：注入真威胁证据（净化 DTO）→ 长告警行。
	var wld: World = ui.world
	(
		wld
		. threat_tracks
		. ingest(
			{
				"evidence_id": 97101,
				"evidence_kind": "RUNNING_NOISE",
				"timestamp": wld.sim_time,
				"bearing_deg": 355.0,
				"bearing_sigma_deg": 3.0,
				"p_torpedo": 0.93,
				"class_state": "PROBABLE_TORPEDO",
			},
			wld.sim_time
		)
	)
	ui._process(0.01)
	await process_frame
	_assert_bool(fails, "W-03 %s alert present" % tag, ui._threat_hud.banner_text() != "", true)
	# 长文案确实超过了侧栏宽（否则本测试没有辨别力）——换行/省略已生效。
	_assert_bool(
		fails,
		"W-03 %s long summary wraps" % tag,
		ui._lbl_selected.get_combined_minimum_size().x <= w0 - 8.0,
		true
	)
	_assert_bool(
		fails,
		"W-03 %s long cmd wraps" % tag,
		mp._lbl_cmd.get_combined_minimum_size().x <= w0 - 8.0,
		true
	)
	_assert_bool(fails, "W-03 %s banner wraps" % tag, _banner_min(ui) <= w0 - 8.0, true)
	_assert_bool(
		fails, "W-03 %s width unchanged" % tag, is_equal_approx(sh.target_width(), w0), true
	)
	_assert_bool(
		fails, "W-03 %s pager width unchanged" % tag, is_equal_approx(ui._pager.size.x, p0), true
	)
	_assert_bool(
		fails, "W-03 %s chart width stable" % tag, is_equal_approx(ui._chart.size.x, chart0), true
	)
	# ④ 切页同样不得改变宽度。
	for pid in ui._pager.page_ids():
		ui._pager.select(pid)
		ui._process(0.01)
		await process_frame
		_assert_bool(
			fails,
			"W-03 %s page switch keeps width %s" % [tag, pid],
			(
				is_equal_approx(sh.target_width(), w0)
				and is_equal_approx(ui._pager.size.x, p0)
				and is_equal_approx(ui._chart.size.x, chart0)
			),
			true
		)
	_t_content_fits(fails, ui, tag + "/after-alert")


# ---------------------------------------------------------------- W-05 OptionButton
## 禁用"最长项撑宽"后：把超长组名塞进 Mark 组下拉并选中，宽度仍不变、
## 页面仍不溢出（属性 + 功能双重断言，避免只测属性开关）。
func _t_option_button_no_push(fails: Array, ui: Control, tag: String) -> void:
	var sh: SidebarShell = ui._sidebar
	var w0: float = sh.target_width()
	_assert_bool(fails, "W-05 %s every option tamed" % tag, _all_options_tamed(ui._pager), true)
	var ob: OptionButton = ui.mark_panel._opt_group
	_assert_bool(fails, "W-05 %s group option exists" % tag, ob != null, true)
	if ob == null:
		return
	var idx: int = ob.item_count
	var long_item: String = "超长目的组名称超长目的组名称超长目的组名称超长目的组名称"
	ob.add_item(long_item)
	ob.select(idx)
	ob.item_selected.emit(idx)  # 真实路径：用户选择 → 同步全文 tooltip
	ui._process(0.01)
	await process_frame
	# clip_text 把最小宽压到可读下限（不是 0）：按钮仍看得见当前项，不撑宽侧栏。
	_assert_bool(
		fails,
		"W-05 %s clipped min readable" % tag,
		ob.get_combined_minimum_size().x <= w0 - 8.0 and ob.get_combined_minimum_size().x >= 60.0,
		true
	)
	# 省略后可查看全文（tooltip）。
	_assert_bool(fails, "W-05 %s full text in tooltip" % tag, ob.tooltip_text == long_item, true)
	_assert_bool(
		fails, "W-05 %s width unchanged" % tag, is_equal_approx(sh.target_width(), w0), true
	)
	_assert_bool(
		fails, "W-05 %s pager width unchanged" % tag, is_equal_approx(ui._pager.size.x, w0), true
	)
	_assert_bool(
		fails,
		"W-05 %s pager never wider than shell" % tag,
		ui._pager.size.x <= sh.target_width() + 1.0,
		true
	)
	ob.remove_item(idx)
	ob.select(0)
	ui._process(0.01)
	await process_frame


# ---------------------------------------------------------------- W-06 可达性
## 不以裁掉按钮代替布局：接触卡四动作、分页按钮都还在，且都在侧栏矩形内。
func _t_key_controls_reachable(fails: Array, ui: Control, tag: String) -> void:
	var sh: SidebarShell = ui._sidebar
	var pr: Rect2 = Rect2(sh.global_position, sh.size)
	var ids: Array = ui._pager.page_ids()
	_assert_bool(fails, "W-06 %s page buttons kept" % tag, ids.size() == 3, true)
	var card: ContactCard = _find_card(ui)
	_assert_bool(
		fails,
		"W-06 %s four actions kept" % tag,
		card != null and card.action_button_count() == 4,
		true
	)
	var inside: bool = true
	for pid in ids:
		var b: Button = ui._pager._btns[pid]
		if not _in_rect(b, pr):
			inside = false
	if card != null:
		for c in card.action_row.get_children():
			if not _in_rect(c as Control, pr):
				inside = false
	_assert_bool(
		fails, "W-06 %s buttons inside sidebar %s" % [tag, str(card != null)], inside, true
	)


func _in_rect(c: Control, r: Rect2) -> bool:
	return (
		c.global_position.x >= r.position.x - 1.0
		and c.global_position.x + c.size.x <= r.end.x + 1.0
	)


# ---------------------------------------------------------------- W-07 通用换行
## 把侧栏里**每一个** Label 都塞成超长中文再量：任何一条没有换行/省略能力的
## Label 都会把页面最小宽顶上去 → 分页器宽于外壳（被裁）。这是"最长文案不撑宽
## 侧栏"的通用机制门槛，比逐条断言单个标签更有辨别力。用完即释放整棵 UI。
func _t_every_label_wrapable(fails: Array, ui: Control, tag: String) -> void:
	var sh: SidebarShell = ui._sidebar
	var labs: Array = []
	_collect_labels(ui._pager, labs)
	_assert_bool(fails, "W-07 %s labels found" % tag, labs.size() > 8, true)
	# 策略必须真的跑过（否则本用例会静默通过在"没有策略"的实现上）。
	_assert_bool(fails, "W-07 %s text policy applied" % tag, int(sh.policy_wrapped) > 0, true)
	for l in labs:
		(l as Label).text = "超长动态文案用于侧栏宽度不变量测试"
	# 不 await 帧：await 会触发 UI._process 重建动态行并把刚收集的 Label 释放掉。
	# 最小宽传播是同步的（Label.set_text → update_minimum_size 立即失效缓存）。
	var over: float = ui._pager.get_combined_minimum_size().x - sh.target_width()
	if over > 1.0:
		_w07_dump(ui._pager, sh.target_width())
	_assert_bool(fails, "W-07 %s long labels never push sidebar" % tag, over <= 1.0, true)
	_assert_bool(
		fails,
		"W-07 %s pager not wider than shell" % tag,
		ui._pager.size.x <= sh.target_width() + 1.0,
		true
	)


func _collect_labels(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Label:
			out.append(c)
		_collect_labels(c, out)


## 诊断：按最小宽倒序列出超宽节点（含父节点），定位是"单个超宽控件"还是"几个
## 控件相加"。宽限 = 目标宽 - 16（留给竖向滚动条）。
func _w07_dump(n: Node, target: float) -> void:
	var rows: Array = []
	_scan_min(n, target - 16.0, rows, "")
	rows.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	print("--- W-07 offenders (limit=%.0f, top 8) ---" % (target - 16.0))
	for i in range(mini(8, rows.size())):
		print("    w=%.1f  %s" % [rows[i][0], rows[i][1]])
		var npath: String = str(rows[i][1]).split(" [")[0]
		var node: Node = n.get_node_or_null(NodePath(npath.lstrip("/")))
		if node != null:
			for c in node.get_children():
				var t: String = ""
				if c is Label:
					t = " text=" + str((c as Label).text).substr(0, 18)
				elif c is Button:
					t = " text=" + str((c as Button).text).substr(0, 14)
				var cw: float = (
					(c as Control).get_combined_minimum_size().x if c is Control else 0.0
				)
				print("        .%s w=%.1f%s" % [c.get_class(), cw, t])


func _scan_min(n: Node, limit: float, out: Array, path: String) -> void:
	for c in n.get_children():
		var here: String = path + "/" + str(c.name)
		if c is Control:
			var cc: Control = c as Control
			var w: float = cc.get_combined_minimum_size().x
			if w > limit:
				out.append([w, "%s [%s]" % [here, cc.get_class()]])
		_scan_min(c, limit, out, here)


# ---------------------------------------------------------------- 辅助
func _banner_min(ui: Control) -> float:
	var lb: Label = ui._threat_hud._banner_lbl
	return lb.get_combined_minimum_size().x if lb != null else 0.0


func _all_options_tamed(n: Node) -> bool:
	for c in n.get_children():
		if c is OptionButton:
			var ob: OptionButton = c as OptionButton
			if ob.fit_to_longest_item or not ob.clip_text:
				return false
		if not _all_options_tamed(c):
			return false
	return true


func _find_card(node: Node) -> ContactCard:
	for c in node.get_children():
		if c is ContactCard:
			return c as ContactCard
		var r: ContactCard = _find_card(c)
		if r != null:
			return r
	return null


func _dump(rep: Dictionary, tag: String, pid: String, why: String) -> void:
	print("--- UI-01 audit (%s / %s / %s) ---" % [tag, pid, why])
	print(
		(
			"    target=%.1f actual=%.1f top_bar=%.1f"
			% [rep["target"], rep["actual"], rep["top_bar_min"]]
		)
	)
	var info: Dictionary = (rep["pages"] as Dictionary)[str(pid)]
	print("    min=%.1f over=%.1f widest=%s" % [info["min"], info["overflow"], info["widest"]])


func _assert_bool(fails: Array, name: String, got: Variant, want: Variant) -> void:
	var ok: bool = false
	if got is float or want is float:
		ok = is_equal_approx(float(got), float(want))
	else:
		ok = got == want
	if not ok:
		fails.append("%s (got=%s want=%s)" % [name, str(got), str(want)])


func _finish(fails: Array) -> void:
	if fails.is_empty():
		print("SIDEBAR_WIDTH_TEST result=PASS")
		quit(0)
	else:
		for f in fails:
			print("TEST FAIL: " + str(f))
		print("SIDEBAR_WIDTH_TEST result=FAIL (%d)" % fails.size())
		quit(1)
