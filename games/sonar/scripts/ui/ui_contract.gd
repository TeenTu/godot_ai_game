class_name UiContract
extends RefCounted
## ui_contract.gd — UI 布局/场景契约（评审 P1-03.1 / P0-08 / REQ-AI-01）。
##
## P1-03.1 侧栏宽度契约：min=300 / preferred=340 / max=420；动态文本
## autowrap（内容不撑宽侧栏）+ 每帧 sidebar_clamp_x 钳制；窗口变窄时
## 侧栏不挤压海图（1280×720 不变量，AT-11）。
##
## UI-01 修正：钳制不是最大宽度机制。侧栏现由 SidebarShell 这个"非 Container
## 外壳"决定宽度（自定义最小宽 = 目标宽，子内容最小宽不再向上传播），宽度
## 只按窗口宽度分档（sidebar_width_for），内容只改变高度（T22）。
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
## UI-01 分档宽度：1280×720 窄窗用 NARROW，常规桌面用 PREF，超宽屏用 WIDE。
const SIDEBAR_NARROW_W: float = 320.0
const SIDEBAR_WIDE_W: float = 380.0
const SIDEBAR_NARROW_BELOW: float = 1440.0  # 视口宽 < 此值 → NARROW 档
const SIDEBAR_WIDE_FROM: float = 2000.0  # 视口宽 ≥ 此值 → WIDE 档
## tame_option_button 的幂等标记（同一控件只连一次 tooltip 同步）。
const META_TAMED: StringName = &"_ui01_tamed_option"
const DEFAULT_SCENARIO: String = "stage1_basic_passive"
const COMBAT_SCENARIO: String = "s1_combat"
const META_SCENARIO: String = "_startup_scenario_override"
const META_SEED: String = "_startup_seed_override"
const META_LAST_SEED: String = "_last_combat_seed"
const META_TOUCH: String = "_touch_hit_override"
## AT-44：触摸模式下的最小命中半径（px）。鼠标细指针用各控件自己的小半径，
## 触摸时统一放大到本值，保证航线点/鱼雷图标/开机标记都好按且不误触平移。
const TOUCH_HIT_PX: float = 26.0


## 触摸命中覆盖（测试用）：true/false 强制，null/清除恢复自动判定。
static func set_touch_override(on: Variant) -> void:
	var ml: Object = Engine.get_main_loop()
	if ml == null:
		return
	if on == null:
		ml.remove_meta(META_TOUCH)
	else:
		ml.set_meta(META_TOUCH, bool(on))


## 当前是否触摸模式（meta 覆盖 > 设备触摸屏）。
static func touch_mode() -> bool:
	var ml: Object = Engine.get_main_loop()
	if ml != null and ml.has_meta(META_TOUCH):
		return bool(ml.get_meta(META_TOUCH))
	return DisplayServer.is_touchscreen_available()


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
## UI-01：保留为**兜底**范围检查；真实最大宽度机制见 SidebarShell（不是钳制）。
static func sidebar_clamp_x(x: float) -> float:
	return clampf(x, SIDEBAR_MIN_W, SIDEBAR_MAX_W)


## UI-01：侧栏目标宽（逻辑像素）——只由窗口宽度分档决定。
## 文本长度、切页、命令 ETA 更新、告警数量都不参与（T22 宽度不变量）。
static func sidebar_width_for(viewport_w: float) -> float:
	if viewport_w < SIDEBAR_NARROW_BELOW:
		return SIDEBAR_NARROW_W
	if viewport_w >= SIDEBAR_WIDE_FROM:
		return SIDEBAR_WIDE_W
	return SIDEBAR_PREF_W


## UI-01：禁用 OptionButton 的"最长项撑宽"行为。
##   - fit_to_longest_item=false + clip_text=true → 最小宽**不再**由最长项决定
##     （实测 416px → 可读下限），超长选中项省略显示；
##   - 固定一个可读下限 min_w（默认 84）——否则 clip_text 会把最小宽压到按钮
##     外框（~32px），紧凑行里会把下拉压到只剩边框、当前项完全看不见；
##   - 选中项变化时把**全文**写进 tooltip（"省略后可查看全文"）。
static func tame_option_button(ob: OptionButton, min_w: float = 84.0) -> OptionButton:
	ob.fit_to_longest_item = false
	ob.clip_text = true
	ob.custom_minimum_size = Vector2(min_w, ob.custom_minimum_size.y)
	if ob.has_meta(META_TAMED):
		return ob
	var cb: Callable = _tamed_tooltip.bind(ob)
	ob.set_meta(META_TAMED, cb)
	ob.item_selected.connect(cb)
	refresh_tamed_tooltip(ob)
	cb.call_deferred(0)  # 调用方通常随后才 add_item：帧末再同步一次首选项全文
	return ob


## 省略后仍可查看全文：tooltip 常显当前选中项文本。
static func refresh_tamed_tooltip(ob: OptionButton) -> void:
	if ob != null and ob.item_count > 0:
		ob.tooltip_text = ob.get_item_text(clampi(ob.selected, 0, ob.item_count - 1))


static func _tamed_tooltip(_idx: int, ob: OptionButton) -> void:
	refresh_tamed_tooltip(ob)
