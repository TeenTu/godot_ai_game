# Vision E2E — 看得见的游戏端到端测试

用 **Playwright 操作浏览器 + DeepSeek 视觉模型看图**，围绕 Godot Web 游戏写 BDD 风格的测试。
定位是**本地开发回归工具**（不进 CI，不阻塞部署）；CI 里的逻辑正确性由游戏自带的
`tools/play_test.gd` 无头自检负责。

## 为什么是"视觉驱动"

Godot Web 游戏渲染在 WebGL canvas 里，DOM 里没有任何游戏元素可断言。
本套件的答案：**截图 → 视觉模型看图说话（输出结构化 JSON）→ 断言 JSON 字段**，
判断逻辑和人眼看画面一致，且对动画/特效不敏感（不用像素对比）。

```
执行动作 → 稳定等待 → 截图 → 视觉模型理解 → 语义断言 → 通过 / 失败(存证重试)
```

## 快速开始

```bash
# 0. 安装（首次）
npm install
npx playwright install chromium

# 1. 配置 key（视觉模型必需；.env.example 有全部可配项）
cp .env.example .env    # 填 DEEPSEEK_API_KEY

# 2. 跑：测本地构建产物（自动起服务，默认根目录 ../../build/web）
./run.sh

# 或测线上
./run.sh https://teentu.github.io/godot_ai_game/suika/

# 或过滤某个场景
./run.sh -g "合体"

# 3. 生成带截图证据的 HTML 报告
npm run report          # 输出 report.html
```

**没有 key 也能先验证链路**：`npm run test:mock`（VISION_MOCK=1，不调 API，
仅确认"打开游戏 → 截图 → 感知 → 断言"框架没坏，所有视觉断言都会通过）。

## 写一个场景

场景文件放 `scenarios/<游戏名>/*.yml`，结构是 Given/When/Then（BDD）：

```yaml
game: suika
base_url: /suika/            # 相对路径：run.sh 自动拼本地 origin；也可写完整地址
viewport: { width: 1280, height: 720 }

scenarios:
  - name: 连续掉落两个葡萄应合体成樱桃
    given:
      - open_game
    when:
      - drop_fruit: { x: 50, y: 15 }    # 点击 canvas 百分比坐标
      - wait: 600
      - wait_for_stable: 2000            # 等画面静止再截图
    then:
      - vision_assert:
          question: 画面上是否出现了一个樱桃（比葡萄大一级的水果）？
          expect:
            merged: true                 # 视觉模型必须输出 JSON，字段在此断言
```

## 动作表（Given / When）

| 动作 | 参数 | 说明 |
|---|---|---|
| `open_game` | `{params: {seed: 42}}` 可选 | 打开 base_url 并等待 WebGL 首帧 |
| `reload` | — | 刷新并等待首帧 |
| `wait` | `{ms: 1000}` | 等待毫秒 |
| `wait_for_stable` | `{ms: 1500}` | 等画面连续两帧一致（动画播完）再继续 |
| `move_mouse` | `{x: 50, y: 80}`（百分比） | 移动鼠标 |
| `click_at` | `{x, y}`（百分比） | 点击 canvas 某处 |
| `click` | — | 点击 canvas 中心 |
| `drop_fruit` | `{x, y}` | suika 组合动作：移动到落点点击放下 |
| `press` | `{key: "ArrowRight"}` | 键盘按键 |
| `set_seed` | `{value: 42}` | 调测试钩子 `__gameTest.setSeed`（无钩子则告警继续） |

坐标一律用**百分比**（相对 canvas 尺寸），不受分辨率/Godot 缩放影响。

## 断言（Then）

```yaml
# 视觉断言：截图 → 视觉模型回答 → 校验
- vision_assert:
    question: 游戏是否结束（出现 Game Over 画面）？
    expect:
      game_over: true
      score: { gt: 100 }        # 操作符: gt/gte/lt/lte/eq/ne

# 数值断言：读游戏测试钩子（需要游戏侧实现，见下）
- hook_assert:
    expect:
      score: { gte: 120 }

# 纯等待
- wait: 800
```

## 游戏测试钩子（可选但强烈建议）

让浏览器能读精确状态、固定随机种子，需要游戏侧加一个 autoload 单例。
**当前已实现：suika**（`games/suika/scripts/test_hook.gd` + `main.gd::_test_hook_get_state()`）。
dodge/sonar 可参照实现。

约定（所有游戏统一）：

- URL 带 `?test=1` 时（`open_game: {params: {test: 1}}` 传参），autoload 挂载：
  - `window.__gameState = { score, best, is_over, fruit_count, held_level, next_level, ... }`
    —— 每 0.1s 刷新一次，精确数值断言可走 `hook_assert`
  - `window.__gameTest = { setSeed, ... }` 命名空间（可选）

每个游戏需要：

1. 新建一个 autoload 脚本（参考 suika 的 `games/suika/scripts/test_hook.gd`），
   关键模式：
   - 平台门 `OS.has_feature("web")` —— 编辑器/桌面构建完全 no-op
   - `Engine.has_singleton("JavaScriptBridge")` 检测单例是否存在
   - **用 `Object.call("eval", "...")` 动态调用**，不要直接调 `JavaScriptBridge.eval(...)`
     —— 后者在 headless 桌面构建中方法不挂载，编辑器打开工程会报 "Parse Error"
   - 读取 URL 参数用字符串比较，不用 boolean（见下）
2. 在 main 脚本加一个 `_test_hook_get_state() -> Dictionary` 纯 getter 方法
3. `project.godot` 注册 autoload：`[autoload]\nTestHook="*res://scripts/your_hook.gd"`

### ⚠️ 关键坑：Emscripten 跨边界 boolean 不可靠

```gdscript
# ❌ 别这样写 —— JS 表达式返回 true，跨边界后可能不是 GDScript 的 true
var result = bridge.call("eval", "new URLSearchParams(location.search).get('test') === '1'")
return result == true  # 偶发不通过

# ✅ 直接拿字符串比较，最稳
var result = bridge.call("eval", "new URLSearchParams(location.search).get('test')")
return typeof(result) == TYPE_STRING and (result as String) == "1"
```

没有钩子时套件照跑（纯视觉模式），只是数值断言会提示"钩子未开启"。

## 项目结构

```
tools/vision-e2e/
├── run.sh                    # 一键：起服务 + 测试（支持传地址/过滤）
├── playwright.config.ts      # workers=1，重试由 runner 控制
├── specs/e2e.spec.ts         # 把每个 YAML 场景注册为 Playwright test
├── scenarios/<game>/*.yml    # BDD 场景（新增游戏 = 新建目录）
└── src/
    ├── driver/               # 手：canvas 百分比操作、等待稳定、钩子读取
    ├── perception/           # 眼：DeepSeek 视觉适配器（可插拔，含 mock）
    ├── dsl/                  # 场景解析、动作执行、语义断言
    └── reporter/             # 自包含 HTML 报告（截图内嵌）
```

产物：`test-results/vision/`（每步截图证据 + results.json）、`report.html`（`npm run report`）。
