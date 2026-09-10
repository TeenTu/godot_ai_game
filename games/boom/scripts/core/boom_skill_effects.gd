class_name BoomSkillEffects
extends RefCounted
## 四个武器主动技能的唯一效果参数表。
## 战斗判定与表现层都从这里取数，避免范围、扇角、目标上限和进化形态各写一套。

const LAMP_FIREFLY_VOLLEY: String = "lamp_firefly_volley"
const LAMP_SOUL_BEACON: String = "lamp_soul_beacon"
const BRUSH_INK_WAVE: String = "brush_ink_wave"
const BRUSH_SEAL_DOMAIN: String = "brush_seal_domain"

const _NORMAL: Dictionary = {
	LAMP_FIREFLY_VOLLEY:
	{
		"projectiles": 5,
		"arc_deg": 30.0,
		"range": 8.0,
	},
	LAMP_SOUL_BEACON:
	{
		"projectiles": 12,
		"arc_deg": 360.0,
		"range": 8.0,
	},
	BRUSH_INK_WAVE:
	{
		"arc_deg": 100.0,
		"range": 5.0,
		"max_targets": 8,
		"damage_mult": 1.8,
	},
	BRUSH_SEAL_DOMAIN:
	{
		"arc_deg": 360.0,
		"range": 4.5,
		"max_targets": 16,
		"damage_mult": 2.5,
	},
}

const _EVOLVED: Dictionary = {
	LAMP_FIREFLY_VOLLEY:
	{
		"projectiles": 7,
		"arc_deg": 40.0,
		"range": 8.0,
	},
	LAMP_SOUL_BEACON:
	{
		"projectiles": 18,
		"arc_deg": 360.0,
		"range": 8.0,
	},
	BRUSH_INK_WAVE:
	{
		"arc_deg": 130.0,
		"range": 6.0,
		"max_targets": 12,
		"damage_mult": 2.4,
	},
	BRUSH_SEAL_DOMAIN:
	{
		"arc_deg": 360.0,
		"range": 5.5,
		"max_targets": 24,
		"damage_mult": 3.2,
	},
}


static func get_effect(skill_id: String, evolved: bool = false) -> Dictionary:
	var source: Dictionary = _EVOLVED if evolved else _NORMAL
	var effect: Dictionary = source.get(skill_id, {})
	return effect.duplicate(true)


static func ids() -> Array[String]:
	return [
		LAMP_FIREFLY_VOLLEY,
		LAMP_SOUL_BEACON,
		BRUSH_INK_WAVE,
		BRUSH_SEAL_DOMAIN,
	]
