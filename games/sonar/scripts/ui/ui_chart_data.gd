class_name UiChartData
extends RefCounted
## ui_chart_data.gd — S1-11 Batch 5：海图/诊断图数据装配（从 main_ui 拆出控行数）。
##
## 纯装配：把 tracker/world/TMA 的净化数据填进 ChartView / BearingTimePlot /
## ResidualPlot / BearingDisplay。绝不读 Truth（真值仅 Show Truth 覆盖层）。
## 全部方法以 ui 引用为入参，只在 ui 的既有公开/私有字段上读写，不复制状态。


## 重建 LOB / meas_index / BT 点列 / 残差数组。
static func rebuild(ui) -> void:
	ui._dirty = false
	var now: float = ui.world.sim_time
	var sel: Track = ui._selected_track()
	var outlier_times: Dictionary = TmaUiData.outlier_times(ui.last_fit, ui.selected_track_id)
	var all_lobs: Array = []
	var meas_index: Array = []
	var leg_bounds: Array = TmaUiData.leg_boundary_times(ui.world.measurements)
	for t in ui.tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var col: Color = color_for_track(ui, t.track_id)
		var is_sel: bool = t.track_id == ui.selected_track_id
		var cap: int = -1 if (is_sel or ui._chart.show_all_lobs) else 1
		all_lobs.append_array(TmaUiData.lob_entries(t, col, is_sel, outlier_times, cap))
		if is_sel:
			meas_index.append_array(TmaUiData.meas_index_entries(t, outlier_times))
	ui._chart.lobs = all_lobs
	ui._chart.meas_index = meas_index
	ui._chart.leg_boundary_times = leg_bounds
	ui._chart.fit_now_time = now
	ui._chart.fit_track_id = ui.selected_track_id
	ui._chart.fit_status = (
		str(ui.last_fit.get("status", "NO_FIT")) if not ui.last_fit.is_empty() else "NO_FIT"
	)
	if ui.last_fit.is_empty() or str(ui.last_fit.get("track_id", "")) != ui.selected_track_id:
		ui._chart.fit_status = "NO_FIT"
	ui._chart.fit_hypotheses = TmaUiData.chart_hypotheses(ui.last_fit, ui.selected_track_id)
	ui._chart.fit_ticks = TmaUiData.fit_tick_times(
		ui.last_fit, ui.selected_track_id, TmaUiData.leg_boundary_times(ui.world.measurements)
	)
	ui._chart.fit_cov_pos = TmaUiData.propagated_cov(ui.last_fit, now)
	if sel != null:
		ui._chart.range_ring = TmaUiData.range_ring_data(
			sel, now, color_for_track(ui, sel.track_id)
		)
	else:
		ui._chart.range_ring = {}

	var points: Array = []
	var t_min: float = INF
	var t_max: float = -INF
	if sel != null:
		var col2: Color = color_for_track(ui, sel.track_id)
		for m in sel.measurement_history:
			(
				points
				. append(
					{
						"time": m.timestamp,
						"bearing_deg": m.measured_bearing_deg,
						"sigma_deg": maxf(m.bearing_sigma_deg, 0.5),
						"color": col2,
						"inlier": not outlier_times.has(m.timestamp),
						"track_id": sel.track_id,
					}
				)
			)
			t_min = minf(t_min, m.timestamp)
			t_max = maxf(t_max, m.timestamp)
	ui._bt_plot.meas_points = points
	ui._bt_plot.model_curves = TmaUiData.bt_curves(ui.last_fit, ui.selected_track_id)
	ui._bt_plot.turn_times = TmaUiData.own_turn_times(ui.world.measurements)
	ui._bt_plot.track_id = ui.selected_track_id
	ui._bt_plot.set_time_window(
		t_min if t_min != INF else 0.0, maxf(t_max, now) if t_max != -INF else 1.0
	)

	var res: Array = []
	if not ui.last_fit.is_empty() and str(ui.last_fit.get("track_id", "")) == ui.selected_track_id:
		res = ui.last_fit.get("residuals", [])
	ui._res_plot.residuals = res
	ui._res_plot.track_id = ui.selected_track_id
	ui._res_plot.sigma_ref_deg = TmaUiData.mean_sigma(res)
	ui._res_plot.sigma_ref_m = TmaUiData.mean_sigma_range(res)
	ui._res_plot.set_time_window(
		t_min if t_min != INF else 0.0, maxf(t_max, now) if t_max != -INF else 1.0
	)


