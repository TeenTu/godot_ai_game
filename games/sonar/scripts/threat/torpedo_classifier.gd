class_name TorpedoClassifier
extends RefCounted
## torpedo_classifier.gd — S109 §3.2 基于可观测特征的鱼雷分类器（玩家/敌方共用）。
##
## 只接受 AcousticObservation（或其 to_dict()），绝不读取 emission_kind /
## target_id / 任何 Truth 派生字段。第一版为可配置规则评分（不要求 ML）。
##
## 线索（全部来自接收端特征估计）：
##   HF_ACTIVE_PULSE       高频短脉冲（主动寻的脉冲特征）→ 强鱼雷线索
##   WIDEBAND_TRANSIENT    低频宽带短持续瞬态（出管/电机启动特征）
##   BROADBAND_TONALS      宽带机械噪声 + 多谱线（持续推进特征）
##   JAMMER_LIKE           中频窄带无谱线短持续（噪声干扰器特征）→ 诱饵线索
##   BLAST_LIKE            低频宽带无谱线较长持续高能量 → 爆炸线索
##
## 状态（§3.2）：UNCLASSIFIED / SUSPECTED_TORPEDO(≥0.40) /
## PROBABLE_TORPEDO(≥0.70) / LOST（由航迹层按龄期判定，不在本类）。

const MODEL_VERSION := "tc-rules-v1"
const SUSPECTED_TH: float = 0.40
const PROBABLE_TH: float = 0.70

# 规则参数（可按阵列/训练水平配置覆盖；对双方同源）。
var hf_pulse_min_hz: float = 6000.0
var hf_pulse_max_dur_s: float = 0.5
var hf_pulse_score: float = 0.70
var transient_max_dur_s: float = 2.0
var transient_min_bw_hz: float = 3500.0
var transient_max_hz: float = 2500.0
var transient_score: float = 0.42
var tonal_min_bw_hz: float = 2500.0
var tonal_min_count: int = 2
var tonal_score: float = 0.75
var jammer_min_hz: float = 800.0
var jammer_max_hz: float = 1500.0
var jammer_min_bw_hz: float = 2000.0
var jammer_max_bw_hz: float = 3500.0
var jammer_max_dur_s: float = 1.2
var jammer_score: float = 0.45
var blast_max_hz: float = 800.0
var blast_min_bw_hz: float = 3000.0
var blast_min_dur_s: float = 1.5


func classify(obs: Dictionary) -> Dictionary:
	var cues: Array = []
	var p_torpedo: float = 0.0
	var p_decoy: float = 0.0
	var p_blast: float = 0.0
	var f: float = _center_hz(obs)
	var bw: float = _bandwidth_hz(obs)
	var dur: float = _duration_s(obs)
	var tonals: int = (obs.get("tonal_peaks", []) as Array).size()
	if f >= hf_pulse_min_hz and (dur < 0.0 or dur <= hf_pulse_max_dur_s):
		cues.append("HF_ACTIVE_PULSE")
		p_torpedo += hf_pulse_score
	if (
		dur > 0.0
		and dur <= transient_max_dur_s
		and bw >= transient_min_bw_hz
		and f <= transient_max_hz
	):
		cues.append("WIDEBAND_TRANSIENT")
		p_torpedo += transient_score
	if bw >= tonal_min_bw_hz and tonals >= tonal_min_count:
		cues.append("BROADBAND_TONALS")
		p_torpedo += tonal_score
	if (
		f >= jammer_min_hz
		and f <= jammer_max_hz
		and bw >= jammer_min_bw_hz
		and bw <= jammer_max_bw_hz
		and dur > 0.0
		and dur <= jammer_max_dur_s
		and tonals == 0
	):
		cues.append("JAMMER_LIKE")
		p_decoy += jammer_score
	if f <= blast_max_hz and bw >= blast_min_bw_hz and dur >= blast_min_dur_s and tonals == 0:
		cues.append("BLAST_LIKE")
		p_blast += 0.6
	p_torpedo = clampf(p_torpedo, 0.0, 1.0)
	var p_unknown: float = clampf(1.0 - maxf(maxf(p_torpedo, p_decoy), p_blast), 0.0, 1.0)
	var state: String = "UNCLASSIFIED"
	if p_torpedo >= PROBABLE_TH:
		state = "PROBABLE_TORPEDO"
	elif p_torpedo >= SUSPECTED_TH:
		state = "SUSPECTED_TORPEDO"
	var confidence: float = maxf(maxf(p_torpedo, p_decoy), p_blast)
	return {
		"p_torpedo": p_torpedo,
		"p_decoy": p_decoy,
		"p_blast": p_blast,
		"p_unknown": p_unknown,
		"cues": cues,
		"confidence": confidence,
		"classification_state": state,
		"model_version": MODEL_VERSION,
	}


## 分类结果 → 净化证据层字段（evidence_kind / alert 语义，供 UI/航迹层用）。
## kind 只描述"线索类型"，不再来自内核事件枚举。
static func evidence_kind_for(res: Dictionary) -> String:
	var cues: Array = res.get("cues", [])
	if (
		cues.has("BLAST_LIKE")
		and float(res.get("p_blast", 0.0)) >= float(res.get("p_torpedo", 0.0))
	):
		return "DETONATION"
	if (
		cues.has("JAMMER_LIKE")
		and float(res.get("p_decoy", 0.0)) >= float(res.get("p_torpedo", 0.0))
	):
		return "DECOY"
	if float(res.get("p_torpedo", 0.0)) < SUSPECTED_TH:
		return "ACOUSTIC_EVENT"
	if cues.has("HF_ACTIVE_PULSE"):
		return "ACTIVE_PING"
	if cues.has("WIDEBAND_TRANSIENT"):
		return "LAUNCH_TRANSIENT"
	return "RUNNING_NOISE"


static func alert_for(res: Dictionary) -> String:
	match str(evidence_kind_for(res)):
		"DETONATION":
			return "DETONATION_HEARD"
		"DECOY":
			return "DECOY_DEPLOYED"
		"ACTIVE_PING":
			return "TORPEDO_ACTIVE_PING"
		"LAUNCH_TRANSIENT":
			return "POSSIBLE_LAUNCH_TRANSIENT"
		"RUNNING_NOISE":
			return "POSSIBLE_TORPEDO"
	return "SONAR_TRANSIENT"


static func _center_hz(obs: Dictionary) -> float:
	if obs.get("spectral_centroid_hz", null) != null:
		return float(obs["spectral_centroid_hz"])
	var lo: float = float(obs.get("measured_band_min_hz", 0.0))
	var hi: float = float(obs.get("measured_band_max_hz", 0.0))
	if hi > lo:
		return 0.5 * (lo + hi)
	return 0.0


static func _bandwidth_hz(obs: Dictionary) -> float:
	if obs.get("spectral_spread_hz", null) != null:
		return float(obs["spectral_spread_hz"])
	var lo: float = float(obs.get("measured_band_min_hz", 0.0))
	var hi: float = float(obs.get("measured_band_max_hz", 0.0))
	if hi > lo:
		return hi - lo
	return 0.0


static func _duration_s(obs: Dictionary) -> float:
	if obs.get("transient_duration_s", null) != null:
		return float(obs["transient_duration_s"])
	if obs.get("pulse_width_s", null) != null:
		return float(obs["pulse_width_s"])
	return -1.0
