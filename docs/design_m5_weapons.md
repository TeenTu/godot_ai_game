# 《砰砰小队》M5 设计增量：多武器系统与动画打磨（design_m5_weapons.md）

> 归属：`docs/design_boom.md` §9 里程碑 M5 · 前置：M2 弹幕技能（`design_m2_danmaku.md`）、
> M4 波次系统（`design_m4_waves.md`）已上线 · **本文只做设计，不改代码**。
> 本文同时是 Codex 素材生成的任务清单（§6 动画规格、§7 素材清单）与删稿清单（§7.2 milk frog 废弃）。

---

## 1. 目标与范围

### 1.1 一句话目标

**进对局前可以选武器；武器不止换数值，还换普攻逻辑、移动节奏与整身动画——先落
「泡泡枪（远程连发）」与「大剑（近战重斩）」两把，让"远程站桩扫射"与"贴脸抡大剑"
成为两种手感不同的玩法，并为"每武器独立技能树"预留可生长的数据扩展点。**

### 1.2 本次交付（M5 落地边界）

| 交付 | 内容 | 状态 |
|---|---|---|
| D1 武器数据模型 | `BoomWeaponDef` + `BoomWeapons` 注册表（纯数据、无 UI 依赖） | 本文给出结构与 Godot 落地建议 |
| D2 选武器 UX | 开局武器选择面板（竖屏布局 + 交互） + 结算→再选择闭环 | 本文给出流程与 UI 规格 |
| D3 大剑普攻 | 与泡泡枪差异化的近战斩击（节奏/范围/数值/打击感草案） | 本文给出数值草案 |
| D4 技能关系决策 | 大剑保留 Fan/Chain/Nuke 三技能（换武器≠换技能） | 本文给出推荐与理由 |
| D5 技能树扩展点 | 每武器独立技能树的**数据/接口层最小结构**（无技能树 UI） | 本文给出结构设计 |
| D6 动画规格清单 | 玩家/敌人/反馈/技能特效逐项规格（§6 表格 = Codex 清单来源） | 本文给出可执行规格 |
| D7 素材/删稿清单 | 新 2D 角色素材命名 + milk frog 废弃删除清单 | §7 |

### 1.3 明确不做（M5 范围红线）

- ❌ **不做技能树 UI / 升级养成循环**：本批只落数据字段与解锁状态查询 API（长线愿景）。
- ❌ **不做第三把武器**：只做"能再加一把"的注册表结构，加武器=登记一行数据。
- ❌ **不改技能手势**：tap / ←swipe / →swipe 槽位与识别参数（main.gd）本批不动。
- ❌ **不做武器局内切换**：选完武器整局固定，结算后返回选择面板再换。
- ❌ **不恢复 .tres 关卡/武器文件方案**：遵循 M4 §8 定调（常量区 + 代码内 Resource 查表够用，
  策划调参改常量不改逻辑；本文武器数据同理走 `Resource 对象表`，但**建表在代码里**，不落 .tres）。

---

## 2. 现状与约束（基于代码核实的真实状态）

以下事实均读码核实（仓库 boom-dev @ fdb7519，路径以 `games/boom/` 为根）：

### 2.1 玩家：程序化造型 + 废弃模型占位（boom_player.gd）

- `BoomPlayer extends Node3D`，`MAX_HP=5 / RADIUS=0.55 / MOVE_SPEED=5.4 / INVULN_TIME=0.9`
  （boom_player.gd:6-9）。移动在 `physics_update()` 内自驱（boom_player.gd:144-181），
  速度是**常量**，无外部注入口。
- `_add_character_art()`（boom_player.gd:93-118）优先级链：**① `milk_frog_3d.tscn`（M5 将删）
  → ② `milk_frog_hero.png` Sprite3D 立绘（M5 将删）→ ③ 程序化圆舱体**。当前真机走①，
  并把身体/枪管等 MeshInstance3D 全部 `visible=false`。
- 视觉受击反馈：无敌闪烁翻转 `_body/_art/_model.visible`（boom_player.gd:154-169）+ 受击闪白
  只作用于程序化身体材质 `_body_mat.emission`（:172-174）——**贴图/模型形态下闪白不生效**
  （建模内 animate_model 处理）。换 2D 动画路线后需改为 modulate/贴图态闪白。
- `muzzle` 锚点：默认 `(0, 0.5, 0.9)`；挂奶蛙后改 `(0, 1.18, 0.72)`。**子弹、Fan 弹幕
  都依赖 `player.basis * player.muzzle.position`**（boom_game.gd:199、333）——新外观必须保留
  一个语义为"枪口"的锚点。

### 2.2 对局核心（boom_game.gd）：泡泡枪参数全部为常量

- 自动开火：`_tick_player()` 按锁定/最近敌人瞄准，`FIRE_CD=0.22s` 发射，无目标朝移动方向扫射
  （boom_game.gd:188-213）；子弹 `BULLET_DMG=1`（:26），速度/寿命在 `BoomBullet`（15/1.6）。
- 子弹命中伤害在 `_tick_bullets()` 碰撞处结算（:454），击杀统一走 `_finalize_kill()`
  （击杀顿帧 80ms/25ms 门控、连击、金币雨都在这）。
- 波次/精英/同屏上限等数值 M4 已常量化（WAVE_* / ELITE_* 常量区）。
- 测试友好：`step(delta)` 单步驱动 + `_new_game()` 纯逻辑实例（play_test 全走这条，
  **武器逻辑必须长在 BoomGame 层、可无头断言**）。

### 2.3 敌人 jelly：程序化球 + PNG 立绘**混合**（boom_jelly.gd）——如实报告

- 结构：`BoomJelly extends Node3D`，身体是程序化 SphereMesh（`_body`），其上再叠一层
  **Sprite3D 立绘**（`_add_character_art()`，boom_jelly.gd:94-110）：75% `jelly_scout.png` /
  25% `water_gunner.png`，billboard + alpha_cut。
- **关键时序细节（如实报告）**：`_build_visuals` 的顺序是 身体球 → `_add_character_art()`
  → 程序化眼睛（:81-86）→ 隐藏循环（:87-90）→ telegraph 环。**隐藏循环在眼睛加入之后
  执行且过滤全部 MeshInstance3D**——因此立绘存在时，身体球**与程序化眼睛一并被隐藏**，
  可见内容 = Sprite3D 立绘 PNG + telegraph 环（环在隐藏循环之后由 `_build_telegraph()` 加入，
  不受影响）。即 jelly 在贴图态是完全的"立绘 + 地面预警环"，无程序化分件。
