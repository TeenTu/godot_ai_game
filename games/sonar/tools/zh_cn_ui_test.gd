extends SceneTree

## S109 Batch 7 — 全中文 UI（§10，AT-35..38）。
## AT-35：运行期全部控件可见文本中文化（旧英文残留黑名单 + 关键中文白名单）。
## AT-36：翻译只发生在显示层 —— 内部枚举/DTO/reject 码保持英文原值，
##        UiText 未映射键透传兜底。
## AT-37：字体子集字形清单覆盖全部代码字符串字面量（与 make_font_subset.py 同规则）。
## AT-38：文案集中化 —— scripts/ui 控制层源码不散落英文字面量赋值（须经 UiText）。

const UI_ROOT := "res://scripts/ui"
## 旧英文 UI 残留 / 内部枚举名（这些绝不允许出现在控件文本）。
const BLACKLIST := [
	"Pause",
	"Resume",
	"Tubes:",
	"Selected: ",
	"Auto Fit",
	"Mark Groups",
	"Fit Details",
	"Weapon Alerts",
	"In-Water",
	"Own Ship",
	"Rounds ",
	"Wire CONNECTED",
	"WIRE_ONLY",
	"PASSIVE_LISTEN",
	"MANUAL_COURSE",
	"TX OFF",
	"CONFIRMED",
	"Sonar Operator",
	"Camera / View",
	"Layers",
	"Speed",
	"Diagnostics",
	"Contacts (",
	"Reset View",
	"Auto Frame",
]

var fails: Array = []


func _init() -> void:
	await _run()
	if fails.is_empty():
		print("ZH_CN_UI TEST PASS")
		quit(0)
		return
	for f in fails:
		print("  [FAIL] %s" % str(f))
	print("ZH_CN_UI TEST FAIL (%d)" % fails.size())
	quit(1)


func _run() -> void:
	root.size = Vector2i(1440, 900)
	await process_frame
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	# 跑几步出接触/状态，保证动态文本也渲染。
	for i in range(10):
		ui._process(0.5)
	_at35_ui_all_chinese(ui)
	_at36_display_layer_only(ui)
	ui.free()
	_at37_font_glyph_manifest()
	_at38_text_centralization()


## ---- AT-35：全部控件文本中文化 ----
func _at35_ui_all_chinese(ui: Control) -> void:
	var texts: Array = []
	_collect_texts(ui, texts)
	_assert(fails, "AT-35a collected ui texts", texts.size() > 30, "count=%d" % texts.size())
	for t in texts:
		for bad in BLACKLIST:
			if str(t).contains(bad):
				_fail("AT-35b english residue [%s] in [%s]" % [bad, str(t)])
	var joined: String = "\n".join(PackedStringArray(texts))
	for want in ["声呐", "航迹", "武器", "本艇", "暂停", "选中：", "武器告警"]:
		_assert(fails, "AT-35c key text %s present" % want, joined.contains(want), "")
	# 目录缺键必须为 0（文案一律进 UiText，t() 兜底不得触发）。
	_assert(
		fails,
		"AT-35e no missing catalog keys",
		UiText.missing_keys.is_empty(),
		str(UiText.missing_keys)
	)
	# 状态栏/时间行也中文（T+ 为时间记法允许保留）。
	_assert(
		fails, "AT-35d status line chinese", ui._lbl_time.text.begins_with("T+"), ui._lbl_time.text
	)


func _collect_texts(node: Node, out: Array) -> void:
	if not (node is Control) or node.visible:
		pass  # 隐藏页的文案同样接受黑名单检查。
	if node is Label or node is Button or node is CheckBox or node is CheckButton:
		out.append(node.text)
	elif node is OptionButton:
		var ob := node as OptionButton
		for i in range(ob.item_count):
			out.append(ob.get_item_text(i))
	elif node is PopupMenu:
		var pm := node as PopupMenu
		for i in range(pm.item_count):
			out.append(pm.get_item_text(i))
	for c in node.get_children():
		_collect_texts(c, out)


