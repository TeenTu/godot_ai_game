# Boom art request — 百怪夜巡（新国风轻 Q 2D 分层帧动画）

Raster assets are resized for Web and kept below the repository's 512 KB per-image gate
(default; character strip sheets & icons may reach 1536 KB under the repository CI rule documented in `.github/workflows/deploy.yml`).
Most assets use the built-in ImageGen workflow. The current canonical direction is
`docs/art_bible_boom.md`; all candy-carnival entries below are archival records only.

## Delivered runtime replacements

The old candy-carnival runtime set is no longer referenced. The live scene uses
the following 百怪夜巡 replacements:

| File | Runtime use |
|---|---|
| `images/characters/paper_doll_move_{down,up,left,right}.png` | 纸偶四向 4 帧移动 |
| `images/characters/mist_spirit_float.png` | 雾灵 4 帧浮动 |
| `images/backgrounds/rainy_ancient_town.png` | 雨夜古镇屏幕背景层 |
| `images/floors/wet_stone_tiles.png` | 湿石路面平铺材质 |
| `images/icons/spirit_seal_coin.png` | 灵印金币图标 |

## Scene cleanup and playable-area expansion (2026-09-08)

- Removed the runtime carnival balloon/decor cluster from `main.gd`; the remaining
  breakable props are gameplay objects and are re-colored as sealed wood boxes and
  old copper vats.
- Expanded the tiled floor from 26×38 to 52×76 world units (approximately 4× area).
  Player/enemy clamps, spawn edges, rails, grid accents and the exit marker use the
  expanded bounds.
- Switched world lighting/background tint to a blue night palette and increased the
  rainy ancient-town backdrop layer opacity so the replacement reads in-game.

## Retired candy-3D assets (2026-09-06)

The former ImageGen candy-toy 3D set was removed from the runtime image tree while
the game's new visual direction is being selected. The nine source PNGs and their
Godot import sidecars remain recoverable under `archive/retired_candy_3d_v1/`:

- `backgrounds/carnival_arena.png`
- `characters/bubble_captain.png`
- `characters/jelly_scout.png`
- `characters/water_gunner.png`
- `floors/carnival_tiles.png`
- `icons/coin.png`
- `icons/skill_fan.png`
- `icons/skill_chain.png`
- `icons/skill_nuke.png`

Runtime code intentionally falls back to its procedural floor, characters and HUD
when these optional textures are absent. Do not restore or replace this set until
the new theme and art contract are approved.

All old candy-carnival references are now either replaced by the assets listed
above or kept only in this archive for rollback; they are not loaded by runtime.

## Night Patrol heroine base sprites (2026-09-06)

The new `百怪夜巡` heroine has three unarmed, transparent-base scene sprites. The
approved high-resolution source renders are retained in
`assets/references/night_patrol_hero/`; `tools/gen_night_patrol_sprites.py` slices,
aligns and quantizes them into 256px-per-frame Web-friendly output strips:

- `images/characters/night_patrol/hero_idle_unarmed.png` — 4 帧待机
- `images/characters/night_patrol/hero_move_unarmed.png` — 6 帧移动
- `images/characters/night_patrol/hero_hurt_unarmed.png` — 3 帧受击
- `images/characters/night_patrol/hero_ranged_cast_body.png` — 3 帧远程施法身体
- `images/characters/night_patrol/hero_melee_swing_body.png` — 5 帧近战挥击身体
- `images/characters/night_patrol/hero_skill_cast_body.png` — 4 帧技能施法身体
- `images/characters/night_patrol/hero_knockdown_unarmed.png` — 4 帧倒地

敌人运行时素材：

- `images/characters/paper_doll_move_down.png`
- `images/characters/paper_doll_move_up.png`
- `images/characters/paper_doll_move_left.png`
- `images/characters/paper_doll_move_right.png`
- `images/characters/mist_spirit_float.png`

