#!/usr/bin/env python3
"""Build deterministic runtime candidates for ASSET_REWORK.md R1-R4.

ImageGen outputs are retained as reference inputs. This script extracts their subjects,
restores alpha, normalizes 256px cells, and applies mechanical fixes to the tracked
runtime strips. Run without --apply to write review candidates under build/.
"""

from __future__ import annotations

import argparse
import shutil
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "assets" / "images"
REWORK = ROOT / "assets" / "references" / "rework"
FRAME = 256


def _components(mask: np.ndarray) -> list[list[tuple[int, int]]]:
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    found: list[list[tuple[int, int]]] = []
    for y in range(height):
        for x in range(width):
            if not mask[y, x] or seen[y, x]:
                continue
            queue = deque([(x, y)])
            seen[y, x] = True
            points: list[tuple[int, int]] = []
            while queue:
                px, py = queue.popleft()
                points.append((px, py))
                for nx, ny in ((px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)):
                    if 0 <= nx < width and 0 <= ny < height and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        queue.append((nx, ny))
            found.append(points)
    return found


def _extract_subject(cell: Image.Image) -> Image.Image:
    """Extract colored/dark subject from ImageGen's neutral checker preview."""
    rgb = np.asarray(cell.convert("RGB"), dtype=np.int16)
    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    light = rgb.mean(axis=2)
    strong = np.logical_or(chroma >= 18, light <= 110)
    components = _components(strong)
    if not components:
        raise ValueError("ImageGen candidate contains no extractable subject")
    # Keep meaningful central components; this retains separated tassels but rejects paper wrinkles.
    # The intended subject is one dominant component. Keeping every medium component also
    # preserves folds/checker seams from the generated RGB preview.
    selected = np.zeros_like(strong)
    points = max(components, key=len)
    xs = [point[0] for point in points]
    if min(xs) <= 2 or max(xs) >= cell.width - 3:
        raise ValueError("Dominant candidate component touches its cell edge")
    ys = [point[1] for point in points]
    selected[ys, xs] = True
    # Restore enclosed light areas (shirt, metal highlights) without reintroducing the checker.
    outside = np.zeros_like(selected)
    queue: deque[tuple[int, int]] = deque()
    height, width = selected.shape
    for x in range(width):
        queue.extend(((x, 0), (x, height - 1)))
    for y in range(height):
        queue.extend(((0, y), (width - 1, y)))
    while queue:
        px, py = queue.popleft()
        if outside[py, px] or selected[py, px]:
            continue
        outside[py, px] = True
        for nx, ny in ((px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)):
            if 0 <= nx < width and 0 <= ny < height:
                queue.append((nx, ny))
    selected = np.logical_or(selected, np.logical_not(np.logical_or(outside, selected)))
    alpha = Image.fromarray(selected.astype(np.uint8) * 255).filter(ImageFilter.GaussianBlur(0.45))
    result = cell.convert("RGBA")
    result.putalpha(alpha)
    bounds = alpha.getbbox()
    if bounds is None:
        raise ValueError("ImageGen candidate extraction produced empty alpha")
    return result.crop(bounds)


def _candidate_cells(path: Path, count: int) -> list[Image.Image]:
    image = Image.open(path).convert("RGB")
    cells: list[Image.Image] = []
    for index in range(count):
        left = round(index * image.width / count)
        right = round((index + 1) * image.width / count)
        cells.append(_extract_subject(image.crop((left, 0, right, image.height))))
    return cells


def _fit_strip(cells: list[Image.Image], max_width: int, max_height: int, baseline: int | None) -> Image.Image:
    scale = min(max_width / max(cell.width for cell in cells), max_height / max(cell.height for cell in cells))
    strip = Image.new("RGBA", (FRAME * len(cells), FRAME), (0, 0, 0, 0))
    for index, cell in enumerate(cells):
        resized = cell.resize(
            (round(cell.width * scale), round(cell.height * scale)), Image.Resampling.LANCZOS
        )
        x = index * FRAME + (FRAME - resized.width) // 2
        y = (FRAME - resized.height) // 2 if baseline is None else baseline - resized.height
        strip.alpha_composite(resized, (x, y))
    return strip


def _repeat_frame(path: Path, count: int, frame_index: int = 0) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    frame = image.crop((frame_index * FRAME, 0, (frame_index + 1) * FRAME, FRAME))
    strip = Image.new("RGBA", (FRAME * count, FRAME), (0, 0, 0, 0))
    for index in range(count):
        strip.alpha_composite(frame, (index * FRAME, 0))
    return strip


