class_name UiContract
extends RefCounted
## ui_contract.gd — UI 布局/场景契约（评审 P1-03.1 / P0-08）。
##
## P1-03.1 侧栏宽度契约：min=300 / preferred=340 / max=420；动态文本
## autowrap（内容不撑宽侧栏）+ 每帧 sidebar_clamp_x 钳制；窗口变窄时
## 侧栏不挤压海图（1280×720 不变量，AT-11）。
##
## P0-08 场景解析：默认保持旧被动教程（不静默改默认）；SONAR_SCENARIO
## 环境变量可显式选择 S1-07 战斗场景（s1_combat）。

const SIDEBAR_MIN_W: float = 300.0
const SIDEBAR_PREF_W: float = 340.0
const SIDEBAR_MAX_W: float = 420.0
const DEFAULT_SCENARIO: String = "stage1_basic_passive"


## 场景解析（P0-08）：SONAR_SCENARIO 优先，空则默认教程场景。
static func resolve_scenario_name() -> String:
	var env := OS.get_environment("SONAR_SCENARIO")
	return env if env != "" else DEFAULT_SCENARIO


## 侧栏宽度钳制（P1-03.1）：契约内取值，超界归边。
static func sidebar_clamp_x(x: float) -> float:
	return clampf(x, SIDEBAR_MIN_W, SIDEBAR_MAX_W)
