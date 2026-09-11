class_name PosEstimateText
extends RefCounted
## pos_estimate_text.gd — PG-04：系统位置估计的统一展示文案（卡片 / 状态行同源）。
##
## 纪律：
##   - 单次观测只有位置 → 文案必须带 POSITION_ONLY，并显示"最近估计位置"
##     （没有速度估计时不得把历史点说成实时精确位置）；
##   - 预测误差随失联时间增长（由 ActivePositionObs.snapshot_at 给出 σ）；
##   - 无位置观测 → 空串（调用方不显示本行），绝不编造。


## 位置估计 DTO → 展示文本。obs 为 ActivePositionObs.evaluate 的输出。
static func format(obs: Dictionary, now_s: float) -> String:
	if not bool(obs.get("has_position", false)):
		return ""
	var snap: Dictionary = ActivePositionObs.snapshot_at(obs, now_s)
	var label: String = str(UiText.t(str(snap.get("label_key", "est_last_known"))))
	var body: String = (
		str(UiText.t("est_pos_fmt"))
		% [
			str(obs.get("kind_name", "")),
			float(obs.get("range_m", 0.0)) / 1000.0,
			float(obs.get("range_sigma_m", 0.0)),
			float(snap.get("sigma_m", 0.0)),
		]
	)
	return label + " " + body
