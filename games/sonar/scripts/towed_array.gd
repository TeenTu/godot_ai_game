class_name TowedArray
extends RefCounted
## towed_array.gd — 拖曳阵物理状态机（批次2+）。
##
## 目标：让操作员层的 TOWED 阵列具备真实的物理生命周期，而不再简单回退成
## "阵航向恒等于本艇航向"（旧实现仅 `_array_heading_deg` 回退 own.course）。
##
## 信息链纪律：本类只描述"本艇拖曳声学阵"的物理状态，不读任何目标 Truth。
## 它把两件事做实：
##   1. 部署生命周期：RETRACTED → DEPLOYING → DEPLOYED → (RETRIEVING→RETRACTED)。
##      deployment_progress 在 0..1 之间按时间推进；未部署完的阵不提供完整覆盖/增益。
##   2. 转向航向滞后：拖曳阵通过长缆拖在本艇后，本艇转向后阵的物理航向不会
##      立刻跟随，而是一阶滞后收敛到本艇新航向（tau 随航速/缆长变化）。
##      布放中的短缆（阵还贴着艇）滞后小；全展的长缆滞后大。
##
## 输出给上层：
##   - state / deployment_progress（UI 显示）
##   - array_heading_deg（拖曳阵当前物理航向，OperatorSonar 用它做覆盖/方向增益）
##   - usable_fraction()（0..1，综合"部署进度 × 转向沉降"，OperatorSonar 用它缩放增益）
##   - is_usable()（bool，usable_fraction 超过门限才算真正可用）
##
## 全部确定性：只依赖注入的 dt 与本艇航向，可无头测试。

enum State {
	RETRACTED,
	DEPLOYING,
	DEPLOYED,
	RETRIEVING,
}

# 物理参数（可由 scenario / own 配置覆盖，默认合理值）
var tow_length_m: float = 400.0
var deploy_time_s: float = 90.0
var retract_time_s: float = 60.0
var full_length_heading_tau_s: float = 45.0  # 全展长缆的转向滞后时间常数
var short_length_heading_tau_s: float = 8.0  # 刚放出短缆的滞后时间常数
var settle_deg: float = 3.0  # 转向后阵航向逼近到本艇航向多少度内视为"已沉降"
var usable_deploy_min: float = 0.98  # 部署进度需达到才给满覆盖
var usable_settle_frac: float = 0.85  # 沉降因子需达到才给满增益

var state: int = State.RETRACTED
var deployment_progress: float = 0.0  # 0..1（布放/回收过程的有效进度）
var array_heading_deg: float = 0.0  # 拖曳阵当前物理航向(从北顺时针)
var _settle_factor: float = 0.0  # 0..1，衡量阵航向与本艇航向的贴合程度


func setup(params: Dictionary = {}) -> void:
	tow_length_m = float(params.get("tow_length_m", tow_length_m))
	deploy_time_s = float(params.get("deploy_time_s", deploy_time_s))
	retract_time_s = float(params.get("retract_time_s", retract_time_s))
	full_length_heading_tau_s = float(
		params.get("full_length_heading_tau_s", full_length_heading_tau_s)
	)
	short_length_heading_tau_s = float(
		params.get("short_length_heading_tau_s", short_length_heading_tau_s)
	)
	settle_deg = float(params.get("settle_deg", settle_deg))
	usable_deploy_min = float(params.get("usable_deploy_min", usable_deploy_min))
	usable_settle_frac = float(params.get("usable_settle_frac", usable_settle_frac))
	array_heading_deg = float(params.get("array_heading_deg", array_heading_deg))


func state_name() -> String:
	match state:
		State.RETRACTED:
			return "RETRACTED"
		State.DEPLOYING:
			return "DEPLOYING"
		State.DEPLOYED:
			return "DEPLOYED"
		State.RETRIEVING:
			return "RETRIEVING"
	return "UNKNOWN"


