extends SceneTree
func _init() -> void:
	var sc: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	sc["seed"] = 20260905
	sc["targets"] = []
	sc["own_acoustic"]["broadband_base_level_db"] = 160.0
	sc["own_ship"]["speed_kn"] = 0.0
	sc["own_ship"]["depth_m"] = 70.0
	var b: float = deg_to_rad(45.0)
	sc["enemy_spawn"] = {
		"depth_band_weights": {"UPPER": 1.0},
		"bearing_min_deg": 43.0, "bearing_max_deg": 47.0,
		"range_min_m": 1500.0, "range_mode_m": 1800.0, "range_max_m": 2000.0,
		"speed_min_kn": 5.0, "speed_max_kn": 8.0, "min_separation_m": 800.0,
		"max_generation_attempts": 50,
		"fallback_spawn": {"position_east_m": sin(b) * 1500.0, "position_north_m": cos(b) * 1500.0, "course_deg": 225.0, "speed_kn": 6.0, "depth_m": 70.0},
		"doctrine": {"sensor_false_alarm_rate": 0.0, "fire_quality_threshold": 0.7, "counterfire_probability": 1.0, "reaction_delay_min_s": 3.0, "reaction_delay_max_s": 15.0, "max_simultaneous_weapons": 2, "torpedo_active_enable_time_s": 60.0, "torpedo_autonomy_distance_m": 800.0},
	}
	var w := World.new()
	w.load_scenario(sc)
	var ent: TruthEntity = w.enemy_ai.entity
	var own: TruthEntity = w.world["own"]
	var brg: float = NavUtils.bearing_to_true(ent.position_east_m, ent.position_north_m, own.position_east_m, own.position_north_m)
	w._enemy_fire({"action": "FIRE_TORPEDO", "bearing_deg": brg})
	var tp = w.enemy_weapons.torpedoes[0]
	var min_d: float = 1e9
	for i in range(1500):
		w.run_steps(1)
		var d: float = NavUtils.distance(tp.pos_east_m, tp.pos_north_m, float(own.position_east_m), float(own.position_north_m))
		min_d = minf(min_d, d)
		if d < 120.0 and i % 4 == 0:
			print("t=%.0f d=%.1f vert=%.1f fuze=%s latched=%s" % [w.sim_time, d, absf(tp.actual_depth_m - own.depth_m), tp.fuze_state, str(w._fuze_safety_latched.get(str(tp.torpedo_id), false))])
		if str(w.world["own"].damage_state) != "ok":
			print("HIT t=", w.sim_time, " min_d=", min_d)
			break
	print("end t=%.0f min_d=%.1f dmg=%s" % [w.sim_time, min_d, str(own.damage_state)])
	quit(0)
