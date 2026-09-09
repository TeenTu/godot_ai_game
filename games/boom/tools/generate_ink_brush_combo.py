#!/usr/bin/env python3
"""Build the three-action 2D ink-brush combo from reviewed source art.

The ImageGen body sheets remain under assets/references/ for provenance.  This
script normalizes them to the runtime 256px-cell contract, derives isolated
brush rotations around one stable two-hand grip, and draws the independent
ink trails.  Run with --apply after inspecting build/ink-brush-combo/.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[1]
FRAME = 256
RUNTIME = ROOT / "assets" / "images"
REFERENCES = ROOT / "assets" / "references" / "ink_brush_combo"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_asset_rework import _extract_subject, _fit_strip  # noqa: E402


SPECS = {
    "left": {"count": 4, "angles": [42, 18, -42, -76], "arc": (205, 70)},
    "right": {"count": 4, "angles": [-42, -18, 42, 76], "arc": (51, 126)},
    "whirl": {"count": 6, "angles": [-120, -66, -12, 42, 96, 150], "arc": (0, 345)},
}


def _body(action: str, count: int) -> Image.Image:
    source = REFERENCES / ("hero_melee_%s_source.png" % action)
    image = Image.open(source).convert("RGB")
    cells: list[Image.Image] = []
    for index in range(count):
        left = round(index * image.width / count)
        right = round((index + 1) * image.width / count)
        # The final pose can deliberately kiss a cell edge with a cape or boot.
        # A neutral margin lets the shared extractor retain it without mistaking
        # that contact for an unbounded checkerboard component.
        padded = ImageOps.expand(image.crop((left, 0, right, image.height)), border=10, fill=(220, 220, 220))
        cells.append(_extract_subject(padded))
    return _fit_strip(cells, 224, 238, 246)


def _brush(action: str, angles: list[int]) -> Image.Image:
    source = Image.open(RUNTIME / "weapons/night_patrol/ink_brush_swing.png").convert("RGBA")
    raw = source.crop((0, 0, FRAME, FRAME))
    grip = (115, 100)
    # The original five-frame brush was authored as a hero prop.  A two-handed
    # greatsword reads better at ~65% of that silhouette; pin the scaled grip
    # back to the old coordinate so binding data stays stable.
    scale = 0.65
    small = raw.resize((round(FRAME * scale), round(FRAME * scale)), Image.Resampling.LANCZOS)
    base = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    scaled_grip = (round(grip[0] * scale), round(grip[1] * scale))
    base.alpha_composite(small, (grip[0] - scaled_grip[0], grip[1] - scaled_grip[1]))
    strip = Image.new("RGBA", (FRAME * len(angles), FRAME), (0, 0, 0, 0))
    for index, angle in enumerate(angles):
        frame = base.rotate(angle, resample=Image.Resampling.BICUBIC, center=grip)
        strip.alpha_composite(frame, (index * FRAME, 0))
    return strip


def _trail_frame(start: int, end: int, phase: float, action: str) -> Image.Image:
    image = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image, "RGBA")
    sweep = end - start
    visible_end = start + int(sweep * phase)
    if action != "whirl" and phase < 0.20:
        return image
    for radius, width, alpha in ((78, 13, 60), (73, 7, 140), (68, 3, 240)):
        box = (128 - radius, 128 - radius, 128 + radius, 128 + radius)
        draw.arc(box, start=start, end=visible_end, fill=(95, 197, 173, alpha), width=width)
    # A small cinnabar seal dot makes the final spin legible without filling the screen.
    if action == "whirl" and phase > 0.54:
        draw.ellipse((121, 121, 135, 135), fill=(184, 66, 53, 180))
    return image.filter(ImageFilter.GaussianBlur(0.35))


def _effect(action: str, count: int, arc: tuple[int, int]) -> Image.Image:
    strip = Image.new("RGBA", (FRAME * count, FRAME), (0, 0, 0, 0))
    for index in range(count):
        phase = (index + 1) / float(count)
        strip.alpha_composite(_trail_frame(arc[0], arc[1], phase, action), (index * FRAME, 0))
    return strip


def build() -> dict[Path, Image.Image]:
    generated: dict[Path, Image.Image] = {}
    for action, spec in SPECS.items():
        count = int(spec["count"])
        generated[Path("characters/night_patrol/hero_melee_%s_body.png" % action)] = _body(
            action, count
        )
        generated[Path("weapons/night_patrol/ink_brush_swing_%s.png" % action)] = _brush(
            action, list(spec["angles"])
        )
        generated[Path("effects/ink_brush_swing_%s_fx.png" % action)] = _effect(
            action, count, spec["arc"]
        )
    return generated


def validate(generated: dict[Path, Image.Image]) -> None:
    for relative, image in generated.items():
        expected = SPECS[relative.stem.removeprefix("hero_melee_").removeprefix("ink_brush_swing_").removesuffix("_body").removesuffix("_fx")]["count"]
        if image.size != (FRAME * int(expected), FRAME):
            raise ValueError("%s has wrong dimensions %s" % (relative, image.size))
        if image.getchannel("A").getbbox() is None:
            raise ValueError("%s is transparent" % relative)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=ROOT.parents[1] / "build" / "ink-brush-combo")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    generated = build()
    validate(generated)
    for relative, image in generated.items():
        preview = args.output_dir / relative
        preview.parent.mkdir(parents=True, exist_ok=True)
        image.save(preview, optimize=True)
        if args.apply:
            destination = RUNTIME / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(preview, destination)
        print("WROTE", preview)
    print("INK_BRUSH_COMBO result=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
