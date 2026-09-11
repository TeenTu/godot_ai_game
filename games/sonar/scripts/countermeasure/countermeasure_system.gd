class_name CountermeasureSystem
extends RefCounted

## CountermeasureSystem（S1-07 §8.1/§8.5，Commit 8）：诱饵发射器。玩家艇与
## 敌艇均可配置（同一类，origin 只是 TruthEntity）。
## 发射有效性：库存/冷却/类型支持/程序合法/方位与深度合法（§8.5），
## 绝无"随时无限发"。
##
## DC-07（备用弹自动再装填）：库存口径**沿用总库存**——`inventory` 含已装填弹，
## 开火 `ready--` 且 `inventory--`，装填只 `ready++`（不再额外扣 inventory），
## 因此不混用两套计数。有备用弹（`ready < inventory`）且发射器未满
## （`ready < launcher_capacity`）时按**仿真时间**自动装填一发；暂停时 World
## 不调用 step() 故不装填，倍速由 dt 已折算满足。开火失败不扣弹；诱饵过期
## 不返还库存（寿命与库存解耦）。

var launcher_id: String = "CM-1"
var launcher_count: int = 1
var ready_rounds: int = 2  # 已装填可用
var inventory: int = 4  # 总库存（含已装填）
## DC-07：发射器可容纳的已装填弹数（再装填上限；configure 时不低于 ready_rounds，
## 以免旧场景配置被本批次改动变得非法）。
var launcher_capacity: int = 2
## DC-07：单发再装填所需仿真秒数（建议 30–60；≤0 表示关闭自动再装填）。
var reload_time_s: float = 45.0
var launch_cooldown_s: float = 10.0
var supported_types: Array = [DecoyProgram.TYPE_MOBILE, DecoyProgram.TYPE_JAMMER]
## P1-C DC-02/DC-03：发射程序默认参数（DecoyLaunchBuilder 读这里；场景
## own_ship.countermeasures 可覆盖）。MOBILE 巡航速度；JAMMER 有真实有限分离
## 阶段（数十米量级，配置化——不宣称真实装置射程），之后低速漂浮。
var mobile_speed_kn: float = 8.0
var jammer_separation_speed_kn: float = 6.0
var jammer_separation_duration_s: float = 20.0
var jammer_drift_speed_kn: float = 0.2
## REQ-CM-04：最近一次拒绝原因（UI 展示用；launch 成功后清空）。
var last_reject_reason: String = ""
## REQ-CM-04：按类型配置的诱饵画像（scenario own_ship.countermeasures.profiles；
## UI 只选类型，不再回调构造物理参数）。值 = AcousticProfile.from_dict 口径字典。
var profiles: Dictionary = {}

var _cooldown_until: float = -1.0
var _deployed: Array = []  # 本发射器已部署的 Decoy（Truth 侧台账）
var _reload_progress_s: float = 0.0  # DC-07：当前这一发的装填已用仿真秒数


func configure(cfg: Dictionary) -> void:
	launcher_id = str(cfg.get("launcher_id", launcher_id))
	launcher_count = int(cfg.get("launcher_count", launcher_count))
	ready_rounds = int(cfg.get("ready_rounds", ready_rounds))
	inventory = maxi(int(cfg.get("inventory", inventory)), ready_rounds)
	launcher_capacity = int(cfg.get("launcher_capacity", launcher_capacity))
	# 旧场景可能 ready_rounds > 容量；抬高容量而非把已有场景判非法（保持兼容）。
	launcher_capacity = maxi(launcher_capacity, ready_rounds)
	reload_time_s = float(cfg.get("reload_time_s", reload_time_s))
	launch_cooldown_s = float(cfg.get("launch_cooldown_s", launch_cooldown_s))
	mobile_speed_kn = float(cfg.get("mobile_speed_kn", mobile_speed_kn))
	jammer_separation_speed_kn = float(
		cfg.get("jammer_separation_speed_kn", jammer_separation_speed_kn)
	)
	jammer_separation_duration_s = float(
		cfg.get("jammer_separation_duration_s", jammer_separation_duration_s)
	)
	jammer_drift_speed_kn = float(cfg.get("jammer_drift_speed_kn", jammer_drift_speed_kn))
	if cfg.has("supported_types"):
		supported_types = cfg["supported_types"]
	if cfg.has("profiles"):
		profiles = cfg["profiles"]


## 按类型取配置画像（无配置返回空字典 → 调用方用默认）。
func profile_for(decoy_type: String) -> Dictionary:
	var p: Variant = profiles.get(decoy_type, null)
	return p if p is Dictionary else {}


## 剩余冷却秒数（UI 显示用；≤0 可发射）。
func cooldown_left(now: float) -> float:
	return maxf(_cooldown_until - now, 0.0)


## DC-07：是否还有备用弹且发射器未满 → 需要（或正在）装填。
func needs_reload() -> bool:
	return ready_rounds < mini(inventory, launcher_capacity)


## DC-07：本次装填剩余仿真秒数（不需要装填时 0）。
func reload_left_s() -> float:
	if not needs_reload() or reload_time_s <= 0.0:
		return 0.0
	return maxf(reload_time_s - _reload_progress_s, 0.0)


