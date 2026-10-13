#!/bin/bash
# pre_push_check.sh — 推送前敏感信息扫描
# 用法: bash pre_push_check.sh
# 发现敏感模式则退出码 1，阻止推送
set -euo pipefail

FAIL=0
PATTERNS=(
  # IP 地址（排除 127.0.0.1 和 0.0.0.0）
  "([0-9]{1,3}\.){3}[0-9]{1,3}"
  # 硬编码密码/密钥
  "SOCKS_PASS\s*="
  "API_KEY\s*=\s*['\"]"
  "ghp_[A-Za-z0-9]{36}"
  "as_sk_[A-Za-z0-9]{20,}"
  "sk-[A-Za-z0-9]{32,}"
  # 端口 + IP 组合
  "@[0-9]{1,3}\.[0-9]{1,3}"
)

echo "=== pre-push 敏感信息检查 ==="

for f in $(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || git ls-files); do
  [ -f "$f" ] || continue
  case "$f" in
    .gitignore|LICENSE|*.md) continue ;;
  esac

  for pat in "${PATTERNS[@]}"; do
    # 排除 127.0.0.1 / 0.0.0.0
    if grep -P "$pat" "$f" 2>/dev/null | grep -vP "127\.0\.0\.1|0\.0\.0\.0|([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -qP "$pat" 2>/dev/null; then
      # 更精确：找 IP 但排除本地地址
      MATCHES=$(grep -nP "$pat" "$f" 2>/dev/null | grep -vP "127\.0\.0\.1|0\.0\.0\.0|#" || true)
      if [ -n "$MATCHES" ]; then
        echo "⚠️  $f: 疑似敏感内容"
        echo "$MATCHES" | head -3 | sed 's/^/    /'
        FAIL=1
      fi
    fi
  done
done

if [ "$FAIL" -eq 1 ]; then
  echo ""
  echo "❌ 发现敏感信息，推送已阻止。请检查上述文件。"
  exit 1
else
  echo "✅ 检查通过"
  exit 0
fi
