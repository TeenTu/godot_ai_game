class_name TowedArray
extends RefCounted
## towed_array.gd — 拖曳阵物理状态机（批次2+ / S1-03 可控长度版）。
##
## 依据《阶段一/阶段二整合需求》S1-03 重做：
##   - 用"实际缆长 ACT ↔ 命令缆长 CMD"取代只有开/关语义的端点控制；
##   - 状态机 STOWED ↔ STREAMING ↔ HOLD_PARTIAL ↔ RETRIEVING，允许在任意
##     长度 HOLD、反向（布放中停/收、回收中停/放）；
##   - 长度按固定收放速率逼近命令值（不是按百分比动画）；
##   - 部分长度的声学性能真实参与计算：有效孔径比例 q_L 决定增益损失，
##     回收从第一帧起连续下降，绝不"开始回收即静音"；
##   - 阵轴航向对本艇转向做一阶滞后收敛，tau 与实际缆长、本艇实际航速相关；
##   - 提供阵列声学中心（观察站位）与阵轴，供 TOWED Measurement 固化。
##
## 信息链纪律：本类只描述"本艇拖曳声学阵"的物理状态，不读任何目标 Truth。
## 全部确定性：只依赖注入的 dt、本艇航向与本艇航速，可无头测试。
##
## 方向性约定（S1-03 统一）：TOWED 是相对阵轴的前视连续波束（-100°..+100°
## 相对阵轴，由配置决定），不再使用"艉部 120°~240° 世界扇区"表述；
## 左右舷镜像歧义（A/B 候选）由 OperatorSonar 按 S1-03A 生成。

enum State {
	STOWED,  # 缆全收，无声学孔径
	STREAMING,  # 放缆中（actual < commanded）
	HOLD_PARTIAL,  # 在任意长度保持
	RETRIEVING,  # 收缆中（actual > commanded）
}

# ---- 长度与收放（S1-03 必需字段）----
var max_tow_length_m: float = 400.0
var actual_tow_length_m: float = 0.0
var commanded_tow_length_m: float = 0.0
var stream_rate_m_s: float = 6.0  # 放缆速率
var retrieve_rate_m_s: float = 8.0  # 收缆速率
var dead_length_m: float = 60.0  # L_dead：有效声学孔径前的"死区"缆长

# ---- 阵轴滞后与沉降 ----
var full_length_heading_tau_s: float = 45.0  # 全展长缆的转向滞后时间常数
var short_length_heading_tau_s: float = 8.0  # 短缆的滞后时间常数
var settle_deg: float = 3.0  # 阵航向贴近本艇航向多少度内视为"已沉降"
var ref_align_speed_ms: float = 2.5  # tau 速度标定参考航速（此速下 tau 取标称值）

# ---- 弯曲 / 高速拖曳损失（dB，配置化）----
var bend_penalty_db: float = 6.0  # 阵形全弯时的附加损失上限
var max_tow_speed_kn: float = 12.0  # 超过此拖速开始产生高速损失
var speed_penalty_db: float = 6.0  # 高速损失上限（按超速比例线性）

# ---- 状态输出 ----
var state: int = State.STOWED
var array_heading_deg: float = 0.0  # 拖曳阵当前物理航向(从北顺时针)
var settle_factor: float = 0.0  # 0..1 沉降因子（阵轴与本艇航向贴合度）
var bend_factor: float = 1.0  # 0..1 弯曲因子（1=直，转向中变小）

var _last_own_speed_ms: float = -1.0  # step 注入的本艇实际航速（供增益损失计算）


