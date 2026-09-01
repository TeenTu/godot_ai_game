# Godot Web Game — CI/CD Demo

Godot 4.5 (GDScript) web game with a fully automated pipeline:
push/merge to `main` → headless Web export → deploy to GitHub Pages.

Pipeline references:
- [abarichello/godot-ci](https://github.com/abarichello/godot-ci) — Docker image `barichello/godot-ci:4.5` with Godot + export templates baked in
- [D4M13N-D3V/godot_template](https://github.com/D4M13N-D3V/godot_template) — export preset naming conventions (`"Web"`)

## Project layout

```
.github/workflows/deploy.yml   # CI/CD pipeline (build + deploy)
export_presets.cfg             # "Web" preset — MUST be committed
project.godot                  # Godot 4.5, GL Compatibility renderer
scenes/main.tscn               # minimal smoke-test scene
scripts/main.gd
```

## One-time setup on GitHub (Steps 5 & 6)

1. Create a **public** repository on GitHub (private repos need GitHub Pro for Pages).
2. Remote is already configured. Push with:
   ```bash
   git push origin main
   ```
   Remote: https://github.com/TeenTu/godot_ai_game.git
3. In the repo: **Settings → Pages → Source → select "GitHub Actions"**
   (NOT "Deploy from a branch" — the workflow uses the official deploy actions).
4. Watch the run in the **Actions** tab. When both jobs are green, open:
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
| Garbled CJK text | Missing CJK font | Import a CJK font in the project and use it in theme/labels |

## Upgrading Godot

1. Check available image tags: <https://hub.docker.com/r/barichello/godot-ci/tags>
2. In `.github/workflows/deploy.yml`, update **both** the `container.image` tag and the `GODOT_VERSION` env.
3. Update `config/features` in `project.godot` to match, and re-open the project in that editor version.
