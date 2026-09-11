class_name DecoyMapLayer
extends RefCounted
## decoy_map_layer.gd — P1-C DC-04：己方诱饵的海图独立图层状态。
##
## 数据来源只有**合法己方资产遥测**（OwnAssetRegistry.decoys()：本艇发射的诱饵，
## 位置/状态/类型/方向/寿命都是本艇事实）。纪律：
##   - 位置一律用**诱饵自身**世界坐标，绝不用本艇当前位置顶替，也不把激活事件的
##     LOA 当作实体位置图标；
##   - 有遥测 → measured=true（标"实测"）；没有遥测的条目必须由调用方显式给
##     measured=false 并带 age_s（标"程序估计"并计龄），不伪造遥测；
##   - 轨迹只存世界坐标，因此地图平移/缩放/改窗口不改变任何一条轨迹；
##   - 诱饵退出活动列表（过期/注销）→ 移出活动图层，最后已知状态进 history，
##     历史仍可查询（history_rows() / track_of()）。

const STATE_EXPIRED: String = "EXPIRED"
## 轨迹点抽稀阈值（米）：位移小于该值不新增顶点（省内存，不改世界坐标语义）。
const TRACK_MIN_STEP_M: float = 1.0

var active: Array = []  # 本帧活动图层 DTO（含 trail/selected）
var tracks: Dictionary = {}  # id -> Array[Vector2]（世界坐标）
var history: Dictionary = {}  # id -> DTO（含 gone_time；已退出活动图层）
var selected_id: String = ""

var _last: Dictionary = {}  # id -> DTO（上一帧活动条目，用于注销留档）


func reset() -> void:
	active.clear()
	tracks.clear()
	history.clear()
	_last.clear()
	selected_id = ""


## 用一帧的 DTO 行刷新活动图层：累积世界坐标轨迹；消失的 id 移入历史。
func sync(rows: Array, now: float) -> void:
	var live: Dictionary = {}
	var out: Array = []
	for r in rows:
		var d: Dictionary = (r as Dictionary).duplicate()
		var did: String = str(d.get("id", ""))
		if did == "":
			continue
		live[did] = true
		if not tracks.has(did):
			tracks[did] = []
		var tr: Array = tracks[did]
		var p := Vector2(float(d.get("e", 0.0)), float(d.get("n", 0.0)))
		if tr.is_empty() or (tr[-1] as Vector2).distance_to(p) > TRACK_MIN_STEP_M:
			tr.append(p)
		d["selected"] = did == selected_id
		d["trail"] = tr.duplicate()
		_last[did] = d
		out.append(d)
	# 注销/过期：退出活动图层（不再绘制图标），最后已知状态留档供历史查询。
	for did in _last.keys():
		var sid: String = str(did)
		if live.has(sid):
			continue
		if not history.has(sid):
			var rec: Dictionary = (_last[sid] as Dictionary).duplicate()
			rec["state"] = STATE_EXPIRED
			rec["gone_time"] = now
			rec["selected"] = false
			history[sid] = rec
		_last.erase(sid)
		if selected_id == sid:
			selected_id = ""
	active = out


func select(decoy_id: String) -> void:
	selected_id = decoy_id
	for r in active:
		(r as Dictionary)["selected"] = str((r as Dictionary).get("id", "")) == decoy_id


## 点击命中点：屏幕坐标一律走与本艇/鱼雷/航线同一个 world_to_screen。
func click_points(chart: ChartView) -> Array:
	var out: Array = []
	for r in active:
		var d: Dictionary = r
		var at := chart.world_to_screen(Vector2(float(d.get("e", 0.0)), float(d.get("n", 0.0))))
		out.append({"pos": at, "decoy_id": str(d.get("id", ""))})
	return out


func row_of(decoy_id: String) -> Dictionary:
	for r in active:
		if str((r as Dictionary).get("id", "")) == decoy_id:
			return (r as Dictionary).duplicate()
	return {}


## 历史记录查询（已退出活动图层的诱饵）。
func history_rows() -> Array:
	var out: Array = []
	for id in history.keys():
		out.append((history[id] as Dictionary).duplicate())
	return out


func track_of(decoy_id: String) -> Array:
	return (tracks.get(decoy_id, []) as Array).duplicate()


## DC-04：**无遥测**时的程序估计条目（位置 = 出管点 + 航向 × 速度 × 计龄）。
## measured=false 让它在地图上明确标"程序估计"（不冒充实测），updated_time 给计龄
## 基准。本批次的实测源是本艇诱饵遥测（OwnAssetRegistry.decoys()），因此**当前
## 没有生产调用方**——本函数是净化观测通道（尚未实现）的既定落点，并被
## decoy_map_test 直接断言，不凭空在地图上构造条目。
static func program_estimated(
	id: String,
	launch_e: float,
	launch_n: float,
	course_deg: float,
	speed_kn: float,
	age_s: float,
	decoy_type: String,
	state: String,
	updated_time: float
) -> Dictionary:
	var dist_m: float = NavUtils.kn_to_ms(speed_kn) * maxf(age_s, 0.0)
	var p := Vector2(launch_e, launch_n) + NavUtils.bearing_to_world_dir(course_deg) * dist_m
	return {
		"id": id,
		"e": p.x,
		"n": p.y,
		"state": state,
		"type": decoy_type,
		"course_deg": course_deg,
		"speed_kn": speed_kn,
		"age_s": maxf(age_s, 0.0),
		"lifetime_s": 0.0,
		"measured": false,
		"updated_time": updated_time,
		"selected": false,
	}
