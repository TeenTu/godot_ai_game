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
		return null
	var errs: Array = prog.validate()
	if not errs.is_empty():
		return null
	if not supported_types.has(prog.decoy_type):
		return null
	if ready_rounds <= 0:
		return null
	if cooldown_left(now) > 0.0:
		return null
	var d := Decoy.new()
	d.deploy(prog.snapshot(), origin, initial_depth_m, commanded_depth_m)
	d.bind_signature(prog.signature)
	if rng != null:
		# JAMMER 谱抖动 RNG 与世界 RNG 同源派生（§2.3 固定 seed 确定性）。
		var jr := RandomNumberGenerator.new()
		jr.seed = rng.randi()
		d.bind_jitter_rng(jr)
	ready_rounds -= 1
	inventory = maxi(inventory - 1, 0)
	_cooldown_until = now + launch_cooldown_s
	_deployed.append(d)
	return d
