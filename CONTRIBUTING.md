# CONTRIBUTING — 多游戏多 Agent 协作契约（必读）

本仓库由**多个 Agent / 协作者并行开发多个游戏**（当前：Sonar、Boom，后续加入 Codex 等），
同时 `main` 是唯一触发 CI/CD 并部署到 GitHub Pages 的分支。这套契约的目的是：
**既能各自并行开发互不覆盖，又保证 main 始终可构建、能过全部游戏冒烟测试**。

> 核心教训（2026-09）：Boom M2 分支曾把 Sonar 操作员层文件整体"误删"带入合并，
> 导致线上 Sonar 被回退到操作员层之前。根因就是**越界改了不属于自己的文件 + 无契约合并**。
> 下面每一条都是在防这一类事故。

---

## 1. 仓库物理结构（worktree 隔离）

同一个 git 仓库，通过 **git worktree** 把不同游戏隔离到不同文件夹、不同分支。
一个分支在同一时间只能被一个 worktree 检出；想同时改两个游戏就开两个 worktree。

当前布局（2026-09-02）：

| worktree / 路径 | 分支 | 负责游戏 | 用途 |
|---|---|---|---|
| `E:\Github\godot_ai_game`（主） | `main` | **集成发布口（Codex CLI）** | 专职把各 dev 分支解决冲突、起 PR、合并回 main；push main 触发 CI/部署。开发不在此做 |
| `E:\Github\worktrees\sonar` | `sonar-dev` | Sonar | Sonar 独立开发现场（Sonar Agent 使用） |
| `E:\Github\worktrees\boom` | `boom-dev` | Boom | Boom 独立开发现场（Boom Agent 使用） |

> main 的集成者是 **Codex CLI（唯一铁律）**。各游戏 Agent 在自己的 dev worktree 写完一批 → push 到远端 dev 分支 → **由开发 Agent 主动触发一次 `codex exec`**，Codex CLI 解决冲突并起记录 / 合并回 main（详见 §4）。**不存在任何 automation 兜底**，触发是开发完成后的显式动作。Agent 不直接 push main。

新增 worktree 的命令（在主仓库执行）：

```bash
git worktree add <路径> <分支名>        # 已有分支
git branch <分支名>; git worktree add <路径> <分支名>   # 或先建分支
git worktree list                        # 查看所有 worktree
git worktree remove <路径>               # 移除（先确保分支无未提交且已 push）
```

> 各游戏 worktree 内跑测试前，必须先注入共享资源（见 §5），否则 GameKitSfx 等共享类
> 会报假 Parse error。

---

## 2. 铁律：每个 Agent / 分支只动自己的 `games/<游戏>/`

这是**防止互相覆盖 / 误删的根本**。

- 你只允许修改 / 新增 / 删除 `games/<你的游戏>/` 下的文件。
- **禁止**在合并或 commit 里夹带对其它 `games/<其他>/`、`games/` 顶层公共文件的删除或改动。
- 历史教训：Boom 分支之所以误删 Sonar，是因为它在旧基线上 diff 出"删除"，合入 main 时照搬。
  合入前务必 `git diff main --stat` 检查是否误删他人文件。

### 谁拥有什么（ownership 表）

| 目录 | Owner | 触碰规则 |
|---|---|---|
| `games/sonar/` | Sonar Agent | 独占 |
| `games/boom/` | Boom Agent | 独占 |
| `games/suika/` `games/dodge/` 等 | 相应 Owner | 独占 |
| `shared/` `tools/` `.github/` 仓库级公共 | **无默认 Owner，改动需提前在群里 / 文档声明并协调** | 协商 |

---

## 3. shared/ 与公共层的改动规则（唯一可能互相踩的地方）

`games/<各自>/` 天然隔离不会撞，真正会冲突的是 **`shared/`**（共享素材、addons、样式）
与仓库级脚本（`tools/`、`.github/`）。

1. **改 `shared/` 前必须先声明**：在仓库根新建 / 更新一份 `docs/shared_changes_<你的游戏>.md`
   或用 PR 说明你要动什么、为什么、影响哪些游戏。
2. 改动要**向后兼容**：新增优先，禁止改名/删除他人正在使用的 key、类、资源路径。
3. 提交时检查 `git diff main --stat -- shared/`，确认只含你声明的改动。
4. 若与其它游戏撞车，**在 main 上串行合入**（谁先合谁过 CI），后合者 rebase 解决。

---

## 4. 分支与合入 main 的节奏（CI 只在 main 跑；main 集成者是 Codex CLI）

CI（`.github/workflows/deploy.yml`）只在 **push 到 `main`** 时触发并部署。
main 是"集成发布口"，**不是开发场**。分工如下：

### 4.1 各游戏 Agent（Sonar / Boom 等）

- 只在**自己的 dev worktree / 分支**（`sonar-dev` / `boom-dev`）上开发：随便 commit、本地跑测试、push 到远端同名 dev 分支。
- **不要自己动 main，也不要停下来问"要不要合"。** 合入 main 是既定铁律（Codex CLI 执行），不是人工决策点。
- 一个 dev 批次开发完成并 `git push origin <dev分支>` 成功后，**立即按 §4.1.1 主动触发一次 `codex exec` 让 Codex CLI 接管评审 + 合入 main**，并当轮确认合入结果。这是开发 Agent 的显式交付动作，不依赖任何后台调度。

### 4.1.1 触发铁律：Codex CLI 唯一执行者，无 automation 兜底（2026-09-03 修订）

