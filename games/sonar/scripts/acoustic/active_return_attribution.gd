class_name ActiveReturnAttribution
extends RefCounted
## active_return_attribution.gd — PG-05：一次 Ping 的**全局一次归属**。
##
## 旧实现有两条各自独立的回波归属链：
##   1) World 只拿威胁航迹（TT）做一对一分配 → 融合进 TT；
##   2) UI 侧 ActivePingController 只拿普通接触做一对一分配 → 挂到普通航迹。
## 同一条回波可能同时被 TT 与普通接触吸收（信息双计），地图上出现"同一物体
## 两个目标"（M 组 + TT 组）。本类把两类候选放进**同一个代价矩阵**，一次遍历
## 决出唯一归属：
##   - owner_kind == "THREAT"  → 归威胁航迹（TT），信息只融合一次；
##   - owner_kind == "CONTACT" → 归普通接触（M/S/P 航迹）；
##   - 无归属（门控失败/最优次优接近）→ 保留未归属，绝不按到达顺序强塞。
##
## 纪律（T16/T17/T19）：
##   - 回波与候选都由调用方提供**同一观测参考站位/参考时刻**下的可观测量
##     （见 OwnStationSnapshot / Measurement.reference_station），不混用旧距离；
##   - 输入顺序无关：代价全序排序后一对一贪心（ActiveReturnBatch）；
##   - 只消费净化 DTO（无内部身份/无 Truth），归属只用 bearing/range/误差/频谱。

const KIND_THREAT: String = "THREAT"
const KIND_CONTACT: String = "CONTACT"
## 门控失败/最优次优接近 → 保留未归属（绝不默认成 CONTACT，否则台账会假装
## 这条观测已经被某个普通接触吸收）。
const KIND_UNASSIGNED: String = "UNASSIGNED"


## 一次全局归属。
## returns: [{id, bearing_deg, bearing_sigma_deg, range_m, range_sigma_m, time, freqs}]
## targets: [{id, kind, bearing_deg, bearing_sigma_deg, range_m, range_sigma_m,
##            time, freqs}]（kind 缺省按 CONTACT）
## 返回 {owners: {return_id: {kind, id}}, assignments, unassigned, ambiguous,
##       counts: {THREAT, CONTACT, UNASSIGNED}}。
static func attribute(returns: Array, targets: Array, opts: Dictionary = {}) -> Dictionary:
	var norm: Array = []
	var kinds: Dictionary = {}
	for t in targets:
		var dto: Dictionary = (t as Dictionary).duplicate()
		var kind: String = str(dto.get("kind", KIND_CONTACT))
		dto["kind"] = kind
		var tid: String = str(dto.get("id", ""))
		if tid == "":
			continue
		norm.append(dto)
		kinds[tid] = kind
	var res: Dictionary = ActiveReturnBatch.assign(returns, norm, opts)
	var assigns: Dictionary = res.get("assignments", {})
	var owners: Dictionary = {}
	var counts: Dictionary = {KIND_THREAT: 0, KIND_CONTACT: 0, KIND_UNASSIGNED: 0}
	for rid in assigns.keys():
		var owner_id: String = str(assigns[rid])
		var kind: String = str(kinds.get(owner_id, KIND_CONTACT))
		owners[str(rid)] = {"kind": kind, "id": owner_id}
		counts[kind] = int(counts.get(kind, 0)) + 1
	for u in res.get("unassigned", []):
		var u_id: String = str((u as Dictionary).get("id", ""))
		owners[u_id] = {"kind": KIND_UNASSIGNED, "id": ""}
		counts[KIND_UNASSIGNED] = int(counts[KIND_UNASSIGNED]) + 1
	return {
		"owners": owners,
		"assignments": assigns,
		"unassigned": res.get("unassigned", []),
		"ambiguous": res.get("ambiguous", []),
		"counts": counts,
	}
