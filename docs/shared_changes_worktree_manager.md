# Worktree 管理器变更声明

日期：2026-09-09

## 变更范围

- 新增 `tools/worktree_manager.ps1`，作为仓库 worktree 拓扑的唯一管理入口。
- 新增 `docs/worktree_registry.json`，登记主仓库、Boom 和 Sonar 的固定路径、分支与 owner。
- 更新 `CONTRIBUTING.md` 与 `AGENTS.md`，禁止 Agent 直接执行 worktree 元数据操作。

## 设计约束

- 不移动、不删除现有 worktree。
- 不自动处理已有未提交改动。
- 不直接操作或删除 `.git/worktrees/*`。
- 长期链接 worktree 使用 `git worktree lock` 防止误 prune。
- 所有结构变更通过 named mutex 串行化。
- 租约状态只写入 Git common dir 下的运行时文件，不进入提交。

## 影响评估

本次变更只影响 worktree 管理流程，不修改任何游戏运行时代码、共享 addon 或素材。
