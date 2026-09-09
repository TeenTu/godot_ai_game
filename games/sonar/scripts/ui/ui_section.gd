class_name UiSection
extends RefCounted
## ui_section.gd — 可折叠区块（从 main_ui 抽出的原 "▼/▲ 标题 + body" 行为）。
## S109 Batch 5 分页重构抽公共件；body 同时挂在 meta("body") 上供取回。


static func make(title_text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var head := Button.new()
	head.text = "▼ " + title_text
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 14)
	var body := VBoxContainer.new()
	head.pressed.connect(
		func():
			body.visible = not body.visible
			head.text = ("▼ " if body.visible else "▲ ") + title_text
	)
	box.add_child(head)
	box.add_child(body)
	box.set_meta("body", body)
	return box


static func body(box: VBoxContainer) -> VBoxContainer:
	return box.get_meta("body") as VBoxContainer


## 一行「标题 + SpinBox」控件（main_ui 试算参数等复用，S109 Batch 7 拆行）。
static func spin_row(
	pg: Control, title: String, min_v: float, max_v: float, step: float, val: float
) -> SpinBox:
	var lbl := Label.new()
	lbl.text = title
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = step
	sp.value = val
	sp.allow_greater = true
	sp.allow_lesser = true
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(lbl)
	box.add_child(sp)
	pg.add_child(box)
	return sp
