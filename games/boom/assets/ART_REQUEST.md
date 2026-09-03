# Boom art request — boom-3d vertical slice

Raster assets are resized for Web and kept below the repository's 512 KB per-image gate.
Most assets use the built-in ImageGen workflow; the current player is a direct cutout of
the established milk-frog meme image, without generative redesign.

## Delivered assets

| File | Runtime use |
|---|---|
| `images/characters/milk_frog_hero.png` | Original milk-frog reference and Sprite3D fallback |
| `images/characters/bubble_captain.png` | Retained alternate player character |
| `images/characters/jelly_scout.png` | Standard jelly enemy Sprite3D art |
| `images/characters/water_gunner.png` | Blue enemy visual variant |
| `images/floors/carnival_tiles.png` | Repeating arena floor material |
| `images/backgrounds/carnival_arena.png` | Warm result-screen backdrop |
| `images/icons/skill_fan.png` | Fan skill HUD icon |
| `images/icons/skill_chain.png` | Chain skill HUD icon |
| `images/icons/skill_nuke.png` | Nuke skill HUD icon |
| `images/icons/coin.png` | Reward counter icon |

## Style invariants

- Player is the only large warm-yellow subject; player energy is bright cyan.
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

## Milk-frog source

`milk_frog_hero.png` uses the widely circulated thinking-pose milk-frog image from
`https://syimg.3dmgame.com/uploadimg/ico/2026/0407/1775523785500570.png`.
Processing is limited to connected white-background removal, cropping, resizing and PNG
compression. The face, pose, proportions and colors are unchanged.

The runtime player now uses `scenes/player/milk_frog_3d.tscn`, a native low-poly model
assembled from opaque Godot meshes. Its green protruding eyes, flat mouth, thinking hand,
cream belly and dark feet reproduce the reference silhouette; the image remains available
as a fallback instead of being rendered as the primary player.
