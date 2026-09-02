"""Generate every Foundry art asset using only Pillow geometry.

The shapes, palette, sizes and filenames are defined by assets/ART_REQUEST.md.
No fonts, external images, network resources, randomness, or AI generation are used.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "assets" / "icons"
UI_DIR = ROOT / "assets" / "ui"
BG_DIR = ROOT / "assets" / "bg"

OUTLINE = "#2B2B2B"
WHITE = "#FFFFFF"
PALETTE = {
    "orange": "#FF8A3D",
    "yellow": "#FFD23F",
    "red": "#FF4D4D",
    "green": "#4CD964",
    "blue": "#4A9DFF",
    "purple": "#B06CFF",
    "pink": "#FF6EC7",
    "cyan": "#3DDAD7",
    "gold": "#FFC93C",
}
SS = 3


def darken(hex_color: str, amount: float) -> str:
    rgb = tuple(int(hex_color[i : i + 2], 16) for i in (1, 3, 5))
    return "#" + "".join(f"{round(c * (1.0 - amount)):02X}" for c in rgb)


class Canvas:
    """Supersampled RGBA drawing surface with coordinates in final pixels."""

    def __init__(self, size: int):
        self.size = size
        self.image = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
        self.draw = ImageDraw.Draw(self.image)

    @staticmethod
    def _p(value: float) -> int:
        return round(value * SS)

    def box(self, values):
        return tuple(self._p(v) for v in values)

    def polygon(self, points, **kwargs):
        self.draw.polygon([(self._p(x), self._p(y)) for x, y in points], **kwargs)

    def line(self, points, fill, width, joint="curve"):
        self.draw.line(
            [(self._p(x), self._p(y)) for x, y in points],
            fill=fill,
            width=self._p(width),
            joint=joint,
        )

    def ellipse(self, box, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self._p(kwargs["width"])
        self.draw.ellipse(self.box(box), **kwargs)

    def rounded_rectangle(self, box, radius, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self._p(kwargs["width"])
        self.draw.rounded_rectangle(self.box(box), radius=self._p(radius), **kwargs)

    def rectangle(self, box, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self._p(kwargs["width"])
        self.draw.rectangle(self.box(box), **kwargs)

    def pieslice(self, box, start, end, **kwargs):
        if "width" in kwargs:
            kwargs["width"] = self._p(kwargs["width"])
        self.draw.pieslice(self.box(box), start, end, **kwargs)

    def arc(self, box, start, end, fill, width):
        self.draw.arc(self.box(box), start, end, fill=fill, width=self._p(width))

    def regular_polygon(self, center, radius, sides, rotation=-90, **kwargs):
        pts = []
        for i in range(sides):
            a = math.radians(rotation + i * 360 / sides)
            pts.append((center[0] + radius * math.cos(a), center[1] + radius * math.sin(a)))
        self.polygon(pts, **kwargs)

    def save(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        final = self.image.resize((self.size, self.size), Image.Resampling.LANCZOS)
        final.save(path, "PNG")


def outlined_polygon(c: Canvas, points, fill, width):
    c.polygon(points, fill=fill)
    closed = list(points) + [points[0]]
    c.line(closed, OUTLINE, width, joint="curve")


def outlined_line(c: Canvas, points, fill, width, outline_width):
    c.line(points, OUTLINE, width + 2 * outline_width, joint="curve")
    c.line(points, fill, width, joint="curve")


def base_icon(size: int, main: str):
    c = Canvas(size)
    margin = size * 0.075
    c.rounded_rectangle(
        (margin, margin, size - margin, size - margin),
        radius=size * 0.22,
        fill=main,
    )
    # Mandatory lower ellipse shadow, behind the subject.
    c.ellipse(
        (size * 0.22, size * 0.72, size * 0.78, size * 0.84),
        fill=darken(main, 0.40),
    )
    return c, darken(main, 0.25), darken(main, 0.40), round(size * 0.06)


def highlight(c: Canvas, size: int):
    # A bold, deterministic upper-left crescent/highlight arc.
    c.arc(
        (size * 0.145, size * 0.145, size * 0.48, size * 0.48),
        194,
        286,
        fill=WHITE,
        width=size * 0.045,
    )


def gear(c: Canvas, cx, cy, outer, inner, teeth, fill, stroke):
    pts = []
    for i in range(teeth * 4):
        a = math.radians(-90 + i * 360 / (teeth * 4))
        r = outer if i % 4 in (0, 1) else outer * 0.78
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    outlined_polygon(c, pts, fill, stroke)
    c.ellipse((cx - inner, cy - inner, cx + inner, cy + inner), fill=WHITE, outline=OUTLINE, width=stroke)


def draw_mine():
    main = PALETTE["orange"]
    c, body, deep, w = base_icon(512, main)
    # Round mine mouth and timber frame.
    c.pieslice((107, 117, 405, 452), 180, 360, fill=body, outline=OUTLINE, width=w)
    c.rectangle((107, 270, 405, 407), fill=body, outline=OUTLINE, width=w)
    c.pieslice((161, 173, 351, 417), 180, 360, fill=OUTLINE)
    c.rectangle((161, 286, 351, 408), fill=OUTLINE)
    outlined_line(c, [(132, 392), (132, 235), (380, 235), (380, 392)], deep, 28, 11)
    outlined_line(c, [(119, 235), (256, 137), (393, 235)], deep, 27, 11)
    # Crossed pickaxes inside the opening.
    outlined_line(c, [(207, 250), (302, 357)], WHITE, 14, 7)
    outlined_line(c, [(305, 250), (210, 357)], WHITE, 14, 7)
    c.arc((170, 225, 247, 289), 205, 335, fill=WHITE, width=16)
    c.arc((264, 225, 341, 289), 205, 335, fill=WHITE, width=16)
    # Large mine cart in front.
    outlined_polygon(c, [(169, 341), (344, 341), (326, 416), (190, 416)], body, w)
    c.ellipse((187, 398, 239, 450), fill=deep, outline=OUTLINE, width=14)
    c.ellipse((277, 398, 329, 450), fill=deep, outline=OUTLINE, width=14)
    highlight(c, 512)
    c.save(ICON_DIR / "building_mine.png")


def draw_forge():
    main = PALETTE["red"]
    c, body, deep, w = base_icon(512, main)
    # Chimney and massive stone furnace.
    c.rounded_rectangle((156, 118, 232, 258), 18, fill=body, outline=OUTLINE, width=w)
    c.rectangle((139, 109, 249, 154), fill=body, outline=OUTLINE, width=w)
    c.rounded_rectangle((106, 213, 344, 420), 46, fill=body, outline=OUTLINE, width=w)
    c.pieslice((147, 274, 303, 441), 180, 360, fill=OUTLINE)
    c.rectangle((147, 355, 303, 419), fill=OUTLINE)
    # Three chunky flames, using only the icon color family and white.
    for pts, fill in [
        ([(174, 347), (156, 286), (196, 305), (213, 242), (235, 315), (224, 364)], main),
        ([(219, 354), (238, 276), (260, 311), (289, 251), (296, 344), (275, 382)], main),
        ([(197, 364), (218, 313), (244, 350), (264, 301), (274, 382)], WHITE),
    ]:
        outlined_polygon(c, pts, fill, 13)
    # Large anvil at right.
    outlined_polygon(c, [(329, 286), (424, 270), (403, 324), (361, 331), (374, 389), (407, 415), (306, 415), (337, 386)], body, w)
    highlight(c, 512)
    c.save(ICON_DIR / "building_forge.png")


def draw_workshop():
    main = PALETTE["yellow"]
    c, body, deep, w = base_icon(512, main)
    # Workshop body and sloped roof.
    c.rounded_rectangle((125, 239, 392, 418), 22, fill=body, outline=OUTLINE, width=w)
    outlined_polygon(c, [(96, 255), (239, 125), (420, 255)], body, w)
    c.ellipse((193, 181, 286, 274), fill=WHITE, outline=OUTLINE, width=w)
    c.line([(239, 194), (239, 259)], OUTLINE, 14)
    c.line([(207, 227), (272, 227)], OUTLINE, 14)
    # Big roof saw: thick white blade with clear teeth.
    saw = [(238, 145), (314, 85), (347, 112), (332, 132), (361, 138), (344, 158), (371, 168), (350, 187), (378, 201), (263, 199)]
    outlined_polygon(c, saw, WHITE, 14)
    # Big wall gear.
    gear(c, 320, 334, 60, 19, 8, main, 13)
    c.rounded_rectangle((149, 302, 226, 418), 14, fill=deep, outline=OUTLINE, width=16)
    highlight(c, 512)
    c.save(ICON_DIR / "building_workshop.png")


def draw_warehouse():
    main = PALETTE["green"]
    c, body, deep, w = base_icon(512, main)
    c.rounded_rectangle((102, 171, 410, 399), 24, fill=body, outline=OUTLINE, width=w)
    c.rounded_rectangle((88, 145, 424, 213), 20, fill=body, outline=OUTLINE, width=w)
    # Broad roll-up door.
    c.rounded_rectangle((161, 226, 351, 399), 20, fill=deep, outline=OUTLINE, width=w)
    for y in (268, 312, 356):
        c.line([(177, y), (335, y)], WHITE, 12)
    # Three big crates stacked at the door.
    boxes = [(109, 329, 217, 429), (216, 335, 324, 435), (161, 257, 269, 353)]
    for x1, y1, x2, y2 in boxes:
        c.rounded_rectangle((x1, y1, x2, y2), 12, fill=body, outline=OUTLINE, width=18)
        c.line([(x1 + 17, y1 + 17), (x2 - 17, y2 - 17)], OUTLINE, 12)
        c.line([(x2 - 17, y1 + 17), (x1 + 17, y2 - 17)], OUTLINE, 12)
    highlight(c, 512)
    c.save(ICON_DIR / "building_warehouse.png")


def draw_market():
    main = PALETTE["pink"]
    c, body, deep, w = base_icon(512, main)
    # Stall frame and counter.
    outlined_line(c, [(132, 230), (132, 412)], deep, 22, 10)
    outlined_line(c, [(380, 230), (380, 412)], deep, 22, 10)
    c.rounded_rectangle((113, 339, 399, 417), 22, fill=body, outline=OUTLINE, width=w)
    # Striped awning with alternating icon shade/white scallops.
    c.rounded_rectangle((101, 183, 411, 267), 25, fill=body, outline=OUTLINE, width=w)
    for x, fill in [(128, WHITE), (190, deep), (252, WHITE), (314, deep), (376, WHITE)]:
        c.pieslice((x - 31, 218, x + 31, 287), 0, 180, fill=fill, outline=OUTLINE, width=10)
    # Three big coins on counter.
    for x, y, r in [(194, 333, 34), (253, 316, 38), (318, 335, 32)]:
        c.ellipse((x-r, y-r, x+r, y+r), fill=main, outline=OUTLINE, width=14)
        c.arc((x-r+8, y-r+8, x+r-8, y+r-8), 165, 280, fill=WHITE, width=9)
    # Small flag.
    outlined_line(c, [(366, 184), (366, 108)], deep, 13, 7)
    outlined_polygon(c, [(367, 108), (425, 128), (367, 157)], WHITE, 11)
    highlight(c, 512)
    c.save(ICON_DIR / "building_market.png")


def draw_barracks():
    main = PALETTE["blue"]
    c, body, deep, w = base_icon(512, main)
    # Big triangular tent and central flap.
    outlined_polygon(c, [(256, 105), (426, 408), (86, 408)], body, w)
    outlined_polygon(c, [(256, 192), (329, 408), (183, 408)], deep, 17)
    c.line([(256, 192), (256, 395)], WHITE, 14)
    # Crossed sword and shield in front.
    outlined_line(c, [(170, 371), (334, 222)], WHITE, 20, 10)
    outlined_polygon(c, [(347, 202), (334, 250), (307, 224)], WHITE, 12)
    c.line([(174, 333), (211, 374)], OUTLINE, 18)
    outlined_polygon(c, [(309, 289), (376, 313), (365, 383), (309, 422), (253, 383), (242, 313)], main, 18)
    c.line([(309, 310), (309, 399)], WHITE, 12)
    highlight(c, 512)
    c.save(ICON_DIR / "building_barracks.png")


def draw_lab():
    main = PALETTE["purple"]
    c, body, deep, w = base_icon(512, main)
    # Flask neck, rim and conical body.
    c.rounded_rectangle((217, 111, 295, 238), 16, fill=body, outline=OUTLINE, width=w)
    c.rounded_rectangle((195, 99, 317, 152), 18, fill=body, outline=OUTLINE, width=w)
    outlined_polygon(c, [(217, 187), (124, 383), (151, 425), (361, 425), (388, 383), (295, 187)], body, w)
    # Liquid area in lower flask.
    outlined_polygon(c, [(157, 327), (355, 327), (388, 383), (361, 425), (151, 425), (124, 383)], deep, 15)
    # Three large bubbles.
    for x, y, r in [(203, 354, 31), (276, 382, 39), (321, 326, 26)]:
        c.ellipse((x-r, y-r, x+r, y+r), fill=main, outline=OUTLINE, width=13)
        c.ellipse((x-r*.45, y-r*.55, x-r*.05, y-r*.15), fill=WHITE)
    # Four-point star above.
    outlined_polygon(c, [(371, 105), (387, 139), (421, 155), (387, 171), (371, 205), (355, 171), (321, 155), (355, 139)], WHITE, 13)
    highlight(c, 512)
    c.save(ICON_DIR / "building_lab.png")


def draw_gearbox():
    main = PALETTE["cyan"]
    c, body, deep, w = base_icon(512, main)
    # Three visibly meshed gears in triangular arrangement.
    gear(c, 258, 300, 115, 37, 10, body, 19)
    gear(c, 165, 184, 80, 25, 9, deep, 17)
    gear(c, 357, 189, 72, 22, 8, WHITE, 16)
    highlight(c, 512)
    c.save(ICON_DIR / "building_gearbox.png")


def draw_coin():
    main = PALETTE["gold"]
    c, body, deep, w = base_icon(256, main)
    c.ellipse((48, 47, 208, 207), fill=body, outline=OUTLINE, width=w)
    c.ellipse((73, 72, 183, 182), fill=main, outline=OUTLINE, width=w)
    c.arc((86, 84, 171, 171), 160, 282, fill=WHITE, width=12)
    highlight(c, 256)
    c.save(UI_DIR / "icon_coin.png")


def draw_worker():
    main = PALETTE["orange"]
    c, body, deep, w = base_icon(256, main)
    # Round face, ears and a broad safety helmet; limited to the icon's color family.
    c.ellipse((47, 103, 85, 149), fill=body, outline=OUTLINE, width=11)
    c.ellipse((171, 103, 209, 149), fill=body, outline=OUTLINE, width=11)
    c.ellipse((64, 67, 192, 211), fill=body, outline=OUTLINE, width=w)
    c.pieslice((52, 38, 204, 151), 180, 360, fill=main, outline=OUTLINE, width=w)
    c.rounded_rectangle((43, 89, 213, 121), 15, fill=main, outline=OUTLINE, width=w)
    c.rounded_rectangle((116, 45, 140, 97), 9, fill=WHITE)
    # Large eyes and a simple smile.
    c.ellipse((84, 119, 113, 153), fill=WHITE, outline=OUTLINE, width=8)
    c.ellipse((143, 119, 172, 153), fill=WHITE, outline=OUTLINE, width=8)
    c.ellipse((96, 130, 105, 144), fill=OUTLINE)
    c.ellipse((155, 130, 164, 144), fill=OUTLINE)
    c.arc((101, 143, 158, 188), 15, 165, fill=OUTLINE, width=9)
    highlight(c, 256)
    c.save(UI_DIR / "icon_worker.png")


def draw_power():
    main = PALETTE["red"]
    c, body, deep, w = base_icon(256, main)
    bolt = [(139, 43), (67, 145), (116, 145), (94, 216), (193, 111), (143, 111), (166, 43)]
    outlined_polygon(c, bolt, body, w)
    # White hard-edged highlight along the upper-left side.
    c.line([(139, 66), (93, 132), (122, 132)], WHITE, 12, joint="curve")
    highlight(c, 256)
    c.save(UI_DIR / "icon_power.png")


def draw_round():
    main = PALETTE["blue"]
    c, body, deep, w = base_icon(256, main)
    # Thick clockwise circular arrow, built from a broad stroked arc and head.
    c.arc((53, 51, 203, 201), 35, 326, fill=OUTLINE, width=52)
    c.arc((53, 51, 203, 201), 35, 326, fill=body, width=24)
    outlined_polygon(c, [(185, 72), (218, 73), (207, 111)], body, 10)
    c.arc((73, 71, 183, 181), 185, 265, fill=WHITE, width=10)
    highlight(c, 256)
    c.save(UI_DIR / "icon_round.png")


def lerp(a, b, t):
    return round(a + (b - a) * t)


def draw_background():
    width, height = 720, 1280
    top = (255, 224, 163)
    middle = (255, 154, 77)
    bottom = (217, 78, 30)
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        if y <= height // 2:
            t = y / (height / 2)
            a, b = top, middle
        else:
            t = (y - height / 2) / (height / 2)
            a, b = middle, bottom
        color = tuple(lerp(a[i], b[i], t) for i in range(3))
        for x in range(width):
            pixels[x, y] = color

    image = image.convert("RGBA")
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    # One soft-edged diagonal light column, about 40 px wide.
    d.polygon([(165, 0), (205, 0), (545, 895), (505, 895)], fill=(255, 255, 255, 60))
    # Seven fixed light points/stars in the sky.
    stars = [(92, 150, 13), (584, 162, 10), (314, 270, 12), (650, 355, 14), (121, 487, 9), (452, 540, 13), (254, 690, 10)]
    for x, y, r in stars:
        d.ellipse((x-r/3, y-r, x+r/3, y+r), fill=(255, 255, 255, 180))
        d.ellipse((x-r, y-r/3, x+r, y+r/3), fill=(255, 255, 255, 180))

    image = Image.alpha_composite(image, overlay)
    d = ImageDraw.Draw(image)
    ground_y = round(height * 0.70)
    d.rectangle((0, ground_y, width, height), fill="#B33A18")
    silhouette = darken("#C94B1F", 0.15)
    # Four simple factory silhouettes, safely below the UI-heavy middle.
    factories = [
        (20, 1015, 175, 1210, [62, 105]),
        (188, 965, 354, 1210, [238]),
        (370, 1035, 535, 1210, [412, 478]),
        (548, 990, 705, 1210, [615]),
    ]
    for x1, y1, x2, y2, stacks in factories:
        d.rectangle((x1, y1, x2, y2), fill=silhouette)
        roof = []
        step = (x2 - x1) / 3
        for i in range(3):
            xa = x1 + i * step
            roof.extend([(xa, y1), (xa + step * 0.55, y1 - 43), (xa + step, y1)])
        d.polygon(roof + [(x2, y1 + 18), (x1, y1 + 18)], fill=silhouette)
        for sx in stacks:
            d.rectangle((sx, y1 - 120, sx + 30, y1 + 10), fill=silhouette)
            d.ellipse((sx, y1 - 132, sx + 30, y1 - 108), fill=silhouette)
    BG_DIR.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(BG_DIR / "bg_workshop.png", "PNG")


def make_preview():
    names = [
        "building_mine.png", "building_forge.png", "building_workshop.png", "building_warehouse.png",
        "building_market.png", "building_barracks.png", "building_lab.png", "building_gearbox.png",
    ]
    preview = Image.new("RGBA", (1024, 512), WHITE)
    for index, name in enumerate(names):
        with Image.open(ICON_DIR / name) as icon:
            thumb = icon.convert("RGBA").resize((256, 256), Image.Resampling.LANCZOS)
            x = (index % 4) * 256
            y = (index // 4) * 256
            preview.paste(thumb, (x, y), thumb)
    preview.save(ICON_DIR / "_preview.png", "PNG")


def validate():
    expected = {
        **{ICON_DIR / n: ((512, 512), True) for n in [
            "building_mine.png", "building_forge.png", "building_workshop.png", "building_warehouse.png",
            "building_market.png", "building_barracks.png", "building_lab.png", "building_gearbox.png",
        ]},
        **{UI_DIR / n: ((256, 256), True) for n in [
            "icon_coin.png", "icon_worker.png", "icon_power.png", "icon_round.png",
        ]},
        BG_DIR / "bg_workshop.png": ((720, 1280), False),
        ICON_DIR / "_preview.png": ((1024, 512), False),
    }
    failures = []
    for path, (wanted_size, transparent_icon) in expected.items():
        with Image.open(path) as image:
            image.load()
            corners = [image.convert("RGBA").getpixel(p)[3] for p in [(0, 0), (image.width-1, 0), (0, image.height-1), (image.width-1, image.height-1)]]
            print(f"{path.relative_to(ROOT).as_posix()} | {image.size[0]}x{image.size[1]} | {image.mode} | corners_alpha={corners}")
            if image.size != wanted_size:
                failures.append(f"{path.name}: wrong size {image.size}")
            if transparent_icon and (image.mode != "RGBA" or corners != [0, 0, 0, 0]):
                failures.append(f"{path.name}: icon corners/mode invalid")
            if not transparent_icon and any(a != 255 for a in corners):
                failures.append(f"{path.name}: must be opaque")
            if path.name == "_preview.png" and image.mode != "RGBA":
                failures.append(f"{path.name}: preview must be RGBA")
    if failures:
        raise RuntimeError("VALIDATION FAILED: " + "; ".join(failures))
    print(f"VALIDATION PASSED: {len(expected)} PNG files")


def main():
    for directory in (ICON_DIR, UI_DIR, BG_DIR):
        directory.mkdir(parents=True, exist_ok=True)
    for draw in (draw_mine, draw_forge, draw_workshop, draw_warehouse, draw_market, draw_barracks, draw_lab, draw_gearbox):
        draw()
    for draw in (draw_coin, draw_worker, draw_power, draw_round):
        draw()
    draw_background()
    make_preview()
    validate()


if __name__ == "__main__":
    main()
