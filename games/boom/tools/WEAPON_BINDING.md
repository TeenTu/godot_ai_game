# 2D 人物与法器绑定规格

权威数据：`scripts/core/boom_weapon_binding.gd`。本轮锚点为对最终运行时 PNG 的首轮人工标注，
需结合本地 Godot 逐帧画面校准；数值对齐不等于握持姿态已通过美术验收。

## 坐标与播放

- 身体和武器均使用 256×256 单帧画布，左上原点，x 向右、y 向下。
- `HANDS[action][frame]` 标注身体实际持械手的掌心；`GRIPS[form][action][frame]`
  标注法器握柄接触点。坐标针对裁切、缩放后的 PNG，重生成素材必须同步重标。
- 同一个动作全程使用同一只持械手。不得将左右手混用来补偿素材姿态不一致。
- 运行时按双方 pixel_size 换算并对齐掌心和握柄，不再使用固定偏移。
- 向左动作镜像武器及其握柄；身体使用独立方向条。背向武器在身体后层。
- 武器不自行播放，由身体换帧信号同步；闪白、透明度与呼吸缩放共用身体状态。
- hurt / skill_cast / knockdown 当前显式收起手持层；后续若需持续握持，必须补对应动作数据。
- 近战五帧分配为前摇 0–1、命中窗 2、收招 3–4，由战斗状态机驱动。

## 新增武器约束

1. 注册独立的视觉配置与动作条，不得仅替换纹理并沿用另一把武器的握柄坐标。
2. 当前 idle/move/recoil/swing 规格分别为 4/6/3/5 帧；静态方向 idle 明确使用首帧。
   所有引用帧必须有对应握柄数据，缺失即报告错误并隐藏不合法绑定。
3. 每帧武器完整落在画布内，握柄属于实体像素，移除残片、棋盘背景与裁切断面。
   特效应分层，不允许用墨迹特效冒充握柄或掩盖错位。
4. 用本地 Godot 检查两武器四向待机/移动、攻击、受击及切换，重点观察手指遮挡、
   同手连续性、灯匣重叠、握柄滑动和左右镜像；通过后才视为素材验收完成。

旧 `build_weapon_binding_preview.py` 使用固定偏移，仅为历史预览，不能证明运行时对齐。
当前 `visual_review.gd` 使用真实 PlayerAnim2D / WeaponAnim2D 渲染。

`weapon_binding_review.gd` 逐帧检查全部注册视觉配置（当前 128 项 checks）的绑定可见性、同步、纹理边界及掌心/握柄处
Alpha ≥ 0.5；透明区锚点使进程返回失败。加 `--capture-dir=<绝对路径>` 可输出各动作
的完整帧排，需使用非 headless Godot。通过像素检查只证明锚点落在实体上，仍需目检
实际手掌、握柄及同手连续性，不能将衣料或特效的非透明像素当作正确握持。

## 三层配置与新武器接入（M8 起生效）

绑定数据分三层，禁止互相硬编码：

1. **战斗武器 ID**：`boom_weapons.gd` 的 `def.id`（如 `bubble` / `greatsword`），只关心数值与攻击方式。
2. **视觉配置 ID**：`boom_weapon_binding.gd` 的 `CONFIGS`（如 `night_ruler` / `ink_brush` / `test_pennant`），
   声明 `weapon_dir`、`weapon_pixel`、`strips`、`form` 与 `combat_ids` 映射；`visual_for_combat(id)` 负责战斗 ID → 视觉配置解析。
3. **动画形态 form**：配置内 `form` 字段（bubble / sword / ...），决定身体/武器/手部层的装配方式。

### 新武器接入步骤（纯数据配置，不改渲染代码）

1. 素材就位：`assets/images/weapons/<目录>/<配置名>_<动作>.png`（256×256、透明底；帧数 4/6/3/5 对应 idle/move/recoil/swing）。
2. 在 `CONFIGS` 注册新条目：`weapon_dir`、`weapon_pixel`、`strips`、`form`、`combat_ids`；
   动作条不全时必须显式声明 `missing_action_policy`（`stow` 收起 / `error` 报错），禁止静默截断帧号或借用其他武器的握柄表。
3. 在 `GRIPS` 补该配置各动作逐帧握柄锚点；需要手部前景遮挡的动作在 `HAND_RECTS` 标注矩形。
4. 验收链：`weapon_binding_review.gd` headless 检查 → `--sheet-dir=` / `--contact-dir=` 标定图与接触表目检
   → `binding_inspector.tscn` 逐帧交互检查（A 锚点叠加 / B N M 分层 / F 缩放）→ `play_test.gd` 冒烟 PASS。
5. 素材不合格的帧一律登记 `tools/ASSET_REWORK.md` 返工，禁止用调偏移掩盖。
6. 参考实现：`test_pennant` 测试配置——仅注册 idle+recoil 两条、grips 指向专属子集表、
   用 `stow` 策略验证缺失动作显式收起，证明第三武器零代码接入能力。

