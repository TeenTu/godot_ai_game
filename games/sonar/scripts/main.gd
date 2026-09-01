extends Node2D
## main.gd — 场景入口。装配阶段三主 UI（SonarUI）。
## 阶段一/二为纯逻辑内核，阶段三把内核接到可交互界面。

const SonarUIScript := preload("res://scripts/ui/main_ui.gd")


func _ready() -> void:
	var ui: Control = SonarUIScript.new()
	ui.name = "SonarUI"
	add_child(ui)
