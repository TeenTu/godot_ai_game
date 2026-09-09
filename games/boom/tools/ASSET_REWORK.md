# Boom 素材返工清单 — 武器绑定（WEAPON BINDING ASSET REWORK）

> 本清单只收**素材本身的问题**，锚点/偏移一律不许用调数据的方式掩盖
> （任务书铁律：无法握持的帧列为素材返工，而非调偏移）。
> 返工完成后必须重跑 `tools/weapon_binding_review.gd`（默认 headless 检查 +
> `--sheet-dir=` 标定图 + `--contact-dir=` 接触表）并重新校准 `boom_weapon_binding.gd`
> 中对应 GRIPS 锚点，`PLAY_TEST result=PASS` 后才可勾销。

状态标记：`[ ] 待返工` / `[x] 已返工并复验`

---

## [x] R1 — swing 身体条：挥击周期内换手

- **文件**：`assets/images/characters/night_patrol/hero_melee_swing_body.png`
- **动作**：swing（墨线判笔近战挥击，5 帧 = 2 前摇 / 1 出手 / 2 收招）
- **帧号**：f5（收招第 2 帧）；f4 需一并目检
- **问题**：挥击周期内持械手发生更换——f1–f4 持械手为同一只（掌心锚点约在画布左半 80–100, 43–86 一带连续移动），f5 突跳到对侧（约 146, 134）。违反"同动作周期必须同一只手"，武器在收招瞬间会跳到另一只手上。
- **验收条件**：
  1. 5 帧掌心为同一只手，位置轨迹连续（相邻帧位移无明显跳变）；
  2. `binding_inspector` 中 A 锚点叠加逐帧目检，十字始终落在持械手掌心实体像素上；
  3. 重校 GRIPS `swing` 五帧锚点后，`weapon_binding_review.gd` 全部 PASS（含 alpha 与锚点位置检查）。

## [x] R2 — ink_brush 移动条：f3–f5 画布漂移

- **文件**：`assets/images/weapons/night_patrol/ink_brush_move.png`
- **动作**：move（6 帧行走周期武器条）
- **帧号**：f3–f5
- **问题**：同一动作内武器实体在 256×256 画布内整体位移（漂移），f0–f2 与 f3–f5 无法共用同一握柄锚点，按当前单锚点绑定会出现 f3 起武器滑柄。
- **验收条件**：
  1. 6 帧武器本体在画布中的位置一致（逐帧与 f0 做武器像素区域 diff，位移 ≤ 1px）；
  2. 重校 GRIPS `ink_brush.move` 六帧锚点后 review 全 PASS，`binding_inspector` B/N/M 分层目检行走全程无滑柄。

## [x] R3 — 墨迹特效烘入武器条

- **文件**：`assets/images/weapons/night_patrol/ink_brush_swing.png`（挥击墨迹部分）
- **动作**：swing 武器条
- **帧号**：出手帧（f2）为主，收招帧需目检
- **问题**：墨迹挥砍特效被烘死在武器条里。特效应独立于武器本体（后续走独立视觉层/粒子），烘入会导致特效无法随命中时机独立播控，且干扰握柄 alpha/锚点检查。
- **验收条件**：
  1. 武器条仅含武器本体 + 握持手包握部分，无墨迹/拖尾特效像素；
  2. 特效按 `docs/art_bible_boom.md` 视觉语义（青绿色灵异能量）另出独立序列帧或粒子素材，文件名与规格进 `ART_REQUEST.md`；
  3. 重校 GRIPS `ink_brush.swing` 后 review 全 PASS。

## [x] R4 — night_ruler 待机/移动条：画布漂移（同坐标不同杆位）

- **文件**：`assets/images/weapons/night_patrol/night_ruler_idle.png`、`night_ruler_move.png`
- **动作**：idle（4 帧）/ move（6 帧）
- **帧号**：整条（各帧均存在不同程度的杆身位置不一致）
- **问题**：同一动作各帧中镇尺杆身/杆头在画布内位置不一致（"同坐标不同杆位"），单组 GRIPS 锚点无法整条对齐，idle/move 切换时武器有轻微跳动。
- **验收条件**：
  1. 每条内各帧武器本体位置一致（逐帧 diff 位移 ≤ 1px）；
  2. idle ↔ move 动作切换时杆身位置连续（`binding_inspector` ↑↓ 切动作目检）；
  3. 重校 GRIPS `night_ruler.idle` / `night_ruler.move` 后 review 全 PASS。