纸偶为四向 4 帧行走；雾灵为单向 4 帧浮动。敌人代码按追击向量选纸偶方向，
浮灵不做正背面切换，避免无意义地放大首章素材量。

These base sprites deliberately contain no hand-held weapon. Weapons and attack
effects must be produced as separate assets and attached as an independent visual
layer rather than baked into the heroine image.

## Night Patrol weapon and spirit-seal candidates (2026-09-08)

The heroine's weapon layer and ranged attack are intentionally decoupled from the
body strips. The old term "bullet" is replaced in the art language by a **灵印投射物**
(spirit-seal projectile): a readable, non-firearm burst of lantern light, talisman
paper, or binding ink. All candidate source boards live in
`assets/references/night_patrol_weapons/` and are not wired to runtime until one
weapon + one projectile family is approved.

| Candidate | Reference | Intended combat read |
|---|---|---|
| A · 镇夜灯·镇尺 | `references/night_patrol_weapons/01_weapon_night_ruler_lantern_concept.png` | Short lantern-ruler; strongest default silhouette and close-range seal strikes. |
| B · 朱砂折伞 | `references/night_patrol_weapons/02_weapon_cinnabar_umbrella_concept.png` | Folding ward umbrella; defensive fan/area control with a memorable cinnabar accent. |
| C · 引魂灯绳 | `references/night_patrol_weapons/03_weapon_soul_lantern_rope_concept.png` | Lantern tether; naturally supports pull, chain and target-link skills. |
| D · 墨线判笔 | `references/night_patrol_weapons/04_weapon_ink_judge_brush_concept.png` | Judge brush and ink strokes; highest supernatural identity, with line-trail VFX. |

| Spirit-seal projectile | Reference source strip | Frame intent |
|---|---|---|
| A · 灯火灵印 | `references/night_patrol_weapons/05_projectile_lantern_seal_source_strip.png` | 5 frames: seal bloom → forward flare → trailing lantern ribbon → fade. |
| B · 纸符流光 | `references/night_patrol_weapons/06_projectile_paper_talisman_source_strip.png` | 5 frames: folded talisman → unfurl → burning-gold flight → paper motes. |
| C · 封缚墨线 | `references/night_patrol_weapons/07_projectile_ink_binding_source_strip.png` | 5 frames: jade ring/ink core → stretched binding line → snap impact. |

Source strips are high-resolution review material. After approval they must be
post-processed into centered 256 px/frame transparent strips, pass
`tools/check_sprite_sheet.py`, and remain a separate visual layer consumed by
`BoomBullet`; gameplay collision remains the existing sphere/area logic.

For review and integration dry-runs, the first centered strips are also available
under `images/projectiles/candidates/`:

- `projectile_lantern_seal.png`
- `projectile_paper_talisman.png`
- `projectile_ink_binding.png`

These candidate strips pass the 5×1 / 256×256 sprite-sheet gate but are not selected
as the live attack until the weapon/projectile pairing is approved.

## Selected first weapon set and action binding (2026-09-08)

The first live pairing is now fixed: logical `bubble` keeps its save/skill-tree id
but displays **镇夜灯·镇尺** and fires **灯火灵印**; logical `greatsword` keeps its
compatibility id but displays **墨线判笔** as the heavy melee weapon. Weapon-only
action strips are loaded from `images/weapons/night_patrol/` and mirrored to the
body's animation frame in `BoomPlayer.WeaponSocket`:

- `night_ruler_idle.png` (4), `night_ruler_move.png` (6), `night_ruler_recoil.png` (3)
- `ink_brush_idle.png` (4), `ink_brush_move.png` (6), `ink_brush_swing.png` (5)

The ranged visual is `images/projectiles/candidates/projectile_lantern_seal.png`.
Collision and damage remain in `BoomGame`; only the visual layer changed.
Review sheets: `assets/review/night_patrol_weapon_actions_preview.png` and
`assets/review/night_patrol_weapon_binding_preview.png`.