> 铁律：**"开发完成 → Codex CLI 评审 → 起记录 → 合并 main"是开发 Agent 在每次 push dev 后主动触发的显式动作**。
> Codex CLI 是 main 的唯一 push 者。**本项目不存在任何 automation / 定时任务作为集成兜底**——历史教训：
> automation 会误导开发 Agent 以为"有人自动接管"，实际它只是补漏且易失联。集成必须由开发 Agent 亲手触发并当轮确认结果。

流程：

1. 开发 Agent 在自己 dev 分支开发完成，本地过门禁（§5 分级冒烟 + 范围 gdlint/gdformat）后 `git push origin <dev分支>`。
2. push 成功后，开发 Agent **立即主动触发一次** `codex exec`（§4.2 指令），把 review + 起记录 + 合入 main + CI 验证整体交给 Codex CLI。
3. **当轮必须确认 codex exec 结果**：合入成功（origin/main 前进、CI 全绿、dev 与 main 对齐）即收尾；若被门禁拦下（Codex 守纪律列人工点），修复后**重发一次 codex exec**，直至合入。不允许把触发延后、遗忘或外包给后台任务。
4. 不得新建 automation 承担"检测待合批次 / 补触发 / 校验"类职责。集成是**每次开发完成的显式动作**，由开发 Agent 亲手按下。

触发命令模板（§4.2 集成指令以 prompt 文件传给 `codex exec`）：

```bash
codex exec --dangerously-bypass-approvals-and-sandbox -C "E:/Github/godot_ai_game" "<集成指令，见 §4.2>"
```

### 4.2 集成者（Codex CLI，唯一允许 push main 的角色）

Codex CLI 在 **主工作区 `E:\Github\godot_ai_game`** 执行集成，职责：
（**一律经 `codex exec` 非交互驱动**（§4.1.1）；由开发 Agent 每次 push dev 后主动触发，无 automation 兜底）

1. 拉取目标 dev 分支 + 最新 main。
2. **rebase dev 分支到 origin/main**，解决冲突（冲突只可能来自 `shared/` 或公共文件——按 §3 处理；各游戏目录物理隔离不会撞）。
3. 校验没误删他人文件：`git diff origin/main --stat`，确认没有删除别的 `games/<游戏>/` 文件。
4. **按 §5.1 分级跑冒烟**：本批 diff 未触碰 `shared/` 则只冒烟当前游戏；触碰 `shared/` / `.github/` / 仓库级 `tools/` 则全量冒烟。相应 play_test 须 PASS。
5. 在 `main` 上 `git merge --no-ff <dev分支>`（或通过 GitHub 起 PR 合并）。
6. `git push origin main` → 触发 CI，等全绿；CI 红则先修或回退。

> 关键：**只有 Codex CLI（集成者）操作 main**。各游戏 Agent 的 push 权限止步于自己的 dev 分支。
> 这样"谁合入 main、谁来保证 main 始终全绿"职责唯一，从根上杜绝多 Agent 互踩 main。

---

## 5. 合入前 / 日常本地验证（防"把别人游戏弄坏"）

### 5.1 冒烟范围分级（2026-09-03 新增：尽量减少 Codex CLI 工作量）

判定依据 = 本次 dev 批次相对 `origin/main` 的 diff **是否触碰 `shared/`**（共享套件 / addons / 共享样式 / 素材）：

- **未触碰 `shared/`**（只改了本分支自己的 `games/<你的游戏>/`，或纯文档如 CONTRIBUTING.md / 本游戏 README）：
  → Codex CLI 与开发 Agent **只需冒烟当前游戏**，lint/format 只跑当前游戏目录。
- **触碰了 `shared/`**，或 `.github/`（CI/deploy）、仓库级 `tools/` 等会影响多游戏构建的公共文件：
  → **全量冒烟**（suika / dodge / sonar / boom 四游戏）+ 全目录 gdlint/gdformat。
- **无论哪种范围，§4.2 步骤 3 的越界检查始终执行**：`git diff origin/main --stat` 不得删除其它 `games/<游戏>/` 文件——这是防"把别人游戏弄坏"的根本，与冒烟范围无关。
- 冒烟范围是**下限不是上限**：Codex CLI 若对共享/公共改动的影响面不确定，可自行升级为全量冒烟。

单游戏冒烟（仅改动本游戏时）：

```bash
cd <你的 worktree>
bash tools/sync_shared.sh
GODOT=<Godot 4.5 路径>
"$GODOT" --headless --path games/<你的游戏> --import && \
"$GODOT" --headless --path games/<你的游戏> --script res://tools/play_test.gd
gdlint games/<你的游戏>/ && gdformat --check games/<你的游戏>/
```

全量冒烟（触碰 shared/ 或公共文件时）：

```bash
cd <你的 worktree>
bash tools/sync_shared.sh
GODOT=<Godot 4.5 路径>
for g in suika dodge sonar boom; do
  "$GODOT" --headless --path games/$g --import && \
  "$GODOT" --headless --path games/$g --script res://tools/play_test.gd
done
gdlint games/ shared/ && gdformat --check games/ shared/
```

> 任一被要求冒烟的游戏 play_test 非 PASS 即不可 push main。

---

## 6. 目录 / 环境速查（2026-09 迁移后）

- **仓库主工作区（集成口，Codex CLI）**：`E:\Github\godot_ai_game`（main）
- **Sonar worktree**：`E:\Github\worktrees\sonar`（sonar-dev）
- **Boom worktree**：`E:\Github\worktrees\boom`（boom-dev）
- 旧地址 `E:\OneDrive\Task\godot-web-game` 已废弃清理，勿再使用。
- 仓库：`https://github.com/TeenTu/godot_ai_game` → Pages：`https://teentu.github.io/godot_ai_game/<game>/`
- Godot 4.5、隔离 Python、gdlint/gdformat、Codex CLI 等详见 `AGENTS.md`。
