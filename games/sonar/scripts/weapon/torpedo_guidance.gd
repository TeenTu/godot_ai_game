class_name TorpedoGuidance
extends RefCounted

## TorpedoGuidance（S1-07 §7.5/§7.7，Commit 7）：纯函数式制导/搜索期望航向
## 计算。输入只有 SeekerTrack（净化）、自身运动状态与配置——绝不接受
## TruthEntity（WPN-SEEK-12）。
##
## 制导（§7.7）：
##   - 有主动测距：简化提前量追踪（lead = bearing_rate * lead_time，钳位）。
##   - 只有被动方位：bearing + bearing-rate 估计提前量，绝不补 Truth range。
##   - WIRE_ONLY 不由本模块接管（Torpedo 侧保证）。
##
## 搜索扫掠（§7.5）：SNAKE 三角波 / CIRCLE 连续旋转，期望航向仍由
## Torpedo 的有限转向率逼近（绝无瞬时 +120°）。

const DEFAULT_LEAD_TIME_S: float = 12.0
const DEFAULT_MAX_LEAD_DEG: float = 25.0
const DEFAULT_SNAKE_PERIOD_S: float = 120.0
const DEFAULT_CIRCLE_PERIOD_S: float = 240.0


## 追踪期望航向：锁定航迹 → 带提前量的方位追踪。
static func pursuit_course_deg(track: SeekerTrack, cfg: Dictionary) -> float:
	if track == null:
		return -1.0
	var lead_time: float = float(cfg.get("lead_time_s", DEFAULT_LEAD_TIME_S))
	var max_lead: float = float(cfg.get("max_lead_deg", DEFAULT_MAX_LEAD_DEG))
	# 提前量 = 方位率 × 提前时间（主动测距时方位率估计更稳，公式同源）。
	# P0-03.3：提前量用惯性视线率（相对率含自转，直用会失真）。
	var lead: float = clampf(track.los_rate_deg_s * lead_time, -max_lead, max_lead)
	return NavUtils.wrap360(track.bearing_estimate_deg + lead)


## 丢失/重搜期望航向（§7.6 第 3 步）：围绕最后预测方位扩大扇区扫掠。
static func reacquire_course_deg(last_bearing_deg: float, now: float, cfg: Dictionary) -> float:
	var period: float = float(cfg.get("snake_period_s", DEFAULT_SNAKE_PERIOD_S)) * 0.5
	var half: float = minf(float(cfg.get("reacquire_half_deg", 90.0)), 150.0)
	var center: float = last_bearing_deg
	if center < 0.0:
		center = 0.0
		half = 180.0
	return NavUtils.wrap360(center + _triangle_wave(now, period) * half)


## 搜索扫掠期望航向（§7.5）。
## pattern: "SNAKE"（三角波 center±half）| "CIRCLE"（连续旋转）。
static func search_course_deg(
	pattern: String, center_deg: float, half_angle_deg: float, now: float, cfg: Dictionary
) -> float:
	var half: float = clampf(half_angle_deg, 1.0, 180.0)
	if pattern == "CIRCLE":
		var period: float = float(cfg.get("circle_period_s", DEFAULT_CIRCLE_PERIOD_S))
		return NavUtils.wrap360(center_deg + (now * 360.0 / maxf(period, 1.0)))
	var period: float = float(cfg.get("snake_period_s", DEFAULT_SNAKE_PERIOD_S))
	return NavUtils.wrap360(center_deg + _triangle_wave(now, period) * half)


## 三角波（-1..1），周期 period。
static func _triangle_wave(t: float, period: float) -> float:
	var p: float = maxf(period, 1.0)
	var phase: float = fmod(t, p) / p  # 0..1
	return (phase * 4.0 - 1.0) if phase < 0.5 else (3.0 - phase * 4.0)
