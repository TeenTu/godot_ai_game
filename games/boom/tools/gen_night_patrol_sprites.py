#!/usr/bin/env python3
"""Build the approved Night Patrol heroine animation strips for Godot.

The high-resolution generated strips are retained in ``assets/references``. This
script slices every action into 256px frames, aligns their feet, removes the one
generation-preview checkerboard, then writes compact alpha PNG strips for runtime.
"""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_DIR = ROOT / "assets" / "references" / "night_patrol_hero"
OUTPUT_DIR = ROOT / "assets" / "images" / "characters" / "night_patrol"
REVIEW_DIR = ROOT / "assets" / "review"
FRAME_PX = 256
CONTENT_WIDTH = 224
CONTENT_HEIGHT = 238
BASELINE_Y = 246

SPRITES = {
    "09_hero_idle_unarmed_source_strip.png": ("hero_idle_unarmed.png", 4, False),
    "10_hero_move_unarmed_source_strip.png": ("hero_move_unarmed.png", 6, False),
    "11_hero_hurt_unarmed_source_strip.png": ("hero_hurt_unarmed.png", 3, False),
    "12_hero_ranged_cast_body_source_strip.png": ("hero_ranged_cast_body.png", 3, False),
    "13_hero_melee_swing_body_source_strip.png": ("hero_melee_swing_body.png", 5, True),
    "14_hero_skill_cast_body_source_strip.png": ("hero_skill_cast_body.png", 4, False),
    "15_hero_knockdown_unarmed_source_strip.png": ("hero_knockdown_unarmed.png", 4, False),
}


def remove_light_checker(image: Image.Image) -> Image.Image:
    """Remove the white/gray checkerboard baked into one generation preview."""
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha > 0 and min(red, green, blue) >= 228 and max(red, green, blue) - min(
                red, green, blue
            ) <= 14:
                pixels[x, y] = (red, green, blue, 0)
    return image


def frame_crops(image: Image.Image, frame_count: int) -> list[Image.Image]:
    """Split a source row into equal visual cells and trim visible content."""
    crops: list[Image.Image] = []
    for index in range(frame_count):
        left = round(index * image.width / frame_count)
        right = round((index + 1) * image.width / frame_count)
        cell = image.crop((left, 0, right, image.height))
        bounds = cell.getchannel("A").getbbox()
        if bounds is None:
            raise ValueError(f"Frame {index} has no visible pixels")
        crops.append(remove_orphan_fragments(cell.crop(bounds)))
    return crops


def remove_orphan_fragments(image: Image.Image) -> Image.Image:
    """Delete tiny disconnected generation artefacts, while retaining character parts."""
    alpha = image.getchannel("A")
    width, height = image.size
    pixels = alpha.load()
    seen: set[tuple[int, int]] = set()
    small_components: list[list[tuple[int, int]]] = []
    for y in range(height):
        for x in range(width):
            if (x, y) in seen or pixels[x, y] < 64:
                continue
            component: list[tuple[int, int]] = []
            stack = [(x, y)]
            seen.add((x, y))
            while stack:
                point_x, point_y = stack.pop()
                component.append((point_x, point_y))
                for next_y in range(max(0, point_y - 1), min(height, point_y + 2)):
                    for next_x in range(max(0, point_x - 1), min(width, point_x + 2)):
                        if (next_x, next_y) not in seen and pixels[next_x, next_y] >= 64:
                            seen.add((next_x, next_y))
                            stack.append((next_x, next_y))
            if len(component) < 700:
                small_components.append(component)
    rgba = image.load()
    for component in small_components:
        for x, y in component:
            rgba[x, y] = (0, 0, 0, 0)
    return image


def build_strip(source: Path, destination: Path, frame_count: int, has_checker: bool) -> Image.Image:
    """Normalize a generated source row into a compact runtime animation strip."""
    image = Image.open(source).convert("RGBA")
    if has_checker:
        image = remove_light_checker(image)
    crops = frame_crops(image, frame_count)
    max_width = max(crop.width for crop in crops)
    max_height = max(crop.height for crop in crops)
    scale = min(CONTENT_WIDTH / max_width, CONTENT_HEIGHT / max_height)
    strip = Image.new("RGBA", (FRAME_PX * frame_count, FRAME_PX), (0, 0, 0, 0))
    for index, crop in enumerate(crops):
        resized = crop.resize(
            (round(crop.width * scale), round(crop.height * scale)), Image.Resampling.LANCZOS
        )
        x = index * FRAME_PX + (FRAME_PX - resized.width) // 2
        y = BASELINE_Y - resized.height
        strip.alpha_composite(resized, (x, y))
    palette = strip.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    palette.save(destination, optimize=True)
    return strip


def build_review_preview(strips: list[tuple[str, Image.Image]]) -> None:
    """Create one dark contact sheet for a quick visual review of every action."""
    row_height = FRAME_PX + 16
    width = max(strip.width for _, strip in strips)
    preview = Image.new("RGBA", (width, row_height * len(strips)), (24, 35, 59, 255))
    for row, (_, strip) in enumerate(strips):
        preview.alpha_composite(strip, (0, row * row_height))
    REVIEW_DIR.mkdir(parents=True, exist_ok=True)
    preview.save(REVIEW_DIR / "night_patrol_hero_animation_preview.png", optimize=True)


def main() -> None:
    generated: list[tuple[str, Image.Image]] = []
    for source_name, (output_name, frame_count, has_checker) in SPRITES.items():
        source = REFERENCE_DIR / source_name
        destination = OUTPUT_DIR / output_name
        if not source.exists():
            raise FileNotFoundError(f"Missing approved reference source: {source}")
        strip = build_strip(source, destination, frame_count, has_checker)
        generated.append((output_name, strip))
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    build_review_preview(generated)
    print("generated assets/review/night_patrol_hero_animation_preview.png")


if __name__ == "__main__":
    main()
