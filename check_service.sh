#!/bin/bash
# check_service.sh — 远程 systemd 服务状态检查
# Usage: check_service.sh <service-name>
set -uo pipefail

[ -n "${1:-}" ] || { echo "用法: check_service.sh <service-name>"; exit 2; }
SERVICE="$1"
[ -n "${VPS_HOST:-}" ] || { echo "FAIL: VPS_HOST 未设置"; exit 1; }
: "${VPS_SSH_PORT:=22}"
: "${VPS_SSH_USER:=root}"
: "${VPS_SSH_KEY:=~/.ssh/id_ed25519}"
case "$VPS_SSH_KEY" in ~*) VPS_SSH_KEY="${HOME}${VPS_SSH_KEY#\~}" ;; esac

SSH=(ssh -i "$VPS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
  -o ConnectTimeout=15 -p "$VPS_SSH_PORT" "${VPS_SSH_USER}@${VPS_HOST}")

echo "=== Service: $SERVICE @ ${VPS_HOST} ==="

STATE=$("${SSH[@]}" "systemctl is-active '$SERVICE' 2>/dev/null" 2>&1)
RC=$?

if [ $RC -ne 0 ] && [ "$STATE" != "active" ]; then
  echo "FAIL: 无法检查服务（SSH 失败或命令报错）"
  echo "  $STATE" | head -2
  exit 1
fi

case "$STATE" in
  active)
    # 顺便拿一下 CPU/内存
    STATS=$("${SSH[@]}" "systemctl show '$SERVICE' --property=MainPID 2>/dev/null | cut -d= -f2" 2>/dev/null || echo "?")
    echo "OK: $SERVICE 运行中 (PID: $STATS)"
    exit 0
    ;;
  inactive) echo "FAIL: $SERVICE 未启动"; exit 1 ;;
  failed)
    echo "FAIL: $SERVICE 已崩溃"
    "${SSH[@]}" "journalctl -u '$SERVICE' --no-pager -n 5 2>/dev/null" 2>&1 | sed 's/^/  /'
    exit 1
    ;;
  *) echo "FAIL: $SERVICE 状态异常: $STATE"; exit 1 ;;
esac
