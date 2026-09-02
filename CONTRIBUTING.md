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

> main 的集成者是 **Codex CLI**。各游戏 Agent 在自己的 dev worktree 写完一批 → push 到远端 dev 分支 → **automation 自动触发** Codex CLI 解决冲突并起 PR / 合并回 main（详见 §4，触发不依赖人工选择）。Agent 不直接 push main。

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
- **不要自己动 main，也不要停下来问"要不要合"。** 合入 main 是自动触发的既定流程，不是人工决策点。
- 一个 dev 批次开发完成并 `git push origin <dev分支>` 成功后，即视为**已进入自动集成队列**。无需人工选择或确认。

### 4.1.1 自动触发（Codex CLI 主执行，automation 兜底）

> 铁律：**"开发完成 → Codex 评审 → 起 PR → 合并 main"是一旦 push dev 即自动衔接的流水线**，
> 任何 Agent / 协作者都无需在中间做"要不要合"的选择。

**主执行者 = Codex CLI，经 `codex exec` 非交互驱动**，真正负责 §4.2 的评审 / 起 PR / 合并 main：

- 集成任务由 **`codex exec` 触发 Codex CLI 执行**（非交互、放行 git 与网络）：
  ```bash
  codex exec --dangerously-bypass-approvals-and-sandbox -C "E:/Github/godot_ai_game" "<集成指令：把 <dev分支> 集成进 main，见 §4.2>"
  ```
- 触发入口可以是游戏 Agent 开发完成 push dev 后、也可以是 CI/webhook/人工脚本，凡是能唤起 `codex exec` 的都算主路径。Codex CLI 是 main 的唯一 push 者。

**兜底 = WorkBuddy automation**（非主执行者，只补漏）：

- 系统维护一个**集成 automation**，职责是**定时监控各 dev 分支是否有已 push 但尚未合入 main 的新 commit**；它**不亲自做集成**，而是检测到待合批次后补一次 `codex exec` 把活交给 Codex，并校验 Codex 是否真合入了 main。
- 触发条件：`sonar-dev` / `boom-dev` 任一分支在最近一次检查中较 `origin/main` 有新增 commit。默认对每个 dev 分支串行处理，一次只集成一个，避免多个 dev 抢 main。
- 若 Codex 集成某批次时 CI 红或冒烟失败，**Codex 负责修复或回退**并记录原因——不回退到人工询问这一步。automation 重试一次仍失败则上报需人工介入点。
- 因此各游戏 Agent 的最终交付动作只有一个：**开发完成 → push 自己的 dev 分支**。之后的评审 / PR / 合并 / CI 由 Codex CLI（主）与 automation（兜底）全自动衔接。

### 4.2 集成者（Codex CLI，唯一允许 push main 的角色）

Codex CLI 在 **主工作区 `E:\Github\godot_ai_game`** 执行集成，职责：
（**通常经 `codex exec` 非交互驱动**（§4.1.1 主路径）；若主路径未及时触发，由 WorkBuddy automation 兜底补一次 `codex exec`）

1. 拉取目标 dev 分支 + 最新 main。
2. **rebase dev 分支到 origin/main**，解决冲突（冲突只可能来自 `shared/` 或公共文件——按 §3 处理；各游戏目录物理隔离不会撞）。
3. 校验没误删他人文件：`git diff origin/main --stat`，确认没有删除别的 `games/<游戏>/` 文件。
4. **跑全量冒烟**（见 §5），确认全部游戏 play_test PASS。
5. 在 `main` 上 `git merge --no-ff <dev分支>`（或通过 GitHub 起 PR 合并）。
6. `git push origin main` → 触发 CI，等全绿；CI 红则先修或回退。

> 关键：**只有 Codex CLI（集成者）操作 main**。各游戏 Agent 的 push 权限止步于自己的 dev 分支。
> 这样"谁合入 main、谁来保证 main 始终全绿"职责唯一，从根上杜绝多 Agent 互踩 main。

---

## 5. 合入前 / 日常本地验证（防"把别人游戏弄坏"）

任何一次 `push main` 前，必须跑**全量冒烟**确认没弄坏其它游戏：

```bash
cd <你的 worktree>
bash tools/sync_shared.sh                    # 注入共享 addons 到各游戏
# 对每个游戏逐个冒烟（headless）
GODOT=<Godot 4.5 路径>
for g in suika dodge sonar boom; do
  "$GODOT" --headless --path games/$g --import && \
  "$GODOT" --headless --path games/$g --script res://tools/play_test.gd
done
# gdlint / gdformat 必须跑全目录（单游戏会漏）
gdlint games/ shared/ && gdformat --check games/ shared/
```

> 任一游戏 play_test 非 PASS 即不可 push main。

---

## 6. 目录 / 环境速查（2026-09 迁移后）

- **仓库主工作区（集成口，Codex CLI）**：`E:\Github\godot_ai_game`（main）
- **Sonar worktree**：`E:\Github\worktrees\sonar`（sonar-dev）
- **Boom worktree**：`E:\Github\worktrees\boom`（boom-dev）
- 旧地址 `E:\OneDrive\Task\godot-web-game` 已废弃清理，勿再使用。
- 仓库：`https://github.com/TeenTu/godot_ai_game` → Pages：`https://teentu.github.io/godot_ai_game/<game>/`
- Godot 4.5、隔离 Python、gdlint/gdformat、Codex CLI 等详见 `AGENTS.md`。
