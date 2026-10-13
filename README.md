# VPS Ops Toolkit

Generic VPS operations toolkit: SOCKS5 proxy tunneling, infrastructure health checks, and search API wrappers.

All credentials are loaded from environment variables or a `.env` file — **nothing is hardcoded**.

## Setup

```bash
cp .env.example .env
# Edit .env and fill in your values
```

| Variable | Description |
|---|---|
| `VPS_HOST` | VPS public IP or hostname |
| `VPS_SOCKS_PORT` | SOCKS5 proxy port |
| `VPS_SOCKS_USER` | SOCKS5 username |
| `VPS_SOCKS_PASS` | SOCKS5 password |
| `VPS_SSH_PORT` | SSH port (default 22) |
| `VPS_SSH_USER` | SSH username |
| `VPS_SSH_KEY` | Path to SSH private key |
| `SEARCH_API_KEY` | Search API key (optional) |

## Scripts

| Script | Purpose |
|---|---|
| `socks5_tunnel.py` | Local SOCKS5 tunnel with auto-restart |
| `ssh_proxy.py` | SSH ProxyCommand via SOCKS5 relay |
| `check_socks5.sh` | SOCKS5 proxy health check |
| `check_vps.sh` | SSH reachability + system stats |
| `check_service.sh` | Remote systemd service check |
| `search_wrapper.sh` | Search API wrapper with proxy |

## License

MIT
