# 合成大西瓜（Suika Game）— Godot 4.5 Web

Godot 4.5 + GDScript 写的合成大西瓜：同级水果相撞就合体，一路合到大西瓜。
推送到 `main` 会自动走完整流水线：lint → 无头自测 → 无头 Web 导出 → 部署到 GitHub Pages。

在线玩：<https://teentu.github.io/godot_ai_game/>

## 玩法

- 鼠标移动 / 手指拖动瞄准，点击（或按空格）放下水果
- 键盘 ← → 也能微调位置
- 相同等级的水果碰到一起会合成更高一级，并加分
- 水果堆过顶部虚线并停留约 2 秒 → 游戏结束
- 最高分存在浏览器本地（Godot 的 `user://`），刷新不会丢

水果共 11 级：葡萄 → 樱桃 → 橘子 → 柠檬 → 猕猴桃 → 西红柿 → 桃子 → 菠萝 → 椰子 → 半个瓜 → 大西瓜。
只会随机掉落前 5 级。

Pipeline references:
- [abarichello/godot-ci](https://github.com/abarichello/godot-ci) — Docker image `barichello/godot-ci:4.5` with Godot + export templates baked in
- [D4M13N-D3V/godot_template](https://github.com/D4M13N-D3V/godot_template) — export preset naming conventions (`"Web"`)

## Project layout

```
.github/workflows/deploy.yml   # CI/CD pipeline (lint + 无头自测 + build + deploy)
export_presets.cfg             # "Web" preset — MUST be committed
project.godot                  # Godot 4.5, GL Compatibility renderer, 720x1080
scenes/main.tscn               # 游戏主场景
scripts/main.gd                # 玩法主控：掉落、合成、计分、判定
scripts/fruit.gd               # 单颗水果（RigidBody2D，程序化绘制）
scripts/fruit_data.gd          # 11 级水果的半径 / 配色 / 分值表
scripts/pop_effect.gd          # 合成时的扩散光圈特效
assets/fonts/ui_subset.ttf     # 裁剪过的中文字体（21 KB）
tools/play_test.gd             # 无头模拟对局自检
tools/collect_font_chars.py    # 扫描源码里用到的字符，供字体子集化
```

## 中文字体

Web 导出时 Godot 默认字体里没有汉字，界面会变成豆腐块。这里的做法是
只把用到的 147 个字符从 `msyh.ttc` 里裁出来（21 KB），在 `project.godot`
里设成 `gui/theme/custom_font`。**以后如果加了新中文文案**，重新跑一遍：

```bash
python tools/collect_font_chars.py        # 重新扫描用到的字符
pyftsubset "C:/Windows/Fonts/msyh.ttc" \
  --font-number=0 --text-file="tools/font_chars.txt" \
  --output-file="assets/fonts/ui_subset.ttf" \
  --layout-features="" --no-hinting --desubroutinize --name-IDs='*'
```

## 本地自检

```bash
# 模拟一整局：一直丢水果，看能不能正常合成
godot --headless --path . --script res://tools/play_test.gd
# 预期输出 PLAY_TEST result=PASS

gdlint scripts/ && gdformat --check scripts/ scenes/
```

## One-time setup on GitHub

1. Create a **public** repository on GitHub (private repos need GitHub Pro for Pages).
2. Remote is already configured. Push with:
   ```bash
   git push origin main
   ```
   Remote: https://github.com/TeenTu/godot_ai_game.git
3. In the repo: **Settings → Pages → Source → select "GitHub Actions"**
   (NOT "Deploy from a branch" — the workflow uses the official deploy actions).
4. Watch the run in the **Actions** tab. When all jobs are green, open:
   `https://teentu.github.io/godot_ai_game/`

Every subsequent merge to `main` automatically rebuilds and redeploys.

## Acceptance checklist

- [x] `export_presets.cfg` committed to the repository
- [x] Web preset has **Thread Support disabled** (`variant/thread_support=false`)
- [x] Renderer is **GL Compatibility** (WebGL 2.0)
- [x] VRAM texture compression enabled for desktop + mobile
- [x] Export filter: all resources; export path `build/web/index.html`
- [x] `.gitignore` does NOT ignore `export_presets.cfg`
- [x] `.github/workflows/deploy.yml` present, YAML syntax validated
- [x] 中文字体子集已内置，Web 端不会出豆腐块
- [ ] Push to `main` → Actions run is green *(requires a remote repo)*
- [ ] Pages URL loads the game *(requires a remote repo)*

## Local export (optional sanity check)

Open the project in Godot 4.5 → **Project → Export → Web** → Export Project.
Output goes to `build/web/index.html` (the `build/` folder is gitignored).

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Cannot export project with preset "Web"` | `export_presets.cfg` missing or preset name mismatch | Ensure the file is committed and the name matches `"Web"` exactly (case-sensitive) |
| `SharedArrayBuffer is not defined` | Thread Support enabled | Keep `variant/thread_support=false` (GitHub Pages cannot send `Cross-Origin-Embedder-Policy` headers) |
| `Export template not found` | Docker image tag ≠ Godot version | Align `barichello/godot-ci:<tag>` with `GODOT_VERSION` in `deploy.yml` |
| Cross Origin Isolation error | Threads enabled in the export | Must export single-threaded |
| Garbled CJK text (豆腐块) | 新加的中文没进字体子集 | 重跑 `tools/collect_font_chars.py` + `pyftsubset`（见上文） |
| 水果相撞不合体 | 两颗只是刚好相切，没真正重叠 | 属于正常物理行为，挤一挤就会合；若想更灵敏可放宽 `Fruit._on_body_entered` |

## Upgrading Godot

1. Check available image tags: <https://hub.docker.com/r/barichello/godot-ci/tags>
2. In `.github/workflows/deploy.yml`, update **both** the `container.image` tag and the `GODOT_VERSION` env.
3. Update `config/features` in `project.godot` to match, and re-open the project in that editor version.