## DC-07：按仿真时间推进自动再装填。World 在**未暂停且任务进行中**时才调用
## （tick() 提前返回即自然满足"暂停不装填"）；dt 已按 time_scale 折算 → 倍速
## 按仿真时间。单通道推进：重复请求不会并行装填，也不会一次装多发。
func step(dt: float) -> void:
	if not needs_reload():
		_reload_progress_s = 0.0
		return
	if reload_time_s <= 0.0:  # 关闭计时 → 立即装填到上限（兼容无装填时间的配置）
		ready_rounds = mini(inventory, launcher_capacity)
		_reload_progress_s = 0.0
		return
	_reload_progress_s += dt
	if _reload_progress_s >= reload_time_s:
		_reload_progress_s -= reload_time_s
		ready_rounds += 1
		if not needs_reload():
			_reload_progress_s = 0.0


## DC-07：弹药口径（面板显示"待发/备用/装填剩余时间"共用同一处）。
func ammo_summary() -> Dictionary:
	return {
		"ready": ready_rounds,
		"spare": maxi(inventory - ready_rounds, 0),
		"capacity": launcher_capacity,
		"reloading": needs_reload(),
		"reload_left_s": reload_left_s(),
		"reload_time_s": reload_time_s,
	}


## DC-07：库存守恒自检（ready ≤ inventory 且 ready ≤ 发射器容量）。
func ammo_errors() -> Array:
	var errs: Array = []
	if ready_rounds > inventory:
		errs.append("ready_rounds exceeds inventory")
	if ready_rounds > launcher_capacity:
		errs.append("ready_rounds exceeds launcher capacity")
	return errs


## 发射（§8.5）：返回部署的 Decoy；拒绝返回 null（UI 按原因提示）。
## initial/commanded 深度由调用方按深度模型解析（hold depth），本类不持模型。
func launch(
	prog: DecoyProgram,
	origin: TruthEntity,
	now: float,
	rng: RandomNumberGenerator,
	initial_depth_m: float,
	commanded_depth_m: float
) -> Decoy:
	if prog == null or origin == null:
		last_reject_reason = "invalid_program"
		return null
	var errs: Array = prog.validate()
	if not errs.is_empty():
		last_reject_reason = "invalid_program"
		return null
	if not supported_types.has(prog.decoy_type):
		last_reject_reason = "type_not_supported"
		return null
	if ready_rounds <= 0:
		last_reject_reason = "no_rounds"
		return null
	if cooldown_left(now) > 0.0:
		last_reject_reason = "cooldown"
		return null
	var d := Decoy.new()
	d.deploy(prog.snapshot(), origin, initial_depth_m, commanded_depth_m)
	# REQ-CM-01：每枚诱饵独立画像副本——JAMMER 抖动会原位改写 tonal_lines，
	# 多枚诱饵共享同一 AcousticProfile 实例会互相覆盖（画像覆盖缺陷）。
	d.bind_signature(_dup_signature(prog.signature))
	if rng != null:
		# JAMMER 谱抖动 RNG 与世界 RNG 同源派生（§2.3 固定 seed 确定性）。
		var jr := RandomNumberGenerator.new()
		jr.seed = rng.randi()
		d.bind_jitter_rng(jr)
	ready_rounds -= 1
	inventory = maxi(inventory - 1, 0)
	# DC-07：开火即重置装填进度（下一发从此刻起）——开火失败在更早处返回，
	# 因此"开火失败不扣弹"由上面的早退保证。诱饵到期只从 World 活动列表移除，
	# 不返还 inventory（寿命与库存解耦）。
	_reload_progress_s = 0.0
	_cooldown_until = now + launch_cooldown_s
	_deployed.append(d)
	last_reject_reason = ""
	return d


## 已部署诱饵只读视图（World 组装敌方自有发射源过滤用；Truth 侧台账）。
func deployed_decoys() -> Array:
	return _deployed


## 画像深拷贝（DC-06）：优先用 AcousticProfile.copy()——明确快照，复制**全部**
## 生效字段（含频段 band_min_hz/band_max_hz；旧逐属性白名单漏掉过频段，
## 会让 JAMMER 干扰带在副本上丢失）。非 AcousticProfile 的画像退回逐属性复制。
func _dup_signature(ac: RefCounted) -> RefCounted:
	if ac == null:
		return null
	if ac.has_method("copy"):
		var snap: Variant = ac.call("copy")
		if snap != null:
			return snap
	return _dup_signature_fields(ac)


## 兜底逐属性复制（非 AcousticProfile 画像；RefCounted 无内建 duplicate）。
func _dup_signature_fields(ac: RefCounted) -> RefCounted:
	var cp := AcousticProfile.new()
	for prop in [
		"broadband_base_level_db",
		"speed_noise_a",
		"speed_noise_n",
		"speed_noise_vref_kn",
		"cavitation_speed_kn_at_surface",
		"cavitation_depth_slope",
		"cavitation_extra_db",
		"turns_per_knot",
		"blade_count",
		"shaft_count",
		"active_target_strength_db",
		"decoy_similarity",
		"band_min_hz",
		"band_max_hz",
	]:
		cp.set(prop, ac.get(prop))
	var tls: Variant = ac.get("tonal_lines")
	cp.tonal_lines = AcousticProfile.copy_tonals(tls if tls is Array else [])
	return cp