---

## 复验记录（2026-09-09，锚点重校 + 前景层补全）

- **R1**：f5 已由 `tools/apply_asset_rework.py` 用同手候选帧整帧替换（f0–f4 未动）。
  复验：新 f4（收招末）掌心标 (81,139) 正确落在下垂手掌上，f0–f4 画面左手同一只，
  下劈轨迹（举拳过顶 → 劈出 → 收于身侧）连贯。标定图 `build/binding-sheets-rework/`。
- **R2**：`ink_brush_move` 六帧 = 原 f0 逐字节重复（`validate()` 字节级断言），
  画布漂移消除；GRIPS `ink_brush.move` 六帧统一为原 f0 锚点 (161,102)。
- **R3**：`ink_brush_swing` 换为无墨迹 clean 条（ImageGen 候选 + alpha 恢复 + 256px 居中 fit）；
  独立特效条落 `assets/images/effects/ink_brush_swing_fx.png`（5×1, 256px，未接入运行时渲染，
  特效层播放属后续增强）。GRIPS `ink_brush.swing` 五帧握点在杆身 35% 处（靠锋端 1/3），
  合成姿态复验：高举劈 → 中位斜劈 → 收于身侧，笔顶不遮脸、锋端方向合理。
- **R4**：`night_ruler_idle` = 原 f0 ×4、`night_ruler_move` = 原 idle f0 ×6（字节级一致）；
  GRIPS `night_ruler.idle/move` 已统一为 (138,157)。代价：move 期间武器不再随步伐摆动（僵硬换稳定），已知取舍。
- **增强（本次新增）**：`HAND_RECTS` 补 swing 五帧手部矩形（40×28，逐帧裁片验证框住握拳/袖口/张掌），
  三层合成（身体→武器→手前景）复验五帧手指全部包住杆身——`build/binding-grip-zoom/swing_three_layer_zoom.png`。
- **回归**：weapon_binding_review PASS 128/0；play_test PASS；gdlint 全绿；gdformat 无改动。

---

## 返工流程（每次返工必走）

1. 按本清单重绘/修帧，保持 256×256 画布、透明底、snake_case 文件名不变；
2. 跑 `tools/check_sprite_sheet.py` 质量门禁 + 拼图预览目检；
3. 跑 `godot --headless --script res://tools/weapon_binding_review.gd`（数据/alpha/锚点检查）；
4. 跑 `--sheet-dir=build/binding-sheets --contact-dir=build/binding-contacts` 出标定图与接触表，重新校准 `boom_weapon_binding.gd` 的 GRIPS（必要时 HANDS）；
5. `binding_inspector.tscn` 逐帧目检（A 锚点叠加、B/N/M 分层、F 放大到游戏尺寸）；
6. `play_test.gd` 冒烟 `PLAY_TEST result=PASS`；
7. 勾销清单条目并在本文件记录复验日期。

## 复验记录

### 2026-09-09 — R1–R4 全部勾销

- `tools/apply_asset_rework.py --apply`：`DRIFT_CHECK result=PASS`；R2/R4 的
  固定画布条逐帧 RGBA 与 f0 完全一致（实际位移 0px）。
- `tools/check_sprite_sheet.py`：身体、判笔 move/swing、镇尺 idle/move、独立墨迹
  VFX 共 6 个序列全部通过 256×256 透明帧门禁。
- `tools/weapon_binding_review.gd`：`PASS checks=128 failures=0`；已重校
  `boom_weapon_binding.gd` 的 swing HANDS 及镇尺/判笔 GRIPS。
- 非 headless 实际渲染输出 `build/rework-rendered/` 已逐帧目检：挥击末帧保持同手，
  判笔移动无滑柄，镇尺 idle/move 无素材画布跳变，判笔挥击条不含墨迹特效。
- `tools/play_test.gd`：`PLAY_TEST result=PASS`。
- 独立特效已落在 `assets/images/effects/ink_brush_swing_fx.png`，规格已写入
  `assets/ART_REQUEST.md`；其播放接线属于效果系统实现，不再阻塞本素材返工清单。

## 已知限制（非返工项，记录在案）

- 手部前景遮罩（HAND_RECTS）目前仅标注 `idle_down`（4 矩形）与 `recoil`（3 矩形）；其余动作的手部前景层暂不显示，待各动作素材稳定后按同法补标注。
- `test_pennant` 为第三武器扩展能力验证配置，不参与真实素材返工。
