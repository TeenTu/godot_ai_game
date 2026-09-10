# 《砰砰小队》M7 设计增量：局内成长三系统——属性 / 经验升级 / 技能树扩容（design_m7_progression.md）

> **状态（2026-09-08）**：本文的属性与经验章节已由 `docs/design_m8_attributes.md` 统一重写；技能树、跨局金币和装备槽章节仍可参考。

> 归属：`docs/design_boom.md` §9 里程碑 M7 · 前置：M4 波次系统（`design_m4_waves.md`）、
> M5 多武器（`design_m5_weapons.md`）已上线 · 本文为设计与落地记录（代码已同步实现）。
>
> **M7R 修订（本版）**：按群主复核拍板撤掉"不做跨局存档"红线，新增跨局持久存档
> （`BoomSave`）；技能池由全局共享改为**每武器独立 6 槽技能树**（用户原需求）；
> 属性点三选一为超出原规格的增补决策，知情保留。
>
> **M12 触发修订（2026-09-10）**：`equipped` 是最多 3 个主动/被动混排的构筑槽；
> tap / 左滑 / 右滑与战斗 HUD 改为读取 `active_equipped()`，被动只常驻生效，不再占用触发位。

---

## 1. 目标与范围

### 1.1 一句话目标

**一局之内，玩家的强度会随战斗生长：击杀攒经验、升级给属性点、跨局金币解锁新技能；
每把武器一棵 6 槽技能树，解锁进度与跨局金币持久保存——把"刷波次"变成"滚雪球"，
同时用「每局装备 ≤3」的硬约束保住三槽手势的决策深度。**

### 1.2 本次交付（M7 + M7R 落地边界）

| 交付 | 内容 | 落点 |
|---|---|---|
| D1 属性系统 | `BoomStats`：hp/speed/dmg 三系升级容器，落地到玩家机体 | `scripts/core/boom_stats.gd` |
| D2 经验升级 | `BoomExperience`：击杀入账 XP、线性升级曲线、升级产属性点 | `scripts/core/boom_experience.gd` |
| D3 每武器技能树 | 技能池 9 定义，bubble/sword 各一棵 6 槽树（共用 4 + 专属 2） | `boom_skill_system.gd` + `boom_weapon_def.gd` |
| D4 跨局存档 | `BoomSave`：`user://boom_save.json` 持久化跨局金币 + 双树解锁进度 | `scripts/core/boom_save.gd` |
| D5 金币解锁 | 树内顺序解锁，树首免费，其余 60/120/200/300/420 递增 | `BoomSkillSystem.try_unlock()` |
| D6 每局装备 ≤3 | 装备上限硬约束 + 手势槽位重映射（tap/←/→ = 装备 0/1/2） | `BoomSkillSystem.handle_slot()` |
| D7 选单技能配置区 | 选武器面板按当前武器显示 6 技能，解锁/勾选即点即得 | `scripts/ui/boom_weapon_select.gd` |
| D8 无头测试 | play_test 新增 `[m7-*]` 五节，目标 250+ 断言 | `tools/play_test.gd` |

### 1.3 明确不做 / 范围修正（M7R 修订）

- ✅ **跨局元进度持久化（M7R 起做）**：解锁进度 + 跨局金币进 `BoomSave`，
  `restart()` 只清局内状态（装备/冷却/成长/局内金币），不再清解锁与跨局币。
- ⚠️ **属性点自由消费 + 三系升级为超出原规格的增补决策**（群主知情保留）：
  原规格只要求经验升级；实现时直接给了 hp/speed/dmg 属性容器与自由消费入口，
  未做三选一 UI。保留不回退，后续如需三选一卡片在此之上扩展。
- ❌ **不做升级三选一 UI**：升级点由玩家对任意属性自由消费（`apply_level_upgrade`），
  不弹卡片选择；HUD 面板后续里程碑补。
