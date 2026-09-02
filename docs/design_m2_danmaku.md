# 《砰砰小队》M2 设计 — 弹幕与技能系统（接 M1 自动瞄准地基）

> 接 `docs/design_boom.md` M1 已落地的"自动瞄准 + 自动开火"垂直切片，本文档落地 M2：
> 给玩家**手动技能**（屏幕点选 + swipe 触发），让战斗从"全自动炮台"升级到"节奏型弹幕
> 解压"。所有设计继续服务**竖屏单手**和**移动端 60~90 秒一关**的总目标。

---

## 1. 一句话定位（M2 增量）

**左手摇杆走位 + 右手屏幕做"手势技能"——点 / 滑 / 长按，三种动作对应三个技能槽位，
节奏感是"平时自动炮台 + 关键时刻甩一手弹幕爆发"。**

M1 的"自动开火"是 60% 输出，M2 的"手动技能"补到 100%——既保留解压的轻负担，
又给玩家"主动掀桌子"的爆点瞬间。

---

## 2. 输入模型：摇杆 + 屏幕手势 共存

### 2.1 输入分配（M2 新增 / 不改 M1）

| 动作 | 触发 | 备注 |
|---|---|---|
| 走位 | 左手 DYNAMIC 虚拟摇杆（M1 已修） | 不变 |
| 自动开火 | `_physics_process` 按当前目标 + 攻速定时发射（M1） | 不变 |
| **主技能** | 右手屏幕**点击**（tap ≤200ms 抬手） | M2 新增 |
| **备用技能 A** | 右手屏幕**向左 swipe**（dx < -120px 且 |dx| > 2|dy|） | M2 新增 |
| **备用技能 B** | 右手屏幕**向右 swipe**（dx > +120px 且 |dx| > 2|dy|） | M2 新增 |

### 2.2 与 DYNAMIC 摇杆的输入冲突解决

DYNAMIC 摇杆也是 `_input` 监听触摸，必须分流避免"点屏幕 = 摇杆跳到那"。

策略（实现细节见 §6.1）：
- **触点落点决定归属**：触点 x < 屏宽 35% → 走摇杆路径；x > 屏宽 35% → 走技能路径
- DYNAMIC 摇杆仅认领屏幕左侧 35% 区域内的触点；右侧触点直接进入技能系统
- 这与 M1 已修复的"全屏可达"**不冲突**——`_try_claim` 加一个 `_in_joystick_region(pos)` 判定，
  非摇杆区域触点不进 `_pointers`，自然转交技能 handler

### 2.3 屏幕手势识别（已按实现回写实测参数，常量见 `main.gd`）

- **技能区分界**：触点 x > 屏宽 × 0.65（`SKILL_ZONE_X = 0.65`）→ 进入技能手势区。
  设计理由：与虚拟摇杆 `exclude_right_x = 0.65` 的排除区分界一致，右区触摸全部路由给
  技能手势，左右互不争抢
- **Tap**：按下到释放 ≤ 200ms（`TAP_MAX_TIME = 0.20s`）且累计位移 ≤ 14px
  （`TAP_MAX_DIST = 14.0`）→ 主技能；起手落在技能按钮圆内（含 12px 容错）则
  直接触发对应按钮技能，其余 tap 维持主技能
- **Swipe**：水平主位移 |dx| ≥ 110px（`SWIPE_MIN_DIST = 110.0`）且 |dx| > 2|dy| →
  备用技能（左滑闪电链 / 右滑核爆）；不设时长上限，抬手时按位移与长宽比判定
- **Hold / 无效手势**：右区不满足 tap 或 swipe 条件的触点抬手后直接丢弃，不触发技能；
  左区触点始终归摇杆
- 三个手势互斥；任何手势触发后该触点的 `touchend` 不再二次触发

---

## 3. 技能槽位与 CD 表

### 3.1 槽位模型

3 个技能共享一个 `cooldowns: Dictionary[name → remaining]`，由 `BoomSkillSystem`（M2 新模块）集中管理：

