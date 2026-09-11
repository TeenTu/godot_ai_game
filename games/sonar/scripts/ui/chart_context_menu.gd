class_name ChartContextMenu
extends PopupMenu
## chart_context_menu.gd — S109 §9.2 / S1-11 §4.3 海图右键上下文菜单（中文条目）。
##
## 条目按 hit_kind 生成；动作经 action_chosen(action, ctx) 转发给
## ChartContextActions 执行（菜单本身零业务写入）。§9.3：菜单打开期间海图
## 暂停拖曳但不自动暂停仿真；Esc/点空白关闭后保留视图与选择；危险动作
## （主动确认 Ping / 切断导线）先显示确认条目，确认后才发 action。
## 文案中文（Batch 7 统一收进字体 cmap 校验，AT-42 要求中文菜单项）。

signal action_chosen(action: String, ctx: Dictionary)

const ITEMS: Dictionary = {
	"THREAT":
	[
		["threat_view", "查看威胁详情"],
		["threat_set_active", "设为当前威胁"],
		["threat_center", "居中此威胁"],
		["threat_evidence", "查看证据历史"],
		["threat_ping", "主动确认 Ping…"],
		["threat_goto_weapons", "转到反制武器"],
	],
	"CONTACT":
	[
		["contact_select", "选择接触"],
		["contact_mark_group", "设为当前 Mark 组"],
		["contact_goto_tma", "转到 TMA"],
		["contact_fit", "自动拟合"],
		["contact_presite", "以此方位预填概略射击…"],
		["contact_center", "居中此接触"],
	],
	"OWN_TORPEDO":
	[
		["torpedo_select", "选择该鱼雷"],
		["torpedo_active_toggle", "立即开启/关闭主动声呐"],
		["torpedo_reroute", "重画剩余航线"],
		["torpedo_center", "居中"],
		["torpedo_cut", "切断导线…"],
	],
	"EMPTY":
	[
		["empty_route_draw", "绘制鱼雷航线"],
		["empty_route_clear", "清除鱼雷航线"],
		["empty_center", "以此处为地图中心"],
		["empty_frame", "自动取景"],
		["empty_clear", "清除选择"],
		["empty_layers", "图层设置"],
	],
}
## 选中某枚在水鱼雷时，右键空白地图追加的指令（§4.3）。
const TORPEDO_EMPTY_ITEMS: Array = [
	["empty_torpedo_goto", "令 %s 向此处航行"],
	["empty_torpedo_waypoint", "从此处继续添加航路点"],
	["empty_torpedo_active", "在此处开启主动声呐"],
	["empty_torpedo_clear_route", "清除剩余航线"],
]
const DANGER_Q: Dictionary = {
	"threat_ping": "确认主动 Ping？本艇将主动暴露敌方",
	"torpedo_cut": "危险动作：确认切断导线？",
}

var _ctx: Dictionary = {}
var _actions: Array = []
var _pending: String = ""


func _init() -> void:
	id_pressed.connect(_on_id)  # 只接一次，避免重复弹窗叠加连接


func open_at(screen_pos: Vector2, ctx: Dictionary) -> void:
	_ctx = ctx
	_pending = ""
	_populate(str(ctx.get("hit_kind", "EMPTY")))
	position = Vector2i(screen_pos)
	_open_popup()


func item_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for i in get_item_count():
		out.append(get_item_text(i))
	return out


func pending_action() -> String:
	return _pending


func _populate(kind: String) -> void:
	clear()
	_actions = []
	var rows: Array = _rows_for(kind)
	for it in rows:
		add_item(str(it[1]))
		_actions.append(str(it[0]))


## 按上下文动态生成条目（EMPTY 会按选中鱼雷/绘制态追加指令）。
func _rows_for(kind: String) -> Array:
	var rows: Array = (ITEMS.get(kind, ITEMS["EMPTY"]) as Array).duplicate()
	if kind != "EMPTY":
		return rows
	var tid: String = str(_ctx.get("selected_torpedo_id", ""))
	var extra: Array = []
	if bool(_ctx.get("route_drawing", false)):
		extra.append(["empty_route_done", "完成航线"])
	if tid != "":
		for it in TORPEDO_EMPTY_ITEMS:
			# 只有「令 %s 向此处航行」带占位符；其余条目为通用文案，不格式化。
			var lab: String = str(it[1])
			if lab.contains("%s"):
				lab = lab % tid
			extra.append([str(it[0]), lab])
	return extra + rows


func _ask_confirm(action: String) -> void:
	clear()
	_actions = [action]
	add_item("危险：" + str(DANGER_Q[action]))
	add_item("取消")
	_open_popup()


## headless（CI/测试）下 popup() 会挂起无头显示服务器：跳过真弹窗，
## 手动补发 about_to_popup 以驱动拖曳锁（条目/确认流程仍可全程驱动）。
func _open_popup() -> void:
	reset_size()
	if DisplayServer.get_name() == "headless":
		about_to_popup.emit()
	else:
		popup()


func _on_id(id: int) -> void:
	if _pending != "":
		if id == 0:
			var done: String = _pending
			_pending = ""
			action_chosen.emit(done, _ctx)
		else:
			_pending = ""  # 取消：清空待确认，不转发
		return
	if id < 0 or id >= _actions.size():
		return
	var action: String = str(_actions[id])
	if DANGER_Q.has(action):
		_pending = action
		_ask_confirm(action)
		return
	action_chosen.emit(action, _ctx)
