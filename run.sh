#!/bin/bash
# run.sh — 统一入口
# 用法:
#   bash run.sh check          # 跑所有检查（socks5 + vps + 指定服务）
#   bash run.sh check socks5   # 只检查 SOCKS5
#   bash run.sh check vps      # 只检查 VPS 系统状态
#   bash run.sh check service <name>  # 检查指定 systemd 服务
#   bash run.sh tunnel [host] [port] [listen]  # 启动本地隧道
#   bash run.sh search <query> # 搜索
#   bash run.sh deps           # 检查依赖
set -euo pipefail
cd "$(dirname "$0")"

# 自动加载 .env（如果存在）
if [ -f .env ]; then
  set -a; source .env; set +a
fi

check_deps() {
  local missing=()
  for cmd in curl python3 ssh; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "❌ 缺少依赖: ${missing[*]}"
    echo "   Debian/Ubuntu: sudo apt install ${missing[*]}"
    echo "   RHEL/CentOS:   sudo dnf install ${missing[*]}"
    return 1
  fi
  echo "✅ 依赖检查通过 (curl, python3, ssh)"
}

run_check() {
  local target="${1:-all}"
  local fail=0

  case "$target" in
    socks5)
      bash check_socks5.sh || fail=1
      ;;
    vps)
      bash check_vps.sh || fail=1
      ;;
    service)
      if [ -z "${2:-}" ]; then
        echo "用法: run.sh check service <service-name>"
        return 2
      fi
      bash check_service.sh "$2" || fail=1
      ;;
    all)
      echo "========== 全部检查 =========="
      echo ""
      bash check_socks5.sh 2>&1 || fail=1
      echo ""
      bash check_vps.sh 2>&1 || fail=1
      echo ""
      echo "========== 检查完成 (退出码: $fail) =========="
      ;;
    *)
      echo "未知检查目标: $target"
      echo "用法: run.sh check [all|socks5|vps|service <name>]"
      return 2
      ;;
  esac
  return $fail
}

run_tunnel() {
  local host="${1:-example.com}"
  local port="${2:-443}"
  local listen="${3:-8443}"
  echo "启动隧道: 127.0.0.1:${listen} -> ${host}:${port}"
  python3 socks5_tunnel.py "$host" "$port" "$listen"
}

run_search() {
  local query="${1:?用法: run.sh search <query>}"
  bash search_wrapper.sh "$query"
}

case "${1:-help}" in
  check)  shift; run_check "${1:-all}" "${2:-}" ;;
  tunnel) shift; run_tunnel "$@" ;;
  search) shift; run_search "$@" ;;
  deps)   check_deps ;;
  help|*)
    echo "VPS Ops Toolkit"
    echo ""
    echo "用法: bash run.sh <command> [args]"
    echo ""
    echo "命令:"
    echo "  check [all|socks5|vps|service <name>]   运行健康检查"
    echo "  tunnel [host] [port] [listen]           启动本地 SOCKS5 隧道"
    echo "  search <query>                          搜索"
    echo "  deps                                    检查依赖"
    echo "  help                                    显示此帮助"
    ;;
esac
