class_name BoomBossSystem
extends RefCounted
## M11 首领编排分册：生成、弹幕池、召唤物、死亡宝箱与波次结算。


static func is_boss_wave(game: BoomGame, wave: int) -> bool:
	return wave > 0 and wave % game.BOSS_EVERY_N_WAVES == 0


static func is_active(game: BoomGame) -> bool:
	return game.boss != null and is_instance_valid(game.boss) and not game.boss.is_dead()


static func spawn(game: BoomGame) -> void:
	var encounter := maxi(1, floori(float(game.wave) / float(game.BOSS_EVERY_N_WAVES)))
	game.boss = BoomBoss.new(encounter)
	# 竖屏上沿预留 HUD 安全区，首领进入战斗时必须完整可见。
	game.boss.position = game.player.position + Vector3(0.0, 0.0, -4.2)
	game.boss.position.x = clampf(game.boss.position.x, -game.ENEMY_BOUND_X, game.ENEMY_BOUND_X)
	game.boss.position.z = clampf(game.boss.position.z, -game.ENEMY_BOUND_Z, game.ENEMY_BOUND_Z)
	game.boss.attack_telegraphed.connect(_on_attack_telegraphed.bind(game))
	game.boss.attack_released.connect(_on_attack_released.bind(game))
	game.boss.boss_phase_changed.connect(_on_phase_changed.bind(game))
	game.enemies.append(game.boss)
	game.add_child(game.boss)
	game._boss_add_cd = 1.5
	game.boss_spawned.emit(game.boss)


static func _on_attack_telegraphed(kind: String, duration: float, game: BoomGame) -> void:
	game.boss_attack_telegraphed.emit(kind, duration)


static func _on_phase_changed(phase_index: int, game: BoomGame) -> void:
	game.boss_phase_changed.emit(phase_index)


static func _on_attack_released(
	kind: String, origin: Vector3, direction: Vector3, phase_index: int, game: BoomGame
) -> void:
	game.boss_attack_released.emit(kind, origin)
	match kind:
		BoomBoss.ATTACK_GHOSTFIRE:
			_spawn_ghostfire(game, origin, direction, phase_index)
		BoomBoss.ATTACK_LANTERN_ARRAY:
			summon_adds(game, 3 + phase_index)


static func _spawn_ghostfire(
	game: BoomGame, origin: Vector3, direction: Vector3, phase_index: int
) -> void:
	var projectile_count := 3 + phase_index * 2
	var spread := deg_to_rad(22.0 + float(phase_index - 1) * 10.0)
	var step_angle := spread * 2.0 / float(maxi(1, projectile_count - 1))
	var damage := game.boss.contact_damage if is_active(game) else BoomBoss.BASE_DAMAGE
	for index in projectile_count:
		var projectile := _next_projectile(game)
		if projectile == null:
			break
		var angle := -spread + float(index) * step_angle
		projectile.launch(
			origin + Vector3(0.0, 0.55, 0.0),
			direction.rotated(Vector3.UP, angle),
			damage,
			game.BOSS_GHOSTFIRE_SPEED + float(phase_index - 1) * 0.6
		)


static func _next_projectile(game: BoomGame) -> BoomBossProjectile:
	for offset in game.BOSS_PROJECTILE_POOL_SIZE:
		var index := (game._boss_projectile_index + offset) % game.BOSS_PROJECTILE_POOL_SIZE
		var projectile := game.boss_projectiles[index] as BoomBossProjectile
		if not projectile.active:
			game._boss_projectile_index = (index + 1) % game.BOSS_PROJECTILE_POOL_SIZE
			return projectile
	return null


static func tick_projectiles(game: BoomGame, delta: float) -> void:
	for entry in game.boss_projectiles:
		var projectile := entry as BoomBossProjectile
		if not projectile.active:
			continue
		projectile.tick(delta)
		if not projectile.active:
			continue
		if (
			projectile.position.distance_to(game.player.position)
			<= projectile.RADIUS + game.player.radius
		):
			var raw_damage := projectile.damage
			var from_pos := projectile.position
			projectile.recycle()
			game._damage_player_raw(raw_damage, from_pos)


static func clear_projectiles(game: BoomGame) -> void:
	for entry in game.boss_projectiles:
		(entry as BoomBossProjectile).recycle()


static func summon_adds(game: BoomGame, requested: int) -> int:
	var current_adds := game.enemies.size() - (1 if is_active(game) else 0)
	var count := mini(requested, maxi(0, game.BOSS_ADD_CAP - current_adds))
	for index in count:
		var angle := TAU * float(index) / float(maxi(1, count)) + randf_range(-0.2, 0.2)
		var pos := (
			game.player.position + Vector3(cos(angle), 0.0, sin(angle)) * randf_range(4.5, 6.5)
		)
		pos.x = clampf(pos.x, -game.ENEMY_BOUND_X, game.ENEMY_BOUND_X)
		pos.z = clampf(pos.z, -game.ENEMY_BOUND_Z, game.ENEMY_BOUND_Z)
		game.spawn_enemy_at(pos, false, "paper")
	return count


static func finalize_defeat(game: BoomGame, defeated: BoomBoss) -> void:
	var defeat_pos := defeated.position
	var encounter := defeated.encounter_index
	game.boss = null
	game.boss_reward_pending = true
	clear_projectiles(game)
	_dismiss_adds(game, defeated)
	game.boss_chest = BoomBossChest.new()
	game.boss_chest.position = defeat_pos
	game.add_child(game.boss_chest)
	game.boss_defeated.emit(encounter, defeat_pos)


static func _dismiss_adds(game: BoomGame, except: BoomJelly) -> void:
	for entry in game.enemies.duplicate():
		var jelly := entry as BoomJelly
		if jelly == null or jelly == except:
			continue
		game.enemies.erase(jelly)
		if jelly.is_inside_tree():
			game.remove_child(jelly)
		jelly.queue_free()


static func complete_reward(game: BoomGame, reward_id: String) -> bool:
	if not game.boss_reward_pending:
		return false
	game.boss_reward_pending = false
	if game.boss_chest != null and is_instance_valid(game.boss_chest):
		game.boss_chest.collect()
	game.boss_chest = null
	var bonus := BoomCombatMath.wave_bonus(game.wave)
	game.score += bonus
	game.wave_cleared.emit(game.wave, bonus)
	game._between_waves = true
	game._next_wave_cd = BoomCombatMath.wave_rest(game.wave)
	game.boss_reward_completed.emit(reward_id)
	return true
