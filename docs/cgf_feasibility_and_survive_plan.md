# CGF（godot-card-game-framework）集成可行性评估 & 《怒海求生》复刻规划

> 调研日期：2026-09-02 ｜ 结论：**不建议直接集成主仓库作为套件；有条件可行路径为 PotatosTimes 的 Godot 4 分支**，但对《怒海求生》这类版图桌游收益有限，首选替代方案是**自研核心 + 参考 CGF 设计思想**。
>
> **2026-09-02 追加（附录九）**：经进一步确认，PotatosTimes 分支（conversion 分支，支持 Godot 4.4–4.7）作为套件 vendored 集成**技术上可行**，判定从"不建议"上调为**"有条件可行（需先过 spike 验证门）"**，详见附录九。

---

## 附录九 · 使用社区 4.x 分支作为套件集成的可行性（追加评估）

### 结论
技术上可以实现。该分支天然支持套件化 vendored 集成，但必须先通过 1–2 天的 spike 技术验证门，不通过则退回自研方案。

### 判断依据
1. **引擎兼容**：无专门的"4.5 分支"；PotatosTimes 的 `conversion` 分支声明在 Godot 4.4–4.7 干净运行，已修复 4.5 三个知名坑（`.uid` sidecar 破坏卡组加载、`FontFile.duplicate()` 丢行距、旧 GUT 与原生 `Logger` 类冲突——后者已用 `.gdignore` 隔离，集成时不要解开）。
2. **天然套件化**：官方安装方式即"拷 `src/` 进工程 + 注册 `cfc` autoload"，无需包管理器；`src/core` 禁改 / `src/custom` 扩展的分层符合 kit 集成需求。
3. **monorepo 隔离成立**：每个游戏独立 Godot 工程（独立 project.godot、独立 pck），vendored 到 `games/<name>/vendor/cgf/` 后 autoload 不跨游戏冲突；**AGPL 传染被限制在单游戏目录**，其余游戏不受影响。仓库公开，AGPL 第 13 条义务事实上满足。
4. **CI 兼容**：满足 project.godot + "Web" 预设 + play_test.gd 即被现有流水线自动发现，零特殊配置。

### 集成蓝图（spike 通过后）
```
games/survive/
  vendor/cgf/          # PotatosTimes conversion 分支的 src/ + LICENSE 副本
  THIRD_PARTY.md       # AGPL-3.0 出处与版本声明（tag 固定）
  project.godot        # 注册 cfc autoload
  scripts/custom/      # CGFBoard 替代、CardConfig、卡组定义
  scripts/core/        # 自研：六边形地图、回合状态机、单位、海怪、计分
```

### 硬性前置门槛（不通过即止损回退自研）
1. **Spike 验证（1–2 天）**：vendor → `--headless --import` → 导出 Web → 手牌抽取/拖拽/翻面冒烟 + gdlint。单人维护分支，README 声明 ≠ 实测，任何一步崩即回退。
2. **gdlint/gdformat 门禁**：先 `gdformat` 清洗 fork 代码（4.5.0 全目录门禁；清洗属修改衍生代码，仍在 AGPL 义务内）。
3. **体积门禁**：CI 只查 `games/*/assets/images/`，删除 demo 图片或避免放入该路径。
4. **升级策略**：vendor 后打 tag 固定版本，不再追上游（保持不改 `src/core` 以保留可选升级能力，但不承诺跟进）。

### 套件化无法解决的成本
- 触屏交互改造：hover→点选、右键拖拽目标箭头→点选目标模式
- 竖屏手牌布局重排（框架按桌面横排设计）
- TestHook 桥接（`window.__gameState`）供 vision-e2e 断言
- 六边形版图/单位/海怪/回合/计分全部自研（框架不管版图棋子类内容）

---

## 一、框架核心功能与架构

**功能**（面向 TCG/LCG 类卡牌游戏）：
- 卡牌操作全家桶：手牌（椭圆/直线排布）、牌堆（视觉化数量）、拖拽、翻面、旋转、附着（attach）、目标箭头、token/计数器
- 字典式脚本引擎：用纯文本 Dictionary 定义卡牌效果（触发器、过滤器、可选能力、多选能力、运行时强度计算、玩家输入请求）→ 完整规则强制执行
- 网格/自由落位、卡牌图书馆、构筑器（Deck Builder）、存档、统计收集

