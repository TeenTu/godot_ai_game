"""Build compact 256px runtime skill icons from retained ImageGen masters."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "assets" / "references" / "skill_tree_icons"
OUTPUT_DIR = ROOT / "assets" / "images" / "icons"
CANVAS_SIZE = 256
CONTENT_SIZE = 236
REVIEW_PATH = ROOT / "assets" / "review" / "m10_skill_tree_icons" / "preview.png"


def process(source: Path) -> Path:
    image = Image.open(source).convert("RGBA")
    alpha_box = image.getchannel("A").getbbox()
    if alpha_box is not None:
        image = image.crop(alpha_box)
    image.thumbnail((CONTENT_SIZE, CONTENT_SIZE), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    offset = ((CANVAS_SIZE - image.width) // 2, (CANVAS_SIZE - image.height) // 2)
    canvas.alpha_composite(image, offset)
    output = OUTPUT_DIR / f"skill_{source.name}"
    canvas.save(output, optimize=True, compress_level=9)
    return output


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    outputs: list[Path] = []
    for source in sorted(SOURCE_DIR.glob("*.png")):
        output = process(source)
        outputs.append(output)
        print(f"{output.name}: {output.stat().st_size} bytes")
    review = Image.new("RGB", (1536, 600), (12, 24, 35))
    draw = ImageDraw.Draw(review)
    for index, output in enumerate(outputs):
        col = index % 6
        row = index // 6
        icon = Image.open(output).convert("RGBA")
        review.paste(icon, (col * 256, row * 300), icon)
        draw.text((col * 256 + 8, row * 300 + 266), output.stem.removeprefix("skill_"), fill=(255, 232, 181))
    REVIEW_PATH.parent.mkdir(parents=True, exist_ok=True)
    review.save(REVIEW_PATH, optimize=True)


if __name__ == "__main__":
    main()
