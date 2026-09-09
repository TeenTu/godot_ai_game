class_name BoomCrowdSystem
extends RefCounted
## 怪海热路径分册：保持 BoomGame 主循环精简，集中管理分帧分离与批量刷新。


static func tick_enemies(game: Node, delta: float) -> void:
	game._crowd_tick = (game._crowd_tick + 1) % game.CROWD_SEPARATION_STRIDE
	for index in game.enemies.size():
		var jelly := game.enemies[index] as BoomJelly
		if jelly == null:
			continue
		jelly.physics_update(
			delta,
			game.player.position,
			game.enemies,
			game.ENEMY_BOUND_X,
			game.ENEMY_BOUND_Z,
			index,
			game._crowd_tick,
			game.CROWD_SEPARATION_STRIDE
		)


static func max_alive(game: Node) -> int:
	return clampi(game.MAX_ALIVE_BASE + game.wave * game.MAX_ALIVE_PER_WAVE, 16, game.MAX_ALIVE_CAP)


static func spawn_interval(game: Node) -> float:
	return clampf(
		game.SPAWN_INTERVAL_START - float(game.wave - 1) * game.SPAWN_INTERVAL_STEP,
		game.SPAWN_INTERVAL_MIN,
		game.SPAWN_INTERVAL_START
	)


@warning_ignore("integer_division")
static func spawn_burst(game: Node) -> int:
	return clampi(2 + (game.wave - 1) / 3, 2, game.SPAWN_BURST_MAX)


static func tick_spawns(game: Node, delta: float) -> void:
	if game.is_over or not game.match_started:
		return
	if game._between_waves:
		game._next_wave_cd -= delta
		if game._next_wave_cd <= 0.0:
			game.wave += 1
			game._begin_wave()
		return
	if game._spawned_total >= game._quota_current:
		if game.enemies.is_empty():
			var bonus: int = BoomCombatMath.wave_bonus(game.wave)
			game.score += bonus
			game.wave_cleared.emit(game.wave, bonus)
			game._between_waves = true
			game._next_wave_cd = BoomCombatMath.wave_rest(game.wave)
		return
	if not game.auto_spawn or game.enemies.size() >= max_alive(game):
		return
	game._spawn_cd -= delta
	if game._spawn_cd > 0.0:
		return
	game._spawn_cd = spawn_interval(game)
	var room: int = max_alive(game) - game.enemies.size()
	var remaining: int = game._quota_current - game._spawned_total
	var count: int = mini(spawn_burst(game), mini(room, remaining))
	for _index in count:
		game._spawned_total += 1
		game._spawn_edge_enemy(game._is_elite_spawn())
