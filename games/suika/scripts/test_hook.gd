## vision-e2e 测试钩子（autoload）。
##
## 当 URL 含 ?test=1 且运行在 Web 平台时，把当前游戏状态周期性地
## 发布到 window.__gameState，方便 vision-e2e 套件（tools/vision-e2e/）
## 做精确数值断言、跳过视觉 API 调用。
##
## 设计约束：
##   - 仅在 Web 平台且 URL 含 ?test=1 时生效；其他平台/缺失参数时完全 no-op
##   - 默认每 0.1s 更新一次 window 对象（10Hz eval 开销可忽略）
##   - 不参与正常游戏逻辑（_process 之外的代码路径都不动）
##
## Godot 侧需要被测脚本（main.gd）实现 _test_hook_get_state() 暴露
## 当前状态字典（见下）。钩子只读，永远不修改游戏状态。
##
## 实现注意：
##   1. JavaScriptBridge 是 Web 平台单例，在桌面/headless 编辑器中部分方法
##      不挂载。用 Engine.has_singleton 检测 + Object.call 动态调用绕过
##      编译时类型检查 —— 编辑器打开工程/校验脚本不报错。
##   2. _detect_test_mode 直接比较 URLSearchParams 字符串返回值，不用 boolean，
##      因为 Emscripten 跨边界序列化 JS boolean → GDScript Variant 不可靠。
extends Node

## 状态发布频率（秒）。0.1s 对测试足够，且 10Hz eval 几乎无感。
const _UPDATE_INTERVAL: float = 0.1

var _time_since_update: float = 0.0
var _enabled: bool = false


func _ready() -> void:
	if not OS.has_feature("web"):
		set_process(false)
		return
	if not Engine.has_singleton("JavaScriptBridge"):
		set_process(false)
		return
	var in_test: bool = _detect_test_mode()
	# 测试模式 + URL 带 ?seed=N → 固定全局随机种子。
	# 必须在 main._ready 的 randomize() 之前执行（autoload 先于场景加载）。
	# 注意：仅在测试模式生效，线上玩家不传 ?test=1 就完全 no-op。
	if in_test:
		var bridge2: Object = Engine.get_singleton("JavaScriptBridge")
		var seed_v: Variant = bridge2.call(
			"eval", "new URLSearchParams(location.search).get('seed')"
		)
		if typeof(seed_v) == TYPE_STRING and (seed_v as String) != "":
			var n: int = int(seed_v)
			seed(n)
			print("[test_hook] fixed seed = ", n)
	_enabled = in_test
	if not _enabled:
		set_process(false)
		return
	# 初始化 window.__gameTest 命名空间，方便套件 setSeed 等调用。
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	bridge.call("eval", "window.__gameTest = window.__gameTest || {};")
	set_process(true)


func _process(delta: float) -> void:
	if not _enabled:
		return
	_time_since_update += delta
	if _time_since_update < _UPDATE_INTERVAL:
		return
	_time_since_update = 0.0
	_publish_state()


## 供外部/JS 调用的种子设置（URL params 也能设，这里保留 JS 入口作为补充）。
func set_seed(n: int) -> void:
	seed(n)


## 检测 URL ?test=1。
## 直接拿字符串值比较，不用 boolean —— Emscripten 跨边界序列化
## JS 的 true/false → GDScript Variant 偶发不正确，字符串最稳。
func _detect_test_mode() -> bool:
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	var result: Variant = bridge.call("eval", "new URLSearchParams(location.search).get('test')")
	if typeof(result) != TYPE_STRING:
		return false
	return (result as String) == "1"


## 把当前场景的状态写到 window.__gameState
func _publish_state() -> void:
	var main: Node = get_tree().current_scene
	if main == null or not main.has_method("_test_hook_get_state"):
		return
	var state: Dictionary = main._test_hook_get_state()
	# JSON.stringify 直接输出合法 JSON 字面量
	var js_code: String = "window.__gameState = %s;" % JSON.stringify(state)
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	bridge.call("eval", js_code)
