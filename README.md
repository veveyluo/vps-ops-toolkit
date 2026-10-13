# VPS Ops Toolkit

通用 VPS 运维工具集：SOCKS5 代理隧道、基础设施健康检查、搜索 API 封装。

所有凭据通过环境变量或 `.env` 文件加载，**无任何硬编码**。

## 快速开始

```bash
cp .env.example .env
# 编辑 .env，填入你的 VPS 连接信息
```

### 环境变量

| 变量 | 说明 |
|---|---|
| `VPS_HOST` | VPS 公网 IP 或域名 |
| `VPS_SOCKS_PORT` | SOCKS5 代理端口 |
| `VPS_SOCKS_USER` | SOCKS5 用户名 |
| `VPS_SOCKS_PASS` | SOCKS5 密码 |
| `VPS_SSH_PORT` | SSH 端口（默认 22） |
| `VPS_SSH_USER` | SSH 用户名 |
| `VPS_SSH_KEY` | SSH 私钥路径 |
| `SEARCH_API_KEY` | 搜索 API 密钥（可选） |

## 脚本一览

| 脚本 | 用途 |
|---|---|
| `socks5_tunnel.py` | 本地 SOCKS5 隧道（自动重连） |
| `ssh_proxy.py` | SSH ProxyCommand 经 SOCKS5 中继 |
| `check_socks5.sh` | SOCKS5 代理连通性检查 |
| `check_vps.sh` | SSH 可达性 + 系统状态（CPU/内存/磁盘） |
| `check_service.sh` | 远程 systemd 服务状态检查 |
| `search_wrapper.sh` | 搜索 API 封装（自动注入 SOCKS5 代理） |

### 用法示例

```bash
# 检查 SOCKS5 代理
source .env && export $(grep -v '^#' .env | xargs)
bash check_socks5.sh

# 检查 VPS 系统状态
bash check_vps.sh

# 检查某个服务
bash check_service.sh sing-box

# 启动本地隧道（监听 8443 → 目标 443）
python3 socks5_tunnel.py example.com 443 8443

# SSH 走 SOCKS5 中继
python3 ssh_proxy.py 1.2.3.4 22
```

## 许可证

MIT