- 因此当前 jelly 的**可见**受击反馈 = 节点 `scale` 的 squash&stretch（`_apply_scale`，
  :277-285，作用于整节点含立绘）+ 击退位移 + 前摇胀大红光脉冲（材质 emission，贴图态身体
  已隐藏不可见，红光只见于无贴图回退）；**材质白闪（body_mat.emission）在立绘激活时
  实际看不到**——这是受击反馈的一个真实缺口，M5 需改走 Sprite3D 的 modulate 白闪或
  可见的白色 overlay。
- 出生：刷怪点直接出现，无出生动画；死亡：`_finalize_kill()` 立即 `remove_child + queue_free`，
  靠 `fx.goo_burst()` 粒子兜住"爆开"感，无死亡表现时长。

### 2.4 技能系统：三槽手势已固化（BoomSkillSystem / main.gd）

- `fan=tap / chain=←swipe / nuke=→swipe`，CD 3/8/20s，槽位与冷却逻辑全在
  `BoomSkillSystem`（boom_skill_system.gd:12-44），纯逻辑、零 UI。
- 输入映射：main.gd `_input()` 手势区判定（`SKILL_ZONE_X=0.65`，:134-183），技能按钮 3 个
  圆形 UI 在右侧竖排（fan y760 / chain y886 / nuke y1012，x596，boom_skill_button.gd
  size 104×122、圆径 48）。**改手势 = 动输入 + 动 HUD + 动 CI 断言，成本高且伤肌肉记忆**。
- 技能视觉/飘字/震屏规格已在 M2 §4.2 收口（fan 黄小字"嘭!" / chain 紫大字"链!" /
  nuke 金巨型"轰!"，boom_skill_system.gd:22-30 + main.gd:255-308）。

### 2.5 CI 门禁（play_test.gd，约 130 断言）对删稿/改造的硬约束

- play_test.gd:120-125 **断言 `MilkFrog3D` 子节点存在且含真实网格**；
- :131-137 **断言 `milk_frog_hero.png` 等 5 个素材可加载**；
- smoke 断言 `hp == max_hp == 5`、`wave == 1`；`_test_auto_fire_kill` 等全走默认泡泡枪参数。
- **约束结论**：① 删除奶蛙必须同步改 play_test（见 §8 风险 R1）；② 默认武器必须仍是泡泡枪且
  参数与现常量一致，否则存量断言全崩；③ 测试模式应自动跳过选武器面板（走默认），
  避免无头 4 帧 smoke 卡在选择层上。

### 2.6 美术基线约束

- 风格契约：`assets/ART_REQUEST.md` + `docs/art_bible_boom.md`（高饱和暖色、暖橙"我"/
  高饱和冷色敌、亮青=我方火力、危险红=预警、无黑描边、透明底 PNG、<512KB/张门禁）。
- 玩家造型基线（art_bible §7）：暖橙圆胶囊 + 亮青大护目镜 + 呆毛 + 肚白斑，"泡泡队长"
  Bubble Captain。**M5 的新 2D 角色与武器形态必须延续此人设，不能另起角色。**

---

## 3. 核心设计（一）：武器数据模型 + 选武器流程

### 3.1 设计决策汇总（需求 1 的五个必须决策）

| # | 决策点 | 结论（一句话） |
|---|---|---|
| 1a | 武器数据模型 | `BoomWeaponDef extends Resource`（类型化字段）+ 代码内静态注册表 `BoomWeapons`，不落 .tres |
| 1b | 选武器 UX | 入口 = 开局先于第一波 + 结算"再来一局"回选择面板；全屏 2 卡竖排选单，确认后注入 BoomGame 再开波 |
| 1c | 大剑普攻差异化 | 自动寻敌**弧斩**：前摇 0.24s / 判定 0.12s / 后摇 0.34s，150°×2.9 弧内≤6 敌各 3 伤，移速×0.85、HP 5→7，打击感走"斩中顿帧+重震屏" |
| 1d | 大剑与三技能关系 | **保留 Fan/Chain/Nuke**（纯换普攻+机体数值）；技能树到位前不做武器专属技能替换，但预留 `skill_kit_id` 扩展点 |
| 1e | 技能树扩展点 | `WeaponDef.tree`（节点/层/依赖）+ 运行时 `BoomSkillTree`（每武器解锁态）数据层，无 UI |

### 3.2 (1a) 武器数据模型

**方案**：`class_name BoomWeaponDef extends Resource`，全字段类型化；所有武器实例在
`class_name BoomWeapons` 的静态函数里代码建表（`static func all() / get(id) / default_id()`）。
遵循 M4 §8"常量查表够用、不改编辑器"的定调，未来若要配表/远程调参，字段本身就是
Resource 导出，可平滑迁到 .tres，**不返工**。

```gdscript
# scripts/core/boom_weapon_def.gd（建议新增，class_name 便于全局引用）
class_name BoomWeaponDef
extends Resource

enum AttackKind { RANGED, MELEE }

@export var id: String = ""              # "bubble" / "greatsword"
@export var display_name: String = ""
@export var icon_path: String = ""       # res://assets/images/icons/weapon_*.png
@export var blurb: String = ""           # 选单一句话卖点（"势大力沉" 等）
@export var kind: AttackKind = AttackKind.RANGED

# ---- 普攻（ranged）----
@export var fire_cd: float = 0.22        # 与现 BoomGame.FIRE_CD 一致
@export var proj_speed: float = 15.0     # BoomBullet.SPEED
@export var proj_life: float = 1.6       # BoomBullet.LIFETIME
@export var proj_dmg: int = 1            # BULLET_DMG（命中结算用它）
@export var proj_color: Color = Color("8ce6ff")  # 命中粒子/弹体调色
# ---- 普攻（melee）----
@export var swing_windup: float = 0.24   # 前摇（可被动画/表现吃掉）
@export var swing_active: float = 0.12   # 判定窗（锁移动）
@export var swing_recover: float = 0.34  # 后摇（可移动）
@export var swing_arc_deg: float = 150.0 # 弧斩张角
@export var swing_range: float = 2.9     # 斩距（世界单位）
@export var swing_max_targets: int = 6   # 单斩命中上限（性能 + 强度双控）
@export var swing_dmg: int = 3
@export var swing_knock: float = 6.0     # 斩击击退初速（jelly.KNOCK_SPEED=4.6 之上）
@export var swing_freeze: float = 0.05   # 斩中顿帧（受防晕门控）
# ---- 机体数值 ----
@export var move_mult: float = 1.0       # 移动速度倍率（BoomPlayer.MOVE_SPEED=5.4 之上）
@export var max_hp_bonus: int = 0        # HP 上限增量（泡泡 0 → 5；大剑 +2 → 7）
@export var radius: float = 0.55         # 碰撞半径（默认同 BoomPlayer.RADIUS）
# ---- 技能槽装备（1d 决策：本期两武器共用同一套三技能）----
@export var skill_kit_id: String = "core" # 见 §5.2，指向一张"3 槽→技能"映射表
@export var skill_mods: Dictionary = {}  # 未来逐技能微调 {fan_dmg_mult: 1.0, ...}，本期全 1.0
# ---- 外观与技能树 ----
@export var anim_set_id: String = ""     # "bubble_captain" / "greatsword_captain"，见 §6
@export var tree: Dictionary = {}        # 技能树节点定义，见 §5.1
```

