#!/bin/bash
# check_vps.sh — SSH 可达性 + 系统状态
# Required: VPS_HOST; Optional: VPS_SSH_PORT VPS_SSH_USER VPS_SSH_KEY
set -uo pipefail

[ -n "${VPS_HOST:-}" ] || { echo "FAIL: VPS_HOST 未设置"; exit 1; }
: "${VPS_SSH_PORT:=22}"
: "${VPS_SSH_USER:=root}"
: "${VPS_SSH_KEY:=~/.ssh/id_ed25519}"

# 展开 ~ 路径
case "$VPS_SSH_KEY" in
  ~*) VPS_SSH_KEY="${HOME}${VPS_SSH_KEY#\~}" ;;
esac

[ -f "$VPS_SSH_KEY" ] || { echo "FAIL: SSH 密钥不存在: $VPS_SSH_KEY"; exit 1; }

SSH=(ssh -i "$VPS_SSH_KEY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=accept-new
  -p "$VPS_SSH_PORT"
  "${VPS_SSH_USER}@${VPS_HOST}")

echo "=== VPS: ${VPS_HOST}:${VPS_SSH_PORT} ==="

# 先测 TCP
if ! timeout 10 bash -c "echo >/dev/tcp/${VPS_HOST}/${VPS_SSH_PORT}" 2>/dev/null; then
  echo "FAIL: TCP 连接 ${VPS_HOST}:${VPS_SSH_PORT} 超时（网络不通或防火墙拦截）"
  exit 1
fi

OUT=$("${SSH[@]}" '
echo "CPU: $(nproc) cores"
echo "Mem: $(free -h | awk "/^Mem:/{print \$2\" total, \"\$7\" available\"}")"
echo "Disk: $(df -h / | awk "NR==2{print \$4\" free of \"\$2\" (\"$5\" used)\"}")"
echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
' 2>&1)
RC=$?

case $RC in
  0)
    echo "$OUT"
    # 检查磁盘/内存告警
    if echo "$OUT" | grep -qP 'Disk: \S+ free.*\((9[0-9]|100)% used\)'; then
      echo "WARN: 磁盘使用率 ≥90%"
    fi
    echo "OK: VPS 可达"
    exit 0
    ;;
  255)
    echo "FAIL: SSH 连接失败（rc=$RC）"
    echo "  可能原因: 密钥不对 / 用户名错 / sshd 未运行 / 被防火墙拦截"
    exit 1
    ;;
  *)
    echo "FAIL: SSH 命令异常 (rc=$RC)"
    echo "$OUT" | head -3
    exit 1
    ;;
esac