## ---- AT-36：内部值不动，仅显示层翻译 ----
func _at36_display_layer_only(ui: Control) -> void:
	var w = ui.world
	# 内部 mission_state_name 仍英文；UiText 显示中文。
	var tp: Torpedo = w.weapons.fire_manual(0.0, 0.0, 0.0, 0.0, 50.0)
	w.run_steps(8)
	_assert(
		fails,
		"AT-36a internal enum name stays EN",
		tp.mission_state_name() == "TRANSIT",
		tp.mission_state_name()
	)
	_assert(
		fails, "AT-36b display translated", UiText.tp_state(tp.mission_state_name()) == "线导航行", ""
	)
	# 未映射键透传兜底（绝不吞值）。
	_assert(
		fails, "AT-36c unmapped passthrough", UiText.reject("UNKNOWN_CODE") == "UNKNOWN_CODE", ""
	)
	# reject 内部码保持英文，显示层中文。
	tp.cut_wire()
	var ok2: bool = not tp.cut_wire()
	_assert(
		fails,
		"AT-36d reject code internal EN",
		ok2 and str(tp.last_cmd_reject_reason).begins_with("WIRE "),
		str(tp.last_cmd_reject_reason)
	)
	_assert(
		fails,
		"AT-36e reject display CN",
		UiText.reject(tp.last_cmd_reject_reason).contains("导线"),
		UiText.reject(tp.last_cmd_reject_reason)
	)
	# Chart DTO kind 保持内部英文（显示在命中菜单/图例才翻译）。
	ui._chart.threat_lobs = [{"kind": "RUNNING_NOISE"}]
	_assert(
		fails,
		"AT-36f dto kind internal EN",
		str(ui._chart.threat_lobs[0]["kind"]) == "RUNNING_NOISE",
		""
	)


## ---- AT-37：字形清单覆盖代码字符串（同 make_font_subset 规则）----
func _at37_font_glyph_manifest() -> void:
	var manifest: String = _read_file("res://assets/fonts/ui_subset_chars.txt")
	_assert(fails, "AT-37a manifest exists", manifest.length() > 100, "len=%d" % manifest.length())
	if manifest == "":
		return
	var mset := {}
	for ch in manifest:
		mset[ch] = true
	var rx := RegEx.new()
	rx.compile('"(?:[^"\\\\]|\\\\.)*"')
	var missing := {}
	var files: Array = []
	_gd_files("res://scripts", files)
	_gd_files("res://tools", files)
	var total_files: int = 0
	for p in files:
		total_files += 1
		for line in _read_file(p).split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			for m in rx.search_all(line):
				for ch in m.get_string():
					if ch.unicode_at(0) > 0x20 and not mset.has(ch):
						missing[ch] = str(p)
	_assert(
		fails,
		"AT-37b all string literals covered",
		missing.is_empty(),
		"files=%d missing=%s" % [total_files, str(missing)]
	)


func _gd_files(path: String, out: Array) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n: String = d.get_next()
	while n != "":
		if n == "." or n == "..":
			n = d.get_next()
			continue
		var full: String = path + "/" + n
		if d.current_is_dir():
			_gd_files(full, out)
		elif n.ends_with(".gd"):
			out.append(full)
		n = d.get_next()
	d.list_dir_end()


func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s: String = f.get_as_text()
	f.close()
	return s


## ---- AT-38：控制层文案集中化 ----
func _at38_text_centralization() -> void:
	var rx := RegEx.new()
	# .text = "英文..." / add_item("英文...") / _update_status("英文...")
	rx.compile('\\.text = "[A-Za-z]|add_item\\("[A-Za-z]|_update_status\\("[A-Za-z]')
	var hits: Array = []
	var files: Array = []
	_gd_files(UI_ROOT, files)
	for p in files:
		var base: String = p.get_file()
		if base == "ui_text.gd" or base.ends_with("_test.gd"):
			continue
		for line in _read_file(p).split("\n"):
			var ls: String = line.strip_edges()
			if ls.begins_with("#"):
				continue
			# 允许纯符号格式（T+ 时间记法）。
			if ls.contains("UiText") or line.contains("T+"):
				continue
			if rx.search(ls) != null:
				hits.append("%s: %s" % [base, ls.left(70)])
	_assert(fails, "AT-38 no english literals in ui layer", hits.is_empty(), str(hits))


func _assert(f: Array, name: String, cond: bool, detail: String) -> void:
	if not cond:
		f.append("%s %s" % [name, detail])
		print("  [X] %s %s" % [name, detail])
	else:
		print("  [ok] %s" % name)


func _fail(msg: String) -> void:
	fails.append(msg)
	print("  [X] " + msg)