### Weapon binding asset rework (2026-09-09)

- `images/effects/ink_brush_swing_fx.png`: 5×1 strip, 256×256 per frame,
  transparent background, teal-green spirit-ink slash (`#5FC5AD`) with no weapon,
  character, text, or UI. This is an independent timing/VFX layer; it must never be
  baked back into `ink_brush_swing.png`.
- `ink_brush_swing.png` is now a weapon-only five-frame strip. The source edits are
  archived under `assets/references/rework/`; `tools/apply_asset_rework.py` performs
  deterministic alpha restoration, normalization, fixed-canvas corrections, and
  an exact frame-equality drift check for the move/idle strips.
- Generation mode: Codex built-in ImageGen, followed by deterministic Pillow
  post-processing. The canonical sprite generator reapplies this approved rework as
  its final stage so regeneration cannot restore the rejected assets.

## Current style invariants

- 百怪夜巡采用新国风轻 Q 2D 分层帧动画：墨夜蓝环境、米纸/布/深木/旧铜绘制质感、暖灯琥珀玩家高光；场景中的 `AnimatedSprite3D` 只承载 2D 精灵，不生成原生 3D 角色模型。
- 玩家是背方灯匣的年轻女灯使；黑发红绳、额间朱砂、靛蓝短披风、米白短衣、朱红腰绳为必备识别件。
- 场景和角色均以俯视三分之四、小屏剪影可读为最高优先级；实机角色为约 2.75–3 头身。
- 角色和图标要求透明底；场景背景允许不透明。任何无武器基础角色图必须双手空置。
- 禁止糖果/果冻/气球质感、嘉年华配色、Bubble Captain、奶蛙、真实枪械、照片级写实及黑色描边。

### 八向跑动扩展（2026-09-09）

- 玩家移动从四向扩展为八向：`down`、`down_left`、`left`、`up_left`、`up`、
  `up_right`、`right`、`down_right`；每个方向使用 6 帧横向跑动条，约 12 fps。
- 四条对角线采用同一角色锚点、脚底基线和灯匣比例；输入以 45° 扇区量化，并留约
  8° 防抖余量，避免摇杆在边界抖动时跳帧。对角线待机取对应跑动首帧，保证松杆不突变。
- 运行时仍是 2.5D：角色为 `AnimatedSprite3D` 的透明 2D 雪碧图，武器继续通过
  `WeaponSocket` 独立层和逐帧掌心锚点绑定。

## Generation manifest

Mode: Codex built-in ImageGen。M5 玩家动画的 prompt 骨架见 `design_m5_weapons.md` §7.1
（同 Bubble Captain 人设、双形态同源约束、暖棕无黑描边）。本批 M5 产出的完整清单见文末「M5 动画素材」小节。

此前各主体的 ImageGen prompt 参考（仅供归档追溯，不再代表当前方向）：

1. `Bubble Captain` — orange capsule mascot, cyan goggles, cream belly and antenna ball,
   three-quarter top-down transparent character render.
2. `Jelly Scout` — translucent saturated-green rounded-square gummy with large cream eyes,
   internal bubbles and transparent background.
3. `Water Gunner` — glossy blue balloon enemy, cream toy-water nozzle and dangling droplet,
   transparent background.
4. `Carnival Arena` — portrait coral-and-cream arena, balloons, bunting and gold stars,
   uncluttered gameplay center and no characters or UI.
5. `Carnival Tiles` — orthographic seamless cream tiles with orange lines and sparse cyan dots.
6. `Fan` — five cyan bubbles spreading from one cream spark on an orange circular badge.
7. `Chain` — cyan lightning linking three cream bubbles on a violet circular badge.
8. `Nuke` — gold central bubble with expanding cream rings on a sun-orange circular badge.
9. `Coin` — rounded gold disk with an embossed cream star on a transparent background.

## M5 动画素材（2026-09-04）

