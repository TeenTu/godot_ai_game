"""Extract baked checkerboards and build deterministic M11 runtime sprites."""

from __future__ import annotations

from collections import deque
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "references" / "m11_boss"
OUTPUTS = {
    "lantern_warden_source.png": (
        ROOT / "assets" / "images" / "characters" / "boss_lantern_warden.png",
        480,
    ),
    "spirit_seal_chest_source.png": (
        ROOT / "assets" / "images" / "props" / "boss_spirit_seal_chest.png",
        400,
    ),
}


def _is_checker_pixel(pixel: tuple[int, int, int]) -> bool:
    return max(pixel) - min(pixel) <= 18 and sum(pixel) / 3.0 >= 175.0


def extract_alpha(source: Path) -> Image.Image:
    rgb = Image.open(source).convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    background = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()

    def seed(x: int, y: int) -> None:
        offset = y * width + x
        if not background[offset] and _is_checker_pixel(pixels[x, y]):
            background[offset] = 1
            queue.append((x, y))

    for x in range(width):
        seed(x, 0)
        seed(x, height - 1)
    for y in range(height):
        seed(0, y)
        seed(width - 1, y)
    while queue:
        x, y = queue.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if nx < 0 or nx >= width or ny < 0 or ny >= height:
                continue
            offset = ny * width + nx
            if not background[offset] and _is_checker_pixel(pixels[nx, ny]):
                background[offset] = 1
                queue.append((nx, ny))
    alpha = Image.new("L", rgb.size, 255)
    alpha.putdata([0 if value else 255 for value in background])
    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha)
    bbox = alpha.getbbox()
    if bbox is None:
        raise RuntimeError(f"no foreground found in {source}")
    return rgba.crop(bbox)


def fit_canvas(image: Image.Image, content_size: int) -> Image.Image:
    image.thumbnail((content_size, content_size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    x = (canvas.width - image.width) // 2
    y = (canvas.height - image.height) // 2
    canvas.alpha_composite(image, (x, y))
    return canvas


def main() -> None:
    for source_name, (output, content_size) in OUTPUTS.items():
        output.parent.mkdir(parents=True, exist_ok=True)
        runtime = fit_canvas(extract_alpha(SOURCE / source_name), content_size)
        runtime.save(output, optimize=True, compress_level=9)
        alpha_range = runtime.getchannel("A").getextrema()
        print(f"{output.relative_to(ROOT)} size={output.stat().st_size} alpha={alpha_range}")


if __name__ == "__main__":
    main()