**架构**：
- `src/core`（核心场景+类，禁止修改，升级时整体替换）+ `src/custom`（继承场景扩展，CardConfig/CFConst/CustomScripts 必须存在）
- 全局 autoload 单例 `cfc`（CFControl.gd）+ 配置类 CFConst；Card/Hand/Pile/Board 类体系，节点路径耦合较紧（"tightly wound in the code"）
- 定位是**卡牌游戏**框架：无回合制系统、无多玩家/热座支持、无 AI、无版图（hex/tile）概念

## 二、Godot 版本支持

| 仓库 | 状态 |
|---|---|
| `db0/godot-card-game-framework`（主仓库 v2.2） | **仅 Godot 3.x**。作者自述"没时间迁移到 Godot 4"，项目实质停更 |
| `menaechmi/godot-card-game-framework4`（conversion 分支） | Godot 4.2 移植，进度不完整（作者自述卡牌场景部分留白） |
| `PotatosTimes/godot-card-game-framework4.7`（conversion 分支） | **Godot 4.4–4.7 可用**，明确修了 4.5 的坑：`.uid` sidecar 破坏卡组加载、`FontFile.duplicate()` 丢行距、自带旧版 GUT 与 4.5 原生 Logger 类冲突（已 .gdignore 规避） |

## 三、许可证

- **AGPL-3.0**（所有版本一致，含两个 fork），另附 Steam 分发附加条款。
- 商用/二次分发**允许**，但强 copyleft：按官方流程复制的核心场景/脚本属于衍生作品，**整个游戏必须以 AGPL 开源**；AGPL 第 13 条要求**网络服务**（Web 游戏）向交互用户提供完整对应源码。
- 我们的游戏仓库（TeenTu/godot_ai_game）本来就是公开 GitHub 仓库 → 第 13 条义务事实上可满足；但代价是本项目所有引用 CGF 的游戏代码被迫锁死 AGPL，未来若想闭源商业化将受限。我们自绘的美术素材不受影响。
- 注：2023 年作者曾发起改 MIT 的 RFC（Issue #189），最终**未落地**，至今仍是 AGPL。

## 四、外部依赖

- 无硬性第三方依赖；仅可选捆绑 **GUT** 测试插件（旧版与 Godot 4.5 原生 `Logger` 类名冲突，fork 已用 `.gdignore` 处理，若要跑测试需升 GUT 9.5+）。

## 五、与现有项目技术栈的兼容性

| 项目要求 | 兼容情况 |
|---|---|
| Godot 4.5 + GL Compatibility | PotatosTimes fork 声明支持 4.4–4.7，✓（需实测） |
| 横屏 1280×720、emulate touch | 框架按鼠标设计（hover/右键拖拽目标箭头），**触屏适配要自己改**，⚠️ |
| CI：gdlint/gdformat 4.5.0 全目录门禁 | fork 代码风格未知，大概率需先 gdformat 清洗，⚠️ |
| CI：`--headless` 冒烟 + `tools/play_test.gd` | 需为 CGF 场景写冒烟断言，成本中等 |
| TestHook autoload / `?test=1` | 自行桥接 `window.__gameState`，成本中等 |
| Web 导出 + GitHub Pages | 框架用 Viewport 做卡牌放大预览、Tween 动画多，WebGL 下性能需压测；无原生 Web 障碍 |
| 移动竖屏偏好 | 框架默认桌面横排手牌 UI，竖屏重排工作量不小，⚠️ |

**关键错配**：《怒海求生》是**六边形版图 + 单位 token 棋子**类桌游，卡牌只是辅助（行动卡 + 地块翻转）。CGF 能覆盖的仅是"行动卡牌堆/手牌/卡牌效果脚本"约 30–40% 的需求；六边形地图、岛屿板块沉降、单位移动、海怪移动与战斗、热座回合流程、计分——**全部要自研**。

## 六、集成成本与风险

