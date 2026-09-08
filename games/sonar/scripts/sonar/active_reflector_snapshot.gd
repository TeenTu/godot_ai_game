class_name ActiveReflectorSnapshot
extends RefCounted

## REQ-B2-01：发射时刻固化的统一主动反射体快照。
##
## issue_ping() 从统一声学场采集（普通水下目标 + 敌方在水鱼雷 + 已激活且具
## 反射能力的诱饵），发射后快照冻结——回波在途期间实体死亡/过期仍按发射时
## 已形成的反射继续到达（REQ-B2-02）。
##
## 内核边界：internal_token/id 只在 World↔结算内部使用，绝不进入
## Measurement.to_dict / Track / TMA / 玩家 UI（Truth 隔离）。

var id: String = ""  # 等于 internal_token（generate_active 读 target.id 用）
var internal_token: String = ""
var platform_kind: String = ""  # "target" / "torpedo" / "decoy"
var position_east_m: float = 0.0
var position_north_m: float = 0.0
var depth_m: float = 0.0
var speed_kn: float = 0.0
var active_target_strength_db: float = 0.0
var acoustic_profile: RefCounted = null  # 结算画像（tonal_lines/TS，含鱼雷标定 TS）
var emitted_ping_id: int = -1
var reflection_reference_time: float = -1.0
var reflection_range_ref_m: float = 0.0  # 发射时刻登记距离（测距同源）


## REQ-B2-01：从统一条目集采集快照（World 发射时刻调用）。覆盖/监听窗裁决
## 也在此冻结——扇区外、往返超固定监听窗的条目不产生快照。
## entries: [{token, kind, ac, e, n, dep, spd}]；位置/深度字段名因实体类型
## 而异（Torpedo=pos_east_m/actual_depth_m），由 World 展开成统一标量传入。
static func collect(
	own: RefCounted,
	sensor: RefCounted,
	listen_max_m: float,
	entries: Array,
) -> Array:
	var out: Array = []
	for ent in entries:
		var token: String = str(ent["token"])
		var ac: RefCounted = ent["ac"]
		if ac == null or token == "" or token == str(own.id):
			continue
		var e_m: float = float(ent["e"])
		var n_m: float = float(ent["n"])
		var tgt_b: float = NavUtils.bearing_to_true(
			float(own.position_east_m), float(own.position_north_m), e_m, n_m
		)
		var rel_b: float = NavUtils.wrap360(tgt_b - float(own.course_deg))
		# S1-03C-P1-03/REQ-08：扇区外不登记回波（窗口到期 NO_RETURN，绝不
		# 在到达时刻补判）。未声明覆盖 = 全向 (0..360)。
		if not sensor.in_coverage(rel_b):
			continue
		var rng_m: float = NavUtils.distance(
			float(own.position_east_m), float(own.position_north_m), e_m, n_m
		)
		# REQ-B2-01：往返传播超固定监听窗的实体不登记（REQ-04 固定窗）。
		if rng_m > listen_max_m:
			continue
		var snap := ActiveReflectorSnapshot.new()
		snap.id = token
		snap.internal_token = token
		snap.platform_kind = str(ent["kind"])
		snap.position_east_m = e_m
		snap.position_north_m = n_m
		snap.depth_m = float(ent["dep"])
		snap.speed_kn = float(ent["spd"])
		snap.acoustic_profile = ac
		snap.active_target_strength_db = float(ac.active_target_strength_db)
		snap.reflection_range_ref_m = rng_m
		out.append(snap)
	return out