运行时注册表（只读，全武器登记处）：

```gdscript
# scripts/core/boom_weapons.gd
class_name BoomWeapons
## 武器注册表：加一把武器 = 在 _build() 里登记一个 BoomWeaponDef。
static func all() -> Array[BoomWeaponDef]: ...
static func get_def(id: String) -> BoomWeaponDef: ...
static func default_id() -> String: return "bubble"   # CI 依赖：默认恒为泡泡枪
```

**为什么 Resource 而不是纯 Dictionary**：字段自带类型、编辑器可提示、迁 .tres 不返工、
`kind` 枚举可让后续普攻分发 switch 有编译期安全。**为什么登记在代码不落 .tres**：
与 M4 定调一致 + 仓库是"全代码构建 UI、少编辑器"路线 + 无头测试零文件依赖。

### 3.3 (1b) 选武器 UX 流程

**入口决策**：本项目现状无主菜单（main.tscn `_ready()` 直接进对局，结算"TAP TO RETRY"
是 `reload_current_scene`）。因此**选武器面板 = 开局必经的一层轻量界面，同时复用为
"再来一局"的中转站**。不做独立主菜单场景（省一个场景 + 一套转场）。

**流程状态机（M5）**：

```
加载 main.tscn
  → main._ready：搭 3D 世界/相机/摇杆/技能 HUD；sim 已建但置为"未开战"（不发波）
  → 弹 WEAPON_SELECT 全屏层（默认高亮"泡泡枪"）
       └ 选卡 → 高亮 + 右侧属性速览
       └ 按【开战】 → main 调 sim.set_weapon(id) → sim.begin_match()（按武器 max_hp/半径重建血条）→ 隐藏选单 → 发波 W1
  ── 中途死亡 ──> 结算面板（原样）→ "再来一局"改为【回到选武器】而非 reload_current_scene
       （reload 会重来一遍选单，语义等价但丢了"失败后快速换武器再战"的试错节奏）
  ── 测试/CI ──> _is_test_mode() 或 play_test 路径：跳过选单，直接 set_weapon("bubble") + 开波
```

**关键工程点**：

1. **注入时机**：现 `BoomGame._init()` 里 `restart()` 直接 `_begin_wave()`（boom_game.gd:120）。
   M5 把"开波"从构造拆出：`restart()` 保持只重置数值；新增 `set_weapon(id)`（写 `weapon_cfg`
   并把 hp/移速/半径落到 player，boom_game.gd:165-167 与 BoomPlayer 常量的引用点改为读 cfg）
   与 `begin_match()`（等于原 restart 的后半段 `_spawn_props()+_begin_wave()`）。
   `restart()` 默认武器 = `BoomWeapons.default_id()` → **存量调用/断言零改动**。
2. **HP 血条 UI 联动**：main.gd `_build_hp()` 按 `sim.player.max_hp` 一次建槽（:696-711）。
   武器决定 max_hp → 必须在**开波前**（选单确认后）用已注入的 max_hp 重建血条；
   开战后不改武器故无需热重建。视觉血量 5→7 的插槽宽度由 :700 的公式自适应。
3. **选单与既有 HUD 的遮挡关系**：选单 `mouse_filter=STOP` 全屏盖层，开战时隐藏；
   底层摇杆/技能 HUD 已构建但未接输入——因 main.gd `_input()` 里加 `if _in_select: return` 守卫，
   并把手势识别全部收到 `_started==true` 之后（现 :134 已判 `sim==null`，加一层选单态即可）。
4. **重开闭环**：结算面板"TAP TO RETRY"改为切回选单（复用现有 `_over_panel`，把 retry 回调
   从 `reload_current_scene` 换成"隐藏结算 + 弹选单 + sim.restart()"），M3 结算动画序列不变。

**竖屏 UI 布局（720×1280 设计空间，代码构建）**：

```
┌──────────────────────────────┐
│  顶部主标题 "选择武器" 48px   │  (y≈60, 中央)
│  副标题 一句话 (解压副标题)    │  (y≈120, 22px 米色 60%)
│  ┌──────────────────────────┐ │
│  │ 武器卡 1：泡泡枪（默认）   │ │  y≈190, 620×300
│  │  [角色泡泡形态缩略图]      │ │  圆角卡：底色暖橙→深橙渐变、白描边 3px
│  │  名称 / 卖点 / 属性chips   │ │  属性chips：攻速●/伤害/范围/移速/HP
│  └──────────────────────────┘ │
│  ┌──────────────────────────┐ │
│  │ 武器卡 2：大剑（势大力沉） │ │  y≈520, 620×300，未选态 = 半透明 + "NEW"角标
│  └──────────────────────────┘ │
│  ┌──────────────────────────┐ │
│  │    [ 开 战 ]  大按钮       │ │  y≈900, 520×120 圆角 40，热区 >> 88px 铁律
│  └──────────────────────────┘ │
│  底注：换武器只影响普攻与体质    │  (y≈1070, 小字)
└──────────────────────────────┘
```

- 选卡交互：点击武器卡高亮（金色描边 + 放大 1.02 + 属性速览同步），**点卡不直接开战**，
  需再按【开战】（防误触）；开战按钮按住放大反馈、松手触发。
- 缩略图直接用玩家动画 idle 帧（复用 §7 素材），零额外立绘成本。
- 布局为 2 卡纵向可容纳 ≥8 武器预留：未来卡片超过 3 张时改上下滚动（ScrollContainer），
  本期不实现。

### 3.4 (1d) 大剑与三技能关系的决策

**决策：本期两把武器共用同一套 Fan/Chain/Nuke，大剑 = 纯换普攻 + 机体数值。**
**不做武器专属技能替换。** 理由（按权重排序）：

1. **输入肌肉记忆是硬资产**：tap/←swipe/→swipe 已是一套「永远可用」的三键语汇
   （M2 设计目标之一：错峰 CD，玩家永远有技能在线）。武器专属技能若替换槽位，等于让
   "切武器"额外负担一套手势学习——竖屏单手品类的学习成本预算承受不起。