```
[主槽] boom_fan      —— 默认装备，3s CD，扇形5发
[左槽] boom_chain    —— 默认装备，8s CD，链式3目标
[右槽] boom_nuke     —— 默认装备，20s CD，全屏 AOE
```

CD 期间对应按钮图标变灰 + 倒计时数字；M1 已有 `_toast: Label` 可复用显示
"技能就绪"。

### 3.2 首期技能清单（3 个，均为"无目标也可用"——降低学习成本）

| 名 | 触发 | 效果 | CD | 解锁/升级（M3+ 留口） |
|---|---|---|---|---|
| **爆裂弹幕** (boom_fan) | Tap | 朝最近敌人方向射 5 发扇形散弹，伤害=BULLET_DMG，每发 ±15° 散布 | 3.0s | 后续：扇形角度/弹数 |
| **闪电链** (boom_chain) | ← swipe | 以最近敌人为起点链式弹跳 3 目标，每跳衰减 70%，弹道可视 | 8.0s | 后续：链数/跳距/减速 |
| **核爆** (boom_nuke) | → swipe | 玩家中心半径 6m AOE，伤害=BULLET_DMG×4，屏震 + 0.12s hitstop | 20.0s | 后续：半径/伤害 |

设计原则：
- **三个技能视觉与节奏完全不一样**：弹幕是"快"，闪电链是"长"，核爆是"重"
- **CD 阶梯 3/8/20**——错峰，玩家永远有一个技能"在线"
- **不用资源/能量**——CD 即可，避免"攒能量"打断节奏

---

## 4. 弹道与特效系统

### 4.1 弹道变体（复用 `BoomBullet`）

M1 的 `BoomBullet` 是单发直线弹。M2 加 3 个变体（共 1 个基类 + 3 个参数集）：

| 变体 | 字段 | 渲染 | 命中 |
|---|---|---|---|
| `straight`（M1） | `dir, speed, dmg` | 默认白球 | 单目标直击 |
| `fan_shot` | `dir, spread_deg=15, count=5` | 小白球 + 轻微拖尾 | 单目标直击 |
| `chain_arc` | `target, bounce=2, decay=0.7` | 黄色电弧 + 闪光 | 单目标直击后弹跳 |
| `nuke_aoe` | `center_pos, radius=6.0, dmg_mult=4.0` | 无可视弹（瞬间 AOE） | 半径内所有敌人瞬伤 |

实现路径：M1 的 `BoomBullet` 已支持 `active` + 命中逻辑；M2 在 `BoomBullet` 加
`variant: String` 字段，`_physics_process` 据此分支；或新建 3 个 `extends BoomBullet`
子类（更干净，文件多）。

**推荐后者**：3 个子类 + 共享 `_hit_logic()`，对应弹道独立测试。

### 4.2 视觉/反馈（接 M1 飘字/白闪/顿帧）

每个技能触发都接 M1 已落地的反馈四件套：

| 技能 | hitstop | 震屏 | 白闪 | 飘字 |
|---|---|---|---|---|
| 爆裂弹幕 | — | 极轻（FastNoiseLite × 0.3） | — | "嘭!" 黄色小字（每个命中 1 个） |
| 闪电链 | 0.06s（首跳） | 中（× 0.6） | 0.10 alpha 30ms | "链!" 紫色大字 1 个 |
| 核爆 | **0.14s** | 重（× 1.2） | 0.15 alpha 60ms | "轰!" 金色巨型 + 数字 |

> 注：nuke 白闪峰值按防晕铁律收口为 0.15（原 0.20），M3 复检确认观感可接受。

> 核爆的 hitstop 0.14s 略超 M1 防晕铁律的 80ms——但 AOE 是"事件型"非"连续命中型"，
> 群主目检已接受类似一次性大反馈，可保留；后续若反馈"晕"再下调。

### 4.3 粒子复用

M1 `boom_fx.gd` 已有 `_scorch` / `_spawn_particles` / `_fade_scorch`（本轮已修）。
M2 新增 `_spawn_burst(pos, color, count)` 通用粒子爆，用于：
- 爆裂弹幕：每个命中点 6 个小白点
- 闪电链：每个命中点 4 个黄闪点
- 核爆：玩家中心 60 个金色粒子爆

