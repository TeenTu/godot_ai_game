class_name DepthLayerModel
extends RefCounted
## depth_layer_model.gd — 双层伪三维深度层模型（S1-07 §4 / Commit 2）。
##
## 战术抽象为 UPPER（温跃层上方）/ LOWER（温跃层下方）两层 + 转换带
## TRANSITION。实体仍保存连续实际深度，绝不只存布尔层。
##
## 跨层传播（S1-07 §4.3）：TL_layer = TL_base + w_cross * L_thermocline(f)，
## w_cross∈[0,1]：同稳定层≈0、稳定跨层≈1、转换带内 smoothstep 平滑变化——
## 只降探测概率，不使用 hard hidden（Pd=1/(1+exp(-SE/kd)) 恒为正）。
##
## 旧二维场景未配置 depth_layers 时 enabled=false：band 归 UPPER、跨层权重恒 0，
## 所有额外损失为 0 → 零行为变化（S1-07A 验收：保持兼容）。

const DEPTH_BAND_UPPER: String = "UPPER"
const DEPTH_BAND_LOWER: String = "LOWER"
const DEPTH_BAND_TRANSITION: String = "TRANSITION"

var enabled: bool = false
var surface_depth_m: float = 0.0
var bottom_depth_m: float = 400.0
var thermocline_depth_m: float = 120.0
var thermocline_thickness_m: float = 20.0
var upper_hold_depth_m: float = 70.0
var lower_hold_depth_m: float = 180.0
var cross_layer_loss_db_by_frequency: Dictionary = {"500": 6.0, "3000": 10.0}


func from_dict(d: Dictionary) -> void:
	enabled = bool(d.get("enabled", enabled))
	surface_depth_m = float(d.get("surface_depth_m", surface_depth_m))
	bottom_depth_m = float(d.get("bottom_depth_m", bottom_depth_m))
	thermocline_depth_m = float(d.get("thermocline_depth_m", thermocline_depth_m))
	thermocline_thickness_m = maxf(
		float(d.get("thermocline_thickness_m", thermocline_thickness_m)), 1.0
	)
	upper_hold_depth_m = float(d.get("upper_hold_depth_m", upper_hold_depth_m))
	lower_hold_depth_m = float(d.get("lower_hold_depth_m", lower_hold_depth_m))
	cross_layer_loss_db_by_frequency = d.get(
		"cross_layer_loss_db_by_frequency", cross_layer_loss_db_by_frequency
	)


## 深度 → 层带。disabled 时全部归 UPPER（旧二维兼容）。
func depth_band(z_m: float) -> String:
	if not enabled:
		return DEPTH_BAND_UPPER
	if z_m <= _upper_bound():
		return DEPTH_BAND_UPPER
	if z_m >= _lower_bound():
		return DEPTH_BAND_LOWER
	return DEPTH_BAND_TRANSITION


## 层命令的目标 hold 深度（UPPER→upper_hold / LOWER→lower_hold）。
func hold_depth_for_band(band: String) -> float:
	if band == DEPTH_BAND_LOWER:
		return lower_hold_depth_m
	return upper_hold_depth_m


## 归一化层坐标 u∈[0,1]：稳定上层=0、稳定下层=1、转换带内 smoothstep。
## disabled 时任意深度 u=0（同层语义 → 跨层权重恒 0）。
func layer_u(z_m: float) -> float:
	if not enabled:
		return 0.0
	var ub: float = _upper_bound()
	var lb: float = _lower_bound()
	if z_m <= ub:
		return 0.0
	if z_m >= lb:
		return 1.0
	return _smoothstep(ub, lb, z_m)


## 跨层权重 w_cross(z_s,z_r) = |u_s - u_r|：同稳定层 0，稳定跨层 1，转换带平滑。
func cross_layer_weight(z_s: float, z_r: float) -> float:
	return clampf(absf(layer_u(z_s) - layer_u(z_r)), 0.0, 1.0)


## 附加跨层损失 = w_cross * L_thermocline(f)（频率表线性插值）。
func cross_layer_loss_db(freq_hz: float, w_cross: float) -> float:
	if w_cross <= 1e-4:
		return 0.0
	return w_cross * _layer_loss_at(freq_hz)


## 深度层状态名（UPPER/LOWER/TRANSITION），UI/测试用。
func band_name(z_m: float) -> String:
	return depth_band(z_m)


func _upper_bound() -> float:
	return thermocline_depth_m - thermocline_thickness_m * 0.5


func _lower_bound() -> float:
	return thermocline_depth_m + thermocline_thickness_m * 0.5


static func _smoothstep(e0: float, e1: float, x: float) -> float:
	var t: float = clampf((x - e0) / maxf(e1 - e0, 1e-6), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 频率表点线性插值（键可能是 String 或 float，JSON 读入多为 String）。
func _layer_loss_at(freq_hz: float) -> float:
	if cross_layer_loss_db_by_frequency.is_empty():
		return 0.0
	var freqs: Array = []
	for k in cross_layer_loss_db_by_frequency.keys():
		freqs.append(float(k))
	freqs.sort()
	if freq_hz <= float(freqs[0]):
		return _table_value_at(freqs[0])
	if freq_hz >= float(freqs[-1]):
		return _table_value_at(freqs[-1])
	for i in range(freqs.size() - 1):
		var f0: float = float(freqs[i])
		var f1: float = float(freqs[i + 1])
		if freq_hz >= f0 and freq_hz <= f1:
			var t: float = (freq_hz - f0) / maxf(f1 - f0, 1e-6)
			return lerpf(_table_value_at(f0), _table_value_at(f1), t)
	return 0.0


func _table_value_at(f_hz: float) -> float:
	for k in cross_layer_loss_db_by_frequency.keys():
		if absf(float(k) - f_hz) < 1e-6:
			return float(cross_layer_loss_db_by_frequency[k])
	return 0.0


## 连续升降一步（命令与实际分离，Vz 限速，禁止瞬移换层）。
## 供本艇/敌艇/鱼雷/诱饵统一调用。
static func step_vertical(
	z: float, z_cmd: float, vz_max: float, z_min: float, z_max: float, dt: float
) -> Dictionary:
	if z_cmd < 0.0:
		return {"z": z, "done": true}
	var dz: float = clampf(z_cmd - z, -vz_max * dt, vz_max * dt)
	var z_next: float = clampf(z + dz, z_min, z_max)
	var done: bool = absf(z_cmd - z_next) < 0.01
	if done:
		z_next = z_cmd
	return {"z": z_next, "done": done}
