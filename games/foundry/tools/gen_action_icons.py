"""Generate the eight Foundry action icons with Pillow only."""

from pathlib import Path
from math import cos, pi, sin

from PIL import Image, ImageDraw


SIZE = 512
SCALE = 4
W = 31 * SCALE
INK = "#2B2B2B"
WHITE = "#FFFFFF"
OUT_DIR = Path(__file__).resolve().parents[1] / "assets" / "icons"


def sc(value):
    if isinstance(value, (tuple, list)):
        return tuple(int(round(v * SCALE)) for v in value)
    return int(round(value * SCALE))


def darken(hex_color, factor=0.62):
    value = hex_color.lstrip("#")
    rgb = tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))
    return tuple(int(channel * factor) for channel in rgb) + (255,)


def polygon(draw, points, fill, outline=INK, width=W):
    pts = [sc(point) for point in points]
    draw.polygon(pts, fill=fill)
    if outline and width:
        draw.line(pts + [pts[0]], fill=outline, width=width, joint="curve")


def line(draw, points, fill=INK, width=W, joint="curve"):
    draw.line([sc(point) for point in points], fill=fill, width=width, joint=joint)


def ellipse(draw, box, fill, outline=None, width=W):
    draw.ellipse(sc(box), fill=fill, outline=outline, width=width if outline else 1)


def rounded(draw, box, radius, fill, outline=None, width=W):
    draw.rounded_rectangle(
        sc(box), radius=sc(radius), fill=fill, outline=outline,
        width=width if outline else 1,
    )


def gear_points(cx, cy, outer, inner, teeth=10, rotation=-pi / 2):
    points = []
    for index in range(teeth * 4):
        phase = index % 4
        radius = outer if phase in (0, 1) else inner
        angle = rotation + index * pi / (teeth * 2)
        points.append((cx + cos(angle) * radius, cy + sin(angle) * radius))
    return points


def base(main_color):
    image = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    rounded(draw, (36, 36, 476, 476), 108, main_color, INK, sc(2))
    ellipse(draw, (112, 378, 400, 438), darken(main_color, 0.60))
    draw.arc(sc((76, 76, 205, 205)), 194, 284, fill=WHITE, width=sc(23))
    return image, draw


def strike():
    image, draw = base("#E23B3B")
    # Crossed swords behind a compact forge hammer.
    polygon(draw, [(129, 331), (160, 347), (335, 160), (309, 134)], "#F4F0E8")
    polygon(draw, [(335, 160), (361, 112), (309, 134)], "#FFF8DD")
    line(draw, [(125, 351), (177, 299)], width=sc(28))
    polygon(draw, [(365, 337), (336, 354), (169, 176), (196, 149)], "#F4F0E8")
    polygon(draw, [(169, 176), (143, 126), (196, 149)], "#FFF8DD")
    line(draw, [(379, 351), (327, 299)], width=sc(28))
    rounded(draw, (181, 205, 331, 273), 20, "#FFD06A", INK)
    line(draw, [(256, 268), (256, 378)], fill=INK, width=sc(42))
    return image


def scrap():
    image, draw = base("#8A7A66")
    polygon(draw, gear_points(224, 257, 132, 101, 10), "#B6AA97")
    ellipse(draw, (178, 211, 270, 303), "#F1E7D5", INK)
    # Bite-like missing wedge and a snapped part to the right.
    polygon(draw, [(227, 175), (270, 221), (244, 249), (289, 294), (255, 328), (214, 279),
                   (241, 250), (198, 207)], "#5E554A", None, 0)
    line(draw, [(305, 185), (352, 151), (385, 194), (354, 221)], width=sc(34))
    line(draw, [(348, 278), (388, 311), (352, 361), (311, 335)], width=sc(34))
    ellipse(draw, (322, 224, 364, 266), "#F1E7D5", INK, sc(13))
    return image


def gearup():
    image, draw = base("#F08A24")
    polygon(draw, gear_points(216, 286, 124, 92, 10), "#FFD26A")
    ellipse(draw, (171, 241, 261, 331), "#FFF1C7", INK)
    # Strong upward arrow overlapping the gear.
    polygon(draw, [(300, 365), (300, 233), (260, 233), (340, 137), (420, 233),
                   (378, 233), (378, 365)], "#FFF7E5")
    return image


