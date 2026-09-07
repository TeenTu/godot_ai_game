# Boom art request — 百怪夜巡（新国风轻 Q 原生 3D）

Raster assets are resized for Web and kept below the repository's 512 KB per-image gate
(default; character strip sheets & icons may reach 1536 KB per design_m5_weapons.md §6/§7).
Most assets use the built-in ImageGen workflow. The current canonical direction is
`docs/art_bible_boom.md`; all candy-carnival entries below are archival records only.

## Delivered assets

| File | Runtime use |
|---|---|
| `images/characters/player_bubble_idle.png` | 泡泡队长·泡泡形态待机（4 帧横条，AnimatedSprite3D） |
| `images/characters/player_bubble_move.png` | 同上·移动（6 帧横条） |
| `images/characters/player_bubble_recoil.png` | 同上·开火后座（3 帧横条） |
| `images/characters/player_sword_idle.png` | 泡泡队长·大剑形态待机（4 帧横条，同源造型） |
| `images/characters/player_sword_move.png` | 同上·移动（6 帧横条） |
| `images/characters/player_sword_swing.png` | 同上·弧斩全套（8 帧横条） |
| `images/characters/player_hurt.png` | 受击（两形态共用，2 帧横条） |
| `images/icons/weapon_bubble.png` | 武器图标·泡泡枪（128×128） |
| `images/icons/weapon_sword.png` | 武器图标·大剑（128×128） |

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

**Update 2026-09-07 (merge review):** only `bubble_captain.png` is replaced by the
Night Patrol heroine and stays retired. The other eight groups still have no
new-style replacements, so their runtime copies were restored from HEAD to avoid
invisible enemies / blank HUD; they will be retired again per-group as
new-direction replacements land.

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

These base sprites deliberately contain no hand-held weapon. Weapons and attack
effects must be produced as separate assets and attached as an independent visual
layer rather than baked into the heroine image.

## Current style invariants

- 百怪夜巡采用新国风轻 Q 原生 3D：墨夜蓝环境、米纸/布/深木/旧铜材质、暖灯琥珀玩家高光。
- 玩家是背方灯匣的年轻女灯使；黑发红绳、额间朱砂、靛蓝短披风、米白短衣、朱红腰绳为必备识别件。
- 场景和角色均以俯视三分之四、小屏剪影可读为最高优先级；实机角色为约 2.75–3 头身。
- 角色和图标要求透明底；场景背景允许不透明。任何无武器基础角色图必须双手空置。
- 禁止糖果/果冻/气球质感、嘉年华配色、Bubble Captain、奶蛙、真实枪械、照片级写实及黑色描边。

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