本批次全部由 `tools/gen_assets_m5.py` 使用 Pillow 程序化绘制，沿用
已归档的 `archive/retired_candy_3d_v1/characters/bubble_captain.png` 所定义的橙色泡泡队长、奶油肚皮、蓝色护目镜、白球天线和泡泡枪造型；
大剑形态仅替换为暖橙宽刃与奶油白剑柄。所有角色帧为透明底、256×256 单帧、横条、256 色 PNG；图标为透明底 128×128。

| 产出 | 规格 | 字节数 | 自检 |
|---|---|---:|---|
| `images/characters/player_bubble_idle.png` | 1024×256，4 帧 | 29,019 | PASS |
| `images/characters/player_bubble_move.png` | 1536×256，6 帧 | 37,395 | PASS |
| `images/characters/player_sword_idle.png` | 1024×256，4 帧 | 27,838 | PASS |
| `images/characters/player_sword_move.png` | 1536×256，6 帧 | 36,956 | PASS |
| `images/characters/player_sword_swing.png` | 2048×256，8 帧 | 26,188 | PASS |
| `images/characters/player_bubble_recoil.png` | 768×256，3 帧 | 13,288 | PASS |
| `images/characters/player_hurt.png` | 512×256，2 帧 | 13,218 | PASS |
| `images/icons/weapon_bubble.png` | 128×128，独立图标 | 1,305 | PASS（尺寸/透明度） |
| `images/icons/weapon_sword.png` | 128×128，独立图标 | 1,320 | PASS（尺寸/透明度） |

逐帧雪 sprite 自检使用根目录 `tools/check_sprite_sheet.py`，参数为 `--min-fill 0.06 --edge-tol 4 --center-tol 0.3`。
每个文件的目检预览位于 `assets/review/m5_assets/`，文件名为对应 PNG 的 `_preview.png`。

### M5 动画幅度返工（2026-09-04）
仅返工 player_bubble_move、player_sword_move、player_sword_swing、player_bubble_recoil，其余 M5 资产保持不动。move 使用 ±10px 正弦重心起伏并加入左右短腿交替抬步；swing 使用 8 个唯一剑位/角度与逐帧身体倾斜；recoil 使用后仰→半程→归位三态。最终逐帧指标见本次交付回报。
> **状态（2026-09-09）**：本文件中的早期 M5 糖果/泡泡素材清单与提示词均为历史归档，不得据此生成或更新运行时素材。当前素材必须遵循 `docs/art_bible_boom.md` 与 `shared/assets/styles/boom-night-2d/contract.yaml`；仅保留用于追溯的旧记录。

## M10 双武器技能树图标（2026-09-10，当前有效）

生成模式：Codex built-in ImageGen，`stylized-concept`，以现有夜巡技能图标为风格参考；
原始 1024px 透明图保存在 `assets/references/skill_tree_icons/`，运行时版本由
`tools/process_skill_tree_icons.py` 统一裁切为 256×256 并执行 PNG 压缩。

共同原始提示词：

> Use case: stylized-concept. Create a square transparent-background 2D game skill icon for the Chinese fantasy roguelite 百怪夜巡. Match the reference's polished New Chinese fantasy painterly icon language and strong circular readable silhouette: cold ink-night palette, rice-paper texture, old bronze, restrained amber, cinnabar and spectral teal highlights. One centered symbol, no text, no full character, no watermark, no candy/plastic look, no photorealism, no native-3D render. Keep generous transparent padding and crisp readability at 64 pixels.

每枚图标在共同提示词后追加的原始主题如下：

