# OpenWebUI komect 广东节点 IPv6 中继修复

## 问题

OpenWebUI（Docker 容器）配置了 komect 广东节点的三个模型，浏览器使用时报 `Server Connection Error`，但偶尔能短暂回复一次。

## 环境

- OpenWebUI v0.12.0，Docker 容器，1Panel 管理
- komect API base URL：`https://<KOMECT_DOMAIN>/ai/llm/gw/v1`
- 模型：`deepseekv4-flash-guangdong`、`qwen38-27b-guangdong`、`Qwen3.6-35B-guangdong`

## 根因

komect 域名同时有 A（IPv4）和 AAAA（IPv6）记录：

| 记录 | 地址 | 从 VPS 可达性 |
|---|---|---|
| A | `<KOMECT_IPV4>` | TCP 能连但不稳定，约 60% 失败率 |
| AAAA | `<KOMECT_IPV6>` | 稳定可达，0% 丢包 |

**IPv4 不可靠的原因**：IPv4 地址属于中国大陆运营商地址段，从海外 VPS 经中国大陆骨干网路由，中途有 20-60% 丢包。ICMP（ping）100% 被封，但 TCP 443 偶尔能通。

**容器无法使用 IPv6 的原因**：Docker bridge 网络默认不分配公网 IPv6 地址，容器只有 IPv4 出口。

**为什么 VPS 主机上的 curl 测试"通过"了**：curl 的 Happy Eyeballs 算法同时尝试 IPv4 和 IPv6，自动选择了可达的 IPv6。但容器被 `extra_hosts` 锁定在不可达的 IPv4 上，且没有 IPv6 出口作为备选。

## 10 次连测对比

从 VPS 各跑 10 次 curl（`--max-time 20`，非流式，`max_tokens:1`）：

**IPv4（curl -4）**：
- 成功 4/10（40%）
- 成功时连接耗时 0.18-4.29s，总耗时 4.9-9.3s
- 失败 6/10（60%）：全部 20s 超时

**IPv6（curl -6）**：
- 成功 10/10（100%）
- 连接耗时 0.19-0.37s，总耗时 1.6-3.6s
- 零超时、零失败

## 修复方案

在 VPS 上用 socat 做 IPv4→IPv6 转发，容器通过宿主机外部 IP 访问 socat，socat 再转发到 komect IPv6 地址。

### 数据流

```
容器 → <VPS_IP>:443（宿主机外部 IP）→ socat → [<KOMECT_IPV6>]:443 → komect 服务器
```

### 步骤 1：创建 socat 服务

```bash
cat > /etc/systemd/system/komect-v6-relay.service << 'EOF'
[Unit]
Description=komect IPv4→IPv6 relay (socat)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:443,reuseaddr,fork,bind=0.0.0.0 TCP6:[<KOMECT_IPV6>]:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now komect-v6-relay
```

### 步骤 2：修改 docker-compose.yml

```yaml
services:
    open-webui:
        # ... 其他配置不变 ...
        extra_hosts:
            - <KOMECT_DOMAIN>:<VPS_IP>
```

**注意**：
- `extra_hosts` 必须指向宿主机外部 IP，不能用 Docker 网关 IP（`172.18.0.1`），因为 Docker bridge 网关不把流量转发到宿主机的 socket
- 不能用 komect 的 IPv4 地址，因为从 VPS 不可靠（60% 失败率）
- socat 只转发 TCP，TLS 直通不影响证书验证

### 步骤 3：重建容器

```bash
cd <OWUI_DATA_DIR>/..
docker compose up -d
```

### 步骤 4：验证

```bash
# 容器内测试
docker exec <CONTAINER_NAME> python3 -c "
import asyncio, aiohttp
async def t():
    async with aiohttp.ClientSession() as s:
        async with s.post('https://<KOMECT_DOMAIN>/ai/llm/gw/v1/chat/completions',
            headers={'Authorization':'Bearer <KOMECT_API_KEY>','Content-Type':'application/json'},
            json={'model':'deepseekv4-flash-guangdong','messages':[{'role':'user','content':'hi'}],'max_tokens':5}) as r:
            print(f'Status: {r.status}')
asyncio.run(t())
"
```

## 后期维护要点

如果后期遇到 komect 模型连不上，按以下顺序排查：

1. **查 socat 服务**：`systemctl status komect-v6-relay`——socat 挂了容器就全断
2. **查 extra_hosts**：必须指向宿主机外部 IP，不是 komect IPv4（不可靠）也不是 Docker 网关（不转发）
3. **不要改回 IPv4 直连**：IPv4 只有 40% 成功率，会导致偶发"短暂回复然后又不行"
4. **komect DNS 只有一个 A 记录和一个 AAAA 记录**，没有其他 IPv4 入口
5. **容器没有 IPv6 出口**（Docker bridge 网络），必须靠 socat 桥接

## 诊断方法

### 测试 IPv4 vs IPv6 可达性

```bash
# DNS 记录
dig +short A <KOMECT_DOMAIN>
dig +short AAAA <KOMECT_DOMAIN>

# 各跑 10 次对比
for i in $(seq 1 10); do
  curl -4 --max-time 20 -s -o /dev/null -w "v4 attempt $i: HTTP:%{http_code} connect:%{time_connect}s total:%{time_total}s\n" \
    -H "Authorization: Bearer <KOMECT_API_KEY>" \
    "https://<KOMECT_DOMAIN>/ai/llm/gw/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"deepseekv4-flash-guangdong","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'
done

for i in $(seq 1 10); do
  curl -6 --max-time 20 -s -o /dev/null -w "v6 attempt $i: HTTP:%{http_code} connect:%{time_connect}s total:%{time_total}s\n" \
    -H "Authorization: Bearer <KOMECT_API_KEY>" \
    "https://<KOMECT_DOMAIN>/ai/llm/gw/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"deepseekv4-flash-guangdong","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'
done
```

### 路由跟踪

```bash
mtr -n -c 5 --report <KOMECT_IPV4>
```

### SSL 握手测试

```bash
echo | openssl s_client -connect <KOMECT_IPV4>:443 -servername <KOMECT_DOMAIN> 2>&1 | head -5
```

## 踩过的坑

1. **ping 全丢 ≠ 不可达**：ICMP 被中国大陆骨干网封了，但 TCP 443 偶尔能通。判断可达性要用 TCP 层测试（curl/openssl），不能用 ping
2. **curl Happy Eyeballs 陷阱**：VPS 上 curl 自动选 IPv6 绕过不可靠 IPv4，让 API 测试"通过"，但容器被 extra_hosts 锁死 IPv4 且无 IPv6 出口。测试时要显式指定 `-4`/`-6` 分别验证
3. **API 测试通 ≠ 浏览器可用**：用 JWT token + curl 从 VPS 内部测 API 绕过了网络层差异。容器实际走的是 extra_hosts 锁定的 IPv4 路径
4. **Docker 网关不转发到宿主机 socket**：容器连 `172.18.0.1:443` 被拒绝（ConnectionRefused），需用宿主机外部 IP
5. **socat IPv4→IPv6 不影响 TLS**：socat 只转发 TCP 流，TLS 握手直通到目标服务器，证书验证正常
