#!/usr/bin/env bash
# 把 shared/ 的可复用内容注入每个游戏工程（本地开发用；CI 构建时也会做同样的事）。
#
# 注入内容：
#   1. shared/addons/         → games/<名>/addons/          （game_kit 代码）
#   2. shared/assets/styles/<风格契约> → games/<名>/assets/_shared/（AI 生成的共享素材）
#   3. shared/assets/audio/<audio_packs> → games/<名>/assets/_shared/audio/
#
# 游戏在 project.godot 里声明：
#   [game_kit]
#   asset_style="flat-cartoon"     # 注入 styles/flat-cartoon/ 的素材
#   audio_packs="bgm,ambient"      # 可选，逗号分隔
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d shared/addons/game_kit ]; then
    echo "error: shared/addons/game_kit not found" >&2
    exit 1
fi

# 从 project.godot 读 [game_kit] 段里的键值（key="value"）
read_kit_setting() {
    local game="$1" key="$2"
    awk -v k="$key" '
        $0 ~ /^\[game_kit\]$/ { in_section=1; next }
        in_section && /^\[/ { in_section=0 }
        in_section && index($0, k"=") == 1 {
            v=$0; sub(/^[^=]*=/, "", v); gsub(/[" ]/, "", v); print v
        }
    ' "${game}project.godot"
}

found=0
for game in games/*/; do
    [ -f "${game}project.godot" ] || continue
    found=1

    # 1) addons（game_kit 代码）
    mkdir -p "${game}addons"
    cp -r shared/addons/. "${game}addons/"
    echo "synced shared addons -> ${game}addons/"

    # 2) 按风格契约注入共享素材
    style=$(read_kit_setting "$game" asset_style || true)
    if [ -n "$style" ]; then
        src="shared/assets/styles/$style"
        if [ -d "$src" ]; then
            dst="${game}assets/_shared"
            rm -rf "$dst"
            mkdir -p "$dst"
            cp -r "$src/." "$dst/"
            echo "synced assets [$style] -> ${dst}/"
        else
            echo "warning: style '$style' not found in shared/assets/styles/" >&2
        fi
    fi

    # 3) 注入 audio packs
    packs=$(read_kit_setting "$game" audio_packs || true)
    if [ -n "$packs" ]; then
        dst="${game}assets/_shared/audio"
        mkdir -p "$dst"
        for pack in ${packs//,/ }; do
            if [ -d "shared/assets/audio/$pack" ]; then
                cp -r "shared/assets/audio/$pack/." "$dst/"
                echo "synced audio [$pack] -> ${dst}/"
            else
                echo "warning: audio pack '$pack' not found" >&2
            fi
        done
    fi
done

if [ "$found" -eq 0 ]; then
    echo "warning: no games/*/project.godot found" >&2
fi