## 开始布放（仅从 RETRACTED 可发起；部署中/已部署忽略）。
func deploy() -> bool:
	if state != State.RETRACTED:
		return false
	state = State.DEPLOYING
	deployment_progress = 0.0
	# 刚布放阵贴着艇，从本艇当前航向起算
	array_heading_deg = NavUtils.wrap360(array_heading_deg)
	return true


## 开始回收（仅从 DEPLOYED 可发起；回收中忽略）。
func retract() -> bool:
	if state != State.DEPLOYED:
		return false
	state = State.RETRIEVING
	return true


## 是否有可用的拖曳阵（部署完整 + 已沉降）。
func is_usable() -> bool:
	return usable_fraction() >= 0.5


## 综合可用度 0..1 = 部署进度因子 × 沉降因子。
## 部署因子：DEVELOPING 未到门限前按 progress 线性爬升；DEPLOYED 后取 1。
## 沉降因子：阵航向紧跟本艇航向 → 1；刚转向偏离 → 按时间恢复。
func usable_fraction() -> float:
	var deploy_factor: float = 0.0
	match state:
		State.RETRACTED, State.RETRIEVING:
			deploy_factor = 0.0
		State.DEPLOYING:
			# 布放中随进度线性可用；但尾部阵还在入水，乘上沉降因子保守处理
			deploy_factor = clampf(deployment_progress / usable_deploy_min, 0.0, 1.0)
		State.DEPLOYED:
			deploy_factor = 1.0
	return deploy_factor * _settle_factor


## 推进一个物理步长。own_course_deg 为本艇当前航向，dt 秒。
func step(dt: float, own_course_deg: float) -> void:
	match state:
		State.DEPLOYING:
			if deploy_time_s > 0.0:
				deployment_progress = clampf(deployment_progress + dt / deploy_time_s, 0.0, 1.0)
				if deployment_progress >= 1.0:
					state = State.DEPLOYED
		State.RETRIEVING:
			if retract_time_s > 0.0:
				deployment_progress = clampf(deployment_progress - dt / retract_time_s, 0.0, 1.0)
				if deployment_progress <= 0.0:
					state = State.RETRACTED
					_settle_factor = 0.0
					return
		_:
			pass

	# 航向滞后：一阶收敛到本艇航向。
	# 有效缆长越长(部署越充分)、越需要阵稳定，则 tau 越大 → 滞后越明显。
	# 布放进度 p：p→0 时 tau 短(短缆)，p→1 时 tau=full。用线性插值近似。
	var p: float = clampf(deployment_progress, 0.0, 1.0)
	var tau: float = lerpf(short_length_heading_tau_s, full_length_heading_tau_s, p)
	if tau <= 0.0:
		tau = 1e-6
	# 有符号角误差（本艇航向 − 阵航向），用最短弧
	var err: float = NavUtils.wrap180(own_course_deg - array_heading_deg)
	# 一阶指数逼近：θ_new = θ + err * (1 - exp(-dt/tau))，防止大角振荡、跨 360 稳定
	var step_frac: float = 1.0 - exp(-dt / tau)
	array_heading_deg = NavUtils.wrap360(array_heading_deg + err * step_frac)

	# 沉降因子：阵航向偏离本艇航向越小，越接近 1。
	# 瞬时(无处理)已足够——err 本身随阵逼近本艇而衰减，用 err 直接映射即可。
	var deg_off: float = absf(NavUtils.wrap180(own_course_deg - array_heading_deg))
	if deg_off < settle_deg:
		_settle_factor = 1.0
	else:
		# 偏离超过 settle 门限时按比例降权，随收敛自动回升到 1
		_settle_factor = clampf(1.0 - (deg_off - settle_deg) / (45.0 - settle_deg), 0.0, 1.0)
	# 部署不足也压沉降因子，保证"没放完不给满覆盖"
	if deployment_progress < usable_deploy_min:
		_settle_factor = minf(
			_settle_factor, clampf(deployment_progress / usable_deploy_min, 0.0, 1.0)
		)
