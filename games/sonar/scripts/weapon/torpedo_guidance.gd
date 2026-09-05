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
## REQ-04 制导律默认参数（全部可经 cfg 覆盖标定）：
##   guidance_kp（方位误差比例项）guidance_n（比例导航系数，3~4 起标）
##   guidance_kd（被动分支视线率阻尼项）guidance_kp_terminal（近程纯追踪）
##   terminal_switch_range_m：近程切换纯追踪的距离门——PN 在近程 LOS 率
##   发散（过靶时刻 λ_dot→∞），继续用会 bang-bang 抖振导致擦过；
##   纯追踪 + 有限转率在近程更平滑。
const DEFAULT_KP: float = 1.2
const DEFAULT_N: float = 3.0
const DEFAULT_KD: float = 3.0
const DEFAULT_KP_TERMINAL: float = 2.0
const DEFAULT_TERMINAL_SWITCH_RANGE_M: float = 300.0
## 中段 PN 视线率项限幅（防异常 λ_dot 制造离谱转率命令；饱和判定仍由
## Torpedo 对总命令执行）。
const NAV_TERM_MAX_DEG_S: float = 12.0


## REQ-04 拦截制导（转率命令，度/秒；正值 = 向右转）。
## 输入只有净化航迹（bearing/los_rate/可选 range/range_rate）与自身状态——
## 绝不接受 Truth 距离/航向/速度。主动测距有效时：
##   cmd = Kp * bearing_error + N * (closing_speed / torpedo_speed) * los_rate
## 纯被动时：
##   cmd = Kp * bearing_error + Kd * filtered_los_rate
## 限幅（omega_max）由调用方（Torpedo）统一执行——本函数返回未饱和命令，
## 便于 UI/测试观测饱和状态。
static func intercept_turn_rate_deg_s(
	track: SeekerTrack, torpedo_course_deg: float, torpedo_speed_ms: float, cfg: Dictionary
) -> float:
	if track == null:
		return 0.0
	var kp: float = float(cfg.get("guidance_kp", DEFAULT_KP))
	var n: float = float(cfg.get("guidance_n", DEFAULT_N))
	var kd: float = float(cfg.get("guidance_kd", DEFAULT_KD))
	var kp_t: float = float(cfg.get("guidance_kp_terminal", DEFAULT_KP_TERMINAL))
	var t_switch: float = float(cfg.get("terminal_switch_range_m", DEFAULT_TERMINAL_SWITCH_RANGE_M))
	var bearing_error: float = NavUtils.wrap180(track.bearing_estimate_deg - torpedo_course_deg)
	if track.range_estimate_m >= 0.0 and track.range_estimate_m <= t_switch:
		# 近程（主动测距有效且小于切换门）：纯追踪——PN 在近程 LOS 率发散，
		# 纯追踪 + 有限转率平滑收尾。
		return kp_t * bearing_error
	var cmd: float = kp * bearing_error
	if track.range_estimate_m >= 0.0:
		# 主动测距有效：比例导航。closing_speed = max(-range_rate, 0)（接近为正）。
		var closing: float = maxf(-track.range_rate_m_s, 0.0)
		var v: float = maxf(torpedo_speed_ms, 1.0)
		cmd += clampf(
			n * (closing / v) * track.los_rate_deg_s, -NAV_TERM_MAX_DEG_S, NAV_TERM_MAX_DEG_S
		)
	else:
		# 纯被动：方位误差 + 滤波视线率阻尼。
		cmd += clampf(kd * track.los_rate_deg_s, -NAV_TERM_MAX_DEG_S, NAV_TERM_MAX_DEG_S)
	return cmd


## Seeker/制导共用默认配置（§7.3 阈值 + REQ-04 制导增益 + REQ-03/06 机会参数；
## 可测试标定）。coast_timeout 覆盖主动 Ping 间隔 + 最大回波延迟 + 余量。
static func default_seeker_cfg(profile: TorpedoAcousticProfile) -> Dictionary:
	var coast_timeout: float = profile.active_ping_interval_s + 34.0 if profile != null else 42.0
	return {
		"acquire_threshold": 0.65,
		"stable_track_threshold": 0.80,
		"drop_threshold": 0.25,
		"beta_miss": 0.10,
		"bearing_gate_deg": 12.0,
		"miss_after_s": 1.2,
		"passive_miss_window_s": 1.2,
		"coast_timeout_s": coast_timeout,
		"reacquire_timeout_s": 120.0,
		"lead_time_s": DEFAULT_LEAD_TIME_S,
		"max_lead_deg": DEFAULT_MAX_LEAD_DEG,
		"guidance_kp": DEFAULT_KP,
		"guidance_n": DEFAULT_N,
		"guidance_kd": DEFAULT_KD,
		"guidance_kp_terminal": DEFAULT_KP_TERMINAL,
		"terminal_switch_range_m": DEFAULT_TERMINAL_SWITCH_RANGE_M,
		"snake_period_s": DEFAULT_SNAKE_PERIOD_S,
		"circle_period_s": DEFAULT_CIRCLE_PERIOD_S,
		"terminal_range_m": 250.0,
	}


## 期望航向（旧接口保留供测试/回退）：锁定航迹 → 带提前量的方位追踪。
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
## P2-01：求 t0 使 pattern(t0) = 当前航向（三角波取第一半周期分支，
## 中心外夹到扇区边界；圆周取最近角），扫掠自当前航向连续展开。
static func search_phase_offset_for(
	course_deg: float, prog: WeaponProgram, pattern: String, cfg: Dictionary
) -> float:
	var center: float = float(prog.search_center_deg)
	if pattern == "CIRCLE":
		var period: float = float(cfg.get("circle_period_s", DEFAULT_CIRCLE_PERIOD_S))
		return NavUtils.wrap360(course_deg - center) * period / 360.0
	var period2: float = float(cfg.get("snake_period_s", DEFAULT_SNAKE_PERIOD_S))
	var half: float = maxf(float(prog.search_half_angle_deg), 1.0)
	var v: float = clampf(NavUtils.wrap180(course_deg - center) / half, -1.0, 1.0)
	return (v + 1.0) / 4.0 * period2


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
