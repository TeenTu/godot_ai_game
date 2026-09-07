# Boom shared change declaration — 2026-09-06

## Change

Update `shared/assets/styles/boom-3d/contract.yaml` from the retired candy-carnival
style to the approved **百怪夜巡·新国风轻 Q 原生 3D** art contract.

## Scope and compatibility

- `rg` confirms `boom-3d` is referenced only by `games/boom/`.
- The contract ID and path are preserved, so CI asset-style injection and the existing
  `project.godot` declaration remain compatible.
- No shared addon, game-kit API, or other game's resource key is changed.

## Source of truth

Human-readable canonical rules are in `docs/art_bible_boom.md`; root `AGENTS.md` links
every future Boom task to that document.
