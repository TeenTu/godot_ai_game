class_name ActiveReflectorCollector
extends RefCounted

## REQ-B2-01：统一主动反射体条目构建（World 发射时刻调用）。
## 来源：普通水下目标 + 敌方在水鱼雷（标定 TS）+ 已激活未过期诱饵；
## 排除：本艇自身、已死亡/过期实体。覆盖/监听窗裁决与快照冻结见
## ActiveReflectorSnapshot.collect。己方鱼雷第一版不进入（已知友方，
## 不混入未知 Contact）。


static func build_entries(
	targets: Array,
	target_acs: Dictionary,
	enemy_weapons: RefCounted,
	decoys: Array,
	own_id: String,
	shadow_ac: Callable,  # World._torpedo_shadow_ac(tp) -> AcousticProfile
) -> Array:
	var entries: Array = []
	for t in targets:
		if str(t.id) == own_id or not target_acs.has(str(t.id)):
			continue
		(
			entries
			. append(
				{
					"token": str(t.id),
					"kind": "target",
					"ac": target_acs[str(t.id)],
					"e": float(t.position_east_m),
					"n": float(t.position_north_m),
					"dep": float(t.depth_m),
					"spd": float(t.speed_kn),
				}
			)
		)
	if enemy_weapons != null:
		for tp in enemy_weapons.torpedoes:
			if tp.is_dead():
				continue
			var ac: RefCounted = shadow_ac.call(tp)
			# REQ-B2-03：覆盖潜艇默认 TS，使用鱼雷标定主动目标强度。
			ac.active_target_strength_db = tp.acoustic_profile.active_target_strength_db
			(
				entries
				. append(
					{
						"token": str(tp.torpedo_id),
						"kind": "torpedo",
						"ac": ac,
						"e": float(tp.pos_east_m),
						"n": float(tp.pos_north_m),
						"dep": float(tp.actual_depth_m),
						"spd": float(tp.speed_kn),
					}
				)
			)
	for d in decoys:
		if not d.activated or d.expired:
			continue
		var dac: RefCounted = d.signature_ac
		if dac == null or not ("active_target_strength_db" in dac):
			var np := AcousticProfile.new()
			np.active_target_strength_db = 10.0
			dac = np
		(
			entries
			. append(
				{
					"token": str(d.id),
					"kind": "decoy",
					"ac": dac,
					"e": float(d.position_east_m),
					"n": float(d.position_north_m),
					"dep": float(d.depth_m),
					"spd": float(d.speed_kn),
				}
			)
		)
	return entries
