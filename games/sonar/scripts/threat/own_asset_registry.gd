class_name OwnAssetRegistry
extends RefCounted
## own_asset_registry.gd — S109 §2.4 己方合法事实登记表。
##
## 己方平台 id、己方已发射鱼雷 id/遥测位置/状态、己方已发射诱饵 id/遥测
## 位置/状态是本艇合法已知信息。用途仅限：
##   - 排除己方资产被标成敌雷（分类前过滤）；
##   - 海图显示友方武器；
##   - 对声学观测作"与已知己方资产一致"的门控。
## 绝不使用敌方资产 id 或敌方 Truth 做同样的过滤；绝不按 ET/PT id 前缀
## 猜阵营（AT-09：删除 id 前缀后行为不变——登记靠内核所有权，不靠命名）。

var _assets: Dictionary = {}  # id -> {kind, e, n, depth, state, ...extra}


func reset() -> void:
	_assets.clear()


## extra：随类的公开事实（DC-04 诱饵的类型/方向/寿命等）。只存本艇遥测已知的字段。
func register(
	id: String,
	kind: String,
	e: float,
	n: float,
	depth: float,
	state: String,
	extra: Dictionary = {}
) -> void:
	var row: Dictionary = {"kind": kind, "e": e, "n": n, "depth": depth, "state": state}
	for k in extra.keys():
		row[str(k)] = extra[k]
	_assets[str(id)] = row


func unregister(id: String) -> void:
	_assets.erase(str(id))


## 每tick由 World 同步：己方在水鱼雷 + 己方诱饵（本艇遥测，合法事实）。
func sync_from_world(weapons: RefCounted, decoys: Array) -> void:
	var live: Dictionary = {}
	if weapons != null:
		for tp in weapons.torpedoes:
			var id: String = str(tp.torpedo_id)
			live[id] = true
			register(
				id,
				"TORPEDO",
				float(tp.pos_east_m),
				float(tp.pos_north_m),
				float(tp.actual_depth_m),
				str(tp.state) if "state" in tp else "RUNNING"
			)
	for d in decoys:
		if str(d.side) != "blue":
			continue
		var did: String = str(d.id)
		live[did] = true
		register(
			did,
			"DECOY",
			float(d.position_east_m),
			float(d.position_north_m),
			float(d.depth_m),
			str(d.state()) if d.has_method("state") else "ACTIVE",
			{
				"decoy_type": str(d.decoy_type),
				"course_deg": float(d.course_deg),
				"speed_kn": float(d.speed_kn),
				"age_s": float(d.age_s),
				"lifetime_s": float(d.lifetime_s),
				"launch_bearing_deg": float(d.launch_bearing_deg),
			}
		)
	for id in _assets.keys():
		if not live.has(str(id)) and str(_assets[str(id)]["kind"]) != "PLATFORM":
			_assets.erase(str(id))


func is_own_emitter(id: String) -> bool:
	return _assets.has(str(id)) or str(id) == "own"


## 兼容旧消费方（emission_sanitizer own_emitter_refs 字典）。
func refs_dict() -> Dictionary:
	var out := {"own": true}
	for id in _assets.keys():
		out[str(id)] = true
	return out


## 己方鱼雷快照（海图友方武器显示用，Batch 4 消费；只读副本）。
func torpedoes() -> Array:
	var out: Array = []
	for id in _assets.keys():
		var a: Dictionary = _assets[id]
		if str(a["kind"]) == "TORPEDO":
			out.append(
				{"id": str(id), "e": float(a["e"]), "n": float(a["n"]), "state": str(a["state"])}
			)
	return out


## DC-04：己方诱饵快照（海图诱饵图层 DTO 源，只读副本）。含稳定 ID、**诱饵自身**
## 世界位置（绝不用本艇位置顶替，也不用激活事件的 LOA 代替实体位置图标）、状态、
## 类型、方向与寿命。过期诱饵由 sync_from_world 注销 → 退出活动图层。
func decoys() -> Array:
	var out: Array = []
	for id in _assets.keys():
		var a: Dictionary = _assets[id]
		if str(a["kind"]) != "DECOY":
			continue
		(
			out
			. append(
				{
					"id": str(id),
					"e": float(a["e"]),
					"n": float(a["n"]),
					"depth": float(a["depth"]),
					"state": str(a["state"]),
					"type": str(a.get("decoy_type", "")),
					"course_deg": float(a.get("course_deg", 0.0)),
					"speed_kn": float(a.get("speed_kn", 0.0)),
					"age_s": float(a.get("age_s", 0.0)),
					"lifetime_s": float(a.get("lifetime_s", 0.0)),
					"launch_bearing_deg": float(a.get("launch_bearing_deg", 0.0)),
				}
			)
		)
	return out
