class_name ScenarioLoader
extends RefCounted
## scenario_loader.gd — 把场景 JSON 装配成可运行的仿真世界。
## 负责创建：Truth 实体（本艇 + 目标）、环境模型、传感器、测量生成器、RNG。


static func build(scenario: Dictionary) -> Dictionary:
	# RNG：固定种子 → 可复现
	var rng := RandomNumberGenerator.new()
	rng.seed = int(scenario.get("seed", 12345))

	# 环境
	var env := EnvironmentModel.new()
	env.from_dict(scenario.get("environment", {}))

	# S1-07A（Commit 2）：双层伪三维深度层。旧场景无 depth_layers → disabled。
	var depth_model := DepthLayerModel.new()
	depth_model.from_dict(scenario.get("depth_layers", {}))
	env.depth_model = depth_model

	# 本艇（蓝方）
	var own := TruthEntity.new()
	var own_dict: Dictionary = scenario.get("own_ship", {})
	own_dict["id"] = own_dict.get("id", "own")
	own_dict["side"] = own_dict.get("side", "blue")
	own.from_dict(own_dict)
	var own_ac := AcousticProfile.new()
	own_ac.from_dict(scenario.get("own_acoustic", {}))

	# 拖曳阵（批次2+）：own_ship.tow 存在则给本艇挂一条物理拖曳阵。
	# 未配置时为 null，OperatorSonar 的 TOWED 退化为 follow own.course（兼容旧测试）。
	if own_dict.has("tow"):
		var towed := TowedArray.new()
		towed.setup(own_dict.get("tow", {}))
		towed.array_heading_deg = float(own_dict.get("course_deg", 0.0))
		own.towed = towed

	# 目标（红方）—— 可多个
	var targets: Array = []
	var target_acs: Dictionary = {}
	for td in scenario.get("targets", []):
		var t := TruthEntity.new()
		t.from_dict(td)
		targets.append(t)
		var ac := AcousticProfile.new()
		ac.from_dict(td.get("acoustic", {}))
		target_acs[t.id] = ac

	# 传感器
	var sensors: Array = []
	for sd in scenario.get("sensors", []):
		var s := SensorArray.new()
		s.from_dict(sd)
		s.set_rng(rng)
		sensors.append(s)

	# 测量生成器
	var gen := MeasurementGenerator.new()
	gen.setup(rng, env)

	return {
		"rng": rng,
		"env": env,
		"depth_model": depth_model,
		"own": own,
		"own_ac": own_ac,
		"targets": targets,
		"target_acs": target_acs,
		"sensors": sensors,
		"generator": gen,
		"dt": float(scenario.get("dt", 0.1)),
		"duration": float(scenario.get("duration", 60.0)),
		"name": str(scenario.get("name", "unnamed")),
	}
