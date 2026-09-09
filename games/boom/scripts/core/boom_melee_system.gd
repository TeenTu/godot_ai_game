class_name BoomMeleeSystem
extends RefCounted
## 判笔双手大剑连招的纯战斗状态机。拆出 BoomGame 以保持 CI 的文件规模门禁。


static func tick(game: BoomGame, delta: float) -> void:
	match game._swing_state:
		game.SwingState.WINDUP:
			var windup: float = float(game._swing_step["windup"])
			game._swing_t -= delta
			game.player.sync_melee_phase(
				String(game._swing_step["action"]),
				0,
				int(game._swing_step["windup_frames"]),
				1.0 - game._swing_t / (windup / game.stats.aspd_mult())
			)
			game.player.face_toward(game._swing_facing)
			if game._swing_t <= 0.0:
				game._swing_state = game.SwingState.ACTIVE
				game._swing_t = float(game._swing_step["active"])
				game.player.sync_melee_phase(
					String(game._swing_step["action"]),
					int(game._swing_step["windup_frames"]),
					int(game._swing_step["active_frames"]),
					0.0
				)
				execute(game)
		game.SwingState.ACTIVE:
			var active: float = float(game._swing_step["active"])
			game._swing_t -= delta
			game.player.sync_melee_phase(
				String(game._swing_step["action"]),
				int(game._swing_step["windup_frames"]),
				int(game._swing_step["active_frames"]),
				1.0 - game._swing_t / active
			)
			game.player.lock_move_left = game._swing_t
			if game._swing_t <= 0.0:
				game._swing_state = game.SwingState.RECOVER
				game._swing_t = float(game._swing_step["recover"])
				game.player.sync_melee_phase(
					String(game._swing_step["action"]),
					int(game._swing_step["windup_frames"]) + int(game._swing_step["active_frames"]),
					int(game._swing_step["recover_frames"]),
					0.0
				)
		game.SwingState.RECOVER:
			var recover: float = float(game._swing_step["recover"])
			game._swing_t -= delta
			game.player.sync_melee_phase(
				String(game._swing_step["action"]),
				int(game._swing_step["windup_frames"]) + int(game._swing_step["active_frames"]),
				int(game._swing_step["recover_frames"]),
				1.0 - game._swing_t / recover
			)
			var mv := Vector3(game.player.move_vec.x, 0.0, game.player.move_vec.y)
			if game.player.move_vec.length_squared() > 0.01 and game._nearest_enemy() == null:
				game.player.face_toward(mv)
			if game._swing_t <= 0.0:
				game._swing_state = game.SwingState.NONE
				game.player.finish_melee_visual(String(game._swing_step["action"]))
		_:
			var target := game._nearest_enemy()
			if target == null:
				var mv2 := Vector3(game.player.move_vec.x, 0.0, game.player.move_vec.y)
				if game.player.move_vec.length_squared() > 0.01:
					game.player.face_toward(mv2)
			else:
				var to_enemy: Vector3 = target.position - game.player.position
				to_enemy.y = 0.0
				game.player.face_toward(to_enemy)
				if to_enemy.length() <= game.weapon_cfg.swing_range:
					game._swing_step = next_step(game)
					game._swing_state = game.SwingState.WINDUP
					game._swing_t = float(game._swing_step["windup"]) / game.stats.aspd_mult()
					game._swing_facing = game.player.facing
					game.player.play_anim_once(String(game._swing_step["action"]))
					game.player.sync_melee_phase(
						String(game._swing_step["action"]),
						0,
						int(game._swing_step["windup_frames"]),
						0.0
					)
	game.player.physics_update(delta, game.PLAYER_BOUND_X, game.PLAYER_BOUND_Z)


static func execute(game: BoomGame) -> void:
	var half_rad: float = deg_to_rad(float(game._swing_step["arc_deg"]) * 0.5)
	var fwd := game._swing_facing
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	var candidates: Array = []
	for entry in game.enemies:
		var jelly := entry as BoomJelly
		if jelly == null or jelly.is_dead() or jelly.hp <= 0:
			continue
		var to_enemy: Vector3 = jelly.position - game.player.position
		to_enemy.y = 0.0
		var dist: float = to_enemy.length()
		if dist <= 0.001 or dist > game.weapon_cfg.swing_range:
			continue
		if acos(clampf(fwd.dot(to_enemy / dist), -1.0, 1.0)) <= half_rad:
			candidates.append([dist, jelly])
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var base: int = maxi(
		1,
		int(
			floor(
				(
					float(game._base_attack() + game.skill_swing_dmg_bonus)
					* float(game._swing_step["damage_mult"])
				)
			)
		)
	)
	var hit_any := false
	var hit_count: int = mini(int(game._swing_step["max_targets"]), candidates.size())
	for index in hit_count:
		var jelly := candidates[index][1] as BoomJelly
		var hit_dir: Vector3 = (jelly.position - game.player.position).normalized()
		hit_dir.y = 0.0
		if hit_dir.length_squared() < 0.001:
			hit_dir = game._swing_facing
		var roll: Array = game._roll_attack(base)
		game.blade_hit.emit(jelly.position, roll[0])
		game.enemy_hit.emit(jelly.position, roll[0], roll[1])
		if jelly.take_damage(roll[0], hit_dir, game.weapon_cfg.swing_knock):
			game._finalize_kill(jelly)
		hit_any = true
	if hit_any and game.game_time - game._last_swing_freeze >= 0.5:
		game._last_swing_freeze = game.game_time
		game._freeze_left = maxf(game._freeze_left, game.weapon_cfg.swing_freeze)
	game.swing_released.emit(game.player.position, game._swing_facing, hit_count)


static func next_step(game: BoomGame) -> Dictionary:
	if game.weapon_cfg.melee_combo.is_empty():
		return {
			"action": "swing_left",
			"windup": game.weapon_cfg.swing_windup,
			"active": game.weapon_cfg.swing_active,
			"recover": game.weapon_cfg.swing_recover,
			"arc_deg": game.weapon_cfg.swing_arc_deg,
			"max_targets": game.weapon_cfg.swing_max_targets,
			"damage_mult": 1.0,
			"windup_frames": 2,
			"active_frames": 1,
			"recover_frames": 1
		}
	var index: int = posmod(game._swing_combo_index, game.weapon_cfg.melee_combo.size())
	game._swing_combo_index = (index + 1) % game.weapon_cfg.melee_combo.size()
	return game.weapon_cfg.melee_combo[index].duplicate()
