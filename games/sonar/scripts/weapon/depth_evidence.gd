class_name DepthEvidence
extends RefCounted
## depth_evidence.gd — S1-11 §7.2/§8.3：合法垂向证据 DTO（目标深度概率估计输入）。
##
## 允许的 evidence（§7.2）只有：带噪俯仰/垂向波束、可区分多路径到达时差、变深后
## 层间相对似然、鱼雷 Seeker 经导线回传的带噪层带提示等**带误差模型**的垂向观测。
## 一条被动方位线、单次二维主动 bearing+range、分类标签、声纹清晰度、TruthEntity
## .depth_m、场景 depth_band 都**不能**单独生成深度——本类用 source_kind 明确标注，
## DepthEstimator 只接受 layer_likelihoods 非空者。
##
## 信息边界：绝不含 target_id / TruthEntity / 真实深度引用。

## 合法来源种类（写入 source_kind）。
const SRC_TORPEDO_WIRE := "TORPEDO_WIRE"
const SRC_SEEKER := "SEEKER"
const SRC_OWN_PITCH := "OWN_PITCH"
const SRC_MULTIPATH := "MULTIPATH"
const SRC_LAYER_COMPARE := "LAYER_COMPARE"
## 非法来源（二维主动测距等）——显式命名，便于测试断言"绝不生成深度"。
const SRC_ACTIVE_2D := "ACTIVE_2D"

## §8.3 字段（绝不含 target_id / Truth）。
var evidence_id: String = ""
var timestamp: float = 0.0
var sensor_id: String = ""
var relation_hint: String = ""
## 各层似然（键 SURFACE_LIKELY/UPPER_LIKELY/LOWER_LIKELY，值 >= 0；空 = 不可用）。
var layer_likelihoods: Dictionary = {}
var depth_observed_m: float = -1.0  # 可选明确垂向测量（<0 = 无）
var depth_sigma_m: float = -1.0  # 可选误差（<0 = 无）
var source_kind: String = SRC_SEEKER
var weight: float = 1.0


static func make(
	id: String, t: float, src: String, sensor: String, likelihoods: Dictionary, hint: String = ""
) -> DepthEvidence:
	var e := DepthEvidence.new()
	e.evidence_id = id
	e.timestamp = t
	e.source_kind = src
	e.sensor_id = sensor
	e.layer_likelihoods = likelihoods.duplicate()
	e.relation_hint = hint
	return e


## 是否可进入估计器：必须是合法来源且带可用层似然。
func is_usable() -> bool:
	if source_kind == SRC_ACTIVE_2D:
		return false
	if layer_likelihoods.is_empty():
		return false
	for k in layer_likelihoods:
		if float(layer_likelihoods[k]) > 0.0:
			return true
	return false


func to_dict() -> Dictionary:
	return {
		"evidence_id": evidence_id,
		"timestamp": timestamp,
		"sensor_id": sensor_id,
		"relation_hint": relation_hint,
		"layer_likelihoods": layer_likelihoods.duplicate(),
		"depth_observed_m": depth_observed_m,
		"depth_sigma_m": depth_sigma_m,
		"source_kind": source_kind,
	}


## AT-35：禁止出现在 DTO 中的真值键。
static func forbidden_keys() -> Array:
	return ["target_id", "truth_entity", "true_depth_m", "depth_band", "target_ref"]
