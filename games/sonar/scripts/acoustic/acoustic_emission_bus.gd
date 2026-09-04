class_name AcousticEmissionBus
extends RefCounted
## acoustic_emission_bus.gd — 通用声学事件总线（S1-07 §9.1，Commit 5）。
##
## World.active_emissions（S1-04C 契约）改为本总线 events 的同一数组引用：
## 本艇主动 Ping（PLATFORM_ACTIVE_PING）与鱼雷各阶段声源（出管瞬态 / 动力
## 启动 / 航行噪声 / 主动 Ping）统一经 record() 落一条事件字典。敌方/玩家感知
## 层（Commit 9/敌方）只消费净化后样本，绝不经此总线外泄 internal_emitter_ref。
##
## 纯数据容器 + 确定性计数；无 RNG、无 Truth、无目标选择。
## src 为 Vector3：x=east、y=north、z=depth。

const MAX_EVENTS: int = 1024

## 底层事件数组（Dictionary，schema 见 AcousticEmissionEvent）。World 的
## active_emissions 与此同引用，旧读方（R22 等）无需改动。
var events: Array = []

var _next_event_id: int = 1


func clear() -> void:
	events.clear()
	_next_event_id = 1


func count() -> int:
	return events.size()


## 记录一条发射事件并返回该事件字典。extra 可带 directivity / debug_truth_only
## （见 AcousticEmissionEvent.make）。超出 MAX_EVENTS 时丢最旧（防无界增长）。
func record(
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
	var ev: Dictionary = (
		AcousticEmissionEvent
		. make(
			_next_event_id,
			kind,
			emitter_ref,
			emit_time,
			src,
			freq_hz,
			bw_hz,
			sl_db,
			dur_s,
			extra,
		)
	)
	_next_event_id += 1
	events.append(ev)
	if events.size() > MAX_EVENTS:
		events.pop_front()
	return ev


## 本艇主动 Ping 便捷入口（emitter="own"；World.issue_ping 使用）。
func record_platform_active_ping(
	emit_time: float, src: Vector3, freq_hz: float, bw_hz: float, sl_db: float, dur_s: float
) -> Dictionary:
	return record(
		AcousticEmissionEvent.PLATFORM_ACTIVE_PING,
		"own",
		emit_time,
		src,
		freq_hz,
		bw_hz,
		sl_db,
		dur_s
	)


func events_of_kind(kind: String) -> Array:
	var out: Array = []
	for ev in events:
		if str(ev.get("emission_kind", "")) == kind:
			out.append(ev)
	return out
