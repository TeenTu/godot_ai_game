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
IMAGE_DIR = ROOT / "assets" / "images"
REVIEW_DIR = ROOT / "assets" / "review"
WEAPON_REFERENCE_DIR = ROOT / "assets" / "references" / "night_patrol_weapons"
WEAPON_OUTPUT_DIR = IMAGE_DIR / "weapons" / "night_patrol"
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
    "16_hero_move_up_source_strip.png": ("hero_move_up.png", 6, False),
    "17_hero_move_left_source_strip.png": ("hero_move_left.png", 6, False),
    "18_hero_move_right_source_strip.png": ("hero_move_right.png", 6, False),
    "32_hero_move_down_right_source_strip.png": ("hero_move_down_right.png", 6, False),
    "33_hero_move_down_left_source_strip.png": ("hero_move_down_left.png", 6, False),
    "34_hero_move_up_left_source_strip.png": ("hero_move_up_left.png", 6, False),
    "35_hero_move_up_right_source_strip.png": ("hero_move_up_right.png", 6, False),
}

STATIC_ASSETS = {
    "19_paper_doll_enemy_source.png": ("characters/paper_doll.png", (512, 512), True),
    "20_mist_spirit_enemy_source.png": ("characters/mist_spirit.png", (512, 512), True),
    "21_spirit_seal_coin_source.png": ("icons/spirit_seal_coin.png", (256, 256), True),
    "22_rainy_ancient_town_source.png": ("backgrounds/rainy_ancient_town.png", (512, 1080), False),
    "23_wet_stone_tiles_source.png": ("floors/wet_stone_tiles.png", (512, 512), False),
    "24_skill_fan_source.png": ("icons/skill_fan.png", (256, 256), True),
    "25_skill_chain_source.png": ("icons/skill_chain.png", (256, 256), True),
    "26_skill_nuke_source.png": ("icons/skill_nuke.png", (256, 256), True),
}

ENEMY_SPRITES = {
    "27_paper_doll_move_down_source_strip.png": ("paper_doll_move_down.png", 4),
    "28_paper_doll_move_up_source_strip.png": ("paper_doll_move_up.png", 4),
    "29_paper_doll_move_left_source_strip.png": ("paper_doll_move_left.png", 4),
    "30_paper_doll_move_right_source_strip.png": ("paper_doll_move_right.png", 4),
    "31_mist_spirit_float_source_strip.png": ("mist_spirit_float.png", 4),
}

PROJECTILE_SPRITES = {
    "05_projectile_lantern_seal_source_strip.png": ("candidates/projectile_lantern_seal.png", 5),
    "06_projectile_paper_talisman_source_strip.png": (
        "candidates/projectile_paper_talisman.png",
        5,
    ),
    "07_projectile_ink_binding_source_strip.png": ("candidates/projectile_ink_binding.png", 5),
}

PROJECTILE_CONTENT_WIDTH = 220
PROJECTILE_CONTENT_HEIGHT = 220

WEAPON_SPRITES = {
    "08_weapon_night_ruler_idle_source_strip.png": ("night_ruler_idle.png", 4, False),
    "09_weapon_night_ruler_move_source_strip.png": ("night_ruler_move.png", 6, False),
    "10_weapon_night_ruler_recoil_source_strip.png": ("night_ruler_recoil.png", 3, False),
    "11_weapon_ink_brush_idle_source_strip.png": ("ink_brush_idle.png", 4, False),
    "12_weapon_ink_brush_move_source_strip.png": ("ink_brush_move.png", 6, False),
    "13_weapon_ink_brush_swing_source_strip.png": ("ink_brush_swing.png", 5, True),
}

WEAPON_CONTENT_WIDTH = 220
WEAPON_CONTENT_HEIGHT = 220


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
        bounds = _strong_alpha_bounds(cell)
        if bounds is None:
            raise ValueError(f"Frame {index} has no visible pixels")
        cleaned = remove_orphan_fragments(cell.crop(bounds))
        # 清理断开的 AI 小碎片后，按实心像素重新收紧透明边；否则被删掉的脚/披风
        # 会留下不可见底边，后续按高度缩放时造成每帧脚底上下漂移。
        cleaned_bounds = _strong_alpha_bounds(cleaned)
        if cleaned_bounds is None:
            raise ValueError(f"Frame {index} has no visible pixels after cleanup")
        crops.append(cleaned.crop(cleaned_bounds))
    return crops


