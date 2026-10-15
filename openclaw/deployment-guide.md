# OpenClaw 部署运维手册

> 记录 OpenClaw 在 GCP VPS 上的完整部署过程、踩过的所有坑、以及最终可用配置。
> 日期：2026-10-15（第二版） | OpenClaw 版本：2026.9.2 | VPS：GCP e2-micro (958MB RAM)

---

## 环境信息

- **VPS**: Google Cloud Platform e2-micro，958MB 内存
- **SSH**: `ssh -i ~/.ssh/<YOUR_SSH_KEY> -p <YOUR_SSH_PORT> <YOUR_SSH_USER>@<YOUR_VPS_IP>`
- **域名**: `openclaw.<YOUR_DOMAIN>`（通过 Caddy 反代）
- **OpenClaw**: npm 全局安装，版本 2026.9.2
- **AI 后端**: <PLATFORM_NAME> 平台 (`<PLATFORM_DOMAIN>`)，免费档
- **API Key**: <PLATFORM_NAME> 平台 key，格式 `<API_KEY_PREFIX>-xxxxx`
- **反向代理**: Caddy (80/443) → localhost:18789
- **防火墙**: ufw，只放行 SSH + Caddy + VPN 端口

---

## 踩坑总览

按发现顺序排列，每个坑标注严重程度和解决状态。

### 坑 1：内存不足导致 Gateway 频繁崩溃 ⚠️⚠️⚠️

**现象**：Gateway 启动后几分钟内崩溃，systemd 自动重启又崩，进入 crash-loop。

**根因**：e2-micro 只有 958MB 内存，OpenClaw Gateway 启动时 SQLite 初始化 + 插件加载消耗大量内存，OOM killer 直接杀进程。

**解决**：
- 插件从 39 个砍到最小必要集（大幅降低内存占用）
- 启动时间从 >30s 降到 ~15s
- crash-loop breaker 触发后需要等 5 分钟冷却，清除 stability 记录后才能重启：
  ```bash
  sudo systemctl stop openclaw
  rm -f /home/<YOUR_SSH_USER>/.openclaw/logs/stability/*.json
  # 等 5 分钟
  sudo systemctl start openclaw
  ```

**教训**：不要在 1GB 内存机器上跑满插件。精简到最小必要集。

---

### 坑 2：插件过多（39个） ⚠️⚠️

**现象**：Gateway 启动慢、内存占用高、部分插件报错。

**根因**：OpenClaw 默认安装大量插件，大部分用不到但都占内存。

**解决**：禁用所有非必要插件。最终只保留 memory-core（记忆核心）。

**教训**：部署后第一时间审查插件列表，禁用不用的。

---

### 坑 3：Memory Search 未开启 ⚠️

**现象**：AI 无法使用长期记忆功能。

**根因**：默认未启用。

**解决**：Settings → Memory → 开启 Memory Search。

---

### 坑 4：opencode-go provider 的 API 格式硬编码 ⚠️⚠️⚠️⚠️

**这是最深的坑，耗费最多时间排查。**

**现象**：使用 `opencode-go/qwen3.8-max` 发消息时报 400 错误。

**根因**：OpenClaw 的 opencode-go provider 是为官方 AI 网关设计的，`qwen3.8-max` 在 catalog 里绑定了 `anthropic-messages` 格式，且 baseUrl 硬编码指向官方服务器。第三方平台只支持 OpenAI 兼容格式，格式不兼容。

**解决**：弃用 opencode-go provider，改用自定义 provider（见坑 11）。

**教训**：不要用 opencode-go provider 连第三方平台。

---

### 坑 5：openai provider 的模型名不在 catalog 中 ⚠️⚠️⚠️⚠️

**现象**：改用 `openai/qwen3.8-max` 后报 `Unknown model`。

**根因**：OpenClaw 的 openai provider 只认识 OpenAI 官方模型名，不认识第三方平台的模型名。有两层检查：
- model-fetch 层（发 HTTP 请求）：通过 `OPENAI_BASE_URL` 环境变量能连到第三方平台
- agent runtime 层（检查 catalog）：发现模型未注册，拒绝执行

