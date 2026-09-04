# boom 批次共享改动声明（M5 武器批次）

> 用途：M5 批次对**仓库级 / 跨游戏共享文件**的改动清单，合并前用于排查与其他批次（sonar /
> Codex 素材等）的冲突。凡未在此列出的改动，均只落在 `games/boom/` 与 `docs/design_m5_weapons.md` 内。

## 1. CI 门禁：Asset size gate 分级（.github/workflows/deploy.yml）

`lint` job 的素材体积红线由"单条 find、全局 512KB"改为**分级**：

- **默认档**：`shared/assets` 与 `games/*/assets/images` 下单张 PNG >512KB 报错；
- **放宽档**：`games/*/assets/images/characters` 与 `games/*/assets/images/icons/`
  允许至 **1536KB**（`-not -path` 排除 + 第二条 find 合并后 `sort -u`）。

依据：`design_m5_weapons.md` §6/§7 的 2048×256 透明底 256 色横条压后体积约
0.8–1.2MB，若维持 512KB 会误伤新动画帧条。

**冲突提示**：该改动影响**全部 game 子目录**的 CI 判定——其他批次若向 characters/icons
提交 >512KB 素材将不再被拦（上限已抬至 1536KB）。若其他批次另有自己的体积口径，
需在此统一对齐。

## 2. 本批次涉及到的其他仓库级文件

- `.github/workflows/deploy.yml`（仅上节 asset gate 一处，无其它 lint/CI 结构调整）
- `docs/design_m5_weapons.md`（新增设计文档，未跟踪、待随批次提交）
- `docs/shared_changes_boom.md`（本文件）
- `games/boom/assets/ART_REQUEST.md`（清理 milk frog 引用 + 更新素材交付清单）

无对 `shared/`（shared GDScript/UI 组件）的代码改动。

## 3. 与 Codex 素材任务对齐：M5 动画帧条路径清单

引擎代码（`scripts/core/boom_player.gd` 的 `FORM_STRIPS`）按以下固定路径与帧数读图，
**正式素材必须保持同名同帧数覆盖**。当前工作树内已有一版程序化占位帧条
（由 `games/boom/tools/gen_assets_m5.py` 生成，未跟踪）；Codex 产出直接覆盖同名文件即可。

| 文件（均在 `games/boom/assets/images/` 下） | 规格 | 用途 |
|---|---|---|
| `characters/player_bubble_idle.png` | 4×256 帧横条 | 泡泡形态待机 |
| `characters/player_bubble_move.png` | 6×256 帧横条 | 泡泡形态移动 |
| `characters/player_bubble_recoil.png` | 3×256 帧横条 | 泡泡开火后座 |
| `characters/player_sword_idle.png` | 4×256 帧横条 | 大剑形态待机 |
| `characters/player_sword_move.png` | 6×256 帧横条 | 大剑形态移动 |
| `characters/player_sword_swing.png` | 8×256 帧横条 | 大剑挥斩攻帧 |
| `characters/player_hurt.png` | 2×256 帧横条 | 双形态共用受击 |
| `icons/weapon_bubble.png` | 方形图标 | 选单缩略图/图标 |
| `icons/weapon_sword.png` | 方形图标 | 选单缩略图/图标 |

约束：单帧 256×256、透明底、横向无缝拼接；素材缺失时引擎自动回退程序化造型
（`ResourceLoader.exists` 判断），不影响逻辑与 CI。
