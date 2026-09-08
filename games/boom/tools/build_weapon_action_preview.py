"""Compose the review sheet for bound weapon action strips."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets" / "images" / "weapons" / "night_patrol"
OUTPUT = ROOT / "assets" / "review" / "night_patrol_weapon_actions_preview.png"
ITEMS = [
    ("镇夜灯·镇尺 · idle（4 帧）", "night_ruler_idle.png"),
    ("镇夜灯·镇尺 · move（6 帧）", "night_ruler_move.png"),
    ("镇夜灯·镇尺 · recoil（3 帧）", "night_ruler_recoil.png"),
    ("墨线判笔 · idle（4 帧）", "ink_brush_idle.png"),
    ("墨线判笔 · move（6 帧）", "ink_brush_move.png"),
    ("墨线判笔 · swing（5 帧）", "ink_brush_swing.png"),
]
CANVAS_W = 1600
CELL_W = 760
CELL_H = 420
GAP = 26
HEADER_H = 76


def get_font(size: int):
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/NotoSansCJK-Regular.ttc")):
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def fit_image(image: Image.Image, max_w: int, max_h: int) -> Image.Image:
    image = image.convert("RGBA")
    scale = min(max_w / image.width, max_h / image.height)
    return image.resize((max(1, int(image.width * scale)), max(1, int(image.height * scale))), Image.Resampling.LANCZOS)


def main() -> None:
    rows = (len(ITEMS) + 1) // 2
    canvas_h = HEADER_H + rows * CELL_H + (rows + 1) * GAP
    canvas = Image.new("RGB", (CANVAS_W, canvas_h), (24, 35, 59))
    draw = ImageDraw.Draw(canvas)
    draw.text((GAP, 20), "百怪夜巡 · 已绑定武器动作条", fill=(244, 232, 208), font=get_font(34))
    for index, (label, filename) in enumerate(ITEMS):
        row, col = divmod(index, 2)
        x = GAP + col * (CELL_W + GAP)
        y = HEADER_H + GAP + row * (CELL_H + GAP)
        cell = Image.new("RGBA", (CELL_W, CELL_H), (16, 24, 42, 255))
        cell_draw = ImageDraw.Draw(cell)
        preview = fit_image(Image.open(SOURCE_DIR / filename), CELL_W - 32, CELL_H - 74)
        cell.alpha_composite(preview, ((CELL_W - preview.width) // 2, 58 + (CELL_H - 58 - preview.height) // 2))
        cell_draw.text((16, 14), label, fill=(244, 232, 208), font=get_font(24))
        canvas.paste(cell.convert("RGB"), (x, y))
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUTPUT, optimize=True)
    print(f"WROTE {OUTPUT} ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
