"""Create a review-only composite showing body + WeaponSocket alignment."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
BODY_DIR = ROOT / "assets" / "images" / "characters" / "night_patrol"
WEAPON_DIR = ROOT / "assets" / "images" / "weapons" / "night_patrol"
OUTPUT = ROOT / "assets" / "review" / "night_patrol_weapon_binding_preview.png"


def font(size: int):
    path = Path("C:/Windows/Fonts/msyh.ttc")
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def frame(path: Path, index: int) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    return image.crop((index * 256, 0, (index + 1) * 256, 256))


def composite(
    body_path: Path,
    body_index: int,
    weapon_path: Path,
    weapon_index: int,
    x_offset: int,
    weapon_scale: float,
) -> Image.Image:
    body = frame(body_path, body_index)
    weapon = frame(weapon_path, weapon_index)
    weapon = weapon.resize(
        (round(weapon.width * weapon_scale), round(weapon.height * weapon_scale)),
        Image.Resampling.LANCZOS,
    )
    body.alpha_composite(weapon, (128 + x_offset - weapon.width // 2, 12))
    return body


def main() -> None:
    items = [
        ("镇夜灯·镇尺 · idle", BODY_DIR / "hero_idle_unarmed.png", 0, WEAPON_DIR / "night_ruler_idle.png", 0, 42, 0.76),
        ("镇夜灯·镇尺 · recoil", BODY_DIR / "hero_ranged_cast_body.png", 1, WEAPON_DIR / "night_ruler_recoil.png", 1, 42, 0.76),
        ("墨线判笔 · idle", BODY_DIR / "hero_idle_unarmed.png", 0, WEAPON_DIR / "ink_brush_idle.png", 0, 35, 0.92),
        ("墨线判笔 · swing", BODY_DIR / "hero_melee_swing_body.png", 2, WEAPON_DIR / "ink_brush_swing.png", 2, 35, 0.92),
    ]
    canvas = Image.new("RGB", (640, 640), (24, 35, 59))
    draw = ImageDraw.Draw(canvas)
    draw.text((18, 14), "百怪夜巡 · WeaponSocket 绑定预览", fill=(244, 232, 208), font=font(26))
    for index, (label, body, bi, weapon, wi, offset, weapon_scale) in enumerate(items):
        row, col = divmod(index, 2)
        x, y = 18 + col * 310, 62 + row * 280
        tile = Image.new("RGBA", (292, 252), (16, 24, 42, 255))
        tile.alpha_composite(composite(body, bi, weapon, wi, offset, weapon_scale), (18, 26))
        ImageDraw.Draw(tile).text((10, 6), label, fill=(244, 232, 208), font=font(17))
        canvas.paste(tile.convert("RGB"), (x, y))
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUTPUT, optimize=True)
    print(f"WROTE {OUTPUT} ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
