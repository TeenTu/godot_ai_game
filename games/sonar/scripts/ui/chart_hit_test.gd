class_name ChartHitTest
extends RefCounted
## chart_hit_test.gd — S109 §9.1 右键命中测试（纯静态，只读 UI DTO）。
##
## 优先级：威胁估计符号 > 己方在水鱼雷 > 普通 Contact/Fit/System 符号 >
## 威胁 LOB > 空白。禁止读取 Truth：坐标全部来自 ChartView 注入的绘制数据。
## S1-11 Batch 7 / AT-44：touch=true 时切换到放大触摸命中半径（UiContract）。

const HIT_PX: float = 14.0


## touch=true 时使用 AT-44 的放大触摸命中半径（航线点/鱼雷图标好按）。
static func pick(chart: Control, screen_pos: Vector2, touch: bool = false) -> Dictionary:
	var r: float = UiContract.TOUCH_HIT_PX if touch else HIT_PX
	var ctx: Dictionary = {
		"screen_position": screen_pos,
		"world_position": chart.screen_to_world(screen_pos),
		"hit_kind": "EMPTY",
		"hit_id": "",
	}
	for h in threat_points(chart):
		if (h["pos"] as Vector2).distance_to(screen_pos) <= r:
			ctx["hit_kind"] = "THREAT"
			ctx["hit_id"] = str(h["track_id"])
			return ctx
	for tp in torpedo_points(chart):
		if (tp["pos"] as Vector2).distance_to(screen_pos) <= r:
			ctx["hit_kind"] = "OWN_TORPEDO"
			ctx["hit_id"] = str(tp["torpedo_id"])
			return ctx
	for c in contact_points(chart):
		if (c["pos"] as Vector2).distance_to(screen_pos) <= r:
			ctx["hit_kind"] = "CONTACT"
			ctx["hit_id"] = str(c["track_id"])
			return ctx
	for t in threat_lob_points(chart):
		if (t["pos"] as Vector2).distance_to(screen_pos) <= r:
			ctx["hit_kind"] = "THREAT_LOB"
			ctx["hit_id"] = str(int(t["evidence_id"]))
			return ctx
	return ctx


## 收敛威胁估计符号中心（draw_center 来自 ui_snapshots；未收敛不参与命中）。
static func threat_points(chart: Control) -> Array:
	var out: Array = []
	for s in chart.threat_snapshots:
		if s.get("draw_center_e_m") == null:
			continue
		var w := Vector2(float(s["draw_center_e_m"]), float(s["draw_center_n_m"]))
		out.append({"pos": chart.world_to_screen(w), "track_id": str(s["track_id"])})
	return out


## 鱼雷头部屏幕点击点（P1-02 命中测试；纯函数）。
static func torpedo_points(chart: Control) -> Array:
	var out: Array = []
	for tp in chart.torpedoes:
		var pts: Array = tp.get("trail", [])
		if pts.is_empty():
			continue
		var head := Vector2(float(pts[-1]["e"]), float(pts[-1]["n"]))
		out.append(
			{"pos": chart.world_to_screen(head), "torpedo_id": str(tp.get("torpedo_id", ""))}
		)
	return out


## 普通目标符号：Fit best 现位置 / System / Trial（hit_id = fit_track_id）。
static func contact_points(chart: Control) -> Array:
	var out: Array = []
	var tid: String = str(chart.fit_track_id)
	for hyp in chart.fit_hypotheses:
		if not bool(hyp.get("is_best", false)):
			continue
		var v := hyp["v_ms"] as Vector2
		var w: Vector2 = (
			(hyp["p_ref"] as Vector2) + v * (float(chart.fit_now_time) - float(hyp["t_ref"]))
		)
		out.append({"pos": chart.world_to_screen(w), "track_id": tid})
	if bool(chart.system_active):
		out.append({"pos": chart.world_to_screen(chart.system_pos), "track_id": tid})
	if bool(chart.trial_active):
		out.append({"pos": chart.world_to_screen(chart.trial_pos), "track_id": tid})
	return out


## 威胁 LOB 观测点命中（P0-07 交叉联动同点位）。
static func threat_lob_points(chart: Control) -> Array:
	var out: Array = []
	for e in chart.threat_lobs:
		out.append(
			{"pos": chart.world_to_screen(e["observer"]), "evidence_id": int(e["evidence_id"])}
		)
	return out
