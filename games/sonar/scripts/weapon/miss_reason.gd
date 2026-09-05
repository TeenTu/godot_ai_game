class_name TorpedoMissReason
extends RefCounted
## miss_reason.gd — 脱靶原因确定性判定（验收14；纯函数）。
##
## 鱼雷未命中终结（燃料耗尽/自毁）时给出七种枚举之一，供 Debrief/测试
## 观测：每次脱靶必须可解释。输入只有鱼雷自身净化状态（无 Truth）。
## 优先级：首个命中项返回。
##   NO_GUIDANCE_AUTHORITY      取得制导权限前从未实际操舵
##   TURN_RATE_SATURATED        曾发生转率饱和（拦截几何不可达）
##   ACTIVE_TRACK_AGED_OUT      主动航迹老化脱锁
##   TRACK_LOST_OUTSIDE_FOV     目标离开 FOV 后 COAST 超时脱锁
##   TRACK_FILTER_DIVERGED      航迹滤波发散（方位方差超限）
##   FUZE_MISSED_BETWEEN_TICKS  有航迹有操舵但引信未触发
##   FUEL_EXHAUSTED             燃料耗尽（由调用方先行短路）

const DIVERGED_VAR_DEG2: float = 900.0  # 30° 方位 σ 视为滤波发散


static func compute(never_engaged: bool, ever_saturated: bool, tracks: Array) -> String:
	if never_engaged:
		return "NO_GUIDANCE_AUTHORITY"
	if ever_saturated:
		return "TURN_RATE_SATURATED"
	for t in tracks:
		if str(t.loss_kind) == "AGED_OUT_ACTIVE":
			return "ACTIVE_TRACK_AGED_OUT"
	for t2 in tracks:
		if str(t2.loss_kind) == "OUT_OF_FOV":
			return "TRACK_LOST_OUTSIDE_FOV"
	for t3 in tracks:
		if t3.bearing_var_deg2 > DIVERGED_VAR_DEG2:
			return "TRACK_FILTER_DIVERGED"
	return "FUZE_MISSED_BETWEEN_TICKS"
