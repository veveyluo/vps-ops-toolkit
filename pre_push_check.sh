#!/bin/bash
# pre_push_check.sh — 推送前敏感信息扫描 (v2)
# 用法: bash pre_push_check.sh
# 发现敏感模式则退出码 1，阻止推送
set -euo pipefail

FAIL=0
CHECKED=0

# 获取待检查文件（暂存区优先，否则全部已跟踪文件）
get_files() {
  local files
  files=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
  if [ -z "$files" ]; then
    files=$(git ls-files 2>/dev/null)
  fi
  echo "$files"
}

echo "=== pre-push 敏感信息检查 (v2) ==="

while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    .gitignore|LICENSE|*.md|.github/*) continue ;;
  esac
  CHECKED=$((CHECKED + 1))

  # 1. IP 地址（排除 127.0.0.1, 0.0.0.0, 255.255.255.255, 示例 1.2.3.4/192.168.x）
  IP_MATCHES=$(grep -nP '\b((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b' "$f" 2>/dev/null \
    | grep -vP '127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255|1\.2\.3\.4|192\.168\.|10\.\d+\.' || true)
  if [ -n "$IP_MATCHES" ]; then
    echo "⚠️  $f: 疑似公网 IP 地址"
    echo "$IP_MATCHES" | head -3 | sed 's/^/    /'
    FAIL=1
  fi

  # 2. 硬编码凭据
  CRED_PATTERNS=(
    'SOCKS_PASS\s*=\s*[^"$]'
    'API_KEY\s*=\s*["'"'"'][A-Za-z0-9]'
    'ghp_[A-Za-z0-9]{36}'
    'gho_[A-Za-z0-9]{36}'
    'as_sk_[A-Za-z0-9]{20,}'
    'sk-[A-Za-z0-9]{32,}'
    'AKIA[0-9A-Z]{16}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
  )
  for pat in "${CRED_PATTERNS[@]}"; do
    M=$(grep -nP "$pat" "$f" 2>/dev/null || true)
    if [ -n "$M" ]; then
      echo "⚠️  $f: 疑似硬编码凭据"
      echo "$M" | head -3 | sed 's/^/    /'
      FAIL=1
    fi
  done

  # 3. 内网/敏感端口（排除通用 22/80/443/8080/1080）
  SENSITIVE_PORTS=':(25774|41080|41084|8088|30208|43253|49815|64614|2052|2222|39540|4083)\b'
  PORT_MATCHES=$(grep -nP "$SENSITIVE_PORTS" "$f" 2>/dev/null || true)
  if [ -n "$PORT_MATCHES" ]; then
    echo "⚠️  $f: 疑似敏感端口"
    echo "$PORT_MATCHES" | head -3 | sed 's/^/    /'
    FAIL=1
  fi

  # 4. 私有路径
  PATH_PATTERNS='/run/csi|/home/<YOUR_USER>|site-packages/qwenpaw|/app/working'
  PATH_MATCHES=$(grep -nP "$PATH_PATTERNS" "$f" 2>/dev/null | grep -v 'PATH_PATTERNS=' || true)
  if [ -n "$PATH_MATCHES" ]; then
    echo "⚠️  $f: 疑似内部路径"
    echo "$PATH_MATCHES" | head -3 | sed 's/^/    /'
    FAIL=1
  fi

done < <(get_files)

echo ""
echo "扫描 $CHECKED 个文件"
if [ "$FAIL" -eq 1 ]; then
  echo "❌ 发现敏感信息，推送已阻止。请检查上述文件。"
  exit 1
else
  echo "✅ 检查通过，未发现敏感信息"
  exit 0
fi