**解决**：在 `openclaw.json` 的 `models.providers.{provider}.models` 数组中手动注册自定义模型。

**源码依据**：`buildConfiguredModelCatalog()` 函数从 config 的 `models.providers.{provider}.models` 数组构建自定义模型目录。

**教训**：OpenClaw 不会自动从第三方 API 的 `/models` 接口发现模型。必须手动在 config 中注册。

---

### 坑 6：systemd 环境变量中的 API key 被截断 ⚠️⚠️⚠️

**现象**：模型注册成功后，聊天报 401 认证失败。

**根因**：systemd service 文件里的 `OPENAI_API_KEY` 只有 13 个字符（完整 key 应该是 52 字符），可能是配置时复制粘贴截断。

**解决**：写入完整 key 到 systemd env var + config 双保险。

**教训**：配置 API key 后一定要用 `wc -c` 验证长度。

---

### 坑 7：OPENAI_BASE_URL 环境变量 vs config baseUrl ⚠️⚠️

**现象**：在 config 中设置 `baseUrl` 不生效，但环境变量 `OPENAI_BASE_URL` 生效。

**根因**：openai provider 通过 `resolveOpenAIEnvironmentBaseUrl()` 函数从环境变量读取 baseUrl，不从 config 的 `baseUrl` 字段读。

**解决**：用环境变量 `OPENAI_BASE_URL` 设置平台地址。

**教训**：OpenClaw openai provider 读取 baseUrl 的优先级是 model.baseUrl > OPENAI_BASE_URL env var，provider 级别的 baseUrl 配置不被识别。

---

### 坑 8：设备配对审批无法关闭 ⚠️⚠️

**现象**：想关闭设备配对审批，但 `devicePairing` 不是合法配置项，加了反而 gateway 崩溃。

**根因**：设备配对是 OpenClaw 核心安全机制，不能通过配置关闭。密码模式下也仍然需要。

**解决**：改回 token 模式，依赖已批准设备连接。新设备通过 Settings → Devices 审批，或 SSH 跑 `openclaw devices join-code` 生成一次性配对链接。

---

### 坑 9：Caddy WebSocket 403 ⚠️⚠️

**现象**：Control UI WebSocket 连接被 Caddy 拒绝，返回 403。

**根因**：Caddy 配置里的 `encode gzip zstd` 干扰 WebSocket 升级。

**解决**：从 Caddy 配置中删除 `encode gzip zstd`。

---

### 坑 10：openai 插件自带 30+ 模型目录 ⚠️⚠️⚠️

**这是第二版部署时发现的核心坑。**

**现象**：设置 `models.mode = "replace"` 后，刷新模型目录仍然出现 30 多个 OpenAI 官方收费模型。

**根因**：openai 插件内置了 OpenAI 官方模型目录（gpt-4、gpt-3.5-turbo 等），只要插件启用且配了 API key，内置目录就会显示。`mode: "replace"` 只控制哪些 provider 生效，管不住单个 provider 的内置 catalog。

**解决**：禁用 openai 插件，改用自定义 provider（名称如 `custom`），在 config 里只放我们手动注册的模型。这样内置的 30+ 模型不再加载。

**教训**：OpenClaw 的 `models.mode = "replace"` 不是万能的。内置插件的 catalog 需要通过禁用插件来移除。

---

### 坑 11：自定义 provider 的 baseUrl 必须显式设置 ⚠️⚠️

**现象**：禁用 openai 插件改用自定义 provider 后，刷新模型目录又冒出 30+ 模型。

**根因**：自定义 provider 没设 `baseUrl`，刷新时走默认 OpenAI API（`api.openai.com/v1/models`）拉回 30+ 官方模型。

**解决**：在自定义 provider 配置里显式设 `baseUrl` 指向第三方平台：
```json
{
  "models": {
    "mode": "replace",
    "providers": {
      "custom": {
        "baseUrl": "https://<PLATFORM_DOMAIN>/compatible-mode/v1",
        "apiKey": "<API_KEY_PREFIX>-XXXXX",
        "models": [...]
      }
    }
  }
}
```