def _strong_alpha_bounds(image: Image.Image) -> tuple[int, int, int, int] | None:
    """Ignore sub-64 alpha fringes when establishing the planted-foot bounds."""
    alpha = image.getchannel("A").point(lambda value: 255 if value >= 64 else 0)
    return alpha.getbbox()


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
    # 缩放会把原本相连的细小边缘重新采样成独立噪点；在最终帧画布上
    # 再清一次，避免实机看到披风/手脚旁漂浮的孤立像素。
    remove_orphan_fragments(strip)
    # 低于此阈值的残余只是生成边缘的半透明毛刺，不承载角色轮廓；
    # 清掉它们可避免相邻帧之间出现闪烁的细线。
    alpha = strip.getchannel("A").point(lambda value: value if value >= 48 else 0)
    strip.putalpha(alpha)
    palette = strip.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    palette.save(destination, optimize=True)
    return strip


def build_projectile_strip(source: Path, destination: Path, frame_count: int) -> Image.Image:
    """Normalize a five-frame spirit-seal source row into a centered 256px strip."""
    image = Image.open(source).convert("RGBA")
    crops = frame_crops(image, frame_count)
    max_width = max(crop.width for crop in crops)
    max_height = max(crop.height for crop in crops)
    scale = min(PROJECTILE_CONTENT_WIDTH / max_width, PROJECTILE_CONTENT_HEIGHT / max_height)
    strip = Image.new("RGBA", (FRAME_PX * frame_count, FRAME_PX), (0, 0, 0, 0))
    for index, crop in enumerate(crops):
        resized = crop.resize(
            (round(crop.width * scale), round(crop.height * scale)), Image.Resampling.LANCZOS
        )
        x = index * FRAME_PX + (FRAME_PX - resized.width) // 2
        y = (FRAME_PX - resized.height) // 2
        strip.alpha_composite(resized, (x, y))
    palette = strip.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    palette.save(destination, optimize=True)
    return strip


def build_weapon_strip(
    source: Path, destination: Path, frame_count: int, has_checker: bool
) -> Image.Image:
    """Normalize a weapon-only action row for the independent WeaponSocket layer."""
    image = Image.open(source).convert("RGBA")
    if has_checker:
        image = remove_light_checker(image)
    crops = frame_crops(image, frame_count)
    max_width = max(crop.width for crop in crops)
    max_height = max(crop.height for crop in crops)
    scale = min(WEAPON_CONTENT_WIDTH / max_width, WEAPON_CONTENT_HEIGHT / max_height)
    strip = Image.new("RGBA", (FRAME_PX * frame_count, FRAME_PX), (0, 0, 0, 0))
    for index, crop in enumerate(crops):
        resized = crop.resize(
            (round(crop.width * scale), round(crop.height * scale)), Image.Resampling.LANCZOS
        )
        x = index * FRAME_PX + (FRAME_PX - resized.width) // 2
        y = (FRAME_PX - resized.height) // 2
        strip.alpha_composite(resized, (x, y))
    palette = strip.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    palette.save(destination, optimize=True)
    return strip


