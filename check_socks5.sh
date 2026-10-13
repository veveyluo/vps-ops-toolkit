#!/bin/bash
# check_socks5.sh — SOCKS5 代理连通性检查
# Required: VPS_HOST VPS_SOCKS_PORT VPS_SOCKS_USER VPS_SOCKS_PASS
# Output: OK / FAIL: <reason>
set -uo pipefail

# 变量检查
MISSING=()
[ -n "${VPS_HOST:-}" ] || MISSING+=("VPS_HOST")
[ -n "${VPS_SOCKS_PORT:-}" ] || MISSING+=("VPS_SOCKS_PORT")
[ -n "${VPS_SOCKS_USER:-}" ] || MISSING+=("VPS_SOCKS_USER")
[ -n "${VPS_SOCKS_PASS:-}" ] || MISSING+=("VPS_SOCKS_PASS")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "FAIL: 缺少环境变量 ${MISSING[*]}（检查 .env 是否配置）"
  exit 1
fi

TEST_URL="${TEST_URL:-https://api.github.com/rate_limit}"
PROXY="socks5h://${VPS_SOCKS_USER}:${VPS_SOCKS_PASS}@${VPS_HOST}:${VPS_SOCKS_PORT}"

echo "=== SOCKS5: ${VPS_HOST}:${VPS_SOCKS_PORT} ==="

# 先测 TCP 连通性（区分网络不通 vs 代理错误）
if ! timeout 10 bash -c "echo >/dev/tcp/${VPS_HOST}/${VPS_SOCKS_PORT}" 2>/dev/null; then
  echo "FAIL: TCP 连接 ${VPS_HOST}:${VPS_SOCKS_PORT} 超时（网络不通或端口未开放）"
  exit 1
fi

# 再测 SOCKS5 代理
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --proxy "$PROXY" \
  --max-time 20 \
  "$TEST_URL" 2>/dev/null) || CODE="000"

case "$CODE" in
  200) echo "OK: SOCKS5 代理正常 (HTTP 200)"; exit 0 ;;
  000) echo "FAIL: SOCKS5 代理无响应（超时或连接被重置）"; exit 1 ;;
  407) echo "FAIL: SOCKS5 认证失败 (HTTP 407)（用户名或密码错误）"; exit 1 ;;
  403) echo "WARN: SOCKS5 连接成功但目标返回 403（代理可用，目标 IP 被封）"; exit 0 ;;
  *)   echo "FAIL: SOCKS5 代理异常 (HTTP $CODE)"; exit 1 ;;
esac