def blueprint():
    image, draw = base("#3B7BD6")
    # Unfurled blueprint with curled ends.
    rounded(draw, (117, 163, 381, 349), 24, "#86C8FF", INK)
    ellipse(draw, (91, 147, 157, 217), "#DDF2FF", INK)
    ellipse(draw, (346, 318, 412, 388), "#DDF2FF", INK)
    line(draw, [(143, 196), (143, 337), (378, 337)], fill="#DDF2FF", width=sc(17))
    # Compass and ruler motif, entirely pictorial.
    line(draw, [(213, 300), (258, 205), (304, 300)], width=sc(22))
    line(draw, [(230, 266), (288, 266)], width=sc(16))
    polygon(draw, [(284, 311), (352, 214), (375, 230), (307, 327)], "#FFE38A", INK, sc(18))
    line(draw, [(326, 260), (342, 271)], width=sc(8))
    return image


def rush():
    image, draw = base("#F5C518")
    # Three staggered speed lines feed into one bold arrowhead.
    line(draw, [(104, 199), (245, 199)], width=sc(27))
    line(draw, [(82, 256), (238, 256)], width=sc(27))
    line(draw, [(112, 313), (245, 313)], width=sc(27))
    polygon(draw, [(208, 151), (307, 151), (307, 109), (427, 256),
                   (307, 403), (307, 359), (208, 359), (280, 256)], "#FFF8D1")
    return image


def bargain():
    image, draw = base("#3FA34D")
    # Tag with punched eye and string.
    polygon(draw, [(130, 181), (287, 143), (387, 243), (245, 385), (130, 270)], "#8ED66F")
    ellipse(draw, (162, 191, 218, 247), WHITE, INK, sc(16))
    line(draw, [(190, 218), (144, 159), (115, 171)], width=sc(13))
    # Coin stack reads as value without any currency glyph.
    ellipse(draw, (275, 278, 382, 373), "#FFD55C", INK)
    ellipse(draw, (290, 291, 367, 358), "#FFF0A2", INK, sc(13))
    ellipse(draw, (298, 219, 405, 314), "#FFD55C", INK)
    ellipse(draw, (313, 232, 390, 299), "#FFF0A2", INK, sc(13))
    return image


def overclock():
    image, draw = base("#8A4FD6")
    rounded(draw, (151, 151, 361, 361), 36, "#B98AF0", INK)
    for pos in (183, 230, 277, 324):
        line(draw, [(pos, 121), (pos, 158)], width=sc(17))
        line(draw, [(pos, 354), (pos, 391)], width=sc(17))
        line(draw, [(121, pos), (158, pos)], width=sc(17))
        line(draw, [(354, pos), (391, pos)], width=sc(17))
    polygon(draw, [(271, 176), (207, 273), (254, 273), (226, 348),
                   (326, 238), (275, 238), (315, 176)], "#FFE45E")
    return image


def steal():
    image, draw = base("#2E8C8C")
    # A hooked grabber enters from upper left and lifts a coin.
    line(draw, [(131, 157), (204, 204), (246, 276)], width=sc(34))
    draw.arc(sc((207, 235, 350, 374)), 310, 151, fill=INK, width=sc(31))
    polygon(draw, [(311, 326), (352, 322), (325, 363)], "#B8EFE7")
    ellipse(draw, (292, 174, 398, 280), "#FFD55C", INK)
    ellipse(draw, (311, 193, 379, 261), "#FFF0A2", INK, sc(12))
    # Three gloved fingers imply a stealthy hand rather than machinery.
    rounded(draw, (142, 270, 204, 365), 28, "#B8EFE7", INK, sc(22))
    rounded(draw, (190, 286, 248, 385), 27, "#B8EFE7", INK, sc(22))
    rounded(draw, (237, 289, 293, 374), 26, "#B8EFE7", INK, sc(22))
    return image


ICONS = [
    ("action_strike.png", strike),
    ("action_scrap.png", scrap),
    ("action_gearup.png", gearup),
    ("action_blueprint.png", blueprint),
    ("action_rush.png", rush),
    ("action_bargain.png", bargain),
    ("action_overclock.png", overclock),
    ("action_steal.png", steal),
]


def finish(image):
    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    generated = []
    for filename, factory in ICONS:
        image = finish(factory())
        path = OUT_DIR / filename
        image.save(path, optimize=True)
        generated.append((filename, image))

    preview = Image.new("RGB", (1024, 512), WHITE)
    for index, (_, image) in enumerate(generated):
        thumb = image.resize((256, 256), Image.Resampling.LANCZOS)
        preview.paste(thumb, ((index % 4) * 256, (index // 4) * 256), thumb)
    preview.save(OUT_DIR / "_preview_actions.png", optimize=True)

    for filename, _ in generated:
        with Image.open(OUT_DIR / filename) as check:
            rgba = check.convert("RGBA")
            corners = [rgba.getpixel(point)[3] for point in ((0, 0), (511, 0), (0, 511), (511, 511))]
            print(f"{filename}: size={rgba.size} corner_alpha={corners}")


if __name__ == "__main__":
    main()