def build_weapon_icon(source: Path, destination: Path) -> None:
    """Extract the first idle frame for the weapon-selection card icon."""
    frame = Image.open(source).convert("RGBA").crop((0, 0, FRAME_PX, FRAME_PX))
    bounds = frame.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError(f"Weapon idle frame is empty: {source}")
    frame = frame.crop(bounds)
    scale = min(224 / frame.width, 224 / frame.height)
    resized = frame.resize(
        (round(frame.width * scale), round(frame.height * scale)), Image.Resampling.LANCZOS
    )
    icon = Image.new("RGBA", (FRAME_PX, FRAME_PX), (0, 0, 0, 0))
    icon.alpha_composite(resized, ((FRAME_PX - resized.width) // 2, (FRAME_PX - resized.height) // 2))
    palette = icon.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    palette.save(destination, optimize=True)


def build_static_asset(source: Path, destination: Path, target: tuple[int, int], transparent: bool) -> None:
    """Crop a source image when appropriate, then fit/quantize for Web runtime."""
    image = Image.open(source).convert("RGBA")
    if transparent:
        bounds = image.getchannel("A").getbbox()
        if bounds is None:
            raise ValueError(f"Transparent source has no visible pixels: {source}")
        image = image.crop(bounds)
        scale = min(target[0] / image.width, target[1] / image.height)
        resized = image.resize(
            (round(image.width * scale), round(image.height * scale)), Image.Resampling.LANCZOS
        )
        canvas = Image.new("RGBA", target, (0, 0, 0, 0))
        canvas.alpha_composite(
            resized, ((target[0] - resized.width) // 2, (target[1] - resized.height) // 2)
        )
        image = canvas
    else:
        image = image.resize(target, Image.Resampling.LANCZOS)
    palette = image.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    palette.save(destination, optimize=True)


def build_directional_idle(strip: Image.Image, output_name: str) -> None:
    """Use the first planted running frame as a one-frame directional idle placeholder."""
    frame = strip.crop((0, 0, FRAME_PX, FRAME_PX))
    destination = OUTPUT_DIR / output_name
    palette = frame.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    palette.save(destination, optimize=True)


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
        if output_name in {
            "hero_move_up.png",
            "hero_move_left.png",
            "hero_move_right.png",
            "hero_move_down_right.png",
            "hero_move_down_left.png",
            "hero_move_up_left.png",
            "hero_move_up_right.png",
        }:
            idle_name = output_name.replace("move", "idle")
            build_directional_idle(strip, idle_name)
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    for source_name, (relative_output, target, transparent) in STATIC_ASSETS.items():
        source = REFERENCE_DIR / source_name
        destination = IMAGE_DIR / relative_output
        if not source.exists():
            raise FileNotFoundError(f"Missing approved reference source: {source}")
        build_static_asset(source, destination, target, transparent)
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    for source_name, (output_name, frame_count) in ENEMY_SPRITES.items():
        source = REFERENCE_DIR / source_name
        destination = IMAGE_DIR / "characters" / output_name
        if not source.exists():
            raise FileNotFoundError(f"Missing approved reference source: {source}")
        build_strip(source, destination, frame_count, False)
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    for source_name, (relative_output, frame_count) in PROJECTILE_SPRITES.items():
        source = ROOT / "assets" / "references" / "night_patrol_weapons" / source_name
        destination = IMAGE_DIR / "projectiles" / relative_output
        if not source.exists():
            raise FileNotFoundError(f"Missing approved reference source: {source}")
        build_projectile_strip(source, destination, frame_count)
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    weapon_outputs: dict[str, Path] = {}
    for source_name, (output_name, frame_count, has_checker) in WEAPON_SPRITES.items():
        source = WEAPON_REFERENCE_DIR / source_name
        destination = WEAPON_OUTPUT_DIR / output_name
        if not source.exists():
            raise FileNotFoundError(f"Missing approved reference source: {source}")
        build_weapon_strip(source, destination, frame_count, has_checker)
        weapon_outputs[output_name] = destination
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    for source_name, output_name in {
        "night_ruler_idle.png": "weapon_night_ruler.png",
        "ink_brush_idle.png": "weapon_ink_judge_brush.png",
    }.items():
        source = weapon_outputs[source_name]
        destination = IMAGE_DIR / "icons" / output_name
        build_weapon_icon(source, destination)
        print(f"generated {destination.relative_to(ROOT)} ({destination.stat().st_size} bytes)")
    build_review_preview(generated)
    print("generated assets/review/night_patrol_hero_animation_preview.png")
    # Approved R1-R4 corrections are a deterministic final stage. Keeping this in
    # the canonical generator prevents old reference strips from restoring drift,
    # baked VFX, or the opposite-hand recovery pose on the next regeneration.
    from apply_asset_rework import apply_runtime

    apply_runtime()
    print("applied and validated tools/ASSET_REWORK.md corrections")


if __name__ == "__main__":
    main()