---

## 5. UI 与 HUD

### 5.1 屏幕右侧技能按钮（M2 新增）

- 3 个圆形大按钮（半径 ~50px），竖排于屏幕右下角，纵向间距 24px
- 顶 = 主技能（Tap 提示"/图标：爆裂"），中 = 备用 A（左箭头 / 闪电），底 = 备用 B（右箭头 / 核爆）
- CD 中：圆形进度环顺时针倒计时 + 内部数字
- 按钮区下沿距屏底 ~24px（避 iPhone home indicator）
- **可点击区域**：按钮本身 + 周边 12px 容错（拇指区）；同时整个屏幕右侧仍可 swipe

### 5.2 与摇杆的可视区分

- 摇杆：左下，浅灰环 + 灰帽（M1）
- 技能按钮：右下，金色描边 + 彩色填充，明确"这是技能"
- 战斗中不显示按钮文字 label（M2 首期），靠图标与手势记忆

### 5.3 不引入的 UI（避免过载）

- 不显示技能 MP / 能量条（CD 即可）
- 不显示冷却完成 toast（图标亮起来就够）
- 不显示"按住 X 触发 Y"提示（手势自解释）

---

## 6. 关键工程实现

### 6.1 输入分流（`BoomInput` 或在 `BoomGame` 内）

```gdscript
# 伪代码（非最终代码）
func _input(event: InputEvent) -> void:
    if event is InputEventScreenTouch:
        var is_right := event.position.x > get_viewport_rect().size.x * 0.35
        if is_right:
            _skill_input.handle(event)   # 屏幕右侧触点 → 技能
        else:
            joystick.try_claim(event)    # 屏幕左侧 → 摇杆
    elif event is InputEventScreenDrag:
        if event.position.x > get_viewport_rect().size.x * 0.35:
            _skill_input.handle_drag(event)
```

虚拟摇杆需在 `_try_claim` 加 `_in_joystick_region(pos)` 限制（左侧 35%），避免"右侧点
击抢了摇杆触点 index"导致技能触发后摇杆以为还在按。

### 6.2 技能系统骨架（`BoomSkillSystem`）

```
scripts/core/boom_skill.gd            —— 技能基类（name, cd, _ready, try_fire, _on_cd_done）
scripts/core/boom_skill_fan.gd        —— 爆裂弹幕
scripts/core/boom_skill_chain.gd      —— 闪电链
scripts/core/boom_skill_nuke.gd       —— 核爆
scripts/core/boom_skill_system.gd     —— 槽位表 + CD tick + 手势→技能映射
```

`BoomSkillSystem` 关键 API：
- `try_tap()` / `try_swipe_left()` / `try_swipe_right()`
- `tick_cooldowns(dt)` —— 每帧减 CD，CD 归零发 `skill_ready(name)` 信号
- `current_cooldowns() -> Dictionary` —— 供 HUD 渲染

### 6.3 手势识别（轻量级，在 `BoomSkillSystem` 内）

不需要引入完整 gesture detector，3 种动作 30 行可解：
```
on touchstart: 记录 start_pos, start_time
on touchmove:   累积 max_dx/dy
on touchend:    elapsed = now - start_time
  if elapsed < 200ms and max_dx < 12px: try_tap()
  elif max_dx < -120 and abs(max_dx) > 2*abs(max_dy): try_swipe_left()
  elif max_dx > +120 and abs(max_dx) > 2*abs(max_dy): try_swipe_right()
  else: 取消（视为无效手势）
```

### 6.4 与 M1 已有模块的接入点

| M1 模块 | M2 接入方式 |
|---|---|
| `BoomGame` | `BoomSkillSystem` 作为子节点挂到 `sim`；`_physics_process` 调 `tick_cooldowns(dt)` |
| `BoomBullet` | 3 个 `extends BoomBullet` 子类，独立 `scene/boom_bullet_*.tscn`（程序化 MeshInstance3D） |
| `BoomFx` | 新增 `_spawn_burst(pos, color, count)`，技能触发时调 |
| `BoomHitNum` | 技能命中调 `hitnum.spawn(pos, "嘭!", color, scale)` |
| `BoomPlayer` | `_on_kill` 已有顿帧；技能触发直接调 `player.trigger_hitstop(s)` + `world.fx.flash(s)` |
| `BoomCam` | `world.cam.shake(intensity, dur)` 已存在；技能触发传入强度 |
| `main.gd` | HUD 加 3 个技能按钮（程序化），绑定到 `_skill_system` 信号 |

