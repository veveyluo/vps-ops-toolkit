# OpenClaw 部署运维手册

> 记录 OpenClaw 在 GCP VPS 上的完整部署过程、踩过的所有坑、以及最终可用配置。
> 日期：2026-10-14 | OpenClaw 版本：2026.9.2 | VPS：GCP e2-micro (958MB RAM)

---

## 环境信息

- **VPS**: Google Cloud Platform e2-micro，958MB 内存
- **SSH**: `ssh -i ~/.ssh/gcp_vps_id_ed25519 -p <YOUR_SSH_PORT> ANAI@<YOUR_VPS_IP>`
- **域名**: `openclaw.<YOUR_DOMAIN>`（通过 Caddy 反代）
- **OpenClaw**: npm 全局安装，版本 2026.9.2
- **AI 后端**: AgentScope 平台 (`platform.agentscope.io`)
- **API Key**: AgentScope 平台 key，格式 `sk-as-xxxxx`
- **反向代理**: Caddy → localhost:18789

---

## 踩坑总览

按发现顺序排列，每个坑标注严重程度和解决状态。

### 坑 1：内存不足导致 Gateway 频繁崩溃 ⚠️⚠️⚠️

**现象**：Gateway 启动后几分钟内崩溃，systemd 自动重启又崩，进入 crash-loop。

**根因**：e2-micro 只有 958MB 内存，OpenClaw Gateway 启动时 SQLite 初始化 + 插件加载消耗大量内存，OOM killer 直接杀进程。

**解决**：
- 插件从 39 个砍到 2 个（大幅降低内存占用）
- 启动时间从 >30s 降到 2.3s
- crash-loop breaker 触发后需要等 5 分钟冷却，清除 stability 记录后才能重启：
  ```bash
  sudo systemctl stop openclaw
  rm -f /home/ANAI/.openclaw/logs/stability/*.json
  # 等 5 分钟
  sudo systemctl start openclaw
  ```

**教训**：不要在 1GB 内存机器上跑满插件。精简到最小必要集。

---

### 坑 2：插件过多（39个） ⚠️⚠️

**现象**：Gateway 启动慢、内存占用高、部分插件报错。

**根因**：OpenClaw 默认安装大量插件（gmail-watcher、各种集成等），大部分用不到但都占内存。

**解决**：在 Settings → Plugins 页面禁用所有非必要插件，只保留：
- `openai`（AI 模型 provider）
- `opencode-go`（备用 provider）

**教训**：部署后第一时间审查插件列表，禁用不用的。

---

### 坑 3：Memory Search 未开启 ⚠️

**现象**：AI 无法使用长期记忆功能。

**根因**：默认未启用。

**解决**：Settings → Memory → 开启 Memory Search。

---

### 坑 4：Command Owner 未设置 ⚠️

**现象**：部分命令无法执行，权限不明确。

**解决**：在配置中设置 owner。

---

### 坑 5：opencode-go provider 的 API 格式硬编码为 Anthropic Messages ⚠️⚠️⚠️⚠️

**这是最深的坑，耗费最多时间排查。**

**现象**：使用 `opencode-go/qwen3.8-max` 发消息时报 400 错误：
```
LLM request failed: provider rejected the request schema or tool payload.
```

**排查过程**：
1. 查日志发现请求发到了 `https://opencode.ai/zen/go/v1/messages`（Anthropic Messages 格式 endpoint）
2. 但 AgentScope 平台只支持 OpenAI 兼容格式（`/v1/chat/completions`）
3. 查源码 `provider-catalog-BFfam1xM.js`，发现 `qwen3.8-max` 模型被硬编码：
   ```js
   {
     "id": "qwen3.8-max",
     "name": "Qwen3.8 Max",
     "api": "anthropic-messages",  // ← 硬编码，无法通过配置修改
     "baseUrl": "https://opencode.ai/zen/go"
   }
   ```

**根因**：OpenClaw 的 opencode-go provider 是为 OpenCode 官方 AI 网关设计的，不是给第三方平台用的。`qwen3.8-max` 这个模型在 catalog 里绑定了 `anthropic-messages` 格式，且 baseUrl 硬编码指向 `opencode.ai`。

**opencode-go provider 模型列表及 API 格式**：

