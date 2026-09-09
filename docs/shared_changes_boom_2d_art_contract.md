# Shared 变更声明：Boom 2D 美术契约切换

日期：2026-09-09  
影响范围：`shared/assets/styles/`、Boom 项目声明与美术入口文档  
状态：已实施，待集成者合并

## 变更

- 新增共享风格 `boom-night-2d`，以 `anchor.png` 为视觉锚点；它定义百怪夜巡的 2D 分层帧动画规范。
- `games/boom/project.godot` 改为声明 `asset_style="boom-night-2d"`。
- `boom-3d` 保留为历史目录并标注退役，禁止新任务引用。

## 不变项与边界

- 世界观、色板、女灯使识别件与 `WeaponSocket` 分层绑定规则不变。
- 世界仍可使用 `Node3D`、`Camera3D` 和 `AnimatedSprite3D` billboard；这是让 2D 精灵进入俯视场景的渲染承载，**不是**把角色改为原生 3D 模型。
- 共享目录变更已按 `CONTRIBUTING.md` 的 shared 协调规则声明；集成时应连同本文件审阅。
