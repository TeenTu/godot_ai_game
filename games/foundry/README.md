# 背包工厂 · Backpack Foundry

DBG 构筑 + 工人放置 + 背包管理 + 异步对战的工厂小游戏。Web 导出，1280×720 横屏。

## 玩法

8 回合一局。先放建筑（每次买 1 张卡放进 4×5 网格），再派 3 个工人激活工位，最后出 5 张手牌放大战力。
每回合你的战力 vs 幽灵对手的战力，赢 +1 分，先到 5 分或总高分胜。

## 核心规则

- **背包 = 工厂平面图**：每张建筑卡占若干格子并生成工位；同色相邻触发加成。
- **工人激活**：3 个工人点 3 栋建筑，没派工的本回合不产出。
- **DBG 放大**：抽 5 打 5，能量 3。基础战力来自工位，手牌叠 flat 加成和倍率。
- **异步对战**：幽灵是预生成的 8 回合战力曲线，本地匹配，不需要服务器。

## 项目结构

```
games/foundry/
├── project.godot           # 1280x720, GL Compatibility, TestHook autoload
├── scenes/main.tscn        # 最小场景（仅挂 main.gd 根节点）
├── scripts/
│   ├── main.gd             # 全部 UI 在 _ready 用代码构建
│   ├── test_hook.gd        # autoload，发布状态到 window.__gameState
│   ├── data/card_db.gd     # 8 建筑 + 8 手牌的静态数据
│   └── core/
│       ├── board.gd        # 4x5 网格 / 相邻加成 / 产出计算
│       ├── game_state.gd   # 回合状态机（5 阶段）
│       └── ghost.gd        # 幽灵对手生成
├── tools/
│   ├── gen_assets.py       # 程序化生成 PNG 素材（codex 写）
│   └── play_test.gd        # 无头自检（CI 门禁）
├── assets/
│   ├── icons/              # 8 建筑 + 1 拼图预览
│   ├── ui/                 # 4 UI 图标
│   ├── bg/                 # 1 背景
│   └── fonts/              # UI 字体
├── addons/game_kit/        # 共享 UI 工具
└── build/web/              # Web 导出产物
```

## 怎么跑

### 编辑器
Godot 4.5 → 打开 `games/foundry/project.godot` → F5 启动。

### 无头自检
```bash
godot --headless --path games/foundry --script res://tools/play_test.gd
```
- 测主场景实例化不崩
- 测 FoundryBoard 放置 / 相邻 / 移除
- 测战力公式（双熔炉 + lab）
- 模拟 4 局 AI 自动对局

### 重新生成美术
```bash
C:/Users/10532/.workbuddy/binaries/python/envs/default/Scripts/python.exe \
  tools/gen_assets.py
```
（codex 已经生成过一次；规格在 `assets/ART_REQUEST.md`）

### 导出 Web
```bash
cd games/foundry
godot --headless --export-release "Web" build/web/index.html
```
然后用 HTTP server 启动（如 `python -m http.server` 指向 `build/web/`），浏览器打开。

## 测试钩子

`window.__gameState` 在 `?test=1` 时由 TestHook autoload 每 0.1s 发布一次。
内容来自 `main._test_hook_get_state()`：phase, round, gold, scores, power, energy 等。

可被 `tools/vision-e2e/` 套件精确读取（与 suika 模式一致）。

## 平衡性

- 起始：3 工人 / 2 金币 / 8 回合
- 工位产出：矿场+3金、熔炉+4战、兵营+6战、实验室+50% 倍率……
- 手牌：1 费 +3 战、2 费 ×1.6 倍、0 费 +1 金+1 战……
- AI 模拟（auto-buy 第一个能买的、激活前 3 个建筑、全打牌）在难度 2 幽灵下胜率约 25%——需手动调整平衡（这是有意的"先跑通、再调"流程）。

## 后续可做

- 商店 UI 升级（动态按已建组合推荐卡牌）
- 异步干扰机制（每 3 回合对手投送负面）
- 50 个本地预生成幽灵池 + 分段匹配
- 拖拽放置建筑卡（当前是点格子直接放）