---

## 7. 节奏表（典型 90s 战斗的技能释放点）

| 时间 | 事件 | 玩家动作 |
|---|---|---|
| 0:00 | 关卡开始，1~3 敌人 spawn | 摇杆找角度，自动开火 |
| 0:10 | 第一波 enemy 出现 | 右滑 swipe → **核爆**（CD 20s）清理 |
| 0:25 | 第二波密集 | 点击 → **爆裂弹幕** × 2 间隔 3s |
| 0:40 | 单个远点精英 | 左滑 swipe → **闪电链**处理 |
| 0:55 | boss 出现 | 持续自动开火 + 屏幕点击 → **爆裂** |
| 1:00 | boss 半血 | **核爆**（CD 早结束）+ 命中 0.14s hitstop |
| 1:15 | 清场 | swipe/click 中场收割 |
| 1:25 | 通关 | 三选一升级（未来） |

CD 3/8/20s 保证 90s 关卡能各放 4/2/1 次以上，玩家不卡手。

---

## 8. 验收标准（vision-e2e 场景草案）

### 8.1 headless 逻辑断言（`tools/play_test.gd`）

新增：
- 技能在 CD 中连发 → 只触发 1 次
- CD 归零后第二次能触发
- 爆裂弹幕 5 发总数命中 1 敌人 → 5 次 hit
- 闪电链 3 跳命中 3 不同敌人 → chain_count=3
- 核爆半径 6m 内所有敌人全伤

### 8.2 vision-e2e 场景（`scenarios/boom/danmaku.yml`）

Given 主场景已加载
When 玩家点击屏幕右侧 → 触发爆裂弹幕
Then `kills += 5`（理想 5 命中）
And `__gameState.skill_cd.boom_fan > 0` 持续 ~3s
And 截图存在 5 个黄白飘字 + 5 处粒子爆

When 右滑 swipe → 触发核爆
Then `kills += 范围内敌人数`
And hitstop 触发后世界时间暂停 0.14s
And 白闪 alpha 峰值 ≥ 0.18

### 8.3 群主人工目检（移动端）

- 屏幕右侧点击 / swipe 响应即时
- 摇杆在左侧仍正常移动，不被技能误吞
- 三个技能视觉差异肉眼可辨（爆裂=多发小白；闪电=亮黄电弧；核爆=大金爆）
- CD 中按钮进度环 + 数字正确

---

## 9. 范围与不做（M2 不做的）

- ✗ 蓄力技 / 多段 combo
- ✗ 技能升级树（DBG，留 M3）
- ✗ 敌人变种 / Boss（M3）
- ✗ 主题关卡（M4）
- ✗ PvP / 异步对战（M5）
- ✗ 技能切换 / 装备选择（首期固定 3 技能）

---

## 10. 时间估计

| 步骤 | 工时 | 依赖 |
|---|---|---|
| 文档线（本文档） | 已完成 | — |
| 技能基类 + BoomSkillSystem 骨架 | 0.5d | 文档 |
| 3 个子类（fan/chain/nuke） + 3 个 bullet 子类 | 1.0d | 骨架 |
| 输入分流 + 手势识别 | 0.5d | — |
| HUD 技能按钮（程序化） | 0.3d | 骨架 |
| 特效（_spawn_burst） + 飘字/白闪/震屏接入 | 0.5d | 子弹子类 |
| play_test 逻辑断言扩展 | 0.3d | 子弹子类 |
| vision-e2e 场景 + 群主目检 | 0.4d | 全部 |
| **合计** | **~3.5d** | |

> 建议 4 天内出第一版（M2 完整），第 5 天打磨手感与 iPhone 真机目检。