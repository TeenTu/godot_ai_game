class_name TruthDebugProvider
extends RefCounted
## truth_debug_provider.gd — S109 §7 开发真值链唯一入口（TruthDebugProvider →
## 海图/方位盘 DebugOverlay 绘制层）。
##
## 信息边界（§2.1 调试链旁路）：
##   - 唯一允许批量读取 Truth 的调试出口；输出仅供 DebugOverlay 绘制；
##   - 快照不得进入 Tracker / Estimator / TMA / FireControl / Automation / AI；
##   - 纯读取 + 字符串化：对 World 零写入、不触碰 RNG ——相同 World 上调用
##     本 provider 与不调用，后续仿真结果必须逐位一致（AT-26 由测试强制）；
##   - 关闭 Show Truth 后调用方不得保留任何 truth 图元（AT-27）。
##
## 覆盖：world.world[own/targets]（普通潜艇）+ world.weapons.torpedoes +
## world.enemy_weapons.torpedoes（双方在水鱼雷，§7.1）。


## 普通潜艇真值（原有 Show Truth 内容 + 敌方潜艇实体）。
static func collect_submarines(world: World) -> Array:
	var out: Array = []
	for t in world.world["targets"]:
		(
			out
			. append(
				{
					"kind": "SUB",
					"side": "TARGET",
					"id": str(t.id),
					"pos": Vector2(t.position_east_m, t.position_north_m),
				}
			)
		)
	var ai_e: RefCounted = world.enemy_ai.entity if world.enemy_ai != null else null
	if ai_e != null:
		(
			out
			. append(
				{
					"kind": "SUB",
					"side": "ENEMY",
					"id": str(ai_e.id),
					"pos": Vector2(ai_e.position_east_m, ai_e.position_north_m),
				}
			)
		)
	return out


## 双方在水鱼雷真值（§7.1）：真方位从当前本艇位置经 bearing_to_true 计算，
## 四基准 N/E/S/W=0/90/180/270（AT-25）。state 为 mission_state 枚举名字符串。
static func collect_torpedoes(world: World) -> Array:
	var own: TruthEntity = world.world["own"]
	var oe: float = float(own.position_east_m)
	var on: float = float(own.position_north_m)
	var out: Array = []
	for side_pairs in [["FRIENDLY", world.weapons], ["ENEMY", world.enemy_weapons]]:
		var sys: WeaponSystem = side_pairs[1]
		if sys == null:
			continue
		for tp in sys.torpedoes:
			(
				out
				. append(
					{
						"kind": "TORPEDO",
						"side": str(side_pairs[0]),
						"debug_id": str(tp.torpedo_id),
						"pos": Vector2(tp.pos_east_m, tp.pos_north_m),
						"depth_m": float(tp.actual_depth_m),
						"course_deg": float(tp.course_deg),
						"speed_kn": float(tp.speed_kn),
						"state": tp.mission_state_name(),
						"bearing_from_own_deg":
						NavUtils.bearing_to_true(oe, on, tp.pos_east_m, tp.pos_north_m),
						"range_from_own_m":
						NavUtils.distance(oe, on, tp.pos_east_m, tp.pos_north_m),
					}
				)
			)
	return out


## 合并快照（海图 _draw_truth 消费）：潜艇矩形 + 鱼雷专用符号/方位线。
static func collect_truth(world: World) -> Array:
	var out: Array = collect_submarines(world)
	out.append_array(collect_torpedoes(world))
	return out
