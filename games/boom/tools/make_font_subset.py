# -*- coding: utf-8 -*-
"""《百怪夜巡》UI 中文字体子集生成（移植自 sonar make_font_subset.py）。

Web 导出没有系统 CJK 回退：不内嵌 CJK 字形时全 UI 中文渲染为豆腐块
（sonar d3653cf/f05cdcb/25cfbe9 三阶段根治方案）。

字符集 = 全部 scripts/**.gd + tools/*.gd 中**字符串字面量**里的非 ASCII
字符（注释里的数学符号不需要字形，不请求）+ ASCII 可打印 + 旧子集 cmap
（保底不回退）+ 显式补充表。
源字体：Microsoft YaHei（msyh.ttc index 0）。产出：
  - assets/fonts/ui_subset.ttf       （Godot 运行时/导出版）
  - assets/fonts/ui_subset_chars.txt （字形清单，供验收核对）

用法（游戏根目录）：
  python tools/make_font_subset.py [源字体路径]
默认源字体 C:/Windows/Fonts/msyh.ttc。依赖 fonttools。

注意：翻译改动文案后必须重跑本脚本，否则新增汉字缺字形（豆腐块）。
"""
import glob
import io
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

GAME_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_TTF = os.path.join(GAME_ROOT, "assets", "fonts", "ui_subset.ttf")
OUT_CHARS = os.path.join(GAME_ROOT, "assets", "fonts", "ui_subset_chars.txt")
# 已知源字体没有字形的字符：从显示文案侧回避（生成时报告，不静默丢弃）。
FALLBACK_EXPLICIT = "°±×—…·°℃"


def collect_chars():
    chars = set()
    src = set()  # 仅源自代码字符串的字符（报告用，不含旧保底）
    roots = [
        os.path.join(GAME_ROOT, "scripts"),
        os.path.join(GAME_ROOT, "tools"),
    ]
    import re

    lit = re.compile(r'"(?:[^"\\\n]|\\.)*"')
    for root in roots:
        for p in glob.glob(os.path.join(root, "**", "*.gd"), recursive=True):
            for line in io.open(p, encoding="utf-8"):
                if line.lstrip().startswith("#"):
                    continue  # 注释里的引号/数学符号（↔ 💥 等）不需要字形
                for m in lit.finditer(line):
                    nonascii = [c for c in m.group(0) if ord(c) > 0x20]
                    chars.update(nonascii)
                    src.update(nonascii)
    # ASCII 可打印（数字/单位/坐标轴）+ 常用符号
    chars.update(chr(i) for i in range(0x20, 0x7F))
    chars.update(FALLBACK_EXPLICIT)
    # 旧子集保底
    if os.path.exists(OUT_TTF):
        old = TTFont(OUT_TTF).getBestCmap()
        chars.update(chr(c) for c in old)
    return chars, src


def main():
    font_src = sys.argv[1] if len(sys.argv) > 1 else "C:/Windows/Fonts/msyh.ttc"
    chars, src_chars = collect_chars()
    text = "".join(sorted(chars))
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.recalc_bounds = False
    args_font = TTFont(font_src, fontNumber=0)
    subsetter = subset.Subsetter(options=opts)
    subsetter.populate(text=text)
    subsetter.subset(args_font)
    args_font.save(OUT_TTF)
    # 字形清单（以产物的实际 cmap 为准）+ 缺字报告
    final = TTFont(OUT_TTF).getBestCmap()
    have = sorted(chr(c) for c in final)
    io.open(OUT_CHARS, "w", encoding="utf-8").write("".join(have))
    # 只报告「当前代码字符串需要但无字形」的字符（旧保底历史字符不计）。
    missing = sorted(c for c in src_chars if ord(c) not in final)
    print("subset glyphs:", len(final))
    print("chars requested:", len(chars))
    if missing:
        print("SOURCE-FONT-MISSING (无字形，需回避或换源):", "".join(missing))
    print("OK ->", OUT_TTF, "/", OUT_CHARS)


if __name__ == "__main__":
    main()
