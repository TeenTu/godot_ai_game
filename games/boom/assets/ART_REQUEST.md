# Boom art request — boom-3d vertical slice

All raster assets follow `docs/art_bible_boom.md` and the `boom-3d` palette. Generated
sources are produced with the built-in ImageGen workflow, resized for Web, and kept below
the repository's 512 KB per-image gate.

## Delivered assets

| File | Runtime use |
|---|---|
| `images/characters/bubble_captain.png` | Player-facing Sprite3D art |
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

## Generation manifest

Mode: Codex built-in ImageGen. The production prompt set used these subjects with the
shared constraints above:

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
