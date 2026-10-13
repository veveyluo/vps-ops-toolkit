#!/bin/bash
# check_service.sh — Check remote systemd service.
# Usage: check_service.sh <service-name>
set -euo pipefail
: "${1:?usage: check_service.sh <service>}"
: "${VPS_HOST:?}"
: "${VPS_SSH_PORT:=22}" : "${VPS_SSH_USER:=root}" : "${VPS_SSH_KEY:=~/.ssh/id_ed25519}"
SSH=(ssh -i "$VPS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -p "$VPS_SSH_PORT" "${VPS_SSH_USER}@${VPS_HOST}")
STATE=$("${SSH[@]}" "systemctl is-active '$1' 2>/dev/null" 2>&1) || true
[ "$STATE" = "active" ] && { echo "OK: $1 active"; exit 0; } || { echo "FAIL: $1 = ${STATE:-unknown}"; exit 1; }
