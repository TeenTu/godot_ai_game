class_name DecoyTrace
extends RefCounted
## decoy_trace.gd — P1-C DC-01：诱饵运动复现记录（**只在调试日志**）。
##
## 目的（DC-01 原文要求）：先记录复现，区分三类状态，再判定"诱饵轨迹是否被绑定/
## 缓存/坐标错误污染"，而不是把"相机跟随本艇导致的相对观感变化"或"同向同速"直接
## 当成位置绑定。
##
## 记录字段：出管时刻、发射方位、本艇与诱饵**各自世界坐标**、实际/命令航向航速与
## 深度、地图相机与绘制坐标。开关默认关闭（`SONAR_DECOY_TRACE=1` 或显式
## set_enabled(true)）；关闭时所有记录调用是零成本空操作。
##
## 信息链纪律：本类只在调试通道使用，**绝不**被任何战术 UI 读取（不向普通 UI 泄露
## 敌方 Truth）；记录里的敌方诱饵条目仅存在于显式打开的调试日志中。

## 每个诱饵的采样间隔（仿真秒）。
const SAMPLE_INTERVAL_S: float = 1.0
const MAX_RECORDS: int = 512

var enabled: bool = false
var records: Array = []
## 地图相机与绘制坐标快照（由 UI 每帧推入；DC-01 要求记录）。
var camera: Dictionary = {}

var _next_sample_s: float = 0.0


func _init() -> void:
	enabled = OS.get_environment("SONAR_DECOY_TRACE") == "1"


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		records.clear()


## UI 推入相机/绘制坐标（world_to_screen 的参数与结果在测试里另附）。
func set_camera(info: Dictionary) -> void:
	if enabled:
		camera = info


## 出管记录：程序快照 + 本艇/诱饵世界坐标 + 实际与命令航向航速深度。
func record_launch(d: Decoy, own: TruthEntity, prog: DecoyProgram) -> void:
	if not enabled or d == null:
		return
	_push(
		{
			"t": 0.0,
			"event": "LAUNCH",
			"decoy": str(d.id),
			"type": str(d.decoy_type),
			"launch_bearing_deg": float(d.launch_bearing_deg),
			"advanced_course": bool(d.advanced_course),
			"separation_s": float(d.separation_duration_s),
			"separation_kn": float(d.separation_speed_kn),
			"cruise_kn": float(d.cruise_speed_kn),
		}
	)
	_attach_entities(d, own)
	records[-1]["t"] = 0.0
	records[-1]["program_course_deg"] = prog.resolved_course_deg() if prog != null else -1.0


## 周期采样（每 SAMPLE_INTERVAL_S 仿真秒，逐诱饵一行）。
func sample(now: float, decoys: Array, own: TruthEntity) -> void:
	if not enabled:
		return
	if now + 1e-6 < _next_sample_s:
		return
	_next_sample_s = now + SAMPLE_INTERVAL_S
	for d in decoys:
		if d == null or bool(d.expired):
			continue
		_push({"t": now, "event": "SAMPLE", "decoy": str(d.id), "type": str(d.decoy_type)})
		_attach_entities(d, own)


func _attach_entities(d: Decoy, own: TruthEntity) -> void:
	var r: Dictionary = records[-1]
	r["decoy_state"] = {
		"e": float(d.position_east_m),
		"n": float(d.position_north_m),
		"z": float(d.depth_m),
		"cmd_z": float(d.commanded_depth_m),
		"course": float(d.course_deg),
		"cmd_course": float(d.commanded_course_deg),
		"speed": float(d.speed_kn),
		"cmd_speed": float(d.commanded_speed_kn),
		"age": float(d.age_s),
		"state": str(d.state()),
	}
	if own != null:
		r["own"] = {
			"e": float(own.position_east_m),
			"n": float(own.position_north_m),
			"z": float(own.depth_m),
			"course": float(own.course_deg),
			"cmd_course": float(own.commanded_course_deg),
			"speed": float(own.speed_kn),
			"cmd_speed": float(own.commanded_speed_kn),
		}
	r["camera"] = camera


func _push(rec: Dictionary) -> void:
	records.append(rec)
	while records.size() > MAX_RECORDS:
		records.pop_front()


## 调试打印（DC-01 的"记录复现"产出；只在 enabled 时调用）。
func dump(label: String = "") -> void:
	if records.is_empty():
		print("[decoy-trace] %s: <empty>" % label)
		return
	print("[decoy-trace] %s: %d records, camera=%s" % [label, records.size(), str(camera)])
	for r in records:
		if str(r.get("event", "")) == "LAUNCH":
			print(
				(
					"  t=%.1f LAUNCH %s %s brg=%.0f advanced=%s sep=%.0fs/%.1fkn cruise=%.1fkn"
					% [
						float(r["t"]),
						str(r["decoy"]),
						str(r["type"]),
						float(r["launch_bearing_deg"]),
						str(r["advanced_course"]),
						float(r["separation_s"]),
						float(r["separation_kn"]),
						float(r["cruise_kn"]),
					]
				)
			)
			continue
		var dd: Dictionary = r.get("decoy_state", {})
		var oo: Dictionary = r.get("own", {})
		var tpl: String = (
			"  t=%.1f %s own(e=%.1f,n=%.1f,z=%.1f,crs=%.0f,v=%.1f)"
			+ " dec(e=%.1f,n=%.1f,z=%.1f,crs=%.0f,v=%.1f,st=%s)"
		)
		print(
			(
				tpl
				% [
					float(r["t"]),
					str(r["decoy"]),
					float(oo.get("e", 0.0)),
					float(oo.get("n", 0.0)),
					float(oo.get("z", 0.0)),
					float(oo.get("course", 0.0)),
					float(oo.get("speed", 0.0)),
					float(dd.get("e", 0.0)),
					float(dd.get("n", 0.0)),
					float(dd.get("z", 0.0)),
					float(dd.get("course", 0.0)),
					float(dd.get("speed", 0.0)),
					str(dd.get("state", "")),
				]
			)
		)


## 某诱饵的采样轨迹（世界坐标），按时间序。
func track_of(decoy_id: String) -> Array:
	var out: Array = []
	for r in records:
		if str(r.get("decoy", "")) != decoy_id:
			continue
		var dd: Variant = r.get("decoy_state", null)
		if dd is Dictionary:
			out.append(dd)
	return out
