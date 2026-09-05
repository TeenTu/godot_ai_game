extends Node2D
## main.gd — 场景入口：StartMenu（REQ-AI-01 教学/战斗 + seed 控制）→ SonarUI。
##
## 选择结果经 UiContract meta 传递（resolve_scenario_name/resolve_seed_override
## 在 SonarUI._ready 时刻解析）；「重玩同 seed」用记录的上一局战斗 seed 重建
## 同局面。游戏内按 M 重新打开主菜单（S1-08 人机工效：入口可回退）。

const SonarUIScript := preload("res://scripts/ui/main_ui.gd")
const StartMenuScript := preload("res://scripts/ui/start_menu.gd")

var _menu: Control = null
var _ui: Control = null


func _ready() -> void:
	# Web 无系统 CJK 回退：全局默认字体指向项目子集字体（豆腐块修复）。
	# 经代码 load 引用保证导出时字体被打进 pck（gui/theme/custom_font
	# 不参与导出依赖扫描，见 DESIGN §0.7）。
	ThemeDB.fallback_font = load("res://assets/fonts/ui_subset.ttf")
	_show_menu()


func _show_menu() -> void:
	if _menu == null:
		_menu = StartMenuScript.new()
		_menu.name = "StartMenu"
		_menu.start_requested.connect(_on_start)
		add_child(_menu)
	else:
		_menu.refresh_state()
	if _ui != null:
		_ui.visible = false
	_menu.visible = true


func _on_start(scenario: String, seed_val: int) -> void:
	UiContract.set_startup_override(scenario, seed_val)
	if seed_val >= 0:
		UiContract.record_last_seed(seed_val)
	if _ui != null:
		remove_child(_ui)
		_ui.free()
		_ui = null
	_ui = SonarUIScript.new()
	_ui.name = "SonarUI"
	add_child(_ui)
	_menu.visible = false


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		_show_menu()
