"""扫描 Godot 源码里用到的字符，生成字体子集化所需的文本清单。

用法（在项目根目录）：
    python tools/collect_font_chars.py

输出 tools/font_chars.txt，供 pyftsubset 裁剪中文字体使用。
"""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

chars = set()

# ASCII 可打印字符（数字、字母、标点）一律保留
chars.update(chr(c) for c in range(0x20, 0x7F))

targets = list(ROOT.glob("scripts/*.gd")) + list(ROOT.glob("scenes/*.tscn"))
for path in targets:
    text = path.read_text(encoding="utf-8")
    for line in text.splitlines():
        stripped = line.strip()
        # 去掉 GDScript 注释，避免把说明文字里的字也打进字体
        if path.suffix == ".gd" and stripped.startswith("#"):
            continue
        for ch in line:
            if ord(ch) > 0x7F:
                chars.add(ch)

# 界面上会用到的一些额外符号
chars.update("·—…")

out = ROOT / "tools" / "font_chars.txt"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("".join(sorted(chars)), encoding="utf-8")

print("unique chars:", len(chars))
print("non-ascii:", sum(1 for c in chars if ord(c) > 0x7F))
print("written:", out)