**教训**：自定义 provider 必须设 `baseUrl`，否则模型目录刷新会走默认 OpenAI API。

---

### 坑 12：误加不支持的配置键导致 Gateway 崩溃 ⚠️⚠️⚠️

**现象**：在 config 里加了 `models.default` 或 `gateway.auth.rateLimit`，Gateway 启动报 `CONFIG` 错误直接退出。

**根因**：OpenClaw 的 config schema 有严格校验，不认识的键直接拒绝启动。`models.default`、`gateway.auth.rateLimit` 都不是合法键。

**解决**：删掉不合法的键。默认模型通过 `agents.defaults.model` 设置（不是 `models.default`）。

**教训**：改 config 前先跑 `openclaw config schema` 确认键名。不确定的键不要加。

---

### 坑 13：restart-loop breaker 反复触发 ⚠️⚠️

**现象**：Gateway 崩溃后 systemd 自动重启，连续崩溃几次后 restart-loop breaker 触发，即使修好了配置也无法启动。

**根因**：breaker 统计 300 秒内的崩溃次数，超过阈值就锁定，阻止 gateway 自动启动 channel/provider。

**解决**：
```bash
sudo systemctl stop openclaw
sudo systemctl reset-failed openclaw
rm -f /home/<YOUR_SSH_USER>/.openclaw/logs/stability/*.json
# 等 5 分钟让 300s 窗口过期
sudo systemctl start openclaw
```

**教训**：改 config 后如果 Gateway 崩了，不要反复重启。先修好 config，清 stability 记录，等 5 分钟再启动。

---

### 坑 14：模型名变更后旧会话找不到模型 ⚠️⚠️

**现象**：从 `openai` provider 改成 `custom` provider 后，旧会话报 `Unknown model: openai/qwen3.8-max`。

**根因**：旧会话的模型选择器还引用旧 provider 名 `openai/xxx`，但 openai 插件已禁用。

**解决**：更新 `agents.defaults.model` 为新 provider 名：
```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "custom/qwen3.8-max",
        "fallbacks": ["custom/glm-5.2", "custom/qwen3.8-flash"]
      }
    }
  }
}
```

**教训**：改 provider 名后，`agents.defaults.model` 里的引用要同步更新。

---

### 坑 15：8080 端口公网暴露 ⚠️⚠️

**现象**：订阅服务（busybox httpd）监听 `*:8080`，公网可访问。

**解决**：改 systemd service 配置，绑定到 `127.0.0.1:8080`：
```bash
sudo sed -i 's/-p 8080/-p 127.0.0.1:8080/' /etc/systemd/system/busybox-httpd.service
sudo systemctl daemon-reload
sudo systemctl restart busybox-httpd
```

**教训**：部署后检查所有监听端口，不需要公网访问的服务一律收回 localhost。

---

### 坑 16：GCP 1GB 内存导致响应慢 ⚠️⚠️⚠️

**现象**：新建会话 + 首次回复需要 18-20 秒，用户体验差。

**根因**：OpenClaw Gateway 占 ~389MB（40% 内存），新建会话时需要启动 agent 进程 + 加载工作区 + 读文件初始化，1GB 机器大量靠 swap 撑。

**解决**：暂无根治方案。设了 `NODE_COMPILE_CACHE` 和 `OPENCLAW_NO_RESPAWN` 环境变量优化性能，但改善有限。

**教训**：OpenClaw 是重型 Node.js 应用，1GB 内存勉强能跑但体验差。建议部署在 ≥2GB 内存的机器上。

---

## 最终可用配置（2026-10-15 第二版）

### systemd service (/etc/systemd/system/openclaw.service)