2. **M4 波次的清群/精英需求靠普攻差异已满足**：大剑的 150° 弧斩 + 强击退本身就是清群器
   （对比：nuke 是 20s 一次的 panic button）。若大剑再拿专属 AOE 替换 nuke，精英波会失去
   备选爆发而失衡；反之让 nuke 保留，玩家在"大剑清近场、nuke 兜远场"里获得组合决策。
3. **工程成本与 CI 矩阵**：技能是纯逻辑层 + 130 断言全绿的核心资产；武器专属技能会让
   技能-CI 变成"每武器 ×3 槽"的叉乘矩阵。本期把它锁死为 1 套技能 × 2 武器（技能部分断言不变）。
4. **升级感缺口由技能树补**：武器差异化的长线成长不靠"换技能"，靠 §5 的每武器技能树
   （未来可在树的终结点解锁"专属技能"，届时 `skill_kit_id` 指向新 kit，槽位手势仍不变）。

**留下的扩展点**（防未来返工，见 §5.2）：`WeaponDef.skill_kit_id` + `skill_mods`。本期
bubble 与 greatsword 的 `skill_kit_id` 都指向同一张默认 kit 表（fan/chain/nuke 原参数），
`skill_mods` 全空（=1.0），代码路径与现状完全等价。

---

## 4. 核心设计（二）：普攻差异化——泡泡枪 vs 大剑

### 4.1 两武器本体对比表（数值草案，均以 M4 W1 敌人 HP3 为基准）

| 维度 | 泡泡枪（保留现手感） | 大剑（新增） | 依据/调整空间 |
|---|---|---|---|
| 攻击方式 | 自动瞄准直线连射 | 自动寻敌**弧斩**（有敌入斩程才挥） | — |
| 节奏 | cd 0.22s 恒定扫射 | 前摇 0.24 / 判定 0.12 / 后摇 0.34 → **周期 ≈0.70s**+下一刀自然间隔 | 斩周期调整 0.6~0.9 |
| 单次伤害 | 1 | **3**（弧内全部命中者都吃 3） | 3~5；若精英偏肉可加"对 ≥5HP 目标 +1"（留平衡口，默认不做） |
| 命中判定 | 单目标碰撞（弹体） | 150°×2.9m 扇形，≤6 敌/斩 | 张角 120~170，斩距 2.6~3.2 |
| 单体 DPS 粗算 | 1 / 0.22 ≈ **4.5** | 3 / 0.85(含间隔) ≈ **3.5** | 单体重伤更慢，换清群与压制 |
| 清群形态 | 需换弹道/转向 | **一斩多杀**（W1 三只 3HP 贴脸≈一刀全清） | 大剑爽点 = 挥刀爆一群 |
| 移动 | ×1.0（5.4） | **×0.85（≈4.59）**——沉重 | 0.8~0.95，配合 +HP 的"肉盾慢速"人格 |
| HP 上限 | 5 | **7**（+2）——近身挨撞的补偿 | +1~+2；触碰伤仍 1/次 |
| 碰撞半径 | 0.55 | 0.55（视觉可更宽，判定不放大） | 半径放大 → jelly 判定难，不作 |
| 击退 | 命中走 KNOCK_SPEED 4.6 | 斩中击退初速 **6.0** + 弧内全体 | 5.5~7.0（把围上来的果冻拍开） |
| 顿帧 | 命中无、击杀走 80/25ms 门控 | 斩中 ≥1 敌触发 **0.05s**（0.5s 门控，复用 `trigger_freeze` + killstop 模式） | 0.04~0.08 |
| 震屏 | 命中 0.05 / 击杀 0.5 衰减 | 斩中 0.25；斩击杀走既有击杀衰减档 | cam.add_trauma 0.2~0.3 |
| 无目标时 | 朝移动方向扫射（打箱子刷金币） | **不空挥**（扛剑待机）——由摇杆把人送进人群 | 若要打箱：后续专属"下砸"再议 |

### 4.2 大剑斩击：挥斩节奏（动词：蓄 → 抡 → 收）

一套"势大力沉"必须能读出来（用户可感知的三段式），每段的逻辑/表现分工：

| 阶段 | 时长 | 玩家可动 | 判定 | 视觉（§6 挥斩动画 + 表现） | 数值 |
|---|---|---|---|---|---|
| 前摇 windup | 0.24s | 可走（不可转向新目标） | 无 | 举剑过头、剑身发光（亮青→危险红轻闪? 否，只用亮青流光），镜头轻微前推 | 若期间敌人跑出 150° 前扇，按挥出瞬间再算一次命中扇（宽容判定，防"举了白举"） |
| 判定 active | 0.12s | **锁移动** | 挥出瞬间计算一次：玩家 facing ±75°、≤2.9m、非死敌人，≤6 名 | 大动作下劈 + 斩迹（白色/亮青大弧 ImmediateMesh，复用 BoomSkillFx 画弧思路）+ 命中爆浆粒子 | 每目标 3 伤；斩中任意 ≥1 → 顿帧 0.05s（门控） + 震屏 0.25 |
| 后摇 recover | 0.34s | 可走 | 无 | 剑落地顿一拍 → 收势扛回肩上，身体回中立 | 后摇期间无目标也可挥（不打断），节奏靠下一刀前摇自然接上 |
| 空窗 | ≤0.2s 自然 | 可走 | — | 待机/移动循环 | 保证斩周期约 0.85~0.9s 的平均手感 |

命中判定细节（纯逻辑、可无头断言）：
- **目标决议**：判定瞬间取玩家 `facing`，对 `enemies` 中未死敌人做「距离 ≤ 2.9 且
  `acos(facing · to_dir) ≤ 75°`」过滤，按距离近→远取前 ≤6。不做预锁定（与泡泡枪不同——
  斩是"挥出那一下命中谁"），宽容判定避免空挥挫败。
- **伤害结算**：逐个走 `jelly.take_damage(swing_dmg, hit_dir)`（hit_dir = 玩家→敌方向），
  致死进 `_finalize_kill()`——**复用既有击杀顿帧/连击/播报/金币管线**，大剑不自造结算。
- **与接触伤害的配合**：斩击 6.0 击退把 jelly 推出接触圈（半径和 0.55+0.6+0.12），
  形成"斩开→补刀→再斩"的攻防节奏；jelly 的 `hit_cd=1.0s` 机制不变。

### 4.3 打击感规格（大剑专用，叠加在既有反馈四件套之上）

