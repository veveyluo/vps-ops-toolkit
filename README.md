# VPS Ops Toolkit

通用 VPS 运维工具集：SOCKS5 代理隧道、基础设施健康检查、搜索 API 封装。

所有凭据通过环境变量或 `.env` 文件加载，**无任何硬编码**。

## 快速开始

```bash
# 1. 复制配置模板
cp .env.example .env

# 2. 编辑 .env，填入你的 VPS 连接信息
vim .env

# 3. 检查依赖
bash run.sh deps

# 4. 跑所有健康检查
bash run.sh check
```

### 环境变量

| 变量 | 说明 | 必填 |
|---|---|:---:|
| `VPS_HOST` | VPS 公网 IP 或域名 | ✅ |
| `VPS_SOCKS_PORT` | SOCKS5 代理端口 | ✅ |
| `VPS_SOCKS_USER` | SOCKS5 用户名 | ✅ |
| `VPS_SOCKS_PASS` | SOCKS5 密码 | ✅ |
| `VPS_SSH_PORT` | SSH 端口 | 默认 22 |
| `VPS_SSH_USER` | SSH 用户名 | 默认 root |
| `VPS_SSH_KEY` | SSH 私钥路径 | 默认 ~/.ssh/id_ed25519 |
| `SEARCH_API_KEY` | 搜索 API 密钥 | 可选 |
| `SEARCH_API_URL` | 搜索 API 地址 | 可选 |

## 命令一览

统一入口 `run.sh`，自动加载 `.env`：

| 命令 | 用途 |
|---|---|
| `bash run.sh check` | 跑所有检查（SOCKS5 + VPS 系统状态） |
| `bash run.sh check socks5` | 只检查 SOCKS5 代理 |
| `bash run.sh check vps` | 只检查 VPS 系统状态 |
| `bash run.sh check service <name>` | 检查指定 systemd 服务 |
| `bash run.sh tunnel [host] [port] [listen]` | 启动本地 SOCKS5 隧道 |
| `bash run.sh search <query>` | 搜索（走 SOCKS5 代理） |
| `bash run.sh deps` | 检查依赖（curl/python3/ssh） |
| `bash run.sh help` | 显示帮助 |

### 示例

```bash
# 全部健康检查
bash run.sh check

# 检查 sing-box 服务
bash run.sh check service sing-box

# 启动隧道：本地 8443 → 目标 example.com:443
bash run.sh tunnel example.com 443 8443

# 搜索
bash run.sh search "QwenPaw latest version"

# 直接用脚本（不经过 run.sh）
bash check_socks5.sh
python3 socks5_tunnel.py example.com 443 8443
```

## 推送安全

`.gitignore` 已配置，以下文件不会被提交：
- `.env`（真实凭据）
- `.secrets/` 目录
- SSH 密钥文件（`*.pem`、`id_ed25519` 等）

推送前运行 `bash pre_push_check.sh` 扫描敏感信息（IP/密钥/token），发现即拒绝。
GitHub Actions CI 会在每次 push 时自动跑语法检查 + 敏感信息扫描。

## 文件结构

```
├── run.sh                 # 统一入口
├── socks5_tunnel.py       # 本地 SOCKS5 隧道（自动重连）
├── ssh_proxy.py           # SSH ProxyCommand 经 SOCKS5 中继
├── check_socks5.sh        # SOCKS5 代理检查
├── check_vps.sh           # VPS 系统状态检查
├── check_service.sh       # 远程 systemd 服务检查
├── search_wrapper.sh      # 搜索 API 封装
├── pre_push_check.sh      # 推送前敏感信息扫描
├── .env.example           # 配置模板
├── .gitignore             # Git 忽略规则
├── .github/workflows/ci.yml  # CI（语法检查 + 敏感扫描）
├── LICENSE
└── README.md
```

## 许可证

MIT
