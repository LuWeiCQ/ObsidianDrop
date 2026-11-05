#!/bin/bash
# ObsidianDrop 控制脚本
# 用法：./控制.sh [start|stop|restart|status|rebuild]
set -uo pipefail

APP="$HOME/Applications/ObsidianDrop.app"
BIN="$APP/Contents/MacOS/ObsidianDrop"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

alive() { pgrep -f "ObsidianDrop.app/Contents/MacOS/ObsidianDrop" >/dev/null 2>&1; }

case "${1:-status}" in
  start)
    if alive; then echo "已在运行（PID $(pgrep -f 'ObsidianDrop.app/Contents/MacOS/ObsidianDrop' | head -1)）"; exit 0; fi
    [ -d "$APP" ] || { echo "未安装，先跑 ./build.sh"; exit 1; }
    open "$APP" && echo "已启动"
    ;;
  stop)
    if alive; then
      pkill -f "ObsidianDrop.app/Contents/MacOS/ObsidianDrop" && echo "已停止"
    else
      echo "未在运行"
    fi
    ;;
  restart)
    pkill -f "ObsidianDrop.app/Contents/MacOS/ObsidianDrop" 2>/dev/null
    sleep 1
    open "$APP" && echo "已重启"
    ;;
  status)
    if alive; then
      echo "运行中"
      echo "  PID     : $(pgrep -f 'ObsidianDrop.app/Contents/MacOS/ObsidianDrop' | head -1)"
      echo "  安装路径: $APP"
      echo "  登录项  : $("$BIN" --login 2>&1 | head -1)"
      echo "  当前目标: $(defaults read com.lw.obsidiandrop targetRel 2>/dev/null || echo '00-收件箱（默认）')"
    else
      echo "未运行"
    fi
    ;;
  rebuild)
    "$SRC_DIR/build.sh" || exit 1
    pkill -f "ObsidianDrop.app/Contents/MacOS/ObsidianDrop" 2>/dev/null
    sleep 1
    open "$APP" && echo "已重装并重启"
    ;;
  *)
    echo "用法：$0 [start|stop|restart|status|rebuild]"
    exit 1
    ;;
esac