| 反馈 | 规格 | 落地点 |
|---|---|---|
| 顿帧 | 斩中 ≥1 敌：0.05s（0.5s 内最多一次，`trigger_freeze`，复用击杀门控变量） | boom_game `trigger_freeze` |
| 震屏 | 斩中 0.25 / 斩杀交回击杀档（×连杀衰减） | `cam.add_trauma` |
| 命中反馈 | 命中点各 1 个"爆浆"粒子（`fx.puff` 大号 + 颜色用敌色）+ 击退 + squash；每斩 1 个飘字（白色 3 伤，若致死走既有金色 +10） | `fx.puff / goo_burst` + `hitnum.spawn` |
| 斩迹 | 亮青色大弧带（0.18s 淡出），复用 BoomSkillFx 的 ImmediateMesh 画带函数改造 | BoomSkillFx 新增 `cleave_arc()` |
| 音效 | 挥空：低吼 swoosh；命中：金属"哐"+ 果冻 pop；均程序化 BoomAudio | `audio.play("sword_swing"/"sword_hit")`（新增程序化音色） |
| 白闪 | 斩杀沿用现击杀白闪（≤0.15/≤50ms），不再加料 | `_trigger_kill_flash` |
| 受击 | 大剑形态同样受击红晕 + 无敌闪烁（modulate 态，见 §6.1） | boom_player 重构点 |

### 4.4 数值与 M4 波次的呼应（防"近战不能玩"）

- 教学段（W1-4，HP3）：泡泡枪要 3 发/只；大剑一刀一只——**首波教学即给近战正反馈**。
- 台阶①（W10-14，HP5/速度×1.1）：大剑需 2 刀/只（1.7s），泡泡枪 5 发/1.1s；
  大剑略慢但范围清群 + 强击退控场，配合 Chain/Nuke 无墙。
- 精英波（每 5 波，HP≈当波有效×3，如 W5=12）：大剑 4 刀/只≈3.4s（泡泡枪 12×0.22≈2.6s）
  ——**大剑打精英确实慢**，这正是"近战风险换范围"的代价，可接受；若手感反馈过差，
  上调 `swing_dmg` 到 4 即可（一档数字，不动结构）。
- 移速惩罚的验证口径：W10+ 敌人速度 1.1 倍后 jelly 追速 1.87；大剑 4.59 仍远高于此，
  走位不被追死；真正风险是贴身 LUNGE（11×1.1），靠斩中击退 + 无敌帧（0.9s）兜底。

---

## 5. 核心设计（三）：技能树扩展点（长线愿景的最小落子）

### 5.1 目标

"每武器独立技能树"是本项目长线愿景。**M5 只保证：换武器之后，"树的形态、每个节点改谁、
解锁到什么程度"这些信息有地方放、能被读、能被无头断言**——不画 UI、不结算成长、不消耗金币。

### 5.2 最小结构

**(1) 树定义挂武器（数据）**——`WeaponDef.tree`（§3.2），结构：

```gdscript
{
  "title": "泡泡枪·泡泡弹幕树",          # 预留（树名，本期 UI 不用）
  "nodes": [
    {
      "id": "fan_count",                 # 节点 ID（写进代码的唯一句柄）
      "tier": 1,                          # 层（1 为根；解锁只允许从已解锁层的可连节点推进）
      "depends_on": [],                   # 依赖的前置节点（空 = 根）
      "name": "弹数 +1",
      "effect": "fan 扇形弹 +1 发",        # 人类可读文案（未来 UI 直接读）
      "max_level": 1,                     # 本次全是 1 级节点（布尔式解锁）
      "cost": 10,                         # 未来金币消耗（本期不结算）
      "apply": "fan_count+1"              # 效果句柄字符串 → 未来 BoomGame 查表应用
    },
    { "id": "recoil_reduce", "tier": 1, "depends_on": [], ... },
    { "id": "chain_jump+1", "tier": 2, "depends_on": ["fan_count"], ... }
  ]
}
```

**(2) 运行时解锁态（状态）**——新增纯逻辑 `class_name BoomSkillTree`（extends RefCounted，零 UI）：
- `var points: Dictionary = {}`（key = `weapon_id`，value = `Dictionary[node_id → level]`）；
- API：`unlocked(weapon_id, node_id) -> bool` / `query_effects(weapon_id) -> Dictionary`
  （把已解锁节点的 `apply` 句柄汇总成 `{handle: level}` 给 BoomGame 消费）/ `grant(weapon_id, node_id)`
  （**本期仅供测试与预留，不接入任何经济**）。
- 消费侧约定：BoomGame 在各 `cast_*` 入口读 `query_effects(当前武器)` 对既有常量做**乘/加**修正。
  本期两个武器 tree 都为空树 → 消费侧自然退化 = 现状，CI 不受扰。

**(3) 武器专属技能 kit（延展点，本期不启用）**——`WeaponDef.skill_kit_id` 指向一张静态表
`{main_slot: "fan", left_slot: "chain", right_slot: "nuke"}`；本期 bubble/greatsword 均指向
默认 core kit。未来某武器解锁"专属技能"= 登记一个新 kit + 技能树终结点改变 kit 引用，
**槽位与手势仍不变**，只换槽内技能数据——这是 1d 决策能向后兼容的保障。

### 5.3 明确不落（防范围蔓延）

- ❌ 不做技能树 UI / 节点图绘制 / 购买交互 / 金币消耗结算。
- ❌ 不做存档持久化（`user://` 本地档留后续；BoomSkillTree 先内存态）。
- ❌ 不做成长对既有 130 断言的任何扰动（空树 = 恒等）。

---

## 6. 动画需求规格清单（Codex 素材生成与引擎表现的唯一来源）

### 6.0 落地路线总纲：2D 雪碧图动画管线

- **载体**：玩家换 2D 后，身体用 **AnimatedSprite3D**（继承 Sprite3D，支持 `billboard` +
  `sprite_frames`，Godot 4 原生）替换现 `Sprite3D _art` 单帧；`_art` 的可见性翻转/受击逻辑
  继续作用于该节点。`billboard = BILLBOARD_ENABLED`（保持现状的面向相机）。
- **帧图规范（全局统一，所有角色动画遵守）**：
  - 单帧画布 **256×256 px，透明底**；帧内角色内容 ≤ 85% 安全区（即≤220px 高、≤200px 宽），
    底部留 8px 地线空隙便于对齐；**无黑描边**（用暖棕 #B86A30 系轮廓）。
  - **横向帧条**存储：一个动画 = 1 张 PNG = `帧数×256` 宽 ×256 高（水平无缝拼接，帧间无间隙
    无 padding）；帧坐标元数据写进代码常量表（`player_anims.gd` 或 BoomPlayer 内 const），
    SpriteFrames 用 AtlasTexture 按 `Rect2(col*256,0,256,256)` 切帧——**不依赖编辑器动画**、
    无 .import 动画配置，CI 可断言帧数。
  - **单文件 ≤512KB 门禁**：卡通平涂压缩率极高，256 宽横条在 ≤8 帧（2048×256）下通常
    <200KB；如超限优先降帧（§6.1 每项给了建议帧数下限）。
  - **世界尺寸换算公式**：`pixel_size = 目标世界高 ÷ 内容像素高`。玩家目标占位约 1.9 世界单位
    （半径 0.55 → 直径 1.1 的"矮胖"体态向上取 1.9 含呆毛），若内容 200px → `pixel_size≈0.0095`；
    挂点 y ≈ 0.95 使脚贴地（`_art.position.y` 相应重构）。此公式供实现换算，最终以真机目检微调。