def _same_hand_body() -> Image.Image:
    runtime = Image.open(
        RUNTIME / "characters" / "night_patrol" / "hero_melee_swing_body.png"
    ).convert("RGBA")
    replacement = _fit_strip(
        [_candidate_cells(REWORK / "hero_melee_swing_same_hand_candidate.png", 5)[4]],
        224,
        238,
        246,
    )
    # Rebuild the strip instead of compositing over the old fifth frame. This keeps
    # repeated runs byte-stable and guarantees that the opposite-hand pose is gone.
    result = Image.new("RGBA", runtime.size, (0, 0, 0, 0))
    result.alpha_composite(runtime.crop((0, 0, FRAME * 4, FRAME)), (0, 0))
    result.alpha_composite(replacement.crop((0, 0, FRAME, FRAME)), (4 * FRAME, 0))
    return result


def _clean_brush_swing() -> Image.Image:
    cells = _candidate_cells(REWORK / "ink_brush_swing_clean_candidate.png", 5)
    return _fit_strip(cells, 220, 220, None)


def _ink_effect_only() -> Image.Image:
    source = Image.open(REWORK / "ink_brush_swing_fx_candidate.png").convert("RGBA")
    cells: list[Image.Image] = []
    for index in range(5):
        left = round(index * source.width / 5)
        right = round((index + 1) * source.width / 5)
        cell = source.crop((left, 0, right, source.height))
        bounds = cell.getchannel("A").getbbox()
        if bounds is None:
            raise ValueError(f"VFX candidate frame {index} is empty")
        cells.append(cell.crop(bounds))
    return _fit_strip(cells, 232, 232, None)


def build(output: Path) -> dict[Path, Image.Image]:
    weapons = RUNTIME / "weapons" / "night_patrol"
    return {
        Path("characters/night_patrol/hero_melee_swing_body.png"): _same_hand_body(),
        Path("weapons/night_patrol/ink_brush_move.png"): _repeat_frame(weapons / "ink_brush_move.png", 6),
        Path("weapons/night_patrol/ink_brush_swing.png"): _clean_brush_swing(),
        Path("weapons/night_patrol/night_ruler_idle.png"): _repeat_frame(weapons / "night_ruler_idle.png", 4),
        Path("weapons/night_patrol/night_ruler_move.png"): _repeat_frame(weapons / "night_ruler_idle.png", 6),
        Path("effects/ink_brush_swing_fx.png"): _ink_effect_only(),
    }


def _assert_identical_frames(image: Image.Image, count: int, label: str) -> None:
    reference = image.crop((0, 0, FRAME, FRAME)).tobytes()
    for index in range(1, count):
        frame = image.crop((index * FRAME, 0, (index + 1) * FRAME, FRAME)).tobytes()
        if frame != reference:
            raise ValueError(f"{label} frame {index} drifts from frame 0")


def validate(generated: dict[Path, Image.Image]) -> None:
    """Prove the R2/R4 fixed-canvas requirement with exact pixel equality."""
    _assert_identical_frames(
        generated[Path("weapons/night_patrol/ink_brush_move.png")], 6, "ink_brush_move"
    )
    _assert_identical_frames(
        generated[Path("weapons/night_patrol/night_ruler_idle.png")], 4, "night_ruler_idle"
    )
    _assert_identical_frames(
        generated[Path("weapons/night_patrol/night_ruler_move.png")], 6, "night_ruler_move"
    )


def apply_runtime() -> None:
    """Apply and validate the approved rework after a full sprite regeneration."""
    generated = build(ROOT.parents[1] / "build" / "asset-rework")
    validate(generated)
    for relative, image in generated.items():
        destination = RUNTIME / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        image.save(destination, optimize=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=ROOT.parents[1] / "build" / "asset-rework")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    generated = build(args.output_dir)
    validate(generated)
    print("DRIFT_CHECK result=PASS (exact frame equality; tolerance requirement <= 1px)")
    for relative, image in generated.items():
        preview = args.output_dir / relative
        preview.parent.mkdir(parents=True, exist_ok=True)
        image.save(preview, optimize=True)
        if args.apply:
            destination = RUNTIME / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(preview, destination)
        print("WROTE", preview.relative_to(ROOT.parents[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