1. **上游死风险**：主仓库停更，fork 单人维护，4.5 之后版本（若继续升级引擎）随时可能掉队。
2. **AGPL 传染**：整个 games/<name> 代码被迫 AGPL，且我们仓库是 monorepo（多个游戏共存），需要目录级隔离，法律边界要小心。
3. **改造深度**：触屏化、竖屏、CI 门禁、与 TestHook/vision-e2e 对接，估计占集成总成本 40%+。
4. **收益有限**：为一个 30–40% 覆盖率的组件引入上述全部负担，性价比偏低。

## 七、可行性结论

**结论：不建议将 CGF 作为套件直接集成。理由：**

1. 主仓库 Godot 3.x + 停更，直接排除；
2. 唯一现实选项 PotatosTimes fork 虽支持 4.4–4.7，但 AGPL 传染 + 单点维护 + 触屏/竖屏深度改造，综合成本高；
3. 目标游戏是版图棋子类，CGF 覆盖率低，引入的复杂度 > 节省的工作量。

**替代方案（推荐）：自研核心，参考而非照抄。**
- 按项目既有 SOP（`games/<name>/scripts/core/` 纯 GDScript 零 UI 依赖 + 无头自检）自建六边形版图引擎与回合系统；
- **借鉴 CGF 的字典式脚本引擎思路**实现行动卡效果（数据驱动 `scripts/data/` + 简单触发器/效果解释器）——设计思想不受版权保护，避免 AGPL 传染；
- 卡牌视觉交互（翻面、拖拽、手牌排布）用 Tween 自研简化版，符合买量手游风 UI 偏好。

**若仍想集成（备选 B）**：vendored 方式把 PotatosTimes fork 放入 `games/<name>/vendor/`（gitignore 例外、目录级 AGPL 隔离声明），先跑通 4.5 导出冒烟，再评估触屏改造量；接受该游戏目录整体 AGPL 开源。

## 八、《怒海求生》复刻 —— 核心玩法模块规划（自研路线）

> ⚠️ **IP 提示**：《Survive: Escape from Atlantis!》是 Julian Courtland-Smith 设计、Asmodee/Stronghold 发行的商业桌游。规则机制本身不受版权保护，但**名称、美术、规则书文本受保护**。建议：换用自己的游戏名与原创美术（水中/沉没主题），页面标注"规则灵感来源"，避免使用原版卡图与规则文本——作为非商业 fan 项目风险较低，但不能 100% 免责。

### 模块拆解（`scripts/core/` 纯逻辑层，可无头测试）

1. **六边形地图系统**：7 块海岩地形 + 中心岛（16 块海滩/丛林/山地板块，翻面分值）；板块沉降动画队列
2. **回合制流程**（热座 2–4 人）：阶段状态机 = 翻板块 → 海怪移动 → 移棋子（3 格）→ 出行动卡（1 张）→ 结算，配 Spinner（漩涡/海怪/生物）
3. **单位系统**：探险者（每人 10）、小船（载 3，分倾斜/倾覆状态）、游泳者； drowning 抽取标记
4. **生物系统**（AI 走简化规则引擎）：海蛇（吃游泳者）、鲨鱼（吃游泳者）、鲸鱼（掀船）、北海巨妖 Kraken（毁船+吃人，扩展）；生物由最后行动玩家代控
5. **行动卡效果引擎**（借鉴 CGF 字典方案）：约 30 张卡，数据驱动 `{trigger, effect, intensity}`，特殊卡（如 SWIM FOR YOUR LIVES、Retaliate）走自定义 handler 钩子
6. **计分与终局**：板块分值 + 获救人数 + 溺亡人数；中央岛屿完全沉没或全员结算即终局

### 需自行扩展的部分
- 触屏交互（点选移动高亮路径、拖拽上船）与竖屏适配
- TestHook 桥接（`window.__gameState` 暴露回合/单位/生物状态）供 vision-e2e 断言
- 素材：按 ART_REQUEST 流程用 ImageGen 生成卡面/地形/棋子（走 contract.yaml 色板）

### Web 导出与 GitHub Pages 部署
- **可行**：零特殊配置，满足 `project.godot` + "Web" 预设 + `tools/play_test.gd` 即被 CI 自动发现发布（teentu.github.io/godot_ai_game/survive/）
- 注意：板块沉降/生物移动的 Tween 数量控制（WebGL 单线程压力大）；`ResourceLoader.exists()` 检查素材；上线后跑 `tools/vision-e2e/` 对真实产物断言 UI/素材
