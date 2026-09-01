#!/usr/bin/env bash
# 把 shared/addons/game_kit 同步进每个游戏工程（本地开发用；CI 构建时也会做同样的事）。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d shared/addons/game_kit ]; then
    echo "error: shared/addons/game_kit not found" >&2
    exit 1
fi

found=0
for game in games/*/; do
    [ -f "${game}project.godot" ] || continue
    found=1
    mkdir -p "${game}addons"
    cp -r shared/addons/. "${game}addons/"
    echo "synced shared addons -> ${game}addons/"
done

if [ "$found" -eq 0 ]; then
    echo "warning: no games/*/project.godot found" >&2
fi
