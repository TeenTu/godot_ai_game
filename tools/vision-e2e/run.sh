#!/usr/bin/env bash
# Vision E2E 本地运行脚本
#
# 用法：
#   ./run.sh                 测本地构建产物（WEB_ROOT，默认 ../../build/web），自动起本地服务
#   ./run.sh <完整地址>       测指定地址（如线上 https://teentu.github.io/godot_ai_game/suika/）
#   ./run.sh -g "场景名"      过滤场景（透传给 playwright）
#
# 环境变量：
#   WEB_ROOT  本地构建产物根目录（相对本脚本目录），默认 ../../build/web
#   PORT      本地服务端口，默认 8123
#   BASE_URL  直接指定被测地址（与传参等价，且可传给 -g 组合使用）
set -euo pipefail
cd "$(dirname "$0")"

ARGS=()
ADDR="${BASE_URL:-}"
for a in "$@"; do
  if [[ "$a" == http://* || "$a" == https://* ]]; then
    ADDR="$a"
  else
    ARGS+=("$a")
  fi
done

if [ -n "$ADDR" ]; then
  echo ">> 直接测试: $ADDR"
  BASE_URL="$ADDR" npx playwright test "${ARGS[@]}"
else
  PORT="${PORT:-8123}"
  WEB_ROOT="${WEB_ROOT:-../../build/web}"
  if [ ! -f "$WEB_ROOT/index.html" ]; then
    echo "错误: $WEB_ROOT 下没有 index.html —— 先导出游戏（本地 Godot 导出或复制 CI 产物），"
    echo "或改用: ./run.sh <线上地址>"
    exit 1
  fi
  echo ">> 本地服务: http://localhost:$PORT （根目录 $WEB_ROOT）"
  ( cd "$WEB_ROOT" && python -m http.server "$PORT" >/dev/null 2>&1 ) &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
  sleep 1.5
  echo ">> 测试本地构建产物..."
  BASE_URL="http://localhost:$PORT" npx playwright test "${ARGS[@]}"
fi

echo ""
echo ">> 生成报告: npm run report"
