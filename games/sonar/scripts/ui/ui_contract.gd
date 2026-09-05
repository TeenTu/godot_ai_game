class_name UiContract
extends RefCounted
## ui_contract.gd — UI 布局/场景契约（评审 P1-03.1 / P0-08 / REQ-AI-01）。
##
## P1-03.1 侧栏宽度契约：min=300 / preferred=340 / max=420；动态文本
## autowrap（内容不撑宽侧栏）+ 每帧 sidebar_clamp_x 钳制；窗口变窄时
## 侧栏不挤压海图（1280×720 不变量，AT-11）。
##
## P0-08 场景解析：默认保持旧被动教程（不静默改默认）；SONAR_SCENARIO
## 环境变量可显式选择 S1-07 战斗场景（s1_combat）。
##
## REQ-AI-01 启动覆写：网页内 StartMenu 选定 教学/战斗 后经 set_startup_override
## 写入 SceneTree meta（随主循环释放；不用 static var——避免退出段错误模式）。
## 解析优先级：meta 覆写 > SONAR_SCENARIO 环境变量 > 默认教程。

const SIDEBAR_MIN_W: float = 300.0
const SIDEBAR_PREF_W: float = 340.0
const SIDEBAR_MAX_W: float = 420.0
const DEFAULT_SCENARIO: String = "stage1_basic_passive"
const COMBAT_SCENARIO: String = "s1_combat"
const META_SCENARIO: String = "_startup_scenario_override"
const META_SEED: String = "_startup_seed_override"
const META_LAST_SEED: String = "_last_combat_seed"


## 启动覆写（REQ-AI-01）：StartMenu 选定后调用；scenario 为空/-1 表示清除。
static func set_startup_override(scenario: String, seed_val: int) -> void:
	var ml: Object = Engine.get_main_loop()
	if ml == null:
		return
	ml.set_meta(META_SCENARIO, scenario)
	ml.set_meta(META_SEED, seed_val)


## 记录最近一局战斗 seed（重玩同 seed 入口的依据）。
static func record_last_seed(seed_val: int) -> void:
	var ml: Object = Engine.get_main_loop()
	if ml != null:
		ml.set_meta(META_LAST_SEED, seed_val)


static func last_seed() -> int:
	var ml: Object = Engine.get_main_loop()
	if ml != null and ml.has_meta(META_LAST_SEED):
		return int(ml.get_meta(META_LAST_SEED))
	return -1


## 场景解析（P0-08/REQ-AI-01）：meta 覆写 > SONAR_SCENARIO > 默认教程。
static func resolve_scenario_name() -> String:
	var ml: Object = Engine.get_main_loop()
	if ml != null and ml.has_meta(META_SCENARIO):
		var s: String = str(ml.get_meta(META_SCENARIO))
		if s != "":
			return s
	var env := OS.get_environment("SONAR_SCENARIO")
	return env if env != "" else DEFAULT_SCENARIO


## seed 覆写（REQ-AI-01）：无覆写返回 -1（用场景 JSON 自带 seed）。
static func resolve_seed_override() -> int:
	var ml: Object = Engine.get_main_loop()
	if ml != null and ml.has_meta(META_SEED):
		return int(ml.get_meta(META_SEED))
	return -1


## 侧栏宽度钳制（P1-03.1）：契约内取值，超界归边。
static func sidebar_clamp_x(x: float) -> float:
	return clampf(x, SIDEBAR_MIN_W, SIDEBAR_MAX_W)
