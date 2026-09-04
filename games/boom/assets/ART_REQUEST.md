# Boom art request — boom-3d vertical slice

Raster assets are resized for Web and kept below the repository's 512 KB per-image gate
(default; character strip sheets & icons may reach 1536 KB per design_m5_weapons.md §6/§7).
Most assets use the built-in ImageGen workflow.

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
| `images/characters/bubble_captain.png` | 旧版单帧玩家立绘（保留参照） |
| `images/characters/jelly_scout.png` | Standard jelly enemy Sprite3D art |
| `images/characters/water_gunner.png` | Blue enemy visual variant |
| `images/floors/carnival_tiles.png` | Repeating arena floor material |
| `images/backgrounds/carnival_arena.png` | Warm result-screen backdrop |
| `images/icons/skill_fan.png` | Fan skill HUD icon |
| `images/icons/skill_chain.png` | Chain skill HUD icon |
| `images/icons/skill_nuke.png` | Nuke skill HUD icon |
| `images/icons/coin.png` | Reward counter icon |

## Style invariants

- Player is the only large warm-orange subject; player energy is bright cyan.
- Enemies use saturated cool hues; danger telegraphs alone use alert red.
- Soft diffuse lighting, rounded toy silhouettes, no black outlines or realistic weapons.
- Character and icon files require transparent backgrounds; arena backgrounds are opaque.
- Keep gameplay silhouettes legible after downscaling to approximately 96 logical pixels.
- 同源双形态（design_m5_weapons.md §7.3）：两形态共用身体比例/配色/五官/肚白斑，
  仅武器与持械姿势/动作差异；`hurt` 两形态共用同一帧条。

## Generation manifest

Mode: Codex built-in ImageGen。M5 玩家动画的 prompt 骨架见 `design_m5_weapons.md` §7.1
（同 Bubble Captain 人设、双形态同源约束、暖棕无黑描边）。本批 M5 产出的完整清单见文末「M5 动画素材」小节。

此前各主体的 ImageGen prompt 参考（仍用于敌人/场景等既有素材）：

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
`images/characters/bubble_captain.png` 的橙色泡泡队长、奶油肚皮、蓝色护目镜、白球天线和泡泡枪造型；
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
