class_name CountermeasureSystem
extends RefCounted

## CountermeasureSystem（S1-07 §8.1/§8.5，Commit 8）：诱饵发射器。玩家艇与
## 敌艇均可配置（同一类，origin 只是 TruthEntity）；本版不要求战斗中再装填，
## ready_rounds 用尽后不可继续发射。发射有效性：库存/冷却/类型支持/程序合法
## /方位与深度合法（§8.5），绝无"随时无限发"。

var launcher_id: String = "CM-1"
var launcher_count: int = 1
var ready_rounds: int = 2  # 已装填可用
var inventory: int = 4  # 总库存（含已装填）
var launch_cooldown_s: float = 10.0
var supported_types: Array = [DecoyProgram.TYPE_MOBILE, DecoyProgram.TYPE_JAMMER]
## REQ-CM-04：最近一次拒绝原因（UI 展示用；launch 成功后清空）。
var last_reject_reason: String = ""
## REQ-CM-04：按类型配置的诱饵画像（scenario own_ship.countermeasures.profiles；
## UI 只选类型，不再回调构造物理参数）。值 = AcousticProfile.from_dict 口径字典。
var profiles: Dictionary = {}

var _cooldown_until: float = -1.0
var _deployed: Array = []  # 本发射器已部署的 Decoy（Truth 侧台账）


func configure(cfg: Dictionary) -> void:
	launcher_id = str(cfg.get("launcher_id", launcher_id))
	launcher_count = int(cfg.get("launcher_count", launcher_count))
	ready_rounds = int(cfg.get("ready_rounds", ready_rounds))
	inventory = maxi(int(cfg.get("inventory", inventory)), ready_rounds)
	launch_cooldown_s = float(cfg.get("launch_cooldown_s", launch_cooldown_s))
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
	_cooldown_until = now + launch_cooldown_s
	_deployed.append(d)
	last_reject_reason = ""
	return d


## 画像深拷贝：RefCounted 无内建 duplicate——逐属性复制（tonal_lines 逐条
## 复制），保证同程序多枚诱饵的抖动/覆写互不干扰。
func _dup_signature(ac: RefCounted) -> RefCounted:
	if ac == null:
		return null
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
	]:
		cp.set(prop, ac.get(prop))
	var lines: Array = []
	var tls: Variant = ac.get("tonal_lines")
	if tls is Array:
		for tl in tls:
			if tl is Dictionary:
				lines.append((tl as Dictionary).duplicate())
			else:
				lines.append(tl)
	cp.tonal_lines = lines
	return cp
