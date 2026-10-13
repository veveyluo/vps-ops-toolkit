#!/bin/bash
# check_socks5.sh — Verify SOCKS5 proxy is reachable.
# Required: VPS_HOST VPS_SOCKS_PORT VPS_SOCKS_USER VPS_SOCKS_PASS
set -euo pipefail
: "${VPS_HOST:?}" : "${VPS_SOCKS_PORT:?}" : "${VPS_SOCKS_USER:?}" : "${VPS_SOCKS_PASS:?}"
TEST_URL="${TEST_URL:-https://api.github.com/rate_limit}"
PROXY="socks5h://${VPS_SOCKS_USER}:${VPS_SOCKS_PASS}@${VPS_HOST}:${VPS_SOCKS_PORT}"
echo "=== SOCKS5: ${VPS_HOST}:${VPS_SOCKS_PORT} ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" --proxy "$PROXY" --max-time 15 "$TEST_URL" 2>/dev/null) || CODE="000"
[ "$CODE" = "200" ] && { echo "OK"; exit 0; } || { echo "FAIL (HTTP $CODE)"; exit 1; }
