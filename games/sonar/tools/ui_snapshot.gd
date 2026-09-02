extends SceneTree
## ui_snapshot.gd — 生成 UI 截图（本机带渲染环境运行）：
##   Godot_v4.5-stable_win64.exe --path games/sonar --script res://tools/ui_snapshot.gd
## 输出 games/sonar/tools/ui_preview.png。
## 模拟：先跑 20 分钟仿真（产生两腿几何），本艇中途机动，然后 Auto Fit + Enter。


func _init() -> void:
	_run()


func _run() -> void:
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	await process_frame
	# 推进 10 分钟仿真（480s），期间本艇转向形成两腿几何
	for i in range(960):
		ui._process(0.5)
		if i == 480:
			ui.world.world["own"].course_deg = NavUtils.wrap360(
				ui.world.world["own"].course_deg + 70.0
			)
	# 自动拟合 + 提交
	ui._on_fit_tma()
	await process_frame
	await process_frame
	# 截图
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("res://tools/ui_preview.png")
	print("SNAPSHOT saved, fit status: ", ui.last_fit.get("status", "none"))
	print("fit summary:\n", ui._lbl_tma.text)
	quit(0)
