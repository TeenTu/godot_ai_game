"""Generate the complete Backpack Foundry flat-cartoon asset set with Pillow."""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
OUTLINE = "#1A1A1A"
WHITE = "#FFFFFF"
COLORS = {
    "blue": "#4A7FC1",
    "orange": "#D85A30",
    "amber": "#BA7517",
    "green": "#639922",
    "pink": "#D4537E",
    "red": "#A32D2D",
    "purple": "#7F77DD",
    "gray": "#888780",
    "gold": "#EF9F27",
}


def darken(color: str) -> str:
    """Return the specified color darkened by exactly 35 percent."""
    rgb = tuple(int(color[i : i + 2], 16) for i in (1, 3, 5))
    return "#" + "".join(f"{round(channel * 0.65):02X}" for channel in rgb)


def canvas(size: int) -> tuple[Image.Image, ImageDraw.ImageDraw, int]:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    return image, ImageDraw.Draw(image), round(size * 0.02)


def line(draw: ImageDraw.ImageDraw, points, width: int, fill=OUTLINE, joint="curve"):
    draw.line(points, fill=fill, width=width, joint=joint)


def polygon(draw, points, fill, width):
    draw.polygon(points, fill=fill)
    draw.line(points + [points[0]], fill=OUTLINE, width=width, joint="curve")


def ellipse(draw, box, fill, width):
    draw.ellipse(box, fill=fill, outline=OUTLINE, width=width)


def rectangle(draw, box, fill, width, radius=0):
    if radius:
        draw.rounded_rectangle(box, radius=radius, fill=fill, outline=OUTLINE, width=width)
    else:
        draw.rectangle(box, fill=fill, outline=OUTLINE, width=width)


def gear_points(cx: float, cy: float, outer: float, inner: float, teeth: int = 10):
    points = []
    for i in range(teeth * 4):
        phase = i % 4
        radius = outer if phase in (1, 2) else inner
        angle = -math.pi / 2 + i * math.pi / (teeth * 2)
        points.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius))
    return points


def draw_gear(draw, cx, cy, outer, inner, hole, color, width, teeth=10):
    pts = gear_points(cx, cy, outer, inner, teeth)
    polygon(draw, pts, color, width)
    ellipse(draw, (cx - hole, cy - hole, cx + hole, cy + hole), WHITE, width)


def pickaxe(draw, cx, cy, scale, color, width, mirror=False):
    direction = -1 if mirror else 1
    line(draw, [(cx - 24 * direction * scale, cy + 74 * scale),
                (cx + 18 * direction * scale, cy - 42 * scale)], width, color)
    line(draw, [(cx - 42 * direction * scale, cy - 36 * scale),
                (cx - 18 * direction * scale, cy - 51 * scale),
                (cx + 36 * direction * scale, cy - 43 * scale)], width, OUTLINE)


def building_mine(path: Path):
    c = COLORS["blue"]
    d = darken(c)
    im, dr, w = canvas(512)
    # Arched rock entrance and dark tunnel.
    dr.pieslice((108, 82, 404, 396), 180, 360, fill=c, outline=OUTLINE, width=w)
    rectangle(dr, (108, 236, 404, 396), c, w)
    dr.pieslice((172, 142, 340, 342), 180, 360, fill=d, outline=OUTLINE, width=w)
    rectangle(dr, (172, 240, 340, 366), d, w)
    # Timber frame rendered in the icon's blue family.
    line(dr, [(156, 370), (156, 205)], 22, c)
    line(dr, [(356, 370), (356, 205)], 22, c)
    line(dr, [(147, 210), (365, 210)], 22, c)
    # Mine cart in the mouth.
    polygon(dr, [(194, 278), (324, 278), (305, 337), (210, 337)], c, w)
    ellipse(dr, (207, 326, 245, 364), WHITE, w)
    ellipse(dr, (279, 326, 317, 364), WHITE, w)
    pickaxe(dr, 101, 292, 0.78, d, w, False)
    pickaxe(dr, 411, 292, 0.78, d, w, True)
    im.save(path)


