"""Compose a review-only contact sheet for the Night Patrol weapon candidates."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets" / "references" / "night_patrol_weapons"
OUTPUT = ROOT / "assets" / "review" / "night_patrol_weapon_candidates_preview.png"

ITEMS = [
    ("武器 A · 镇夜灯·镇尺", "01_weapon_night_ruler_lantern_concept.png"),
    ("武器 B · 朱砂折伞", "02_weapon_cinnabar_umbrella_concept.png"),
    ("武器 C · 引魂灯绳", "03_weapon_soul_lantern_rope_concept.png"),
    ("武器 D · 墨线判笔", "04_weapon_ink_judge_brush_concept.png"),
    ("灵印 A · 灯火灵印（5 帧源条）", "05_projectile_lantern_seal_source_strip.png"),
    ("灵印 B · 纸符流光（5 帧源条）", "06_projectile_paper_talisman_source_strip.png"),
    ("灵印 C · 封缚墨线（5 帧源条）", "07_projectile_ink_binding_source_strip.png"),
]

CANVAS_W = 1600
CELL_W = 760
CELL_H = 500
GAP = 26
HEADER_H = 76
ROWS = 4


def font(size: int):
    candidates = [
        Path("C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/NotoSansCJK-Regular.ttc"),
    ]
    for path in candidates:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def fit_image(image: Image.Image, max_w: int, max_h: int) -> Image.Image:
    image = image.convert("RGBA")
    scale = min(max_w / image.width, max_h / image.height)
    size = (max(1, int(image.width * scale)), max(1, int(image.height * scale)))
    return image.resize(size, Image.Resampling.LANCZOS)


def main() -> None:
    canvas_h = HEADER_H + ROWS * CELL_H + (ROWS + 1) * GAP
    canvas = Image.new("RGB", (CANVAS_W, canvas_h), (24, 35, 59))
    draw = ImageDraw.Draw(canvas)
    title_font = font(34)
    label_font = font(24)
    draw.text((GAP, 20), "百怪夜巡 · 武器与灵印投射物候选", fill=(244, 232, 208), font=title_font)

    for index, (label, filename) in enumerate(ITEMS):
        row = index // 2
        col = index % 2
        x = GAP + col * (CELL_W + GAP)
        y = HEADER_H + GAP + row * (CELL_H + GAP)
        cell = Image.new("RGBA", (CELL_W, CELL_H), (16, 24, 42, 255))
        cell_draw = ImageDraw.Draw(cell)
        source = Image.open(SOURCE_DIR / filename)
        preview = fit_image(source, CELL_W - 32, CELL_H - 74)
        px = (CELL_W - preview.width) // 2
        py = 54 + (CELL_H - 54 - preview.height) // 2
        cell.alpha_composite(preview, (px, py))
        cell_draw.text((16, 14), label, fill=(244, 232, 208), font=label_font)
        canvas.paste(cell.convert("RGB"), (x, y))

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUTPUT, optimize=True)
    print(f"WROTE {OUTPUT} ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
