# 程序化生成音量开关图标（买量风：圆角块 + 粗描边 + 白色高光弧）
# 输出: assets/icons/icon_sound_on.png / icon_sound_off.png (128x128 透明底)
import math
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "ui")
S = 128
EDGE = "#2B2B2B"
BODY = "#FFB84D"  # 暖橙，与 HUD 图标一致


def rounded_bg(d):
    d.rounded_rectangle([6, 6, S - 6, S - 6], radius=26, fill=BODY, outline=EDGE, width=6)


def highlight(d):
    d.arc([18, 14, 70, 60], start=190, end=300, fill="#FFE0A3", width=7)


def speaker(d, waves):
    """喇叭主体 + 声波弧线 / 斜杠"""
    # 喇叭箱体
    d.polygon([(34, 52), (52, 52), (68, 38), (68, 90), (52, 76), (34, 76)],
              fill="#FFFFFF", outline=EDGE)
    # 声波
    if waves:
        for r in (14, 26):
            d.arc([68 - r, 64 - r, 68 + r, 64 + r], start=-50, end=50,
                  fill="#FFFFFF", width=6)
    else:
        # 斜杠（静音）
        d.line([(44, 40), (90, 88)], fill="#D64545", width=9)
        d.line([(44, 40), (90, 88)], fill="#FFFFFF", width=4)


def gen(name, waves):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded_bg(d)
    highlight(d)
    speaker(d, waves)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    img.save(path)
    print(f"  {name}")


gen("icon_sound_on.png", True)
gen("icon_sound_off.png", False)
print("done")