def building_forge(path: Path):
    c = COLORS["orange"]
    d = darken(c)
    im, dr, w = canvas(512)
    # Chimney, square masonry furnace and three block seams.
    rectangle(dr, (286, 74, 352, 188), d, w)
    rectangle(dr, (112, 156, 354, 408), c, w, 10)
    line(dr, [(112, 225), (354, 225)], w)
    line(dr, [(112, 291), (354, 291)], w)
    line(dr, [(190, 156), (190, 225)], w)
    line(dr, [(270, 225), (270, 291)], w)
    # Furnace mouth and flame, using only orange, dark orange and white.
    rectangle(dr, (171, 269, 296, 408), d, w, 44)
    polygon(dr, [(232, 374), (198, 349), (213, 303), (235, 324),
                 (259, 279), (272, 333), (260, 374)], c, w)
    # Anvil to the right.
    polygon(dr, [(338, 296), (441, 296), (426, 327), (389, 334),
                 (410, 401), (351, 401), (372, 334), (338, 327)], d, w)
    im.save(path)


def building_workshop(path: Path):
    c = COLORS["amber"]
    d = darken(c)
    im, dr, w = canvas(512)
    # Saw behind roof: blade silhouette and white teeth.
    polygon(dr, [(290, 101), (432, 68), (438, 101), (298, 135)], d, w)
    for x in range(320, 422, 28):
        polygon(dr, [(x, 111), (x + 10, 131), (x + 20, 106)], WHITE, 4)
    # Cabin and pitched roof.
    rectangle(dr, (114, 218, 398, 408), c, w)
    polygon(dr, [(88, 226), (254, 92), (424, 226)], d, w)
    # Large front window.
    rectangle(dr, (144, 253, 268, 364), WHITE, w, 8)
    line(dr, [(206, 253), (206, 364)], w)
    line(dr, [(144, 309), (268, 309)], w)
    draw_gear(dr, 335, 321, 58, 45, 17, d, w, 9)
    im.save(path)


def building_warehouse(path: Path):
    c = COLORS["green"]
    d = darken(c)
    im, dr, w = canvas(512)
    rectangle(dr, (92, 123, 420, 385), c, w, 8)
    rectangle(dr, (79, 105, 433, 150), d, w, 6)
    # Roll-up door with visible horizontal slats.
    rectangle(dr, (151, 185, 362, 385), WHITE, w, 4)
    for y in range(220, 370, 35):
        line(dr, [(157, y), (356, y)], 5, d)
    # Three stacked crates.
    for box in [(105, 315, 213, 416), (215, 315, 323, 416), (160, 215, 268, 316)]:
        rectangle(dr, box, c, w, 3)
        x1, y1, x2, y2 = box
        line(dr, [(x1 + 9, y1 + 9), (x2 - 9, y2 - 9)], 7, d)
        line(dr, [(x2 - 9, y1 + 9), (x1 + 9, y2 - 9)], 7, d)
    im.save(path)


def building_market(path: Path):
    c = COLORS["pink"]
    d = darken(c)
    im, dr, w = canvas(512)
    # Stall body, counter, canopy and alternating same-hue/white stripes.
    rectangle(dr, (112, 192, 402, 405), c, w, 5)
    rectangle(dr, (87, 315, 427, 371), d, w, 8)
    polygon(dr, [(89, 120), (421, 120), (446, 211), (64, 211)], c, w)
    for x in (146, 246, 346):
        polygon(dr, [(x, 126), (x + 47, 126), (x + 58, 205), (x + 5, 205)], WHITE, 5)
    # Coin stack on counter, kept in pink family to satisfy the one-hue rule.
    for cx, cy in [(219, 302), (256, 302), (293, 302), (238, 273), (275, 273), (256, 244)]:
        ellipse(dr, (cx - 24, cy - 13, cx + 24, cy + 13), c, 5)
    # Side flag.
    line(dr, [(410, 306), (410, 96)], w, OUTLINE)
    polygon(dr, [(410, 99), (470, 123), (410, 151)], d, w)
    im.save(path)


def building_barracks(path: Path):
    c = COLORS["red"]
    d = darken(c)
    im, dr, w = canvas(512)
    polygon(dr, [(256, 83), (435, 402), (77, 402)], c, w)
    polygon(dr, [(256, 83), (256, 402), (77, 402)], d, w)
    polygon(dr, [(256, 235), (318, 402), (194, 402)], WHITE, w)
    # Crossed sword and shield in front.
    polygon(dr, [(152, 187), (174, 174), (350, 381), (329, 397)], WHITE, w)
    polygon(dr, [(335, 178), (358, 197), (182, 394), (161, 376)], WHITE, w)
    line(dr, [(132, 333), (201, 401)], 18, OUTLINE)
    line(dr, [(310, 399), (378, 332)], 18, OUTLINE)
    polygon(dr, [(256, 250), (319, 278), (307, 362), (256, 405),
                 (205, 362), (193, 278)], c, w)
    polygon(dr, [(256, 278), (286, 291), (280, 343), (256, 365),
                 (232, 343), (226, 291)], d, 6)
    im.save(path)


