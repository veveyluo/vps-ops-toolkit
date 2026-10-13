#!/bin/bash
# search_wrapper.sh — Search API with SOCKS5 proxy.
# Usage: search_wrapper.sh <query>
set -euo pipefail
: "${1:?usage: search_wrapper.sh <query>}"
: "${VPS_HOST:?}" : "${VPS_SOCKS_PORT:?}" : "${VPS_SOCKS_USER:?}" : "${VPS_SOCKS_PASS:?}"
PROXY="socks5h://${VPS_SOCKS_USER}:${VPS_SOCKS_PASS}@${VPS_HOST}:${VPS_SOCKS_PORT}"
API_URL="${SEARCH_API_URL:-https://api.example.com/search}"
KEY="${SEARCH_API_KEY:-}"
Q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1")
AUTH=(); [ -n "$KEY" ] && AUTH=(-H "Authorization: Bearer $KEY")
curl -s --proxy "$PROXY" --max-time 30 "${AUTH[@]}" "$API_URL?q=$Q"
