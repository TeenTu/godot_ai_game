# game_kit — 多端适配 / 触控支持套件

仓库级共享支持套件，**独立于任何游戏**。CI 构建时会自动把它复制进每个
`games/<name>/addons/game_kit/`；本地开发先跑一次同步：

```bash
bash tools/sync_shared.sh
```

| 脚本 | 类名 | 作用 |
|---|---|---|
| `virtual_joystick.gd` | `GameKitVirtualJoystick` | 虚拟摇杆，原生多点触控（`InputEventScreenTouch/Drag`）。`mode` 支持 FIXED / DYNAMIC / FOLLOWING；`use_input_actions=true` 可把方向直接写成 Input Action，与键盘统一处理；读 `output`（-1..1）驱动角色 |
| `touch_button.gd` | `GameKitTouchButton` | 触屏按钮（原生触控响应，程序化绘制），用于重开/跳跃等；连接 `pressed`/`released` 信号 |
| `safe_area.gd` | `GameKitSafeArea` | 刘海/挖孔/手势条安全区适配，作为全屏 UI 的父节点即可，旋转窗口自动重算 |
| `touch_debug.gd` | `GameKitTouchDebug` | 多点触控调试覆盖层，真机上可视化每个触点（参考官方 multitouch_view） |
| `sfx.gd` | `GameKitSfx` | 程序化音效：运行时合成 PCM，零音频素材；`play("pickup"/"boom"/"over"/...)` 按名播放 |
| `fsm.gd` + `fsm_state.gd` | `GameKitFsm` / `GameKitFsmState` | 通用层级状态机：挂子状态节点、设 `start_state`，状态间 `emit finished.emit("xxx")` 切换（面向复杂游戏，参考官方 finite_state_machine） |

## 摇杆模式示例

```gdscript
var j := GameKitVirtualJoystick.new()
j.mode = GameKitVirtualJoystick.Mode.DYNAMIC   # 摇杆出现在手指落点，拇指舒适
j.use_input_actions = true                     # 写入 move_left/right/up/down
j.action_left = "move_left"                    # 与 project.godot 的输入映射一致
```

DYNAMIC / FOLLOWING 模式特别适合触屏游戏：玩家不用精确点到固定底座，任意位置点下即出摇杆。

## 桌面端调试触屏行为

项目设置里开启（本仓库的 suika 已开启）：

```ini
[input_devices]
pointing/emulate_mouse_from_touch=true
pointing/emulate_touch_from_mouse=true
```

前者让真机触控自动兼容鼠标 UI，后者让桌面鼠标可以模拟触摸测试摇杆。

## 参考来源（godot-demo-projects，MIT）

- `mobile/multitouch_view` / `mobile/multitouch_cubes` — 触摸事件处理模式、多指手势状态机
- `3d/platformer` 的 VirtualJoystick 插件 — 摇杆 FIXED/DYNAMIC/FOLLOWING 模式与 input-actions 注入
- `3d/platformer` 的 touch_screen_ui — TouchScreenButton 触屏按键思路（本套件做成零素材 Control）
- `gui/multiple_resolutions` — 多分辨率/拉伸模式设置示例
- `2d/finite_state_machine` — 通用层级状态机（本套件 `GameKitFsm` 直接吸收）

## 新增游戏

1. `mkdir games/<新游戏名>`，用 Godot 打开创建工程（或复制 suika 的骨架）。
2. 每个游戏有自己独立的 `project.godot` 和 `export_presets.cfg`（预设名 `Web`）。
3. 需要 game_kit 就跑一次 `bash tools/sync_shared.sh`（CI 会自动注入）。
4. 推送到 main，CI 自动导出全部游戏并发布：
   - `https://teentu.github.io/godot_ai_game/` — 总索引页
   - `https://teentu.github.io/godot_ai_game/<游戏名>/` — 各游戏