| 模型 ID | API 格式 | 备注 |
|---------|----------|------|
| deepseek-v4-pro | openai-completions（默认） | AgentScope 有此模型 |
| deepseek-v4-flash | openai-completions（默认） | AgentScope 上 404，不可用 |
| kimi-k3 | openai-completions（默认） | AgentScope 有此模型 |
| kimi-k2.6 | openai-completions（默认） | AgentScope 无此模型 |
| gpt-5.6-luna | openai-responses | AgentScope 无此模型 |
| qwen3.8-max | **anthropic-messages（硬编码）** | AgentScope 有此模型，但格式不兼容 |
| hy3-preview | 默认 | AgentScope 无此模型 |

**教训**：opencode-go provider 的 baseUrl 硬编码指向 `opencode.ai`，即使配了 AgentScope 的 API key，请求也发到 OpenCode 官方服务器而非 AgentScope 平台。不要用 opencode-go provider 连第三方平台。

---

### 坑 6：openai provider 的模型名不在 catalog 中 ⚠️⚠️⚠️⚠️

**这是第二个核心坑。**

**现象**：改用 `openai/qwen3.8-max` 后报：
```
Unknown model: openai/qwen3.8-max
```

**排查过程**：
1. openai provider 确实通过 `OPENAI_BASE_URL` 环境变量连到了 AgentScope 平台
2. 日志里曾有 `status=200` 的成功记录（说明连通性没问题）
3. 但 agent runtime 层（不是 model-fetch 层）检查模型 catalog，发现 `qwen3.8-max` 不在 openai provider 的已知模型列表中
4. OpenClaw 的 openai provider 只认识 OpenAI 官方模型名（gpt-4, gpt-5.6-sol 等），不认识第三方平台的模型名

**根因**：OpenClaw 有两层检查：
- **model-fetch 层**：负责发 HTTP 请求，通过 `OPENAI_BASE_URL` 能正确连到 AgentScope（status=200）
- **agent runtime 层**：负责工具定义、系统提示词等，会检查模型是否在 catalog 中注册

model-fetch 层能通，但 agent runtime 层拒绝未知模型名。

**解决**：在 `openclaw.json` 的 `models.providers.openai.models` 数组中手动注册自定义模型：
```json
{
  "models": {
    "providers": {
      "openai": {
        "apiKey": "sk-as-XXXXX",
        "models": [
          {
            "id": "qwen3.8-max",
            "name": "Qwen3.8 Max",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text", "image"]
          }
        ]
      }
    }
  }
}
```

**源码依据**：`model-selection-shared-BlLyx1r2.js` 中的 `buildConfiguredModelCatalog()` 函数会从 `cfg.models.providers.{provider}.models` 数组构建自定义模型目录。每个 model 支持的字段：
- `id`：模型 ID（必填）
- `name`：显示名称
- `api`：API 格式（`openai-completions` / `openai-responses` / `anthropic-messages`）
- `baseUrl`：覆盖 provider 的 baseUrl
- `contextWindow`：上下文窗口大小
- `contextTokens`：上下文 token 数
- `reasoning`：是否支持推理（boolean）
- `input`：输入类型数组（`["text", "image"]`）
- `params`：模型参数
- `compat`：兼容性设置

**教训**：OpenClaw 不会自动从第三方 API 的 `/models` 接口发现模型。必须手动在 config 中注册自定义模型名。

---

### 坑 7：systemd 环境变量中的 API key 被截断 ⚠️⚠️⚠️

**现象**：模型注册成功后，聊天报 401 认证失败：
```
openai/qwen3.8-max request failed (authentication failed, HTTP 401)
```

**排查过程**：
1. 检查 systemd service 文件，发现 `OPENAI_API_KEY=sk-as-...WJZE`
2. 用 `wc -c` 验证，key 值只有 13 个字符（完整 key 应该是 52 字符）
3. 这不是 UI 脱敏显示，而是 **systemd 文件里真的存了截断的 key**

**根因**：初始配置 systemd service 时，API key 被意外截断（可能是复制粘贴时的问题，或者从某处引用了脱敏后的值）。

**解决**：
```bash
# 修复 systemd env var
sudo sed -i "s|Environment=OPENAI_API_KEY=.*|Environment=OPENAI_API_KEY=sk-as-完整KEY|" /etc/systemd/system/openclaw.service
sudo systemctl daemon-reload

# 同时在 openclaw.json config 里也设置 apiKey（双保险）
```

**教训**：配置 API key 后一定要用 `wc -c` 或 `echo -n $KEY | wc -c` 验证长度，不能只看开头结尾像不像对的。