- ❌ **不改动既有手势识别参数**：tap / ←swipe / →swipe 的识别与技能 HUD 布局不动，
  只是"手势→技能"的映射从硬编码改为按装备槽查表。
- ❌ **不改 M2–M5 存量数值**：所有加成默认为零，存量断言逐字通过。
- ⚠️ **解锁价 M7→M7R 变更**：ring 30→200、heal 25→200（树内顺序定价所致），
  属规格修正非数值漂移。

---

## 2. 现状与约束（读码核实，boom-dev）

- 金币经济已存在：`BoomGame.coins`（木箱 +1 / 精英雨 40），HUD 有金币计数（main.gd
  `_build_coin_hud`）——M7 解锁直接复用，**零新增经济系统**。
- 技能系统原为"三技能硬编码"：`BoomSkillSystem` 持有 fan/chain/nuke 三个 `BoomSkill`
  实例，手势 API（`handle_tap/handle_swipe_left/handle_swipe_right`）与技能一一绑定。
- 玩家机体数值由武器 def 注入（M5 `apply_weapon`），M7 起有局内成长通道。
- 击杀结算集中在 `BoomGame._finalize_kill()`——经验入账的天然挂点。

---

## 3. D1 属性系统 BoomStats（超出原规格的增补决策，知情保留）

### 3.1 结构

纯数据 `RefCounted`，零节点依赖：

```
BoomStats
├─ hp_stacks / speed_stacks / dmg_stacks   # 各系已消费档数
├─ apply(kind) -> bool                     # 消费一档（kind: "hp"/"speed"/"dmg"）
├─ max_hp_bonus() -> int                   # hp_stacks × 1
├─ move_mult() -> float                    # 1.08 ^ speed_stacks（乘算叠加）
└─ dmg_bonus() -> int                      # dmg_stacks × 1
```

### 3.2 数值表

| 升级 | 每档效果 | 落点（`BoomGame._apply_stats_to_player`） |
|---|---|---|
| hp | max_hp +1，并回复等量 HP | `BASE_MAX_HP(5) + weapon.max_hp_bonus + stats.max_hp_bonus()` |
| speed | 移速 ×1.08 | `MOVE_SPEED(5.4) × weapon.move_mult × stats.move_mult()` |
| dmg | 单发伤害 +1 | `BoomGame._bullet_dmg() = BULLET_DMG(1) + dmg_bonus()`，普弹/fan/chain/nuke 共用 |

### 3.3 关键工程点

1. **零加成 = 存量数值逐字一致**：默认档数为 0，`max_hp=5`（泡泡）/`7`（大剑）、
   `move_speed=5.4×mult` 与 M5 完全相同——M5 断言零改动。
2. **升级点唯一入口**：`BoomGame.apply_level_upgrade(kind)` 消费 `pending_upgrades`
   并落地机体；未知 kind / 无点数返回 false（防御）。
3. **血量上限变化只增量回血**：max_hp 增加时 `hp += gain`（不溢出、不重置已掉血）。

---

## 4. D2 经验升级 BoomExperience

### 4.1 曲线与入账

| 项 | 数值 | 说明 |
|---|---|---|
| 普通击杀 XP | +1 | `_finalize_kill` 内入账 |
| 精英击杀 XP | +8 | 精英更肉，值得一段"跳级"反馈 |
| 升 2 级所需 | 5 XP | `xp_to_next(l) = 5 + (l-1)×4`（线性） |
| 升 3 级所需 | 9 XP | 每级 +4，节奏越往后越慢 |
| 等级封顶 | 20 | 满级后溢出 XP 丢弃（防刷红线） |
| 每级产出 | 1 属性点 | `pending_upgrades += 1`，玩家自由消费 |

### 4.2 关键工程点

- `add_xp(amount)` 返回升级次数，支持跨级（一次精英击杀可能直接升 1 级 + 余 3 XP）。
- 每升 1 级发一次 `leveled_up(new_level)`；`BoomGame` 转发为 `level_up` 信号 +
  `pending_upgrades` 计数，main.gd 弹 "升级！ Lv.N" toast。
