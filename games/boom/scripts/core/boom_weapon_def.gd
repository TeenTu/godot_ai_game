class_name BoomWeaponDef
extends Resource
## M5 武器数据定义（design_m5_weapons.md §3.2 1a）。
## 纯数据 Resource：字段类型化，可无头断言；未来迁 .tres 或接技能树不返工。
## 普攻分两类：RANGED（连射弹道）/ MELEE（近战弧斩），字段按需填。

enum AttackKind { RANGED, MELEE }

@export var id: String = ""  # "bubble" / "greatsword"
@export var display_name: String = ""
@export var icon_path: String = ""  # res://assets/images/icons/weapon_*.png
@export var blurb: String = ""  # 选单一句话卖点（"势大力沉" 等）
@export var kind: AttackKind = AttackKind.RANGED

# ---- 普攻（ranged）----
@export var fire_cd: float = 0.22  # 与现 BoomGame.FIRE_CD 一致
@export var proj_speed: float = 15.0  # BoomBullet.SPEED
@export var proj_life: float = 1.6  # BoomBullet.LIFETIME
@export var proj_dmg: int = 1  # 命中结算用它（现 BULLET_DMG）
@export var proj_color: Color = Color("8ce6ff")  # 命中粒子/弹体调色
# ---- 普攻（melee）----
@export var swing_windup: float = 0.24  # 前摇（可走、锁定朝向）
@export var swing_active: float = 0.12  # 判定窗（锁移动）
@export var swing_recover: float = 0.34  # 后摇（可移动）
@export var swing_arc_deg: float = 150.0  # 弧斩张角
@export var swing_range: float = 2.9  # 斩距（世界单位）
@export var swing_max_targets: int = 6  # 单斩命中上限
@export var swing_dmg: int = 3
@export var swing_knock: float = 6.0  # 斩击击退初速（> jelly.KNOCK_SPEED=4.6）
@export var swing_freeze: float = 0.05  # 斩中顿帧（0.5s 门控）
# ---- 机体数值 ----
@export var move_mult: float = 1.0  # 移动速度倍率（BoomPlayer.MOVE_SPEED=5.4 之上）
@export var max_hp_bonus: int = 0  # HP 上限增量（泡泡 0 → 5；大剑 +2 → 7）
@export var radius: float = 0.55  # 碰撞半径（默认同 BoomPlayer.RADIUS）
# ---- 技能槽装备（1d 决策：本期两武器共用同一套三技能）----
@export var skill_kit_id: String = "core"  # 指向"3 槽→技能"映射表（见 design §5.2）
@export var skill_mods: Dictionary = {}  # 未来逐技能微调，本期全空
# ---- 外观与技能树 ----
@export var anim_set_id: String = ""  # "bubble_captain" / "greatsword_captain"
@export var tree: Dictionary = {}  # 技能树节点定义（§5.1，本期空）
