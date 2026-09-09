class_name BoomWeaponDef
extends Resource
## M5 武器数据定义（design_m5_weapons.md §3.2 1a）。
## 纯数据 Resource：字段类型化，可无头断言；未来迁 .tres 或接技能树不返工。
## 普攻分两类：RANGED（连射弹道）/ MELEE（近战弧斩），字段按需填。

enum AttackKind { RANGED, MELEE }

@export var id: String = ""  # 逻辑 id 保持 "bubble" / "greatsword"，显示名由世界观覆盖
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
## M8 基础攻击力（design_m8_attributes.md §5.1）：由武器决定的初始攻击参数；
## 所有输出经 BoomGame 统一结算入口 floor(base × (1+伤害加成)) 放大。
@export var base_attack: int = 10
# ---- 普攻（melee）----
@export var swing_windup: float = 0.32  # 重剑前摇（可走、锁定朝向）
@export var swing_active: float = 0.08  # 瞬时释放窗（锁移动）
@export var swing_recover: float = 0.36  # 带惯性的收势（可移动）
@export var swing_arc_deg: float = 150.0  # 弧斩张角
@export var swing_range: float = 2.9  # 斩距（世界单位）
@export var swing_max_targets: int = 12  # 怪海单斩命中上限
@export var swing_dmg: int = 3
@export var swing_knock: float = 6.0  # 斩击击退初速（> jelly.KNOCK_SPEED=4.6）
@export var swing_freeze: float = 0.065  # 斩中顿帧（0.5s 门控）
# ---- 机体数值 ----
@export var move_mult: float = 1.0  # 移动速度倍率（BoomPlayer.MOVE_SPEED=5.4 之上）
@export var max_hp_bonus: int = 0  # HP 上限增量（M8：泡泡 0 → 50；大剑 +20 → 70，§4.1）
@export var radius: float = 0.55  # 碰撞半径（默认同 BoomPlayer.RADIUS）
# ---- 技能槽装备（1d 决策：本期两武器共用同一套三技能）----
@export var skill_kit_id: String = "core"  # 指向"3 槽→技能"映射表（见 design §5.2）
@export var skill_mods: Dictionary = {}  # 未来逐技能微调，本期全空
# ---- 外观与技能树 ----
@export var anim_set_id: String = ""  # "night_ruler" / "ink_judge_brush"
## M7R 每武器独立技能树：{"skills": [6 个技能 id 按树序]}——
## 加新武器 = 定义一棵树（见 design_m7_progression.md §5.1）。
@export var tree: Dictionary = {}