- **同源双形态原则**（对应需求 3 决策，详 §7.3）：两形态**共用身体比例/配色/五官/肚白斑**，
  仅武器与持械臂/动作差异；`hurt` 两形态共用同一帧条。

### 6.1 玩家本体动画（每项给 动作名/触发/帧数/循环/尺寸/落地/必须素材）

| 动作名 | 触发条件 | 建议帧数 | 循环/单次 | 单帧尺寸(px) | 落地方式 | 必须雪碧图素材? |
|---|---|---|---|---|---|---|
| `bubble_idle` | 无敌人入斩程/移动归零时（泡泡形态常驻） | 4 | 循环（≈6fps，呼吸起伏+呆毛晃） | 256×256 画布/内容≤220px | AnimatedSprite3D 帧条；下摆 y±0.03 呼吸可叠加 Tween | **是**（第一优先） |
| `bubble_move` | |dx|>0（泡泡形态） | 6 | 循环（≈12fps，小步快挪+左右倾） | 同上 | **是** |
| `bubble_recoil` | 每次开火（0.22s/发） | 3 | 单次（≈24fps，0.125s，后坐 1~2px + 枪口闪光位） | 同上 | 帧条单次；粒子枪口闪仍走 BoomSkillFx muzzle_flash | **是**（可接受先纯程序化后坐，建议做帧） |
| `sword_idle` | 大剑形态待机 | 4 | 循环（≈6fps，剑肩扛微晃） | 同上 | 帧条 | **是** |
| `sword_move` | 大剑形态移动 | 6 | 循环（≈12fps，步伐更沉、身体更倾，剑随身晃） | 同上 | 帧条 | **是** |
| `sword_swing` | 斩击 active 段 | 8（蓄 3/抡 2/定 1/收 2） | 单次（≈30fps，0.27s 攻帧；后摇 0.34s 由逻辑空窗接管，动画提前归 idle） | 同上 | 帧条 + 斩迹 ImmediateMesh 弧 + 命中爆浆粒子 | **是**（大剑灵魂，必须） |
| `hurt_shared` | `take_damage` 瞬间（两形态共用） | 2 | 单次（0.12s 后回 idle/walk） | 同上 | 帧条 2 帧 + **modulate 白闪**（SpriteBase3D.modulate 拉白→衰减，修复现"贴图态闪白无效"缺口） | **否**（可用 modulate 程序化；2 帧表情帧可选增强） |

> 附注：现 `physics_update` 的闪烁（`_art.visible` 翻转）与呼吸 bob（`:177-179`）在新管线中
> 保留（作用于 AnimatedSprite3D 节点），无敌闪烁建议改**modulate alpha 脉冲**而非硬切 visible
> （对帧动画更柔和），细节留实现。

### 6.2 敌人 jelly（现状核实见 §2.3：程序化球 + PNG 立绘混合）

需求"出生/受击/死亡"三项现状皆缺（出生瞬时出现、受击白闪不可见、死亡即消失由粒子兜底）。
**决策：敌人本批全部走引擎程序化，不生成雪碧序列帧**（省 Codex 预算给玩家/武器；敌人是
"被爆的耗材"，爆发爽感靠粒子而非细腻动画）：

| 动作名 | 触发 | 建议规格 | 循环/单次 | 尺寸 | 落地方式 | 必须素材? |
|---|---|---|---|---|---|---|
| `jelly_spawn` | `spawn_enemy_at` 入列时 | 0.18s 弹出：scale 0→1（TRANS_BACK 过冲 1.15→1）+ 透明→不透明 | 单次 | 沿用现有 PNG 尺寸（pixel_size 0.0031/0.00325） | Tween 驱动节点 scale + Sprite3D modulate:a | **否** |
| `jelly_hit` | `take_damage` | 0.10s 白闪（modulate 拉白→衰减）+ 已有 squash&stretch 加强一档（`squash_impact` 触发现逻辑）+ 击退 | 单次 | 同上 | **修复缺口**：白闪改作用在 `_art.modulate`（现 body_mat emission 在贴图态不可见）；受击瞬间可选加 1 帧"扁嘴"表情（增强项） | **否** |
| `jelly_die` | `_finalize_kill` | 0.20s 收尾：压扁 0.15s + 上抛淡出（粒子 goo_burst 已有，改"先压扁再爆"时序）；爆点沿用 8 粒果冻粒子 + 击杀白闪 | 单次 | — | 新增「死亡表现窗」：jelly 置 `_dead` 后不立即 free，由表现层 Tween 完成后 `queue_free`（**需与 boom_game 的 remove_child 时序协调**，见 §8 R3） | **否**（压扁/粒子/白闪全程序化） |

> 精英：体型差 + telegraph 放大已表达（M4），M5 不追加精英专属帧。

### 6.3 战斗反馈升级点（命中爆浆 / 飘字节奏 / 震屏）

| 反馈 | 现状（代码核实） | M5 升级规格 | 落地方式 | 必须素材? |
|---|---|---|---|---|
| 命中爆浆 | 命中 `fx.puff(…,6)` 小粒（main.gd:316-321）；击杀 `goo_burst` + `scorch` | 按伤害分级：普攻命中 puff 6→按 dmg 缩放（大剑 3 伤 = 12 粒 + 轻微 scale-up）；命中同时敌人 squash 已触发（叠加） | 调 BoomFx.puff 参数（count 由调用方传入），零新节点 | **否** |
| 飘字节奏 | 命中每发白字 "1"；击杀金 "+10" 连杀放大 1.3×（main.gd:334-336）；技能三档字号 | ① 普通命中飘字**降频合并**：同 0.15s 窗内同一目标只出 1 个（防刷屏）② 大剑 3 伤字 1.15×、斩击杀沿用 1.3× 放大 ③ 精英首斩（命中精英）字加 "!" 后缀（红字白描边，增强项） | 在 BoomHitNum 加 0.15s 去重窗 + spawn 参数透传；纯参数改动 | **否** |
| 震屏升级 | 命中 0.05 / chain 0.3 / nuke 0.6 / 受击 0.65 / 击杀衰减（boom_cam 参数） | ① 大剑命中 0.25（新档位）② 精英斩杀 +0.1（既有档内加）③ 方向性震屏增强项（横向位移）仅记录，不实现 | `cam.add_trauma` 入参 + 新档位常量 | **否** |

