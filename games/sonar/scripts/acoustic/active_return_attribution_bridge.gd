class_name ActiveReturnAttributionBridge
extends RefCounted
## active_return_attribution_bridge.gd — PG-05：世界侧一次 Ping 会话与
## ActiveReturnAttribution（全局一次归属）之间的桥。
##
## 纯函数、无副作用、不读 Truth 身份；世界只负责"落地"：
##   THREAT  → 融合进威胁航迹一次；
##   CONTACT → 交 UI 按 owner_id 挂到普通航迹；
##   无归属（UNASSIGNED）→ 保留净化证据（含歧义未归属，绝不按到达顺序强塞）。
##
## 职责：
##   1) 回波批次 → 归属输入 DTO（观测时刻/误差一律取回波自身参考系）；
##   2) TT 威胁航迹快照 → 威胁候选 DTO（只含可观测状态）；
##   3) 一次归属，产出**可落地**的条目（自带 idx，调用方可取回原始回波对象）；
##   4) 按 Ping 过滤取走结论队列（取走一个监听窗的结论不丢其他监听窗的）。


## 批次内回波稳定 id（顺序无关，仅用于分配索引）。
static func return_id_of(ping_id: int, idx: int) -> String:
	return "P%d-R%03d" % [ping_id, idx]


## 回波批次 → 归属输入 DTO。净化 DTO 目前不带谱线，故矩阵只按 方位/距离/时刻
## 比较（候选两侧同口径；谱线判别在候选两侧同时接入，见 P1-C 的威胁签名频段字段）。
static func returns_of(batch: Array, ping_id: int, fallback_time: float) -> Array:
	var out: Array = []
	for i in range(batch.size()):
		var e: Dictionary = batch[i]
		(
			out
			. append(
				{
					"id": return_id_of(ping_id, i),
					"bearing_deg": float(e.get("bearing_deg", 0.0)),
					"bearing_sigma_deg": float(e.get("bearing_sigma_deg", 2.0)),
					"range_m": float(e.get("measured_range_m", -1.0)),
					"range_sigma_m": float(e.get("range_sigma_m", 100.0)),
					"time": float(e.get("available_time", fallback_time)),
					"freqs": [],
				}
			)
		)
	return out


## TT 威胁航迹快照（ThreatTrackManager.estimate_snapshot 的输出）→ 威胁候选 DTO。
static func threat_targets(snaps: Array) -> Array:
	var out: Array = []
	for snap in snaps:
		var s: Dictionary = snap
		var rng: float = -1.0
		var rng_sig: float = 100.0
		if s.get("range_est_m") != null:
			rng = float(s["range_est_m"])
			if s.get("range_sigma_m") != null:
				rng_sig = float(s["range_sigma_m"])
		(
			out
			. append(
				{
					"id": str(s.get("track_id", "")),
					"kind": ActiveReturnAttribution.KIND_THREAT,
					"bearing_deg": float(s.get("bearing_est_deg", 0.0)),
					"bearing_sigma_deg": float(s.get("bearing_sigma_deg", 2.0)),
					"range_m": rng,
					"range_sigma_m": rng_sig,
					"time": float(s.get("last_update_time", 0.0)),
					"freqs": [],
				}
			)
		)
	return out


## 一次全局归属（TT 候选与普通接触候选在同一代价矩阵里竞争）。
## 返回 [{idx, ping_id, return_id, evidence_id, owner_kind, owner_id,
##        bearing_deg, range_m}]，顺序与批次一致；每条回波必有且只有一条。
static func resolve(batch: Array, targets: Array, ping_id: int, fallback_time: float) -> Array:
	var res: Dictionary = ActiveReturnAttribution.attribute(
		returns_of(batch, ping_id, fallback_time), targets
	)
	var owners: Dictionary = res.get("owners", {})
	var out: Array = []
	for i in range(batch.size()):
		var rid: String = return_id_of(ping_id, i)
		var o: Dictionary = owners.get(rid, {})
		var e: Dictionary = batch[i]
		(
			out
			. append(
				{
					"idx": i,
					"ping_id": ping_id,
					"return_id": rid,
					"evidence_id": int(e.get("evidence_id", -1)),
					"owner_kind": str(o.get("kind", ActiveReturnAttribution.KIND_UNASSIGNED)),
					"owner_id": str(o.get("id", "")),
					"bearing_deg": float(e.get("bearing_deg", 0.0)),
					"range_m": float(e.get("measured_range_m", -1.0)),
				}
			)
		)
	return out


## 按 Ping 过滤取走结论队列：{taken, keep}。
static func split_for(queue: Array, ping_id: int) -> Dictionary:
	var taken: Array = []
	var keep: Array = []
	for a in queue:
		if int((a as Dictionary).get("ping_id", -1)) == ping_id:
			taken.append(a)
		else:
			keep.append(a)
	return {"taken": taken, "keep": keep}
