# Godot Web Games — 多游戏仓库（Godot 4.5）

一个仓库管理多个 Godot 小游戏，推送到 `main` 后 CI 自动构建**全部游戏**并部署到 GitHub Pages：

- 总索引页：<https://teentu.github.io/godot_ai_game/>
- 合成大西瓜：<https://teentu.github.io/godot_ai_game/suika/>
- 太空闪避：<https://teentu.github.io/godot_ai_game/dodge/>

仓库结构参考 [godotengine/godot-demo-projects](https://github.com/godotengine/godot-demo-projects)：
每个游戏是 `games/<名称>/` 下的**独立工程**（有自己的 `project.godot` 和 `export_presets.cfg`），
游戏之外的支持套件放在仓库级 `shared/` 目录，CI 构建时自动注入。

## 当前游戏

### suika — 合成大西瓜

Godot 4.5 + GDScript 写的合成大西瓜：同级水果相撞就合体，一路合到大西瓜。

- 鼠标移动 / 手指拖动瞄准，点击（或按空格）放下水果
- 相同等级的水果碰到一起会合成更高一级，并加分
- 水果堆过顶部虚线并停留约 2 秒 → 游戏结束
- 最高分存在浏览器本地（Godot 的 `user://`），刷新不会丢

水果共 11 级：葡萄 → 樱桃 → 橘子 → 柠檬 → 猕猴桃 → 西红柿 → 桃子 → 菠萝 → 椰子 → 半个瓜 → 大西瓜。
只会随机掉落前 5 级。

### dodge — 太空闪避

用 `game_kit` 共享套件写的示例游戏：虚拟摇杆（触屏）或方向键操控飞船，躲开越来越密的陨石，存活即得分。

- 演示了 `GameKitVirtualJoystick`（左下角摇杆）、`GameKitSafeArea`（HUD 安全区包裹）的接入方式
- 全部图形程序化绘制，无外部素材；带自己的中文字体子集（20 KB）
- 无头自检覆盖：移动 / 计分 / 碰撞判定 / 重开，四项全过才允许部署

## 新增一个游戏

1. `mkdir games/<新游戏名>`，用 Godot 在该目录创建工程（GL Compatibility 渲染器）。
2. 添加导出预设：名称必须叫 **`Web`**，Thread Support 关闭
   （可直接复制 `games/suika/export_presets.cfg` 改）。
3. 需要共享套件就跑 `bash tools/sync_shared.sh`（CI 也会自动注入）。
4. 推送到 main，自动发布到 `/godot_ai_game/<新游戏名>/` 并出现在索引页。

## 共享支持套件 shared/addons/game_kit

多端适配与触控支持，独立于任何游戏（详见 [shared/addons/game_kit/README.md](shared/addons/game_kit/README.md)）：

- `GameKitVirtualJoystick` — 虚拟摇杆（原生多点触控）
- `GameKitSafeArea` — 刘海/手势条安全区适配
- `GameKitTouchDebug` — 多点触控可视化调试层

## Project layout

```
.github/workflows/deploy.yml   # CI/CD：lint + 遍历 games/* 导出 + 生成索引页 + deploy
games/
  suika/                       # 合成大西瓜（独立 Godot 工程）
    project.godot              # Godot 4.5, GL Compatibility, 720x1080
    export_presets.cfg         # "Web" preset — MUST be committed
    scenes/main.tscn           # 游戏主场景
    scripts/main.gd            # 玩法主控：掉落、合成、计分、判定
    scripts/fruit.gd           # 单颗水果（RigidBody2D，程序化绘制）
    scripts/fruit_data.gd      # 11 级水果的半径 / 配色 / 分值表
    scripts/pop_effect.gd      # 合成时的扩散光圈特效
    assets/fonts/ui_subset.ttf # 裁剪过的中文字体（21 KB）
    tools/play_test.gd         # 无头模拟对局自检
    tools/collect_font_chars.py# 扫描源码里用到的字符，供字体子集化
  dodge/                       # 太空闪避（game_kit 示例游戏）
    project.godot              # 720x1080，双 emulate 触摸/鼠标设置
    scenes/main.tscn           # 极简入口，节点全部在 main.gd 里代码构建
    scripts/main.gd            # 主控：移动、生成、碰撞、计分、重开
    scripts/player.gd          # 玩家飞船（程序化绘制）
    scripts/asteroid.gd        # 陨石（随机多边形 + 下落自旋）
    tools/play_test.gd         # 无头自检：移动/计分/碰撞/重开四项
shared/addons/game_kit/        # 仓库级共享套件（触控 / 安全区适配）
tools/sync_shared.sh           # 把 shared 注入各游戏的本地脚本
tools/ci_status.py             # 查询 Actions 运行状态/日志的小工具
```

## 中文字体

Web 导出时 Godot 默认字体里没有汉字，界面会变成豆腐块。这里的做法是
只把用到的 147 个字符从 `msyh.ttc` 里裁出来（21 KB），在 `project.godot`
里设成 `gui/theme/custom_font`。**以后如果加了新中文文案**，重新跑一遍：

```bash
python games/suika/tools/collect_font_chars.py        # 重新扫描用到的字符
pyftsubset "C:/Windows/Fonts/msyh.ttc" \
  --font-number=0 --text-file="games/suika/tools/font_chars.txt" \
  --output-file="games/suika/assets/fonts/ui_subset.ttf" \
  --layout-features="" --no-hinting --desubroutinize --name-IDs='*'
```

## 本地自检

```bash
# suika：模拟一整局，看能不能正常合成
godot --headless --path games/suika --script res://tools/play_test.gd
# 预期输出 PLAY_TEST result=PASS

# dodge：确定性四项自检（移动/计分/碰撞/重开）
godot --headless --path games/dodge --script res://tools/play_test.gd

gdlint games/ shared/ && gdformat --check games/ shared/

# 把共享套件同步进各游戏（本地开发时）
bash tools/sync_shared.sh

# 本地导出某个游戏（先跑 sync，输出到 dist/<游戏名>/，已 gitignore）
mkdir -p dist/suika
godot --headless --path games/suika --export-release "Web" dist/suika/index.html
```

## One-time setup on GitHub

1. Create a **public** repository on GitHub (private repos need GitHub Pro for Pages).
2. Remote is already configured. Push with:
   ```bash
   git push origin main
   ```
   Remote: https://github.com/TeenTu/godot_ai_game.git
3. In the repo: **Settings → Pages → Source → select "GitHub Actions"**
   (NOT "Deploy from a branch" — the workflow uses the official deploy actions).
4. Watch the run in the **Actions** tab. When all jobs are green, open the index:
   `https://teentu.github.io/godot_ai_game/` (each game lives at `/<游戏名>/`)

Every subsequent merge to `main` automatically rebuilds and redeploys.

## Acceptance checklist

- [x] `export_presets.cfg` committed to the repository
- [x] Web preset has **Thread Support disabled** (`variant/thread_support=false`)
- [x] Renderer is **GL Compatibility** (WebGL 2.0)
- [x] VRAM texture compression enabled for desktop + mobile
- [x] Export filter: all resources; export path `build/web/index.html`
- [x] `.gitignore` does NOT ignore `export_presets.cfg`
- [x] `.github/workflows/deploy.yml` present, YAML syntax validated
- [x] 中文字体子集已内置，Web 端不会出豆腐块
- [ ] Push to `main` → Actions run is green *(requires a remote repo)*
- [ ] Pages URL loads the game *(requires a remote repo)*

## Local export (optional sanity check)

Open the project in Godot 4.5 → **Project → Export → Web** → Export Project.
Output goes to `build/web/index.html` (the `build/` folder is gitignored).

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Cannot export project with preset "Web"` | `export_presets.cfg` missing or preset name mismatch | Ensure the file is committed and the name matches `"Web"` exactly (case-sensitive) |
| `SharedArrayBuffer is not defined` | Thread Support enabled | Keep `variant/thread_support=false` (GitHub Pages cannot send `Cross-Origin-Embedder-Policy` headers) |
| `Export template not found` | Docker image tag ≠ Godot version | Align `barichello/godot-ci:<tag>` with `GODOT_VERSION` in `deploy.yml` |
| Cross Origin Isolation error | Threads enabled in the export | Must export single-threaded |
| Garbled CJK text (豆腐块) | 新加的中文没进字体子集 | 重跑 `games/suika/tools/collect_font_chars.py` + `pyftsubset`（见上文） |
| 水果相撞不合体 | 两颗只是刚好相切，没真正重叠 | 属于正常物理行为，挤一挤就会合；若想更灵敏可放宽 `Fruit._on_body_entered` |

## Upgrading Godot

1. Check available image tags: <https://hub.docker.com/r/barichello/godot-ci/tags>
2. In `.github/workflows/deploy.yml`, update **both** the `container.image` tag and the `GODOT_VERSION` env.
3. Update `config/features` in `project.godot` to match, and re-open the project in that editor version.