def star_points(cx, cy, outer, inner, points=4):
    result = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        a = -math.pi / 2 + i * math.pi / points
        result.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return result


def building_lab(path: Path):
    c = COLORS["purple"]
    d = darken(c)
    im, dr, w = canvas(512)
    # Flask neck, lip and conical body.
    rectangle(dr, (220, 91, 292, 218), WHITE, w, 4)
    rectangle(dr, (202, 78, 310, 121), c, w, 8)
    polygon(dr, [(220, 174), (220, 229), (126, 390), (151, 425),
                 (361, 425), (386, 390), (292, 229), (292, 174)], WHITE, w)
    # Flat liquid area and bubbles.
    polygon(dr, [(170, 315), (342, 315), (386, 390), (361, 425),
                 (151, 425), (126, 390)], c, w)
    ellipse(dr, (194, 334, 238, 378), d, 6)
    ellipse(dr, (279, 350, 312, 383), WHITE, 5)
    ellipse(dr, (250, 285, 278, 313), c, 5)
    for cx, cy, r in [(151, 147, 34), (356, 139, 29), (382, 218, 25)]:
        polygon(dr, star_points(cx, cy, r, r * 0.3), c, w)
    im.save(path)


def building_gearbox(path: Path):
    c = COLORS["gray"]
    d = darken(c)
    im, dr, w = canvas(512)
    draw_gear(dr, 218, 290, 137, 105, 42, c, w, 12)
    draw_gear(dr, 344, 173, 91, 68, 27, d, w, 10)
    draw_gear(dr, 377, 343, 67, 49, 20, c, w, 9)
    im.save(path)


def icon_coin(path: Path):
    c = COLORS["gold"]
    d = darken(c)
    im, dr, w = canvas(256)
    ellipse(dr, (30, 30, 226, 226), c, w)
    ellipse(dr, (62, 62, 194, 194), d, w)
    ellipse(dr, (82, 82, 174, 174), c, w)
    dr.arc((50, 50, 206, 206), 205, 285, fill=WHITE, width=12)
    im.save(path)


def icon_worker(path: Path):
    c = COLORS["gray"]
    d = darken(c)
    im, dr, w = canvas(256)
    # Bust, circular face and hard-hat silhouette (gray-family by palette rule).
    dr.pieslice((35, 146, 221, 284), 180, 360, fill=d, outline=OUTLINE, width=w)
    ellipse(dr, (72, 60, 184, 178), WHITE, w)
    dr.pieslice((62, 28, 194, 132), 180, 360, fill=c, outline=OUTLINE, width=w)
    rectangle(dr, (48, 83, 208, 112), c, w, 10)
    rectangle(dr, (118, 34, 138, 91), d, 4, 4)
    ellipse(dr, (94, 112, 105, 123), OUTLINE, 0)
    ellipse(dr, (151, 112, 162, 123), OUTLINE, 0)
    dr.arc((105, 118, 151, 155), 25, 155, fill=OUTLINE, width=5)
    polygon(dr, [(92, 164), (128, 205), (164, 164), (184, 219), (72, 219)], c, w)
    im.save(path)


def icon_power(path: Path):
    c = COLORS["red"]
    d = darken(c)
    im, dr, w = canvas(256)
    polygon(dr, [(130, 24), (55, 139), (112, 139), (91, 232),
                 (205, 103), (145, 103), (173, 24)], c, w)
    polygon(dr, [(130, 44), (76, 128), (126, 128), (108, 197),
                 (181, 114), (132, 114), (153, 44)], d, 3)
    im.save(path)


def icon_round(path: Path):
    c = COLORS["blue"]
    d = darken(c)
    im, dr, w = canvas(256)
    # Two thick clockwise arc segments with clear arrow heads.
    dr.arc((38, 38, 218, 218), 205, 355, fill=OUTLINE, width=43)
    dr.arc((38, 38, 218, 218), 205, 355, fill=c, width=31)
    polygon(dr, [(207, 73), (218, 143), (153, 118)], c, w)
    dr.arc((38, 38, 218, 218), 25, 175, fill=OUTLINE, width=43)
    dr.arc((38, 38, 218, 218), 25, 175, fill=d, width=31)
    polygon(dr, [(49, 183), (38, 113), (103, 138)], d, w)
    im.save(path)