func setup(params: Dictionary = {}) -> void:
	# 兼容旧键：tow_length_m=最大缆长；deploy/retract_time_s 折算收放速率
	max_tow_length_m = float(
		params.get("max_tow_length_m", params.get("tow_length_m", max_tow_length_m))
	)
	stream_rate_m_s = float(params.get("stream_rate_m_s", stream_rate_m_s))
	retrieve_rate_m_s = float(params.get("retrieve_rate_m_s", retrieve_rate_m_s))
	if params.has("deploy_time_s") and float(params["deploy_time_s"]) > 0.0:
		stream_rate_m_s = max_tow_length_m / float(params["deploy_time_s"])
	if params.has("retract_time_s") and float(params["retract_time_s"]) > 0.0:
		retrieve_rate_m_s = max_tow_length_m / float(params["retract_time_s"])
	dead_length_m = float(params.get("dead_length_m", dead_length_m))
	full_length_heading_tau_s = float(
		params.get("full_length_heading_tau_s", full_length_heading_tau_s)
	)
	short_length_heading_tau_s = float(
		params.get("short_length_heading_tau_s", short_length_heading_tau_s)
	)
	settle_deg = float(params.get("settle_deg", settle_deg))
	ref_align_speed_ms = maxf(float(params.get("ref_align_speed_ms", ref_align_speed_ms)), 0.1)
	bend_penalty_db = float(params.get("bend_penalty_db", bend_penalty_db))
	max_tow_speed_kn = float(params.get("max_tow_speed_kn", max_tow_speed_kn))
	speed_penalty_db = float(params.get("speed_penalty_db", speed_penalty_db))
	array_heading_deg = NavUtils.wrap360(float(params.get("array_heading_deg", array_heading_deg)))
	# 兼容旧字段：给初始长度（默认 STOWED 全收）
	actual_tow_length_m = clampf(
		float(params.get("actual_tow_length_m", 0.0)), 0.0, max_tow_length_m
	)
	commanded_tow_length_m = clampf(
		float(params.get("commanded_tow_length_m", actual_tow_length_m)), 0.0, max_tow_length_m
	)
	_refresh_state()


func state_name() -> String:
	match state:
		State.STOWED:
			return "STOWED"
		State.STREAMING:
			return "STREAMING"
		State.HOLD_PARTIAL:
			return "HOLD_PARTIAL"
		State.RETRIEVING:
			return "RETRIEVING"
	return "UNKNOWN"


# ------------------------------------------------------------------
#  长度命令（S1-03）：STREAM / HOLD / RETRIEVE，任意长度可反向
# ------------------------------------------------------------------


## 设置命令缆长（玩家长度命令的唯一入口）。
## 目标 > 当前 → 放缆；目标 < 当前 → 收缆（任意位置可发起、可反向）。
func set_length_command(target_m: float) -> void:
	commanded_tow_length_m = clampf(target_m, 0.0, max_tow_length_m)
	_refresh_state()


## STREAM：把命令长度设为玩家选择值（默认全放）。
func stream(target_m: float = -1.0) -> void:
	set_length_command(max_tow_length_m if target_m < 0.0 else target_m)


## HOLD：把命令长度锁定为当前实际长度（在任意长度保持）。
func hold() -> void:
	commanded_tow_length_m = actual_tow_length_m
	_refresh_state()


## RETRIEVE：从任意长度开始回收（默认收到 0）。
func retrieve() -> void:
	set_length_command(0.0)


## 兼容旧 API：deploy = 全放；retract = 全收。
func deploy() -> bool:
	stream()
	return true


func retract() -> bool:
	retrieve()
	return true


func _refresh_state() -> void:
	if actual_tow_length_m <= 1e-6 and commanded_tow_length_m <= 1e-6:
		state = State.STOWED
	elif actual_tow_length_m < commanded_tow_length_m - 1e-6:
		state = State.STREAMING
	elif actual_tow_length_m > commanded_tow_length_m + 1e-6:
		state = State.RETRIEVING
	else:
		state = State.HOLD_PARTIAL


# ------------------------------------------------------------------
#  声学可用性（S1-03 部分长度性能）
# ------------------------------------------------------------------


## 有效孔径比例 q_L = clamp((L-L_dead)/(L_full-L_dead), 0, 1)。
func aperture_fraction() -> float:
	var span: float = maxf(max_tow_length_m - dead_length_m, 1e-6)
	return clampf((actual_tow_length_m - dead_length_m) / span, 0.0, 1.0)


## 阵列是否真正在声学意义上工作（有超过死区的有效孔径）。
## 完全收回或孔径不足 → false：极强目标也不能穿过此状态产生 TOWED 测量。
func is_acoustically_active() -> bool:
	return actual_tow_length_m > dead_length_m and state != State.STOWED


## 综合可用度 0..1 = 孔径比例 q_L × 沉降因子。
## （孔径与沉降分开计算，不在两个因子中重复相乘部署进度。）
func usable_fraction() -> float:
	return aperture_fraction() * settle_factor


func is_usable() -> bool:
	return is_acoustically_active() and usable_fraction() > 0.5


## 增益损失（dB，≤0）：孔径缩短 + 阵形弯曲 + 高速拖曳，三项独立计算后相加。
## AG_eff = AG_full + 10log10(q_L) + L_bend + L_speed，本函数返回后三项之和。
func gain_penalty_db() -> float:
	var q: float = aperture_fraction()
	var aperture_db: float = 10.0 * log(maxf(q, 1e-3)) / log(10.0)
	return aperture_db + bend_speed_loss_db()


