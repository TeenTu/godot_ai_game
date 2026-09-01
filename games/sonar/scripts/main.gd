extends Node2D
## main.gd — 阶段一占位入口。
## 阶段一仅有仿真内核（无 UI），此脚本只负责最小装配，避免 main.tscn 报错。
## 阶段三会重写为完整的 UI 场景装配（声呐显示/海图/控制面板/Show Truth）。


func _ready() -> void:
	# 阶段一：可以跑一段确定性测量流做演示，但不绘制（纯逻辑已在 stage1_test.gd 验证）。
	print("sonar stage1: simulation core ready (no UI)")
