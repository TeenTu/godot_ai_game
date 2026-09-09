# Boom 武器绑定修复 — 交付总览（2026-09-08）

## 任务

按任务书完成《百怪夜巡》武器绑定系统修复：镇夜灯·镇尺与墨线判笔被人物正确握持、
建立可复用的新武器绑定配置/素材规格/验收流程、改善动作切换连贯性。
坚持 2D 精灵分层动画（AnimatedSprite3D 载体不变），先解耦后校准。

## 已完成

### 1. 武器握持修复（优先级 1）
- **根因修复**：`resolve()` 返回 offset 时错误取反 y（`SpriteBase3D.offset` y+ 向上，
  探针 `probe_offset_y.gd` 实证）→ 武器浮空至头部。改为直接返回 shift，禁止取反。
- **锚点全量校准**：86 项 HANDS/GRIPS 锚点全部落到真实持械手/握柄实体像素
  （alpha ≥ 0.5 + 位置目检），统一右手、同动作周期同手；镜像动作用原始坐标测原始图。
- **手部前景遮挡**：从同帧身体贴图裁 HAND_RECTS 垫回原位重绘（render_priority 4），
  等效手指包握柄，零接缝；已有 idle_down + recoil 标注。

### 2. 可复用绑定配置（优先级 2）
- **三层分离**：战斗武器 ID（boom_weapons def.id）→ 视觉配置 ID（CONFIGS）→ 动画形态
  form；`missing_action_policy`（stow/error）显式声明，禁止静默截断帧号。
- **第三武器零代码接入验证**：`test_pennant` 测试配置纯数据注册（专属子集握柄表 +
  stow 策略），验收 checks 86 → 128 全 PASS，stow 收起经 headless + 渲染双验证。
- **验收工具完善**（复用现有 review 工具，未另起逻辑）：
  - `weapon_binding_review.gd`：headless 数据检查（失败累计 → 退出码 1）、
    `--capture-dir=` 渲染帧排、`--sheet-dir=` 标定图（2x+网格+红/青叉）、
    `--contact-dir=` 接触表；
  - `binding_inspector.tscn`：交互逐帧检查（暂停/逐帧/锚点叠加/分层/放大/固定命名截图）。
- 文档：`tools/WEAPON_BINDING.md` 补三层配置与新武器接入步骤；`tools/ASSET_REWORK.md`
  素材返工清单（R1 swing 换手、R2 ink_brush move f3-f5 漂移、R3 墨迹特效烘入、
  R4 night_ruler 条漂移，各带验收条件与返工流程）。

### 3. 动作连续性（优先级 3）
- 新增 `[m8-motion]` 测试节（play_test_m8.gd，真实战斗状态机驱动，14 项断言）：
  命中恰落在 ACTIVE 出手窗、前摇零命中、swing 逐帧与 FSM 三阶段同步、
  攻速 ×1.2 前摇 15→13 步且命中仍在 ACTIVE、受击 hurt 不被下一帧挥击覆盖、
  挥击中切枪 FSM 复位 + 视觉层重建无残留。
- 近战 FSM 阶段驱动 `sync_swing_phase`（两帧前摇/一帧命中/两帧收招）维持不变，经测试确认。

## 验证结果（本机 Godot 4.5 console）

| 检查 | 结果 |
|---|---|
| weapon_binding_review.gd headless | PASS checks=128 failures=0（exit 0） |
| play_test.gd 冒烟（含 m8-motion） | PLAY_TEST result=PASS（exit 0） |
| gdlint games/ shared/ | 0 问题 |
| gdformat --check | 仅 sonar 2 个既有问题文件（约定不动） |
| --headless --import | exit 0（仅 feature_profiles 噪音） |
| git diff --check | 干净 |

逐帧/动态证据（build/ 下，gitignored）：
- 标定图 `build/binding-sheets/`（2x+网格+锚点叉标）
- 接触表 `build/binding-contacts/`（每动作身体行+武器行+帧号）
- 渲染帧排 `build/binding-capture6/`（真实渲染器逐动作截图）
- offset 方向证据 `games/boom/tools/probe_offset_y.gd`（保留）

## 未做 / 已知限制

- 手部前景遮罩仅 idle_down + recoil，其余动作待素材稳定后补标注（ASSET_REWORK.md 有记录）。
- swing 身体条换手等 4 项素材问题按任务书列为返工项，未调锚点掩盖（见 ASSET_REWORK.md）。
- 未扩展属性系统/武器范围/战斗数值；未动无关游戏与公共文档。
- 临时探针 probe_pixel.gd / probe_override.gd 已删除。
- 代码未 commit/push——按协作规则待群主确认后提交 boom-dev。

---

## 追加：素材返工复验（2026-09-09）

- R1–R4 素材返工（外部管线 apply_asset_rework.py）复验通过：锚点重校正确、
  下劈轨迹连贯、帧字节级一致消除漂移、特效已独立成 effects/ink_brush_swing_fx.png。
- 本次增量：HAND_RECTS 补 swing 五帧手部矩形，三层合成复验五帧手指包杆
  （build/binding-grip-zoom/swing_three_layer_zoom.png）。
- 回归全绿：binding review 128/0、play_test PASS、gdlint 全绿。
- 已提交 7ad768c 并推送 origin/boom-dev（30 files, +1889/-45）；
  main 集成由 Codex 按 CONTRIBUTING §4.2 执行。
- 已知取舍：night_ruler move 条静态化（不随步伐摆动）；fx 条未接入运行时（后续增强）。
