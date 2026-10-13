#!/bin/bash
# check_vps.sh — SSH reachability + system stats.
# Required: VPS_HOST; Optional: VPS_SSH_PORT VPS_SSH_USER VPS_SSH_KEY
set -euo pipefail
: "${VPS_HOST:?}"
: "${VPS_SSH_PORT:=22}" : "${VPS_SSH_USER:=root}" : "${VPS_SSH_KEY:=~/.ssh/id_ed25519}"
SSH=(ssh -i "$VPS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -p "$VPS_SSH_PORT" "${VPS_SSH_USER}@${VPS_HOST}")
echo "=== VPS: ${VPS_HOST}:${VPS_SSH_PORT} ==="
OUT=$("${SSH[@]}" 'echo "CPU: $(nproc) cores"; echo "Mem: $(free -h | awk "/^Mem:/{print \$2" total, "\$7" avail"}")"; echo "Disk: $(df -h / | awk "NR==2{print \$4" free of "\$2}"; echo "Up: $(uptime -p 2>/dev/null || uptime)"' 2>&1) || { echo "FAIL: unreachable"; exit 1; }
echo "$OUT"; echo "OK"