| 运行时图标 | 追加主题 |
|---|---|
| `skill_lamp_quick_wick.png` | A quick newly lit wick with two amber speed trails, communicating faster basic attacks. |
| `skill_lamp_bright_core.png` | A square night lantern with an intense amber core, communicating increased base attack. |
| `skill_lamp_threefold_seal.png` | A central lantern seal splitting into three synchronized amber talisman shots. |
| `skill_lamp_firefly_volley.png` | A square lantern releasing five fan-shaped firefly seals. |
| `skill_lamp_echo.png` | Two concentric amber sound-wave halos around a small square lantern, communicating reduced skill cooldown. |
| `skill_lamp_soul_beacon.png` | A large square lantern beacon projecting a complete circular ring of twelve teal-and-amber seals. |
| `skill_brush_firm_grip.png` | Two crossed wrapped hands gripping a thick dark wooden judge-brush handle, communicating base attack. |
| `skill_brush_flowing_script.png` | A judge brush making two fast alternating ink slash strokes, communicating attack speed. |
| `skill_brush_verdict.png` | A thick dark wooden judge brush completes one huge broad verdict arc in black ink and cinnabar, with three rhythmic stroke echoes suggesting left slash, right slash and great spin. |
| `skill_brush_ink_wave.png` | One giant judge brush sends a focused forward teal-black ink wave shaped like a decisive crescent. |
| `skill_brush_focus.png` | A single controlled breathing ink circle coils tightly around a glowing brush tip, communicating reduced skill cooldown. |
| `skill_brush_seal_domain.png` | A judge brush planted vertically into a cinnabar seal circle, with radial black-ink runes and a spectral teal boundary. |

## M11 首领与宝箱（2026-09-10，当前有效）

生成模式：Codex built-in ImageGen，`stylized-concept`。原始生成图保存在
`assets/references/m11_boss/`；ImageGen 返回的是带伪棋盘格的 RGB 图，因此未直接进入运行时。
`tools/process_m11_assets.py` 使用确定性的边缘连通域算法去除棋盘背景、裁切居中并压缩为
512×512 RGBA；运行时成品为 `images/characters/boss_lantern_warden.png` 和
`images/props/boss_spirit_seal_chest.png`。

提灯无常原始提示词：

> Use case: stylized-concept. Create a production-ready transparent-background 2D boss sprite for the Chinese fantasy roguelite 百怪夜巡, matching the current boom-night-2d direction. A compact 2.75–3-head-tall Chinese night spirit called 提灯无常, viewed from a top-down three-quarter gameplay angle. He wears a tall folded paper hat with no writing, a broad dark ink-blue robe with simplified off-white paper panels, old-bronze fittings and restrained cinnabar cords. He grips a square dark-wood and aged-bronze hand lantern glowing warm amber; two teal spectral hands or wisps emerge around the sleeves. Strong readable silhouette at mobile size, rice-paper and painted-cloth texture, soft painted edges without black outline. Center one full-body character, generous transparent padding, no ground, no text, no UI, no watermark, no candy/plastic look, no photorealism, no native-3D render.

提灯无常比例返工提示词（precise-object-edit）：

> Keep the exact same character identity, costume, lantern, palette and top-down three-quarter orientation, but compress the anatomy into a compact 2.75–3-head-tall light-Q gameplay proportion. Enlarge the head and hat, shorten the torso and legs, broaden the robe silhouette, simplify internal robe detail by about 60%, and keep the lantern large and readable. Preserve transparent background, centered full body, no text, no floor, no black outline, no 3D render.

首领宝箱原始提示词：

> Use case: stylized-concept. Create a production-ready square transparent-background 2D reward chest sprite for the Chinese fantasy roguelite 百怪夜巡, matching the current boom-night-2d direction. A compact spirit-seal chest made of dark wood and aged bronze, viewed from a top-down three-quarter gameplay angle. The lid is bound by one off-white paper seal and restrained cinnabar cord; warm amber light leaks through the lid seam, with exactly three small spectral-teal wisps curling upward. Strong mobile-readable silhouette, rice-paper painted texture, soft edges without black outline. Center one object with generous transparent padding, no ground, no text or readable characters, no UI, no watermark, no candy/plastic look, no photorealism, no native-3D render.
