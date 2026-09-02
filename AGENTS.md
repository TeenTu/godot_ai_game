# Godot Web Game 项目 — Agent 开发流程（每次游戏开发必读）

> ⚠️ **多 Agent worktree 协作**：本仓库多个 Agent 并行开发不同游戏（Sonar / Boom / 后续 Codex）。
> **动手前必读 `CONTRIBUTING.md`**——那里定义了 worktree 隔离、目录 ownership、shared/ 协调规则。
> **main 的集成者是 Codex CLI**：各 Agent 在自己的 dev worktree 开发，做完了交给 Codex 解决冲突、起 PR、合并回 main；**Agent 不直接 push main**。遵守 CONTRIBUTING §4/§5。

## 1. 环境速览

- Godot 4.5：`E:\Program\Godot\Godot_v4.5-stable_win64.exe`（bash 用全路径；CLI 无 `godot` 命令）
- 仓库：`https://github.com/TeenTu/godot_ai_game` → Pages：`https://teentu.github.io/godot_ai_game/<game>/`，git push 免密（Git Credential Manager），账号 TeenTu
- 隔离 Python（Pillow/gdtoolkit 已装）：`C:/Users/10532/.workbuddy/binaries/python/envs/default/Scripts/{python,gdlint,gdformat}.exe`，pip 装包走清华源
- ⚠️ 仓库已从 OneDrive 迁至 worktree 布局：`E:\Github\godot_ai_game`（main，集成口 Codex）+ `E:\Github\worktrees\sonar`（sonar-dev）+ `E:\Github\worktrees\boom`（boom-dev）。旧 OneDrive 地址已废弃清理。worktree 布局见 CONTRIBUTING.md §1。删除/rm 前先确认不在 worktree 检出冲突；优先用可回滚的 git 操作，恢复用 `git checkout HEAD -- games/*`

## 2. 新游戏标准流程（SOP）

1. **脚手架** `games/<name>/`：project.godot 复制 suika 模板（1280×720 横屏 / GL Compatibility / `TestHook` autoload / 字体 `assets/fonts/ui_subset.ttf` / emulate touch）；export_presets.cfg 直接复制 suika 的；.tscn 最小化（仅根节点挂 main.gd）
2. **逻辑先行**：`scripts/core/*.gd` 纯 GDScript 零 UI 依赖（可无头测试），数据在 `scripts/data/*.gd`；UI 全部 `main.gd` 的 `_ready()` 代码构建
3. **无头自检** `tools/play_test.gd`：`extends SceneTree`，主场景冒烟 + 逻辑断言，输出 `PLAY_TEST result=PASS`
4. **素材并行**（不阻塞开发）：写 `assets/ART_REQUEST.md` 规格清单 → 后台 `codex exec --approve-for-me "..."` 生成（Pillow 程序化绘制，指定隔离 venv python，禁止它装包/联网）→ 产出 `tools/gen_assets.py` + PNG + 拼图预览
5. **测试钩子**：复制 suika `scripts/test_hook.gd`（autoload，`?test=1` → `window.__gameState`），main.gd 实现 `_test_hook_get_state() -> Dictionary`
6. **本地验证**：`--headless --import` + `--script res://tools/play_test.gd`；**gdlint/gdformat 必须跑全目录**（`gdlint games/ shared/` + `gdformat --check games/ shared/`，单游戏会漏）
7. **导出**：`mkdir -p build/web` 后 `--export-release "Web" build/web/index.html`（目录不存在直接报错）
8. **提交 push 到 dev 分支**（如 `sonar-dev`/`boom-dev`）→ 交给 Codex CLI 合回 main → CI 自动构建部署，等全绿（2-3 分钟）。**不要在 main 上直接开发/提交**

## 3. CI/CD 流水线（.github/workflows/deploy.yml）

- jobs：`lint`（gdlint+gdformat 全目录、素材 >512KB 门禁）→ `export-web`（遍历 `games/*/`，注入 shared/addons，`--import`，跑 play_test 冒烟，导出 `dist/<name>/`，生成索引页）→ `deploy`（GitHub Pages）
- **新游戏零配置自动发布**：满足 project.godot + "Web" 导出预设 + tools/play_test.gd 即可
- deploy 只依赖 export（不依赖 lint）；产物结构：CI=`dist/<name>/index.html`，本地=`build/web/index.html`
- 体积门禁只查 `games/*/assets/images/`（注意此路径外不查）

## 4. 素材生成（docs/asset_pipeline.md 权威）

