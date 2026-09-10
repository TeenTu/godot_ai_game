class_name BoomSkillPresenter
extends Node
## 武器主动技能表现协调器。四个技能各自使用与真实判定一致的形状、范围和色彩语言。

signal presented(skill_id: String, presentation_id: String)

const COL_AMBER: Color = Color("f2b84b")
const COL_TEAL: Color = Color("5fc5ad")
const COL_CINNABAR: Color = Color("b84235")

var game: BoomGame
var skill_system: BoomSkillSystem
var skill_fx: BoomSkillFx
var audio: BoomAudio
var cam: BoomCam
var _flash: Callable
var _float_text: Callable
var _last_skill_id: String = ""
var _last_presentation_id: String = ""
var _last_effect: Dictionary = {}


func setup(
	p_game: BoomGame,
	p_skill_system: BoomSkillSystem,
	p_skill_fx: BoomSkillFx,
	p_audio: BoomAudio,
	p_cam: BoomCam,
	flash: Callable,
	float_text: Callable,
) -> void:
	game = p_game
	skill_system = p_skill_system
	skill_fx = p_skill_fx
	audio = p_audio
	cam = p_cam
	_flash = flash
	_float_text = float_text


func present(skill_id: String, result: Variant) -> void:
	if game == null or skill_system == null or skill_fx == null:
		return
	var evolved := skill_system._is_evolved(skill_id)
	var effect := BoomSkillEffects.get_effect(skill_id, evolved)
	if effect.is_empty():
		return
	_last_skill_id = skill_id
	_last_effect = effect
	game.player.play_anim_once("skill_cast")
	match skill_id:
		BoomSkillEffects.LAMP_FIREFLY_VOLLEY:
			_present_firefly(effect)
		BoomSkillEffects.LAMP_SOUL_BEACON:
			_present_beacon(effect)
		BoomSkillEffects.BRUSH_INK_WAVE:
			_present_ink_wave(effect, result)
		BoomSkillEffects.BRUSH_SEAL_DOMAIN:
			_present_seal_domain(effect, result)
	presented.emit(skill_id, _last_presentation_id)


func _present_firefly(effect: Dictionary) -> void:
	_last_presentation_id = "firefly_fan"
	_play("shoot", -9.0)
	_trauma(0.15)
	var origin := game.player.position + Vector3(0.0, 0.5, 0.0)
	skill_fx.muzzle_flash(origin, game.player.facing, COL_AMBER)
	skill_fx.sector_wave(
		game.player.position,
		game.player.facing,
		float(effect["range"]),
		float(effect["arc_deg"]),
		COL_AMBER
	)


func _present_beacon(effect: Dictionary) -> void:
	_last_presentation_id = "soul_beacon_ring"
	_play("wave", -7.0)
	_trauma(0.36)
	skill_fx.shockwave(game.player.position, float(effect["range"]), COL_TEAL)
	skill_fx.burst(
		game.player.position + Vector3(0.0, 0.65, 0.0),
		COL_AMBER,
		mini(54, int(effect["projectiles"]) * 3)
	)
	_spawn_float(BoomSkillEffects.LAMP_SOUL_BEACON)


func _present_ink_wave(effect: Dictionary, result: Variant) -> void:
	_last_presentation_id = "ink_wave_sector"
	_play("graze", -6.0)
	skill_fx.sector_wave(
		game.player.position,
		game.player.facing,
		float(effect["range"]),
		float(effect["arc_deg"]),
		COL_TEAL
	)
	if _hit_count(result) > 0:
		_trauma(0.32)
		_flash_screen(0.08)
		_spawn_float(BoomSkillEffects.BRUSH_INK_WAVE)


func _present_seal_domain(effect: Dictionary, result: Variant) -> void:
	_last_presentation_id = "cinnabar_seal_domain"
	_play("boom", -4.0)
	_trauma(0.62)
	_flash_screen(0.12)
	skill_fx.shockwave(game.player.position, float(effect["range"]), COL_CINNABAR)
	skill_fx.burst(game.player.position + Vector3(0.0, 0.6, 0.0), COL_TEAL, 48)
	if _hit_count(result) > 0:
		_spawn_float(BoomSkillEffects.BRUSH_SEAL_DOMAIN)


func _hit_count(result: Variant) -> int:
	return result.size() if result is Array else int(result)


func _play(cue: String, volume_db: float) -> void:
	if audio != null:
		audio.play(cue, volume_db)


func _trauma(amount: float) -> void:
	if cam != null:
		cam.add_trauma(amount)


func _spawn_float(skill_id: String) -> void:
	if _float_text.is_valid():
		_float_text.call(game.player.position, skill_id)


func _flash_screen(peak: float) -> void:
	if _flash.is_valid():
		_flash.call(peak)


func debug_state() -> Dictionary:
	return {
		"skill_id": _last_skill_id,
		"presentation": _last_presentation_id,
		"effect": _last_effect.duplicate(true),
	}
