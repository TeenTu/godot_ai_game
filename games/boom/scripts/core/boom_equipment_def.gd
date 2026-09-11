class_name BoomEquipmentDef
extends Resource
## 固定装备定义；只有法器通过 artifact_id 引用战斗形态与技能树。

@export var id: String = ""
@export var slot: String = ""
@export var category: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var icon_path: String = ""
@export var flat_stats: Dictionary = {}
@export var multipliers: Dictionary = {}
@export var passive_id: String = ""
@export var visual_id: String = ""
@export var artifact_id: String = ""