### 6.4 技能特效升级（Fan / Chain / Nuke 视觉）

现状：Fan=枪口闪光粒子、Chain=ImmediateMesh 抖动电弧 + 端火花、Nuke=躺平扩散圆环 +
金色粒子爆（BoomSkillFx 全部程序化，M2 §4.2 收口）。M5 **不推翻程序化路线**，只补"更贵"
的一层；**技能图标素材已存在（skill_fan/chain/nuke.png）不重出**：

| 技能 | 升级点 | 规格 | 落地方式 | 必须素材? |
|---|---|---|---|---|
| Fan | 弹体拖尾 + 命中爆泡 | 扇形 5 发每发加 2px 泡泡拖尾（粒子）；命中点 6→10 个小白点 + 泡泡形闪烁 | CPUParticles3D 追加拖尾发射器（对象池复用 BoomSkillFx 模式）；hitnum 已有 | **否** |
| Chain | 链头光标 + 跳转火花 | 起跳点 0.3s 高亮星闪（白心亮青芒）；每跳落点爆 4 粒黄闪；电弧宽度 0.09→0.11 加粗一档 | 复用现有 `_build_emitter` / `arc_bolt` 参数化 | **否**（星芒 64×64 贴图**可选**增强） |
| Nuke | 双层环 + 热浪蘑菇 | 冲击波外层 + 内圈反向小环（0.25s 错相）；中心柱状热浪（12 粒竖向上抛金粒，0.5s） | `shockwave` 参数化双层 + `burst` 改 direction=UP；全 CPUParticles | **否** |
| （武器选单） | 大剑卡预览 | 见 §3.3 复用 idle 帧 | — | 复用 §6.1 帧条 |

---

## 7. 素材需求汇总（Codex 生成清单 + 删稿清单）

### 7.1 生成清单（snake_case，路径均在 `games/boom/assets/images/` 下）

> 全部遵循 art_bible prompt 骨架（高饱和暖色 3D 卡通、透明底、无文字、暖棕轮廓、
> 亮青=我方火力）。Codex 出图后须压到单文件 <512KB 并过 `check_sprite_sheet.py` 式自检。

| # | 文件名（建议） | 内容 | 规格 | 优先级 |
|---|---|---|---|---|
| 1 | `characters/player_bubble_idle.png` | 泡泡队长·泡泡形态待机（持泡泡枪） | 4 帧横条 1024×256，内容≤220px | P0 |
| 2 | `characters/player_bubble_move.png` | 同上·移动 | 6 帧横条 1536×256 | P0 |
| 3 | `characters/player_bubble_recoil.png` | 同上·开火后座 | 3 帧横条 768×256 | P1 |
| 4 | `characters/player_sword_idle.png` | 泡泡队长·大剑形态待机（同源造型 + 大剑） | 4 帧横条 1024×256 | P0 |
| 5 | `characters/player_sword_move.png` | 同上·移动（更沉） | 6 帧横条 1536×256 | P0 |
| 6 | `characters/player_sword_swing.png` | 同上·弧斩全套（蓄/抡/定/收 8 帧） | 8 帧横条 2048×256 | P0 |
| 7 | `characters/player_hurt.png` | 受击（两形态共用） | 2 帧横条 512×256 | P1（程序化 modulate 可先顶） |
| 8 | `icons/weapon_bubble.png` | 武器图标·泡泡枪（圆底徽章，亮青泡泡+暖橙枪身） | 128×128 独立 | P1 |
| 9 | `icons/weapon_sword.png` | 武器图标·大剑（圆底徽章，暖橙刃+奶油白柄，无黑描边） | 128×128 独立 | P1 |
| — | （可选）`fx/spark_star.png` | Chain 星闪 / Nuke 热浪用 64×64 星形 | 64×64 | P2（全程序化可跳过） |

同源规格写入每张图的 prompt：`同 Bubble Captain 人设：暖橙圆胶囊身(#FF8A3D)、亮青大护目镜
(#2BD9FF)、呆毛+肚白斑(#FFF6E8)，四分之三侧俯视角，玩具感无描边轮廓用暖棕；除武器与持械姿势外
身体完全一致（供两形态间复用/对齐）。`

### 7.2 删稿清单（milk frog 废弃，本批删除；**勿提交前先改代码引用**）

