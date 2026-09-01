#!/usr/bin/env python3
"""雪碧图（Sprite Sheet）校验脚本：AI 出图后的质量门禁。

AI 生成雪碧图后，用本脚本检查是否符合行业规范（网格完整、透明背景、
帧内容不越界/不粘连/不空帧）。**不合格时输出结构化返工清单**，可直接
贴回给生成方（如 Codex CLI）让它返工。

用法：
  python tools/check_sprite_sheet.py <sheet.png> --frame 64x64 [选项]

选项：
  --frame WxH        帧大小（必须，如 64x64 或 128x128）
  --columns N        网格列数（可选；不提供则按图片宽度整除帧宽自动算）
  --rows N           网格行数（可选）
  --min-fill 0.02    空帧判定：帧内非透明像素占比低于此值视为空（默认 2%）
  --edge-tol 2       越界判定：帧内容距格子边缘低于此像素数视为"贴边/可能粘连"
  --center-tol 0.35  居中判定：内容中心偏离格子中心超过此比例视为偏移

退出码：0 = 全部通过；1 = 存在问题。

输出格式（FAIL 时）可直接当 prompt 贴回生成方：
  ❌ 帧(行,列) 类型: 描述 → 建议
"""
import argparse
import sys

from PIL import Image


def analyze(sheet_path: str, fw: int, fh: int, cols: int | None, rows: int | None,
            min_fill: float, edge_tol: int, center_tol: float) -> list[str]:
    """返回问题清单；为空表示通过。"""
    img = Image.open(sheet_path).convert("RGBA")
    w, h = img.size
    problems: list[str] = []

    # 1) 网格完整性：宽高必须是帧大小的整数倍
    if w % fw != 0 or h % fh != 0:
        problems.append(
            f"❌ 尺寸不符合帧大小: 图片 {w}x{h} 无法被帧 {fw}x{fh} 整除 "
            f"(cols={w // fw} 余 {w % fw}, rows={h // fh} 余 {h % fh}) → "
            f"请把画布调整为 {fw * (w // fw)}x{fh * (h // fh)} 或整数倍"
        )
        return problems  # 尺寸不对后面没法算网格，直接返回

    grid_cols = cols if cols else w // fw
    grid_rows = rows if rows else h // fh
    if grid_cols * fw != w or grid_rows * fh != h:
        problems.append(
            f"❌ 网格与尺寸不匹配: 指定 {grid_cols}x{grid_rows} 帧但图片是 {w}x{h} → "
            f"应传 --columns {w // fw} --rows {h // fh}"
        )
        return problems

    # 2) 图集背景透明（四角采样）
    for name, (px, py) in {
        "左上角": (0, 0), "右上角": (w - 1, 0),
        "左下角": (0, h - 1), "右下角": (w - 1, h - 1),
    }.items():
        if img.getpixel((px, py))[3] > 0:
            problems.append(
                f"❌ 背景不透明: {name}({px},{py}) 非透明 → 请使用透明背景导出"
            )
            break

    # 3) 逐帧检测
    for r in range(grid_rows):
        for c in range(grid_cols):
            l, t = c * fw, r * fh
            frame = img.crop((l, t, l + fw, t + fh))
            alpha = frame.getchannel("A")
            bbox = alpha.getbbox()  # 非透明内容的范围（None = 全透明）

            # 3a) 空帧
            if bbox is None:
                problems.append(
                    f"❌ 帧({r},{c}) 空帧: 整格无内容 → 请补齐该帧（或调整网格）"
                )
                continue

            # 非透明像素占比：alpha 直方图去掉 0 通道计数，O(1) 无逐像素遍历
            alpha_hist = alpha.histogram()
            nontransparent = sum(alpha_hist[1:])
            content_px = nontransparent / (fw * fh)
            if content_px < min_fill:
                problems.append(
                    f"❌ 帧({r},{c}) 内容过少: 非透明占比 {content_px:.1%} < {min_fill:.0%} "
                    f"→ 该帧几乎空白，请重画"
                )

            # 3b) 贴边/越界（内容距格子边缘过近，可能和邻帧粘连）
            bl, bt, br, bb = bbox
            if bl <= edge_tol or bt <= edge_tol or br >= fw - edge_tol or bb >= fh - edge_tol:
                problems.append(
                    f"❌ 帧({r},{c}) 内容贴边: bbox=({bl},{bt},{br},{bb}) 距格子边缘 "
                    f"≤{edge_tol}px → 缩小该帧内容或留出至少 {edge_tol * 4}px 边距，"
                    f"避免与邻帧粘连"
                )

            # 3c) 居中偏移
            cx, cy = (bl + br) / 2, (bt + bb) / 2
            off_x = abs(cx - fw / 2) / (fw / 2)
            off_y = abs(cy - fh / 2) / (fh / 2)
            if off_x > center_tol or off_y > center_tol:
                problems.append(
                    f"❌ 帧({r},{c}) 内容偏移: 中心偏离 x={off_x:.0%} y={off_y:.0%} "
                    f"(>{center_tol:.0%}) → 请把主体移回格子中心"
                )

    # 4) 相邻帧粘连检测（共享边界两侧都有内容 = 溢出）
    def edge_nontransparent(box: tuple[int, int, int, int]) -> int:
        a = img.crop(box).getchannel("A")
        h = a.histogram()
        return sum(h[1:])

    for r in range(grid_rows):
        for c in range(grid_cols - 1):
            l, t = c * fw, r * fh
            if edge_nontransparent((l + fw - edge_tol, t, l + fw + edge_tol, t + fh)) > 0 and \
               edge_nontransparent((l + fw, t, l + fw + edge_tol * 2, t + fh)) > 0:
                problems.append(
                    f"❌ 帧({r},{c})与({r},{c + 1})水平粘连: 共享边界两侧都有内容 → "
                    f"两帧主体都留边距，避免跨界"
                )
    for r in range(grid_rows - 1):
        for c in range(grid_cols):
            l, t = c * fw, r * fh
            if edge_nontransparent((l, t + fh - edge_tol, l + fw, t + fh + edge_tol)) > 0 and \
               edge_nontransparent((l, t + fh, l + fw, t + fh + edge_tol * 2)) > 0:
                problems.append(
                    f"❌ 帧({r},{c})与({r + 1},{c})垂直粘连: 共享边界两侧都有内容 → "
                    f"两帧主体都留边距，避免跨界"
                )

    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description="雪碧图质量校验（AI 出图门禁）")
    ap.add_argument("sheet", help="雪碧图路径")
    ap.add_argument("--frame", required=True, help="帧大小 WxH，如 64x64")
    ap.add_argument("--columns", type=int, default=None)
    ap.add_argument("--rows", type=int, default=None)
    ap.add_argument("--min-fill", type=float, default=0.02)
    ap.add_argument("--edge-tol", type=int, default=2)
    ap.add_argument("--center-tol", type=float, default=0.35)
    args = ap.parse_args()

    fw, fh = (int(x) for x in args.frame.lower().split("x"))
    problems = analyze(args.sheet, fw, fh, args.columns, args.rows,
                       args.min_fill, args.edge_tol, args.center_tol)

    if not problems:
        img = Image.open(args.sheet)
        cols = args.columns or img.width // fw
        rows = args.rows or img.height // fh
        print(f"✅ 雪碧图通过校验: {args.sheet} ({cols}x{rows} 帧, 帧 {fw}x{fh})")
        return 0

    print(f"❌ 雪碧图 {args.sheet} 有 {len(problems)} 个问题，返工清单：")
    print()
    for p in problems:
        print(p)
    print()
    print("—— 请按以上清单逐条修改后重新导出，再跑一次本脚本 ——")
    return 1


if __name__ == "__main__":
    sys.exit(main())