- 波次配额（W10≈18 敌）下，纯普杀到 W6–8 约升 4–5 级、精英波跳 1 级出头——
  成长曲线与波次难度曲线（HP 档 ×1.34/波5）大致同频，不掀桌。

---

## 5. D3/D5/D6 每武器技能树 + 金币解锁 + 每局 ≤3（M7R）

### 5.1 双武器技能树全表（池 9 定义；加新武器 = 定义一棵树）

**bubble 树（泡泡枪）**

| 树序 | id | 名称 | 类型 | CD | 解锁价 | 效果 |
|---|---|---|---|---|---|---|
| 1 | fan | BULLET STORM | 主动 | 3s | 免费（默认解锁） | 扇形 5 发（存量） |
| 2 | chain | CHAIN LIGHTNING | 主动 | 8s | 60 | 闪电链 3 跳（存量） |
| 3 | nuke | MEGA NUKE | 主动 | 20s | 120 | 6m 核爆 ×4（存量） |
| 4 | ring | RING BURST | 主动 | 10s | 200 | 12 发 360° 环形弹（`cast_ring_shot`） |
| 5 | twin | TWIN CANNON | 主动·专属 | 6s | 300 | 双管重弹：平行 2 发（`cast_twin_shot`，错位 0.35 聚焦即重击） |
| 6 | rapid | OVERDRIVE | 被动·专属 | - | 420 | 装备期普攻 CD ×0.8（射速 +25%，`skill_fire_cd_mult` 管线） |

**greatsword 树（大剑；`sword` 仅是动画/形态俗称）**

| 树序 | id | 名称 | 类型 | CD | 解锁价 | 效果 |
|---|---|---|---|---|---|---|
| 1 | fan | BULLET STORM | 主动 | 3s | 免费（默认解锁） | 扇形 5 发（存量；大剑形态走 muzzle 锚点） |
| 2 | chain | CHAIN LIGHTNING | 主动 | 8s | 60 | 闪电链 3 跳（存量） |
| 3 | nuke | MEGA NUKE | 主动 | 20s | 120 | 6m 核爆 ×4（存量） |
| 4 | heal | REPAIR | 主动 | 30s | 200 | 回复 2 HP（`cast_repair`，满血 0 但 CD 照常） |
| 5 | whirl | WHIRLWIND | 主动·专属 | 12s | 300 | 旋风斩：斩距内 360° 全向一斩，≤8 敌各受 swing_dmg（`cast_whirl`，复用 blade_hit/击退/击杀管线） |
| 6 | titan | TITAN EDGE | 被动·专属 | - | 420 | 装备期弧斩/旋风斩伤害 +1（`skill_swing_dmg_bonus` 管线） |

- **数据层**：`BoomWeaponDef.tree = {"skills": [6 个 id 按树序]}`（M5 预留字段启用）；
  `BoomSkillSystem.pool` 仍存全部 9 个技能定义（含 CD/配色/被动标记），
  **武器树决定可见/可解锁集合**——"加新武器 = 定义一棵树"即架构规范。
- **跨树隔离**：非本树技能 `unlock_cost = -1`、`is_unlocked = false`、不可装备；
  解锁进度按武器分桶存储互不串扰。
- **被动技能**：占装备槽提供常驻加成，`cast_skill` 对被动静默忽略（不发
  `skill_fired`、无冷却）；`BoomSkillSystem._refresh_passives()` 在
  equip/unequip/换树时把加成写到 `BoomGame.skill_fire_cd_mult / skill_swing_dmg_bonus`，
  `restart()` 归零（局内状态），再次 equip 管线恢复。

### 5.2 金币解锁（跨局货币）

- **货币语义（M7R 拍板）**：解锁消耗**跨局货币**（`BoomSave.coins`）；
  对局内拾取金币（木箱/精英金币雨）在**获得时即时累加进存档**
  （`BoomSave.add_coins` 内存即时），落盘合并到解锁（`unlock_skill` 即时 `save()`）
  与结算（main `_on_game_over` → `BoomSave.save()`）两个时机，避免逐金币 I/O。