```ini
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Environment=NODE_OPTIONS=--max-old-space-size=768
Environment=OPENAI_API_KEY=<API_KEY_PREFIX>-<YOUR_API_KEY>
Environment=OPENAI_BASE_URL=https://<PLATFORM_DOMAIN>/compatible-mode/v1
Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
Environment=OPENCLAW_NO_RESPAWN=1
Type=simple
User=<YOUR_SSH_USER>
ExecStart=/usr/bin/openclaw gateway run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### openclaw.json 关键配置

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "custom/qwen3.8-max",
        "fallbacks": ["custom/glm-5.2", "custom/qwen3.8-flash"]
      }
    }
  },
  "models": {
    "mode": "replace",
    "providers": {
      "custom": {
        "baseUrl": "https://<PLATFORM_DOMAIN>/compatible-mode/v1",
        "apiKey": "<API_KEY_PREFIX>-<YOUR_API_KEY>",
        "models": [
          {
            "id": "qwen3.8-max",
            "name": "Qwen3.8 Max",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text", "image"]
          },
          {
            "id": "glm-5.2",
            "name": "GLM-5.2",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text"]
          },
          {
            "id": "qwen3.8-flash",
            "name": "Qwen3.8 Flash",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text"]
          },
          {
            "id": "kimi-k3",
            "name": "Kimi K3",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text", "image"]
          },
          {
            "id": "qwen3.7-plus",
            "name": "Qwen3.7 Plus",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text"]
          }
        ]
      }
    }
  }
}
```

### ufw 防火墙规则

```bash
# 默认拒绝所有入站
sudo ufw default deny incoming
sudo ufw default allow outgoing

# 只放行必要端口
sudo ufw allow <YOUR_SSH_PORT>/tcp   # SSH
sudo ufw allow 80/tcp                 # Caddy HTTP
sudo ufw allow 443/tcp                # VPN (sing-box)
sudo ufw allow <YOUR_HTTPS_PORT>/tcp  # Caddy HTTPS (Komari 等)

# 启用
echo 'y' | sudo ufw enable
```

> 18789（OpenClaw）和 8080（订阅服务）不在放行列表中，被 ufw 默认拒绝。OpenClaw 通过 Caddy 80 端口反代访问。

### 数据流

```
用户 → Caddy (openclaw.<YOUR_DOMAIN>:80) → Gateway (localhost:18789)
  → custom provider (baseUrl 指向 <PLATFORM_DOMAIN>)
  → https://<PLATFORM_DOMAIN>/compatible-mode/v1/chat/completions
  → qwen3.8-max 模型
  → 流式回复
```

### <PLATFORM_NAME> 平台可用模型

| 模型 ID | 视觉 | 备注 |
|---------|------|------|
| qwen3.8-max | ✅ | 默认模型 |
| glm-5.2 | ❌ | 中文强 |
| qwen3.8-flash | ❌ | 快速 |
| kimi-k3 | ✅ | 视觉备选 |
| qwen3.7-plus | ❌ | 均衡 |
| deepseek-v4-flash | ❌ | 平台已下线（404），不可用 |

---

## 常用运维命令

### 检查状态
```bash
ss -tlnp | grep 18789       # Gateway 是否在监听
systemctl is-active openclaw # systemd 状态
journalctl -u openclaw --no-pager -n 10  # 最近日志
```

### 重启 Gateway
```bash
# 正常重启
sudo systemctl restart openclaw

# crash-loop 恢复
sudo systemctl stop openclaw
sudo systemctl reset-failed openclaw
rm -f /home/<YOUR_SSH_USER>/.openclaw/logs/stability/*.json
# 等 5 分钟
sudo systemctl start openclaw
```

### 修改配置
```bash
# 读当前配置
openclaw config get models

# 改配置（用 Python 安全写入 JSON）
python3 -c "
import json
f='/home/<YOUR_SSH_USER>/.openclaw/openclaw.json'
with open(f) as fh: cfg=json.load(fh)
# 修改...
with open(f,'w') as fh: json.dump(cfg,fh,indent=2)
"
sudo systemctl restart openclaw
```

### 验证 API key 完整性
```bash
grep "OPENAI_API_KEY" /etc/systemd/system/openclaw.service | cut -d= -f3 | wc -c
# 应该是 53（52 字符 + 换行）
```

