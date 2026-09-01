#!/usr/bin/env python3
"""AI 生成的素材后处理工具：去白成透明 + 调色板量化压缩。
   把"近白/近灰"像素当背景转透明（适用于 AI 出图常有浅色背景的情况），
   然后调色板量化（保 alpha），大幅压缩体积。

用法：
  python tools/postprocess_image.py <input.png> [output.png] [--threshold 200] [--colors 256]
"""
import sys, os
from PIL import Image


def postprocess(src: str, dst: str, threshold: int = 200, colors: int = 256) -> tuple[int, int]:
    img = Image.open(src).convert("RGBA")
    w, h = img.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    data = img.load()
    for y in range(h):
        for x in range(w):
            r, g, b = data[x, y][:3]
            avg = (r + g + b) / 3
            # 高亮 + 低色差（偏白/偏灰）当作背景；高饱和的素材色不会被误伤
            if avg > threshold and max(r, g, b) - min(r, g, b) < 30:
                out.putpixel((x, y), (255, 255, 255, 0))
            else:
                out.putpixel((x, y), (r, g, b, 255))
    # RGBA 量化只支持 FASTOCTREE / libimagequant；前者 PIL 自带
    p = out.quantize(colors=colors, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    p.save(dst, optimize=True)
    return os.path.getsize(src), os.path.getsize(dst)


if __name__ == "__main__":
    args = sys.argv[1:]
    src = args[0]
    dst = args[1] if len(args) > 1 and not args[1].startswith("--") else src
    threshold = 200
    colors = 256
    for i, a in enumerate(args):
        if a == "--threshold" and i + 1 < len(args):
            threshold = int(args[i + 1])
        elif a == "--colors" and i + 1 < len(args):
            colors = int(args[i + 1])
    src_size, dst_size = postprocess(src, dst, threshold, colors)
    print(f"{src} -> {dst}: {src_size // 1024} KB -> {dst_size // 1024} KB")