## 轻刷新：海图注入数据（威胁快照/本艇/试拟/系统解/深度条）+ 方位盘。
static func update_light(ui) -> void:
	var own: TruthEntity = ui.world.world["own"]
	ui._chart.now_time = ui.world.sim_time
	ui._chart.set_threat_evidence(ui.world.player_evidence, ui.world.sim_time)
	ui._chart.threat_snapshots = ui.world.threat_tracks.ui_snapshots()
	ui._threat_hud.refresh(ui._chart.threat_snapshots, ui.world.sim_time)
	ui._threat_list.refresh(ui._chart.threat_snapshots, ui.world.sim_time)
	ui._pager.set_badge("tactics", ui._active_threat_count())  # §8.3 红点（隐页也更新）
	ui._chart.own_pos = Vector2(own.position_east_m, own.position_north_m)
	ui._chart.own_course_deg = own.course_deg  # S1-01.4：本艇符号随实际艏向旋转
	ui._chart.own_track = own_track_cache(ui)
	ui._chart.trial_pos = Vector2(
		ui.trial.estimated_position_east_m, ui.trial.estimated_position_north_m
	)
	ui._chart.trial_active = ui.trial.range_m > 0.0
	if ui._chart.trial_active:
		var v_ms: float = NavUtils.kn_to_ms(ui.trial.speed_kn)
		ui._chart.trial_velocity = Vector2(
			v_ms * sin(deg_to_rad(ui.trial.course_deg)), v_ms * cos(deg_to_rad(ui.trial.course_deg))
		)
	else:
		ui._chart.trial_velocity = Vector2.ZERO
	if ui.system_sol != null:
		ui._chart.system_pos = Vector2(
			ui.system_sol.estimated_position_east_m, ui.system_sol.estimated_position_north_m
		)
		ui._chart.system_active = true
	else:
		ui._chart.system_active = false
	ui._chart.truth_positions = TmaUiData.truth_snapshot(
		ui.world, ui._chart.show_truth or bool(ui._chart.layers.get("truth", false))
	)
	ui._chart.depth_badges = depth_badges(ui)
	ui._chart.queue_redraw()

	ui._bearing.own_course_deg = own.course_deg
	ui._bearing.lobs = TmaUiData.latest_lobs_for_dial(ui._chart.lobs)
	var latest: Measurement = TmaUiData.latest_measurement(ui.world)
	if latest != null:
		ui._bearing.latest_bearing_deg = latest.measured_bearing_deg
		ui._bearing.latest_color = color_for_track(ui, "LATEST")
	else:
		ui._bearing.latest_bearing_deg = -1.0
		ui._bearing.queue_redraw()
	ui._bt_plot.queue_redraw()
	ui._res_plot.queue_redraw()


## S1-11 §7.4：敌方深度概率徽标（选中 → 文字；未选中 → 小型层带符号）。
## 无合法证据的 Track 也进列表（known=false → 地图显式"深度未知"，AT-27）。
static func depth_badges(ui) -> Array:
	var out: Array = []
	for t in ui.tracker.all_tracks():
		if t.state != Track.TrackState.ACTIVE:
			continue
		var lm: Measurement = t.latest_measurement()
		if lm == null:
			continue
		var s: Dictionary = t.depth_estimate_summary(ui.world.sim_time)
		var known: bool = (
			not s.is_empty()
			and float(s.get("confidence", 0.0)) >= 0.55
			and str(s.get("dominant", "UNKNOWN")) != "UNKNOWN"
		)
		(
			out
			. append(
				{
					"origin": Vector2(float(lm.observer_east_m), float(lm.observer_north_m)),
					"bearing_deg": float(lm.measured_bearing_deg),
					"text":
					UiText.depth_band_summary(s) if known else str(UiText.t("depth_band_unknown")),
					"selected": str(t.track_id) == ui.selected_track_id,
					"known": known,
					"layer": str(s.get("dominant", "UNKNOWN")) if not s.is_empty() else "UNKNOWN",
				}
			)
		)
	return out


static func own_track_cache(ui) -> Array:
	if ui._own_track_pts.is_empty() or ui._last_meas_count > ui._own_track_pts.size() - 1:
		ui._own_track_pts = TmaUiData.sample_own_track(ui.world)
	return ui._own_track_pts


static func color_for_track(ui, id: String) -> Color:
	if ui._track_colors.has(id):
		return ui._track_colors[id]
	var palette: Array = [
		Color(1.0, 0.85, 0.3),
		Color(0.4, 1.0, 0.6),
		Color(0.5, 0.7, 1.0),
		Color(1.0, 0.5, 0.9),
		Color(0.9, 0.6, 0.4),
	]
	var c: Color = palette[ui._track_colors.size() % palette.size()]
	ui._track_colors[id] = c
	return c
