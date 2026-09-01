extends SceneTree
## play_test.gd — CI 冒烟测试（确定性，供 deploy.yml 的 smoke test 使用）。
##
## 运行：godot --headless --path games/sonar --script res://tools/play_test.gd
## 必须输出 "PLAY_TEST result=PASS" 才算通过（CI grep 此字符串）。
## 阶段一：验证仿真内核能稳定跑完一个固定种子场景并产出合理测量流，
## 同时确认核心模块无编译错误（nav_utils / 声学 / 传感器 / world）。


func _init() -> void:
	# 1) 编译检查：NavUtils 可调用
	var probe: float = NavUtils.wrap360(370.0)
	if absf(probe - 10.0) > 0.001:
		print("PLAY_TEST result=FAIL (nav_utils)")
		quit(1)
		return

	# 2) 跑固定种子场景，确认能产出测量
	var scenario: Dictionary = ConfigLoader.load_scenario("stage1_basic_passive")
	if scenario.is_empty():
		print("PLAY_TEST result=FAIL (scenario load)")
		quit(1)
		return

	var w := World.new()
	w.load_scenario(scenario)
	w.run_steps(int(scenario.get("duration", 30.0) / scenario.get("dt", 0.5)))

	if w.measurement_count() <= 0:
		print("PLAY_TEST result=FAIL (no measurements)")
		quit(1)
		return

	print("sonar smoke: %d measurements, sim_time=%.1fs" % [w.measurement_count(), w.sim_time])
	print("PLAY_TEST result=PASS")
	quit(0)