| 路径（games/boom/） | 内容 | 处理 |
|---|---|---|
| `scenes/player/milk_frog_3d.tscn` | 废弃 3D 玩家场景 | 删除（连同空掉的 scenes/player/ 目录） |
| `scripts/core/milk_frog_3d.gd` | MilkFrog3D 脚本（class_name） | 删除 |
| `assets/models/milk_frog/*`（milk_frog.glb / milk_frog_0.png + .import） | GLB 模型 + 贴图 | 删除 |
| `assets/images/characters/milk_frog_hero.png`（+ .import） | 主立绘回退 | 删除（回退链由新 AnimatedSprite3D 取代） |
| `assets/review/milk_frog_model/*` | 建模评审截图 | 删除 |
| `tools/milkfrog/`（index.html / milkfrog.js / exports/*） | Three.js 建模评审工具 | 删除 |
| `tools/render_milk_frog_views.gd`（+ .uid） | 渲染评审工具 | 删除 |
| `assets/images/references/milk_frog_*.png`（idle/laugh 四件 + .import） | 奶蛙参考图 | 删除 |
| `tools/process_cutout.py` | 如仅服务于奶蛙抠图则删（**先确认无其他消费方**） | 待核 |
| **代码引用（改，不删文件本身）** | boom_player.gd:93-118（删①奶蛙分支，新 2D 分支）；play_test.gd:120-125（MilkFrog3D 断言→改为断言默认玩家动画节点/帧条可加载）、:131-137（素材清单换新）；ART_REQUEST.md（内容改写为新玩家） | 必改 |

> 删除后 `.godot/imported/` 与 .uid 缓存由 Godot 启动自愈；CI 前跑一遍 play_test 即可暴露残留引用。

### 7.3 需求 3 决策：新 2D 角色 = **同一角色双形态**（泡泡队长·远程/近战形态）

**决策：不引入第二个角色，采用「同源双形态」——泡泡枪与大剑是同一个 Bubble Captain 的
两种装备形态；形态决定动画集与武器外观，不是两个独立角色。**

理由：

1. **IP 与美术基线连续性**：art_bible §7 与 ART_REQUEST 已确立暖橙"泡泡队长"唯一主角语义
   （全屏唯一大块暖橙）。另起"大剑武士"会破坏"暖橙=我"的读图铁律，且双主角稀释买量识别度。
2. **素材成本翻倍不值得**：独立角色 = 全套 idle/walk/hurt/攻击各一套（约 2 倍帧数）。
   同源双形态只差武器 + 持械姿势 + 斩击全身演出（§6.1 清单约 6 条帧条，其中 hurt 共用），
   节省近半生成预算，还能保证两形态动作剪影一致、切形态不跳戏。
3. **动画结构收益**：身体/受击/移动可同源（prompt 级约束），`anim_set_id` 只做"形态切换
   （换 SpriteFrames 组）"而非"换角色节点"——BoomPlayer 的闪烁/受击/bob 逻辑一套代码
   覆盖两形态，符合"换武器=换外观/动画集"的长线愿景。
4. **挂点方案的取舍**：纯"固定角色 + 武器挂点"无法表达大剑的整身劈砍剪影（"势大力沉"
   必须靠全身姿态），所以武器不能只是挂点小件；但挂点思想被吸收为"形态层"——武器差异
   收敛到形态动画集内，不做引擎层武器骨骼挂接（省一整套骨骼/挂点对齐工作）。

---

## 8. 落地分期与风险

### 8.1 分期建议

| 阶段 | 内容 | 出口标准（验收） |
|---|---|---|
| **P1 数据与逻辑层** | `BoomWeaponDef`/`BoomWeapons`；BoomGame `set_weapon/begin_match` 拆分；大剑斩击 FSM（纯逻辑）；默认武器恒 bubble | play_test 新增：默认武器参数=现状回归全绿；`set_weapon("greatsword")` 后斩击伤害/范围/上限/顿帧可断言 |
| **P2 选武器 UX** | 选单面板（代码构建）+ 输入守卫 + 血条重建 + 结算"再来一局"回选单；测试模式自动跳过 | 目检：开局面板 → 选大剑 → 7 格血条 → 开局；结算 → 再选枪可切换 |
| **P3 删稿与玩家 2D 化** | 删 §7.2 清单 + boom_player 改 AnimatedSprite3D + 同步 play_test 断言 | 全量 play_test 绿；无头 smoke 断言新默认玩家帧条可加载；奶蛙零残留引用 |
| **P4 素材接入与打磨** | Codex 出 §7.1 素材 → 接 SpriteFrames → 大剑/泡泡反馈参数落地 | 真机目检两形态：后座/斩击/受击 modulate 白闪肉眼可辨；两形态同屏 0.5s 可辨 |
| **P5 动画打磨增强** | §6.3/6.4 升级点（去重飘字、爆浆分级、技能特效增量） | vision-e2e 截图 + 目检；512KB 门禁过 |

> 顺序理由：先逻辑后表现（P1 保 CI），先删后立（P3 在 P4 素材前清干净），避免"背着
> 废弃模型长新功能"。

### 8.2 风险与对策

| # | 风险 | 等级 | 对策 |
|---|---|---|---|
| R1 | **删奶蛙触发 play_test 失败**（:120-125 断言 MilkFrog3D、:131 断言 milk_frog_hero.png） | 高 | 删稿与代码改动同 PR；P3 明确列为"改断言 + 删素材"一体化任务；CI 前置跑 `godot --headless --path games/boom --script res://tools/play_test.gd` |
| R2 | **默认武器/默认参数漂移**导致存量 130 断言大面积崩 | 高 | `BoomWeapons.default_id()="bubble"` 且泡泡枪参数逐字等于现常量（FIRE_CD=0.22/BULLET_DMG=1/HP=5）；restart() 保留原语义 |
| R3 | **大剑死亡表现时序与 boom_game 立刻 free 冲突**（现 `_finalize_kill` 同步 remove_child+free） | 中 | 表现窗做成"纯视觉延迟销毁"：jelly 置 dead 后移出逻辑数组（enemies）但延迟 queue_free，由 BoomJelly 自身 Tween 完成后再 free；不阻塞击杀结算（分数/连击/信号即时发） |
| R4 | **玩家视觉形态切换回归影响既有闪烁/受击**（现 `_body/_art/_model` 三态互斥逻辑） | 中 | P3 重构收敛为单一 AnimatedSprite3D 持有者；无敌改 modulate 脉冲；play_test smoke 加"默认形态节点存在"断言兜底 |
| R5 | **技能/子弹对 `player.muzzle` 的硬依赖**（boom_game.gd:199/333） | 中 | 新外观保留 muzzle 锚点（泡泡形态枪口语义位、大剑形态可指向前上方）；不随形态删除 |
| R6 | **素材超 512KB 门禁 / 双形态"同源"漂移** | 中 | §6.0 帧条 + §7 prompt 同源约束 + 出图自检（尺寸/门禁/透明底）；若超限先砍帧数后砍分辨率 |
| R7 | **选单态与手势/摇杆抢占** | 中 | main.gd `_input`/摇杆 `_try_claim` 加选单态守卫（比现 `SKILL_ZONE_X` 判更早 return）；选单层 mouse_filter=STOP |
| R8 | **大剑手感失衡（清群过强 / 打精英过慢）** | 中 | 数值全收敛在 WeaponDef 常量可调：swing_dmg 3↔4、arc 120~170°、max_targets 6↔8、周期 0.7~0.9；真机后按 M4 同款"调参不改结构"处理 |
| R9 | **wave_started 前置**：现 `BoomGame._init` 即发波，选单期间若玩家停留，W1 会在后台开刷 | 高 | `_init` 不自动开波（见 3.3 注入时机拆分）；测试路径显式调 `begin_match()`；smoke 的 wave==1 断言在 begin 前不变 |

### 8.3 验收清单（勾选即 M5 收口）

- [ ] P1：play_test 全绿，含新增 `set_weapon`/斩击断言；默认武器回归零改动。
- [ ] P2：真机从启动到 W1 必经选单；大剑形态 7 格血条；结算可回选单换武器再战。
- [ ] P3：milk frog 相关文件零残留（grep `milk|MilkFrog` 仅命中历史文档可留或一并清理）。
- [ ] P4：两形态 2D 动画全接入；受击 modulate 白闪可见；大剑斩击动作/斩迹/顿帧规格达成。
- [ ] P5：素材全过 512KB 门禁；§6.3/6.4 反馈与特效升级点落地并目检。
- [ ] 技能三槽 / 手势 / CD / 飘字映射与 M2 规格一致（改动前后断言比对通过）。