- `try_unlock(id)`：已解锁 / 非本树技能 / 余额不足 拒绝；成功扣存档币 →
  写入存档并即时落盘 → 发 `skill_unlocked`。
- **树内顺序定价**：`TREE_PRICES = [0, 60, 120, 200, 300, 420]`（第 1 个免费，
  其余递增；±30% 调参空间内取标准值）。树首免费即默认解锁，不可重复购买。
- 定价依据：对局一局金币量级 ≈ 木箱 3 + 清波奖励 + 精英雨 40，W5 前后约 100+，
  60/120 档对齐"一两局的节奏"，200+ 档给中长期目标。

### 5.3 每局装备 ≤3（硬约束）

- `MAX_EQUIPPED = 3`：手势只有 3 槽，装备第 4 个技能无处安放——**超编直接拒绝**，
  这是"构建构筑感"的来源（6 选 3），不是技术限制。
- 装备槽顺序 = 手势槽：`equipped[0]`=tap、`[1]`=←swipe、`[2]`=→swipe；
  `handle_slot(i)` 是唯一施放入口，`handle_tap/...` 全部委托到槽位。
- 新档默认：各树仅树首 fan 解锁并装备（`equipped = ["fan"]`）——
  ←/→ 手势在解锁 chain/nuke 前为空槽，这是成长的一部分而非回归。
- **restart() 语义（M7R 拍板）**：清局内状态（成长/冷却/局内金币/被动加成），
  **不清**解锁进度与跨局金币（在 `BoomSave`）；装备配置随选单确认
  （`set_weapon_tree`）重建——同武器保留玩家勾选，换武器重置为该树已解锁前 3。
- 解锁 ≠ 装备：解锁是"获得资格"（跨局持久），装备是"本局占用槽位"（局内状态）。

### 5.4 选单技能配置区（D7，boom_weapon_select.gd）

- 卡片压缩让位后，选单下方为 `SKILL TREE` 配置区：按**当前选中武器**显示该树
  6 技能行（树序编号 + 名称 + 状态标签）。
- 已解锁行：点击勾选/取消勾选（≤3 由 `equip()` 拒绝兜底）；未解锁行：显示
  `[解锁 n]`，点击花跨局金币解锁（余额不足当前为静默失败，待补反馈）。
- 切武器卡即 `set_weapon_tree` 切树，列表随之切换；跨树技能不可见。
- 进局携带的就是所配武器树已勾选技能（main `_start_match_with` →
  `skill_sys.set_weapon_tree(weapon_id)` 后再 `begin_match`）。

---

## 6. D4 跨局存档 BoomSave（M7R 新增）

### 6.1 存档结构示例 JSON（`user://boom_save.json`）

```json
{
  "coins": 145,
  "unlocked": {
    "bubble": ["fan", "chain", "ring"],
    "greatsword": ["fan"]
  }
}
```

> 存档键 = `BoomWeaponDef.id`（"bubble"/"greatsword"），加新武器自动分桶。

### 6.2 工程要点

- 纯静态门面（`class_name BoomSave extends RefCounted`）：内存缓存 + 整包覆盖写，
  headless 可读写（user:// 在 `--headless --script` 下可用）。
- 容错：文件缺失 / JSON 损坏 / 字段缺失 → 回退默认结构（coins=0、各树 `[fan]`），
  不抛错不崩溃。
- **测试无残留**：play_test 各存档相关节前后 `BoomSave.test_reset()`（清缓存 + 删文件），
  `_finish()` 收尾再清一次；CI 的 user:// 与玩家数据隔离。

---

## 7. 表现层接线（main.gd，最小增量）