---

### 坑 8：OPENAI_BASE_URL 环境变量 vs config baseUrl ⚠️⚠️

**现象**：在 config 中设置 `baseUrl` 不生效，但环境变量 `OPENAI_BASE_URL` 生效。

**排查**：
1. 源码 `provider-policy-api-CAxxTyEq.js` 中有 `resolveOpenAIEnvironmentBaseUrl()` 函数：
   ```js
   function resolveOpenAIEnvironmentBaseUrl(context) {
     return (context.env ?? process.env).OPENAI_BASE_URL;
   }
   ```
2. openai provider 通过环境变量读取 baseUrl，不是从 config 的 `baseUrl` 字段读
3. 但自定义模型注册时的 `model.baseUrl` 字段可以覆盖 provider 的 baseUrl

**最终方案**：用环境变量 `OPENAI_BASE_URL` 设置 AgentScope 平台地址，不在 config 里设 baseUrl。

**教训**：OpenClaw 的 openai provider 读取 baseUrl 的优先级是：model.baseUrl > provider.baseUrl > OPENAI_BASE_URL env var。但 provider 级别的 baseUrl 配置项不被 openai provider 识别。

---

### 坑 9：密码模式未设置 ⚠️

**现象**：OpenClaw Control UI 直接开放，无密码保护。

**解决**：设置密码模式，密码：`<YOUR_PASSWORD>`

---

### 坑 10：设备审批机制 ⚠️

**配置**：
- Owner 已有权限，可通过 Settings → Devices 审批新设备
- join-code 方式可免审批自动配对

---

## 最终可用配置

### systemd service (/etc/systemd/system/openclaw.service)

```ini
[Service]
Environment=OPENAI_API_KEY=sk-as-<YOUR_AGENTSCOPE_API_KEY>
Environment=OPENAI_BASE_URL=https://platform.agentscope.io/compatible-mode/v1
Environment=OPENCODE_GO_API_KEY=sk-as-<YOUR_AGENTSCOPE_API_KEY>
ExecStart=/usr/bin/openclaw gateway
# ... 其他 systemd 配置
```

### openclaw.json 关键配置

```json
{
  "agents": {
    "defaults": {
      "workspace": "/home/ANAI/.openclaw/workspace",
      "model": "openai/qwen3.8-max"
    }
  },
  "models": {
    "providers": {
      "openai": {
        "apiKey": "sk-as-<YOUR_AGENTSCOPE_API_KEY>",
        "models": [
          {
            "id": "qwen3.8-max",
            "name": "Qwen3.8 Max",
            "api": "openai-completions",
            "contextWindow": 131072,
            "input": ["text", "image"]
          }
        ]
      },
      "opencode-go": {
        "apiKey": "sk-as-<YOUR_AGENTSCOPE_API_KEY>"
      }
    }
  }
}
```

### 数据流

```
用户 → Caddy (openclaw.<YOUR_DOMAIN>) → Gateway (localhost:18789)
  → openai provider (OPENAI_BASE_URL env var)
  → https://platform.agentscope.io/compatible-mode/v1/chat/completions
  → qwen3.8-max 模型
  → 流式回复
```

### AgentScope 平台可用模型

| 模型 ID | 备注 |
|---------|------|
| qwen3.8-max | ✅ 已注册，正在使用 |
| qwen3.8-flash | 可用，未注册 |
| qwen3.7-plus | 可用，未注册 |
| deepseek-v4-flash | 404，不可用 |
| kimi-k3 | 可用，未注册 |
| glm-5.2 | 可用，未注册 |

如需切换模型，在 `openclaw.json` 的 `models.providers.openai.models` 数组中添加新模型条目，并修改 `agents.defaults.model`。

---

## 常用运维命令

### 检查状态
```bash
# Gateway 是否在监听
ss -tlnp | grep 18789

# systemd 状态
systemctl is-active openclaw
systemctl status openclaw

# 最近日志
tail -20 /tmp/openclaw/openclaw-$(date +%F).log | python3 -c "
import sys,json
for l in sys.stdin:
    if not l.strip(): continue
    try:
        d=json.loads(l)
        print(d.get('message','')[:200])
    except: pass
"
```

### 重启 Gateway（注意内存问题）
```bash
# 正常重启
sudo systemctl restart openclaw

# 如果 crash-loop 了
sudo systemctl stop openclaw
rm -f /home/ANAI/.openclaw/logs/stability/*.json
# 等 5 分钟
sudo systemctl start openclaw
```

