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

var _assets: Dictionary = {}  # id -> {kind, e, n, depth, state}


func reset() -> void:
	_assets.clear()


func register(id: String, kind: String, e: float, n: float, depth: float, state: String) -> void:
	_assets[str(id)] = {"kind": kind, "e": e, "n": n, "depth": depth, "state": state}


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
			"ACTIVE" if (bool(d.activated) and not bool(d.expired)) else "STANDBY"
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