- **风格契约**：`shared/assets/styles/<id>/contract.yaml`（description/anchor/prompt_template/image_params/categories），游戏 `project.godot` 的 `[game_kit] asset_style` 声明，CI 自动注入 `assets/_shared/`（gitignore）
- **双层资产**：`shared/assets/`（跨游戏复用） vs `games/<name>/assets/images/`（游戏专属）；游戏层同名覆盖共享层
- **渠道**：ImageGen（混元，约 5-10 credits/张）或本机 Codex CLI；统一产出规格：透明底 PNG、snake_case 命名、1024 起步
- **后处理**：`tools/check_sprite_sheet.py`（雪碧图质量门禁，不合格出返工清单）`tools/postprocess_image.py`（去白/裁剪/256 色压缩）
- 适合 AI 生成：角色/道具/背景/图标；**不适合**：特效帧/像素画/UI 九宫格（程序化更优）

## 5. BDD 测试（两层）

- **CI 门禁**：各游戏 `tools/play_test.gd` 无头自检（逻辑正确性）
- **本地回归（不进 CI）**：`tools/vision-e2e/` 视觉 E2E（Playwright + DeepSeek 视觉模型）。BDD 场景 `scenarios/<game>/*.yml`（Given/When/Then），`./run.sh` 测本地（默认 `build/web`）或 `./run.sh <url>` 测线上，`-g` 过滤场景；`npm run test:mock` 无 key 验链路；`npm run report` 出带截图报告
- 视觉模型默认 `deepseek-v4-flash-vision-exp`，key 在 `tools/vision-e2e/.env`（gitignored，参考 .env.example）
- vision-e2e 的 YAML `base_url`：单游戏产物 `/`；多游戏 dist `/<游戏名>/`
- 测试钩子模式：`?test=1` + `window.__gameState` / `window.__gameTest.setSeed`；Emscripten boolean 跨边界不可靠→字符串比较

## 6. 可用 Skill

- `godot-dev-guide`：Godot 4.x 开发总指南（GDScript/场景/导出/测试，Godot 任务自动触发）
- `godot-web-gh-pages`：Godot Web 导出 + GitHub Pages 多游戏部署（COOP/COEP 与 SharedArrayBuffer 处理）
- `vision-e2e-scaffold`：为 WebGL/Canvas 游戏搭视觉 E2E 套件
- `godot-mcp`：Godot 编辑器 MCP 集成
- 按需：`find-skills` / `skill-creator` / `marketplace-skill-installer`

## 7. 可用 MCP

- `~/.workbuddy/mcp.json`：`godot` = npx @coding-solo/godot-mcp（GODOT_PATH 指向 4.5 exe）
- 会话已连接：`github`（GitHub 官方）、`tencent-docs`（腾讯文档）、`agent-mail`（智能体邮箱）
- 腾讯文档 CLI 拿不到 token → 用 `tools/tc_doc.py` 走 MCP JSON-RPC 直连（上传大图/调任意 MCP 工具通用）

## 8. 关键坑点

- GDScript 4：不支持具名参数调用；`:=` 不能从 Dictionary 索引推断类型（显式 `: int = int(...)`）；Dict 元素为 null 时 `is_empty()` 报错（先 `== null` 判断）；match case 缩进必须严格
- codex CLI 0.152：用 `--approve-for-me`（自带 workspace-write 沙箱），不支持 `--full-auto`；素材任务先预装 Pillow 免得它卡装包
- gdtoolkit 版本与 CI 一致（4.5.0），本地复现用全目录命令
- 必须提交 `.uid` / `.import`；gitignore 覆盖 `build/` `dist/` `.godot/` `games/*/addons/` `assets/_shared/` `.workbuddy/`
- 素材生成质量靠 ART_REQUEST.md 规格 + 拼图预览目检；配色统一走 contract.yaml 色板
- **导出包加载资源用 `ResourceLoader.exists()`，禁止 `FileAccess.file_exists()`**——后者不跟随 .import remap，源 PNG 被 pck 剔除后永远 false（本地 headless 假阳性、线上全空白的 v2.2 事故根因）
- headless 本地 ALL OK ≠ 线上正常；素材/UI 断言必须对真实导出产物跑 vision-e2e（`WEB_ROOT=<产物目录> ./run.sh`，线上直接传 URL）
- vision-e2e 的 run.sh 中断时会漏杀 http.server（trap 不可靠）→ 跑前先查端口残留（curl 看 title 是否是目标游戏）；agent-browser 装 Chromium 需走代理 `HTTPS_PROXY=http://127.0.0.1:7890`
