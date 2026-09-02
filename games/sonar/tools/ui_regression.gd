extends SceneTree
## ui_regression.gd — TMA 可视化 7 状态截图回归（1280x720，带渲染环境运行）：
##   Godot_v4.5-stable_win64.exe --path games/sonar --script res://tools/ui_regression.gd
## 输出 games/sonar/tools/regression/<state>.png 共 7 张：
##   NO_FIT / CONVERGED / MULTIMODAL / INSUFFICIENT_GEOMETRY / STALE /
##   OUTLIER / NORTH_CROSSING


func _init() -> void:
	_run()


func _prepare(sim_frames: int, turn_at: int = -1) -> Control:
	var ui: Control = (load("res://scripts/ui/main_ui.gd") as GDScript).new()
	root.add_child(ui)
	root.size = Vector2i(1280, 720)
	await process_frame
	for i in range(sim_frames):
		ui._process(0.5)
		if i == turn_at:
			ui.world.world["own"].course_deg = NavUtils.wrap360(
				ui.world.world["own"].course_deg + 70.0
			)
	for t in ui.tracker.all_tracks():
		if t.state == Track.TrackState.ACTIVE and t.measurement_history.size() >= 4:
			ui.selected_track_id = t.track_id
			break
	ui._dirty = true
	ui._rebuild_display_data()
	return ui


func _shot(ui: Control, name: String) -> void:
	await process_frame
	await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://tools/regression")
	img.save_png("res://tools/regression/%s.png" % name)
	print("REGRESSION %s saved (fit=%s)" % [name, ui._chart.fit_status])


func _run() -> void:
	# 1) NO_FIT：未拟合直接截图
	var ui: Control = await _prepare(160)
	await _shot(ui, "NO_FIT")
	ui.queue_free()

	# 2) INSUFFICIENT_GEOMETRY：单腿（不机动）拟合
	ui = await _prepare(200)
	ui._on_fit_tma()
	await _shot(ui, "INSUFFICIENT_GEOMETRY")
	ui.queue_free()

	# 3) CONVERGED：两腿（480s 处 +70° 转向）拟合
	ui = await _prepare(960, 480)
	ui._on_fit_tma()
	var converged_ok: bool = (
		str(ui.last_fit.get("status", "")) == "CONVERGED" and ui._chart.fit_cov_pos.size() == 2
	)
	await _shot(ui, "CONVERGED")
	print("REGRESSION CONVERGED check: ", "PASS" if converged_ok else "FAIL")
	ui.queue_free()

	# 4) MULTIMODAL：单腿镜像歧义 → 强制标记多假设
	ui = await _prepare(200)
	var synth: Array = []
	var t0: float = 0.0
	var obs := Vector2.ZERO
	for i in range(40):
		(
			synth
			. append(
				{
					"time": t0 + i * 4.0,
					"observer_e": obs.x,
					"observer_n": obs.y,
					"bearing": 42.0 + 0.05 * i,
					"sigma": 0.8,
				}
			)
		)
	var r: Dictionary = TmaSolver.solve_auto(synth, {"now_time": 160.0})
	if bool(r.get("success", false)):
		r["status"] = "MULTIMODAL"
		r["track_id"] = ui.selected_track_id
		ui.last_fit = r
		ui._dirty = true
		ui._rebuild_display_data()
	await _shot(ui, "MULTIMODAL")
	ui.queue_free()

	# 5) STALE：两腿拟合后人为加大 stale
	ui = await _prepare(960, 480)
	ui._on_fit_tma()
	if not ui.last_fit.is_empty() and bool(ui.last_fit.get("success", false)):
		ui.last_fit["status"] = "STALE"
		ui.last_fit["stale_seconds"] = 900.0
		ui._chart.fit_status = "STALE"
		ui._dirty = true
		ui._rebuild_display_data()
	await _shot(ui, "STALE")
	ui.queue_free()

	# 6) OUTLIER：两腿拟合后把部分残差标为离群
	ui = await _prepare(960, 480)
	ui._on_fit_tma()
	if not ui.last_fit.is_empty() and bool(ui.last_fit.get("success", false)):
		var res: Array = ui.last_fit.get("residuals", [])
		var marked: int = 0
		for i in range(res.size()):
			if marked < 4 and i % 97 == 13:
				res[i]["inlier"] = false
				marked += 1
		ui._dirty = true
		ui._rebuild_display_data()
	await _shot(ui, "OUTLIER")
	ui.queue_free()

	# 7) NORTH_CROSSING：注入跨北方位序列（359→1）验证 BT 连续
	ui = await _prepare(160)
	var pts: Array = []
	var curve: Array = []
	for i in range(60):
		var tt: float = float(i) * 2.0
		var brg: float = 359.0 + i * 0.08  # 跨越 360
		(
			pts
			. append(
				{
					"time": tt,
					"bearing_deg": NavUtils.wrap360(brg),
					"sigma_deg": 0.8,
					"color": Color(1.0, 0.85, 0.3),
					"inlier": true,
					"track_id": ui.selected_track_id,
				}
			)
		)
		curve.append({"time": tt, "bearing_deg": NavUtils.wrap360(brg + 0.3)})
	ui._bt_plot.meas_points = pts
	ui._bt_plot.model_curves = [{"points": curve, "color": Color(0.98, 0.55, 0.15), "best": true}]
	ui._bt_plot.set_time_window(0.0, 120.0)
	ui._bt_plot.track_id = ui.selected_track_id
	ui._bt_plot.queue_redraw()
	await _shot(ui, "NORTH_CROSSING")
	ui.queue_free()

	print("REGRESSION done: 7 screenshots in tools/regression/")
	quit(0)