### 修改配置后重启
```bash
# 编辑配置
python3 -c "
import json
f='/home/ANAI/.openclaw/openclaw.json'
with open(f) as fh: cfg=json.load(fh)
# 修改...
with open(f,'w') as fh: json.dump(cfg,fh,indent=2)
"
sudo systemctl restart openclaw
```

### 验证 API key 完整性
```bash
# 检查 systemd env var 中的 key 长度
grep "OPENAI_API_KEY" /etc/systemd/system/openclaw.service | cut -d= -f3 | wc -c
# 应该是 53（52 字符 + 换行）
```

### 测试 AgentScope 平台连通性
```bash
curl -s https://platform.agentscope.io/compatible-mode/v1/models \
  -H "Authorization: Bearer sk-as-XXXXX" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('data',[]):
    print(m.get('id',''))
"
```

### 查看模型请求日志
```bash
grep "model-fetch" /tmp/openclaw/openclaw-$(date +%F).log | tail -10 | python3 -c "
import sys,json
for l in sys.stdin:
    if not l.strip(): continue
    try:
        d=json.loads(l)
        print(d.get('message','')[:300])
    except: pass
"
```

---

## 排错决策树

```
聊天报错
├── "Unknown model: openai/xxx"
│   └── 模型未注册 → 在 openclaw.json models.providers.openai.models 添加
├── "authentication failed, HTTP 401"
│   ├── 检查 config apiKey 是否完整
│   └── 检查 systemd OPENAI_API_KEY 是否截断（wc -c 验证）
├── "provider rejected the request schema or tool payload" (400)
│   ├── 检查模型 api 格式是否为 openai-completions
│   └── 如果用 opencode-go provider，检查是否被硬编码为 anthropic-messages
├── "No models available"
│   └── provider 未配置 apiKey 或 baseUrl
├── Gateway 崩溃 / 无法访问
│   ├── 检查 18789 端口: ss -tlnp | grep 18789
│   ├── crash-loop: 清 stability 记录 + 等 5 分钟
│   └── 内存不足: 减少插件数量
└── 页面 502
    └── Gateway 没起来，检查 systemd 状态
```

---

## 关键源码位置

| 文件 | 作用 |
|------|------|
| `provider-catalog-BFfam1xM.js` | Provider 和模型 catalog 定义（硬编码） |
| `model-selection-shared-BlLyx1r2.js` | 自定义模型注册逻辑（`buildConfiguredModelCatalog`） |
| `provider-policy-api-CAxxTyEq.js` | OpenAI baseUrl 解析逻辑（`resolveOpenAIEnvironmentBaseUrl`） |
| `provider-catalog-BFfam1xM.js` | opencode-go 模型列表和 API 格式硬编码 |

路径前缀：`/usr/lib/node_modules/openclaw/dist/`

---

## 未解决问题 / 已知限制

1. **GCP e2-micro 内存不足**：958MB 跑 OpenClaw 勉强可用，但不能频繁重启
2. **opencode-go provider 无法用于第三方平台**：baseUrl 和 API 格式都硬编码，只适合 OpenCode 官方网关
3. **openai provider 不自动发现模型**：第三方平台的模型必须手动在 config 中注册
4. **Settings 页面 "Test connection" 不准确**：openai provider 的连接测试不使用 `OPENAI_BASE_URL`，会连到 `api.openai.com` 导致误报失败。但实际聊天时 env var 是生效的
5. **Settings 页面 "Connect a verified AI model" 流程**：对自定义注册的模型仍报 "Unknown model"，但实际聊天不受影响（agent runtime 读的是 config catalog）

---

## 总结：三个必须同时满足的条件

要让 OpenClaw 连接第三方 OpenAI 兼容平台（如 AgentScope）正常工作，必须同时满足：

1. **环境变量正确**：`OPENAI_API_KEY`（完整，未截断）+ `OPENAI_BASE_URL`（指向第三方平台）
2. **模型注册**：在 `openclaw.json` 的 `models.providers.openai.models` 中手动注册模型
3. **默认模型设置**：`agents.defaults.model` 设为 `openai/{model_id}`

缺任何一个都会报错，且错误信息不同，容易误导排查方向。

---

*文档维护：Zero（AI 助手）| 最后更新：2026-10-14*