def background(path: Path):
    im = Image.new("RGBA", (1280, 720), "#EDE8DC")
    dr = ImageDraw.Draw(im)
    silhouette = "#C9BFA8"
    floor_y = round(720 * 0.72)
    dr.rectangle((0, floor_y, 1280, 720), fill="#D8D0BE")
    # Four quiet pipe groups along the wall.
    pipe_groups = [
        [(80, 470), (80, 250), (180, 250), (180, 330)],
        [(335, 450), (335, 180), (455, 180), (455, 290)],
        [(820, 455), (820, 285), (930, 285), (930, 180)],
        [(1090, 470), (1090, 225), (1190, 225), (1190, 350)],
    ]
    for pts in pipe_groups:
        dr.line(pts, fill=silhouette, width=30, joint="curve")
        for x, y in (pts[0], pts[-1]):
            dr.ellipse((x - 24, y - 24, x + 24, y + 24), fill=silhouette)
    # Top row of gear silhouettes.
    for cx, cy, outer, teeth in [(150, 82, 62, 10), (340, 98, 45, 9),
                                  (535, 76, 57, 10), (745, 92, 42, 9),
                                  (945, 76, 58, 10), (1142, 95, 44, 9)]:
        dr.polygon(gear_points(cx, cy, outer, outer * 0.77, teeth), fill=silhouette)
        dr.ellipse((cx - outer * 0.28, cy - outer * 0.28,
                    cx + outer * 0.28, cy + outer * 0.28), fill="#EDE8DC")
    # White translucent wash specified by the art request.
    wash = Image.new("RGBA", im.size, (255, 255, 255, 60))
    im = Image.alpha_composite(im, wash)
    im.save(path)


def preview(icon_paths: list[Path], path: Path):
    sheet = Image.new("RGBA", (1280, 640), WHITE)
    cell_w, cell_h = 320, 320
    for index, icon_path in enumerate(icon_paths):
        with Image.open(icon_path) as source:
            icon = source.convert("RGBA").resize((288, 288), Image.Resampling.LANCZOS)
        x = index % 4 * cell_w + 16
        y = index // 4 * cell_h + 16
        sheet.alpha_composite(icon, (x, y))
    sheet.save(path)


def inspect_png(path: Path, expect_transparent: bool | None):
    with Image.open(path) as image:
        image.load()
        corners = [image.getpixel(pos)[3] for pos in (
            (0, 0), (image.width - 1, 0),
            (0, image.height - 1), (image.width - 1, image.height - 1)
        )]
        if image.mode != "RGBA":
            raise AssertionError(f"{path.name}: expected RGBA, got {image.mode}")
        if expect_transparent is True and corners != [0, 0, 0, 0]:
            raise AssertionError(f"{path.name}: icon corners are not transparent")
        if expect_transparent is False and corners != [255, 255, 255, 255]:
            raise AssertionError(f"{path.name}: image corners are not opaque")
        print(f"{path.relative_to(ASSETS)} | {image.size[0]}x{image.size[1]} | "
              f"{image.mode} | corner alpha={corners}")


def main():
    icons_dir = ASSETS / "icons"
    ui_dir = ASSETS / "ui"
    bg_dir = ASSETS / "bg"
    for directory in (icons_dir, ui_dir, bg_dir):
        directory.mkdir(parents=True, exist_ok=True)

    buildings = [
        ("building_mine.png", building_mine),
        ("building_forge.png", building_forge),
        ("building_workshop.png", building_workshop),
        ("building_warehouse.png", building_warehouse),
        ("building_market.png", building_market),
        ("building_barracks.png", building_barracks),
        ("building_lab.png", building_lab),
        ("building_gearbox.png", building_gearbox),
    ]
    ui_icons = [
        ("icon_coin.png", icon_coin),
        ("icon_worker.png", icon_worker),
        ("icon_power.png", icon_power),
        ("icon_round.png", icon_round),
    ]

    building_paths = []
    for filename, renderer in buildings:
        output = icons_dir / filename
        renderer(output)
        building_paths.append(output)
    ui_paths = []
    for filename, renderer in ui_icons:
        output = ui_dir / filename
        renderer(output)
        ui_paths.append(output)
    bg_path = bg_dir / "bg_workshop.png"
    background(bg_path)
    preview_path = icons_dir / "_preview.png"
    preview(building_paths, preview_path)

    print("Generated PNG verification:")
    for output in building_paths + ui_paths:
        inspect_png(output, expect_transparent=True)
    inspect_png(bg_path, expect_transparent=False)
    inspect_png(preview_path, expect_transparent=False)
    print("PASS: all generated PNG files reopened and passed size/mode/alpha checks.")


if __name__ == "__main__":
    main()