## 弯曲 + 高速拖曳损失（dB，≤0）。孔径项另计（见 gain_penalty_db），
## 避免调用方把 usable_fraction（已含孔径）与本项一起用时重复扣孔径。
func bend_speed_loss_db() -> float:
	var bend_db: float = -bend_penalty_db * (1.0 - bend_factor)
	var speed_db: float = 0.0
	if _last_own_speed_ms >= 0.0 and max_tow_speed_kn > 0.0:
		var over: float = (
			(NavUtils.ms_to_kn(_last_own_speed_ms) - max_tow_speed_kn) / max_tow_speed_kn
		)
		speed_db = -speed_penalty_db * clampf(over, 0.0, 1.0)
	return bend_db + speed_db


## 阵列声学中心距本艇的距离（米）：有效孔径 [L_dead, L] 的中点。
func array_center_offset_m() -> float:
	if actual_tow_length_m <= dead_length_m:
		return 0.5 * actual_tow_length_m
	return clampf(0.5 * (dead_length_m + actual_tow_length_m), 0.0, max_tow_length_m)


## 阵列声学中心的世界位置（S1-03 观察站位，二维近似）：
## p_array = p_own - d_center * [sin(psi_a), cos(psi_a)]。
func array_center_position(own_east_m: float, own_north_m: float) -> Vector2:
	var d: float = array_center_offset_m()
	var rad: float = array_heading_deg * NavUtils.DEG_TO_RAD
	return Vector2(own_east_m - d * sin(rad), own_north_m - d * cos(rad))


# ------------------------------------------------------------------
#  物理推进
# ------------------------------------------------------------------


## 推进一个物理步长。own_course_deg 为本艇当前实际航向，
## own_speed_ms 为本艇实际航速（m/s；<0 表示未知，按参考航速处理）。
## 阵轴滞后 tau 必须与实际放缆长度和本艇实际速度相关（S1-03）。
func step(dt: float, own_course_deg: float, own_speed_ms: float = -1.0) -> void:
	_last_own_speed_ms = own_speed_ms

	# 1) 缆长按固定速率逼近命令值（允许任意位置反向）
	if actual_tow_length_m < commanded_tow_length_m - 1e-6:
		actual_tow_length_m = minf(
			actual_tow_length_m + stream_rate_m_s * dt, commanded_tow_length_m
		)
	elif actual_tow_length_m > commanded_tow_length_m + 1e-6:
		actual_tow_length_m = maxf(
			actual_tow_length_m - retrieve_rate_m_s * dt, commanded_tow_length_m
		)
	_refresh_state()

	# 2) 阵轴航向：全收(STOWED)时直接跟随本艇（阵在艇上，无独立航向）
	if state == State.STOWED:
		array_heading_deg = NavUtils.wrap360(own_course_deg)
		settle_factor = 0.0
		bend_factor = 1.0
		return

	# tau 随有效孔径插值（缆越长滞后越大），并按本艇航速标定：
	# 慢速拖曳阵更"飘"（tau 变大），快速拖直（tau 变小）。
	var q: float = aperture_fraction()
	var tau: float = lerpf(short_length_heading_tau_s, full_length_heading_tau_s, q)
	var spd: float = own_speed_ms if own_speed_ms > 0.0 else ref_align_speed_ms
	var speed_scale: float = clampf(ref_align_speed_ms / maxf(spd, 0.2), 0.5, 2.5)
	tau = maxf(tau * speed_scale, 1e-6)

	# 一阶滞后收敛（有符号角误差，跨 360 稳定）
	var err: float = NavUtils.wrap180(own_course_deg - array_heading_deg)
	array_heading_deg = NavUtils.wrap360(array_heading_deg + err * (1.0 - exp(-dt / tau)))

	# 3) 沉降因子：阵轴偏离本艇航向越小越接近 1
	var deg_off: float = absf(NavUtils.wrap180(own_course_deg - array_heading_deg))
	if deg_off < settle_deg:
		settle_factor = 1.0
	else:
		settle_factor = clampf(1.0 - (deg_off - settle_deg) / (45.0 - settle_deg), 0.0, 1.0)

	# 4) 弯曲因子：转向差角越大缆越弯（独立于 q_L / 沉降）
	bend_factor = clampf(1.0 - deg_off / 45.0, 0.0, 1.0)
