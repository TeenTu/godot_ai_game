class_name AcousticEmissionEvent
extends RefCounted
## acoustic_emission_event.gd — 通用声学发射事件 schema（S1-07 §9.1，Commit 5）。
##
## 事件即普通 Dictionary（与 S1-04C active_emissions 契约同构，见 World 与
## ping_tma_integration_test R22），便于序列化 / 净化 / 审计。本文件只提供
## emission_kind 常量 + make() 构造器，不含任何 Truth 目标引用。
##
## 字段（§9.1）：
##   event_id, emitter_internal_ref（内部引用，出 UI 前必须净化，禁止暴露真实
##   目标；S1-04C 契约沿用此键名）, emit_time, source_position_internal{e,n},
##   source_depth_internal, emission_kind, center_frequency_hz, bandwidth_hz,
##   source_level_db, duration_s, directivity, debug_truth_only。
## 另保留 S1-04C 兼容键 pulse_duration_s（= duration_s，旧读方如 R22 依赖）。
##
## src 为 Vector3：x=east、y=north、z=depth（统一声源几何）。

## emission_kind（§9.1 至少含以下类型；DECOY/EXPLOSION 为后续 Commit 预留）。
const PLATFORM_ACTIVE_PING := "PLATFORM_ACTIVE_PING"
const TORPEDO_TUBE_TRANSIENT := "TORPEDO_TUBE_TRANSIENT"
const TORPEDO_MOTOR_START := "TORPEDO_MOTOR_START"
const TORPEDO_RUNNING_NOISE := "TORPEDO_RUNNING_NOISE"
const TORPEDO_ACTIVE_PING := "TORPEDO_ACTIVE_PING"
const DECOY_ACTIVATION := "DECOY_ACTIVATION"
const EXPLOSION := "EXPLOSION"


## 构造一条发射事件字典。extra 可带 directivity（Vector2 扇区，0,0=全向，
## G_dir 方向增益在敌方感知 Commit 9 消费时计算）与 debug_truth_only。
static func make(
	event_id: int,
	kind: String,
	emitter_ref: String,
	emit_time: float,
	src: Vector3,
	freq_hz: float,
	bw_hz: float,
	sl_db: float,
	dur_s: float,
	extra: Dictionary = {}
) -> Dictionary:
	var ev := {
		"event_id": event_id,
		# S1-04C 契约键名（R22 依赖）：emitter_internal_ref（§9.1 概念同名）。
		"emitter_internal_ref": emitter_ref,
		"emit_time": emit_time,
		"source_position_internal": {"e": src.x, "n": src.y},
		"source_depth_internal": src.z,
		"emission_kind": kind,
		"center_frequency_hz": freq_hz,
		"bandwidth_hz": bw_hz,
		"source_level_db": sl_db,
		"duration_s": dur_s,
		"pulse_duration_s": dur_s,  # S1-04C 兼容别名（R22 依赖）
		"directivity": extra.get("directivity", Vector2.ZERO),
		"debug_truth_only": bool(extra.get("debug_truth_only", false)),
	}
	# 其余 extra 键透传（如 tonal_lines，§6.1 分类特征来源）；固定键优先。
	for k in extra:
		if not ev.has(k):
			ev[k] = extra[k]
	return ev