### ufw 防火墙管理
```bash
sudo ufw status verbose    # 查看规则
sudo ufw allow <PORT>/tcp  # 添加放行
sudo ufw deny <PORT>/tcp   # 添加拒绝
```

### 禁用插件
```bash
openclaw plugins disable <plugin_name>
sudo systemctl restart openclaw
```

---

## 排错决策树

```
聊天报错
├── "Unknown model: xxx/yyy"
│   ├── provider 名变了 → 更新 agents.defaults.model 引用
│   └── 模型未注册 → 在 config models.providers.xxx.models 添加
├── "authentication failed, HTTP 401"
│   ├── 检查 config apiKey 是否完整
│   └── 检查 systemd OPENAI_API_KEY 是否截断（wc -c 验证）
├── "provider rejected the request schema" (400)
│   └── 检查模型 api 格式是否为 openai-completions（非 anthropic-messages）
├── 模型目录出现 30+ 收费模型
│   ├── 检查是否禁用了 openai 插件
│   └── 检查自定义 provider 是否设了 baseUrl
├── Gateway 崩溃 (exit code 78/CONFIG)
│   ├── 检查 config 是否有不支持的键
│   └── 跑 openclaw config schema 确认键名
├── Gateway 崩溃后无法重启
│   ├── restart-loop breaker → 清 stability + reset-failed + 等 5 分钟
│   └── 内存不足 → 减少插件
├── 页面 502
│   └── Gateway 没起来，检查 systemd + ufw 是否放行 80
└── 响应慢 (18-20s)
    └── 内存不足，考虑迁移到 ≥2GB 机器
```

---

## 关键源码位置

| 文件 | 作用 |
|------|------|
| `provider-catalog-*.js` | Provider 和模型 catalog 定义（硬编码） |
| `model-selection-shared-*.js` | 自定义模型注册逻辑（`buildConfiguredModelCatalog`） |
| `provider-policy-api-*.js` | OpenAI baseUrl 解析逻辑（`resolveOpenAIEnvironmentBaseUrl`） |

路径前缀：`/usr/lib/node_modules/openclaw/dist/`

---

## 未解决问题 / 已知限制

1. **GCP e2-micro 内存不足**：958MB 跑 OpenClaw 勉强可用，响应 18-20 秒，建议 ≥2GB
2. **rateLimit 无法通过 config 设置**：`gateway.auth.rateLimit` 不是合法键，需通过其他方式实现
3. **opencode-go provider 无法用于第三方平台**：baseUrl 和 API 格式都硬编码
4. **openai 插件内置 catalog 无法通过 mode=replace 隐藏**：必须禁用插件
5. **device pairing 无法关闭**：核心安全机制，token 和密码模式都需要
6. **Settings 页面 "Test connection" 不准确**：openai provider 的连接测试不使用自定义 baseUrl

---

## 总结：要让 OpenClaw 连接第三方平台正常工作

1. **禁用内置 openai 插件** — 避免自带 30+ 收费模型目录
2. **创建自定义 provider** — 设 `baseUrl` 指向第三方平台 + 手动注册模型
3. **设置 `agents.defaults.model`** — 用 `{primary, fallbacks}` 对象格式引用新 provider 名
4. **环境变量正确** — `OPENAI_API_KEY`（完整）+ `OPENAI_BASE_URL`（指向第三方平台）
5. **`models.mode = "replace"`** — 只使用配置的 provider
6. **装 ufw 防火墙** — 只放行必要端口，18789 收回 localhost 走 Caddy 反代

---

## 版本历史

- **v1（2026-10-14）**：初始部署，10 个坑，openai provider + opencode-go provider
- **v2（2026-10-15）**：模型配置重构，禁用 openai/opencode-go 插件改用自定义 provider，5 个免费模型，ufw 防火墙，8080 收回 localhost，新增坑 10-16

---

*文档维护：AI 助手 | 最后更新：2026-10-15*
