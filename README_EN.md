# OFM Gateway

> Turn [Our Free Model](https://github.com/Ebony-Vinyl/dsh-our-free-model)'s standalone
> service into a **public OpenAI-compatible API** with one command: admin dashboard
> (request logs / usage stats / egress proxy management), automatic residential-IP
> rotation with quota-wall self-healing. Works with any third-party client
> (ChatBox, NextChat, Cherry Studio, OpenAI SDK, …).

```
client ──HTTPS──> Caddy(domain, auto TLS) ──> standalone(127.0.0.1:18900)
                                                ├─ /v1/*   inference (public)
                                                ├─ admin   loopback / IP-allowlisted
                                                └─ egress ──> residential proxy ──> upstream
```

## One-minute install

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/ofm-gateway/main/install.sh \
  | sudo bash -s -- --domain api.example.com \
      --proxy "http://user:pass@us.yourproxy.io:3000" \
      --yes
```

Prints: API URL `https://api.example.com/v1`, API key, admin entry.

## Docs

- [Installation](docs/INSTALL.en.md) · [Architecture](docs/ARCHITECTURE.en.md)
- [Business logic](docs/BUSINESS.en.md) · [Development](docs/DEVELOPMENT.en.md)
- 中文版：[安装](docs/INSTALL.zh.md) · [架构](docs/ARCHITECTURE.zh.md) ·
  [业务逻辑](docs/BUSINESS.zh.md) · [开发](docs/DEVELOPMENT.zh.md)

## Notes

- Free is not private: prompts go to the upstream as-is; do not send secrets.
- Upstream quota is per-egress-IP with growing 429 windows; the built-in watcher
  rotates the residential proxy sid and restarts the service to recover.
- Supported: Debian 11+/12/13, Ubuntu 20.04+, RHEL-family 7+/8+, Fedora,
  openSUSE, Arch (systemd + root).