- `sim.level_up` → toast "升级！ Lv.N" + 提示音。
- `sim.player_healed(amount)` → 玩家头顶金色 "+N HP" 飘字 + 拾取音。
- test_hook state 增补 `level / xp / pending_upgrades`（vision-e2e 可读）。
- 选单注入 `skill_sys` 引用，技能配置区直接走逻辑层 API（解锁/装备零新管线）。
- `_start_match_with` → `sim.set_weapon` + `skill_sys.set_weapon_tree`（同武器保留
  勾选）；`_on_game_over` → `BoomSave.save()` 落盘。
- 技能 HUD（3 圆钮）布局不动，展示当前 `equipped` 槽位技能及其冷却；默认树首为 fan，装备 ring/twin/rapid/whirl 等技能时按装备结果重映射手势。

---

## 8. 测试与验收（play_test，250+ 条全 PASS）

| 节 | 断言要点 |
|---|---|
| `[m7-assets]` | 9 项玩家帧条/武器图标素材 `ResourceLoader.exists`（走 .import remap） |
| `[m7-stats]` | 零加成回归 M5 数值；hp/speed/dmg 各档落地（max_hp 6 / ×1.08 / dmg+1）；点数耗尽拒绝；未知 kind 拒绝；`restart()` 清零 |
| `[m7-exp]` | 曲线边界 5/9；升级信号；跨级；满级封顶；普杀 +1、精英 +8、升级产点 |
| `[m7-tree]` | 全池 9 定义；双武器树 6 槽序列逐字比对；跨树过滤（bubble 树看不到 heal/whirl/titan 及其解锁价）；树内顺序价 60/120/200/300/420；新档仅 fan 解锁；解锁扣**跨局币**并写档；装备 ≤3 与换装；twin/ring 槽位施放；切树装备重置；heal 补 2/满血 0；restart 保留解锁与跨局币 |
| `[m7-passive]` | rapid 装备/卸落 `skill_fire_cd_mult`；被动不进施放管线（无 skill_fired、无 CD）；titan 弧斩 +1 与 whirl 伤害 4；whirl 命中数与 8 敌封顶 |
| `[m7-save]` | 新档默认结构；货币入账/消费/余额不足；roundtrip（写盘→清内存→重读一致，金币+解锁）；对局拾取金币即时入档；restart 后局内币清零、跨局币与解锁保留；精英雨 40 即时入档；结算落盘文件存在 |
| `[m7-tree-ui]` | 选单技能区 6 行按当前武器切换；bubble 区不含 sword 专属；未解锁行显示价格；根节点行显示 已装备；行点击勾选/取消 |

- lint：`gdlint games/boom/ shared/` 全绿；改动文件过 `gdformat`。
- 结果：`PLAY_TEST result=PASS`（基线 228 → 250+）。
- 注意：headless 下 user:// 写入由 `test_reset()` 收尾清除，无残留。

---

## 9. 调参与扩展指引

- 所有数值均为常量：属性每档值（`boom_stats.gd`）、XP 曲线（`boom_experience.gd`）、
  技能 CD/树序价/发数/回复量/被动值（`boom_skill_system.gd` / `boom_game.gd` 常量区）、
  存档路径（`boom_save.gd`）。
- **加新武器（= 定义一棵树）四步**：① `boom_weapons.gd` 登记 def 并填
  `tree = {"skills": [...]}`（可复用池内 id，也可新增）；② 新技能在
  `BoomSkillSystem._init` 的 pool 登记一行（被动标 `is_passive`）；③ 新效果在
  `BoomGame` 写 `cast_xxx()` + `_dispatch_cast` 加分支（被动则落在
  `_refresh_passives`/机体字段）；④ 存档自动分桶，无需迁移。
- 加新属性两步：① `BoomStats` 加 stacks + apply 分支 + getter；
  ② `_apply_stats_to_player` / `_bullet_dmg` 落地。
- 调解锁价：改 `TREE_PRICES` 一个数组；调被动强度：`RAPID_FIRE_MULT` / `TITAN_DMG_BONUS`。
