#!/usr/bin/env bash
# S1-11 Batch 7 / AT-45：真实 Web 导出 + 视觉 E2E（本地回归工具，不进 CI）。
#
# 做三件事：
#   1. 无头导出 Web release 产物（games/sonar/build/web）；
#   2. 起 COOP/COEP 本地服务（SharedArrayBuffer 必需）；
#   3. 用真实 Chromium 依次跑 3 个 shot 计划，落盘截图 + console 日志；
#      任一计划出现 console error / pageerror 即非零退出。
#
# 用法（仓库根目录）：tools/vision-e2e/run_sonar_web.sh
# 环境变量：GODOT（Godot 可执行文件，默认 godot）、PYTHON（默认 python）、
#          PORT（默认 8330）、PW_PLAYWRIGHT / PW_CHROME（见 scripts/sonar_web_visual.mjs）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../.."          # 仓库根（Godot 的 --path 用相对路径，避免 MSYS/Windows 路径混用）

GODOT="${GODOT:-godot}"
PYTHON="${PYTHON:-python}"
PORT="${PORT:-8330}"
GAME="games/sonar"

echo ">> 1/3 导出 Web release"
mkdir -p "$GAME/build/web"
"$GODOT" --headless --path "$GAME" --export-release "Web"

echo ">> 2/3 起 COOP/COEP 服务 127.0.0.1:$PORT"
"$PYTHON" "$GAME/tools/serve_web_coop.py" "$GAME/build/web" "$PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
sleep 2

echo ">> 3/3 视觉 E2E（真浏览器 WebGL2）"
cd "$HERE"
node scripts/sonar_web_visual.mjs @scenarios/sonar/webshot_1280x720.json
node scripts/sonar_web_visual.mjs @scenarios/sonar/webshot_1920x1080.json
node scripts/sonar_web_visual.mjs @scenarios/sonar/webshot_1600x900_flow.json
echo ">> 全部通过（0 console error），证据见 tools/vision-e2e/evidence/sonar/"
