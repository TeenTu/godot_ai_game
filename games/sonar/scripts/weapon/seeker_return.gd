class_name SeekerReturn
extends RefCounted
## seeker_return.gd — 鱼雷 Seeker 采样输出（S1-07 §6.5，Commit 6）。
##
## TorpedoSensorAdapter（仿真内核边界，唯一可触 Truth 声源）把对目标的声学
## 采样净化为本对象后交给鱼雷/Seeker。本类字段与序列化结果（to_dict）绝不
## 包含 target_id、真实位置、真实航向或 damage_state——Seeker/制导/UI 层只能
## 消费 SeekerReturn（§2.1 禁止：用 target_id 把 SeekerReturn 绑定真实目标）。
##
## 字段语义（§6.5）：
##   sensor_mode    "PASSIVE" | "ACTIVE"
##   detected       本帧是否判定为一次探测（miss 帧不产生 return，由上层 Track
##                  以"该采样帧无 return"消费，§7；不携带未加噪真方位）。
##   bearing_deg / bearing_sigma_deg   带噪方位与不确定度（SE 越强越稳定）。
##   range_m / range_sigma_m           仅 ACTIVE 且 detected 有值；
##                                     PASSIVE 恒 -1（被动 Return 绝不自带真实 range，§6.3）。
##   available_time                    return 生效时刻（ACTIVE=回波到达时刻；
##                                     PASSIVE=timestamp）。
##   signal_excess_db / detection_probability   与玩家声呐同源的连续概率刻画。
##   depth_relation    "SAME_LAYER" | "CROSS_LAYER" | "TRANSITION"（深度层关系）。
##   spectral_features {band_min_hz, band_max_hz, tonal_hz:[{freq_hz, level_db}]}
##   source_kind_hypotheses   声源类型假设（Commit 8 诱饵/分类竞争起填充；本批空）。
##   debug_truth_ref          仅 debug/test 通道可填；普通链路必须为空字符串。

var return_id: int = 0
var timestamp: float = 0.0
var available_time: float = 0.0
var sensor_mode: String = "PASSIVE"
var detected: bool = false
var bearing_deg: float = 0.0
var bearing_sigma_deg: float = 0.0
var range_m: float = -1.0  # <0 = 无距离（PASSIVE 恒 -1）
var range_sigma_m: float = -1.0
var signal_excess_db: float = -999.0
var detection_probability: float = 0.0
var spectral_features: Dictionary = {}
var depth_relation: String = "SAME_LAYER"
var source_kind_hypotheses: Array = []
var debug_truth_ref: String = ""
# P0-09：主动链传播——ACTIVE return 携带产生它的 ping_id（同 id 串联）。
var ping_id: String = ""


## 序列化结果（UI/日志/净水管线消费）。只含 §6.5 玩法字段，
## 绝不输出 debug_truth_ref / 任何 Truth 引用。
func to_dict() -> Dictionary:
	return {
		"return_id": return_id,
		"timestamp": timestamp,
		"available_time": available_time,
		"sensor_mode": sensor_mode,
		"detected": detected,
		"bearing_deg": bearing_deg,
		"bearing_sigma_deg": bearing_sigma_deg,
		"range_m": range_m,
		"range_sigma_m": range_sigma_m,
		"signal_excess_db": signal_excess_db,
		"detection_probability": detection_probability,
		"spectral_features": spectral_features,
		"depth_relation": depth_relation,
		"source_kind_hypotheses": source_kind_hypotheses,
	}
