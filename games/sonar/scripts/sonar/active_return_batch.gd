class_name ActiveReturnBatch
extends RefCounted
## active_return_batch.gd — S1-11 §3.5 / D-14：同一 Ping 回波批次一对一分配。
##
## 输入：一次主动 Ping 监听窗内的全部 detected 回波（净化 DTO，无 target_id）与
## 当前候选航迹（普通接触或 TT 威胁航迹，同样只含可观测状态）。
## 输出：每回波最多消费一次、每航迹最多吸收一条回波的分配结果。
##
## 关键纪律（AT-51..54）：
##   - 代价矩阵含方位创新、距离创新、各自 sigma、谱线相似度、运动连续性；
##   - 全序排序（代价 → 回波 id → 航迹 id）后一对一贪心，结果与输入顺序无关；
##   - 最优/次优代价接近 → 该回波保持"关联不确定/未归属"，不按到达顺序强塞；
##   - 任何情况下不读取 Truth 身份，裁决只依赖上述可观测量。

## 次优/最优代价比阈值：低于此比值视为关联不确定（保留未归属）。
const UNCERTAIN_RATIO: float = 1.35
## 方位门：3σ 与 8° 取大者（候选门，非玩家命令否决门）。
const BEARING_GATE_MIN_DEG: float = 8.0
## 距离门：3σ 与 150 m 取大者。
const RANGE_GATE_MIN_M: float = 150.0
## 谱线不共享时的代价惩罚。
const SPECTRAL_PENALTY: float = 1.5
## 运动连续性：时间间隔超过该值开始计惩罚。
const CONTINUITY_REF_S: float = 45.0


## 一对一分配。returns / targets 均为数组字典（见文件头）。
## 返回 {assignments: {return_id: target_id}, unassigned: [{id, reason}],
##       costs: {return_id: float}, ambiguous: [return_id]}。
static func assign(returns: Array, targets: Array, opts: Dictionary = {}) -> Dictionary:
	var ratio: float = float(opts.get("uncertain_ratio", UNCERTAIN_RATIO))
	var out: Dictionary = {"assignments": {}, "unassigned": [], "costs": {}, "ambiguous": []}
	if returns.is_empty() or targets.is_empty():
		for r in returns:
			out["unassigned"].append({"id": str(r.get("id", "")), "reason": "no_target"})
		return out
	# 1) 代价矩阵：全部 (return, target) 对的有限代价，按全序排序。
	var pairs: Array = []
	for r in returns:
		var rid: String = str(r.get("id", ""))
		var best: float = INF
		var second: float = INF
		for t in targets:
			var c: float = pair_cost(r, t)
			if not is_finite(c):
				continue
			pairs.append({"rid": rid, "tid": str(t.get("id", "")), "cost": c})
			if c < best:
				second = best
				best = c
			elif c < second:
				second = c
		# 2) 歧义裁决：最优/次优接近 → 关联不确定（与输入顺序无关）。
		var ambiguous: bool = second < INF and best < INF and second / maxf(best, 1.0e-6) < ratio
		if best < INF and ambiguous:
			out["ambiguous"].append(rid)
			out["unassigned"].append({"id": rid, "reason": "uncertain"})
		elif best < INF:
			out["costs"][rid] = best
	pairs.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if absf(float(a["cost"]) - float(b["cost"])) > 1.0e-9:
				return float(a["cost"]) < float(b["cost"])
			if str(a["rid"]) != str(b["rid"]):
				return str(a["rid"]) < str(b["rid"])
			return str(a["tid"]) < str(b["tid"])
	)
	# 3) 一对一贪心（已按代价全序，等价于该代价下的确定性最优可用对）。
	var used_r: Dictionary = {}
	var used_t: Dictionary = {}
	var amb: Dictionary = {}
	for rid in out["ambiguous"]:
		amb[str(rid)] = true
	for r in returns:
		used_r[str(r.get("id", ""))] = false
	for t in targets:
		used_t[str(t.get("id", ""))] = false
	for p in pairs:
		var rid: String = str(p["rid"])
		var tid: String = str(p["tid"])
		if bool(used_r[rid]) or bool(used_t[tid]) or amb.has(rid):
			continue
		used_r[rid] = true
		used_t[tid] = true
		out["assignments"][rid] = tid
	# 4) 未获分配且非歧义的回波 → 未归属（交由调用方建立临时接触）。
	for r in returns:
		var rid2: String = str(r.get("id", ""))
		if bool(used_r[rid2]) or amb.has(rid2):
			continue
		out["unassigned"].append({"id": rid2, "reason": "gate"})
	out["unassigned"].sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"])
	)
	return out


## 单对代价：方位创新 + 距离创新（双方都有测距时）+ 谱线 + 运动连续性。
## 门控失败返回 INF。仅消费可观测量与误差，不读取任何 Truth 身份。
static func pair_cost(r: Dictionary, t: Dictionary) -> float:
	var s_b_r: float = maxf(float(r.get("bearing_sigma_deg", 2.0)), 0.5)
	var s_b_t: float = maxf(float(t.get("bearing_sigma_deg", 2.0)), 0.5)
	var db: float = absf(
		NavUtils.wrap180(float(r.get("bearing_deg", 0.0)) - float(t.get("bearing_deg", 0.0)))
	)
	var gate_b: float = maxf(3.0 * maxf(s_b_r, s_b_t), BEARING_GATE_MIN_DEG)
	if db > gate_b:
		return INF
	var cost: float = pow(db / s_b_r, 2.0)
	var rng_r: float = float(r.get("range_m", -1.0))
	var rng_t: float = float(t.get("range_m", -1.0))
	if rng_r > 0.0 and rng_t > 0.0:
		var s_r: float = maxf(float(r.get("range_sigma_m", 100.0)), 1.0)
		var s_rt: float = maxf(float(t.get("range_sigma_m", 100.0)), 1.0)
		var dr: float = absf(rng_r - rng_t)
		var gate_r: float = maxf(3.0 * maxf(s_r, s_rt), RANGE_GATE_MIN_M)
		if dr > gate_r:
			return INF
		cost += pow(dr / s_r, 2.0)
	cost += spectral_penalty(r.get("freqs", []), t.get("freqs", []))
	var dt: float = absf(float(r.get("time", 0.0)) - float(t.get("time", 0.0)))
	cost += 0.5 * pow(maxf(dt - CONTINUITY_REF_S, 0.0) / CONTINUITY_REF_S, 2.0)
	return cost


## 谱线失配惩罚：双方都带谱线且完全不重叠 → 惩罚；任一方无谱线 → 0。
static func spectral_penalty(a: Array, b: Array) -> float:
	if a.is_empty() or b.is_empty():
		return 0.0
	for fa in a:
		for fb in b:
			if absf(float(fa) - float(fb)) <= 25.0:
				return 0.0
	return SPECTRAL_PENALTY
