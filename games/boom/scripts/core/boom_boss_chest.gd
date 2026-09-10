class_name BoomBossChest
extends Node3D
## M11 首领宝箱：死亡点显示，奖励选择完成后收起。

const ART_PATH: String = "res://assets/images/props/boss_spirit_seal_chest.png"

var _sprite: Sprite3D
var _time: float = 0.0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not ResourceLoader.exists(ART_PATH):
		return
	_sprite = Sprite3D.new()
	_sprite.texture = load(ART_PATH) as Texture2D
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.pixel_size = 0.0042
	_sprite.position.y = 0.72
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.render_priority = 3
	add_child(_sprite)


func _process(delta: float) -> void:
	_time += delta
	if _sprite == null:
		return
	_sprite.position.y = 0.72 + sin(_time * 4.0) * 0.08
	var pulse := 1.0 + sin(_time * 5.0) * 0.04
	_sprite.scale = Vector3.ONE * pulse


func collect() -> void:
	queue_free()
