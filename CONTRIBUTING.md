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
| `E:\Github\godot_ai_game`（主） | `main` | Sonar + 发布把关 | Sonar 主线开发；合并 boom-dev；最终 push main 触发 CI |
| `E:\Github\worktrees\boom` | `boom-dev` | Boom | Boom 独立开发现场（由 Boom 专属 Agent 使用） |

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

## 4. 分支与合入 main 的节奏（CI 只在 main 跑）

CI（`.github/workflows/deploy.yml`）只在 **push 到 `main`** 时触发并部署。因此：

- 各游戏开发在**自己的 worktree / 分支**上进行（如 `boom-dev`），可随意 commit、本地跑测试。
- **合入 `main` 前**该游戏分支应已完成并本地验证通过。
- 合入方式（推荐 `--no-ff` 保留合并记录）：
  ```bash
  # 在要合入的分支上，先同步最新 main
  git fetch origin
  git rebase origin/main          # 或 git merge origin/main
  # 确认没有误删他人文件
  git diff origin/main --stat --stat | grep -E '^ .*games/(?!<你的>)' || echo "无越界改动"
  # 切到 main，合入
  git checkout main
  git merge --no-ff <你的分支>
  git push origin main            # 触发 CI
  ```
- 合入后**等 CI 全绿**（lint + 全部游戏 export-web 冒烟）。若 CI 失败，先在 main 修复或回退，
  不要让 main 长期处于红。
- main 之上不直接做大改；大改走分支合入。

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

- **仓库主工作区**：`E:\Github\godot_ai_game`（main）
- **Boom worktree**：`E:\Github\worktrees\boom`（boom-dev）
- **旧地址 `E:\OneDrive\Task\godot-web-game` 已废弃清理**，勿再使用。
- 仓库：`https://github.com/TeenTu/godot_ai_game` → Pages：`https://teentu.github.io/godot_ai_game/<game>/`
- Godot 4.5、隔离 Python、gdlint/gdformat、Codex CLI 等详见 `AGENTS.md`。
