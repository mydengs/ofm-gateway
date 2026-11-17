# OFM Gateway — Installation (EN)

## Prerequisites

| Item | Requirement |
|---|---|
| OS | Mainstream Linux with systemd, root |
| Domain | A record pointing to the server (auto HTTPS needs it) |
| Ports | 80/443 open (cloud SG + local firewall) |
| Memory | ≥1G recommended (standalone idles <100MB) |
| Proxy | Residential rotating proxy, `http://user:pass@host:port` (sticky-sid capable) |

## Quick start

```bash
curl -fsSL <url>/install.sh | sudo bash -s -- \
  --domain api.example.com \
  --proxy "http://user:pass@us.yourproxy.io:3000" --yes
```

All flags: `--domain` (required) `--email` `--proxy` `--port` (default 39808)
`--admin-allow <IP>` `--rotate <min>` (default 10) `--yes`.

## What the installer does (10 stages)

1. Preflight (root/systemd/domain). 2. Distro detect (apt/dnf/yum/pacman/zypper).
3. Node.js ≥22.19 (NodeSource fallback). 4. Bun (official binary, x64/arm64).
5. Caddy (cloudsmith/copr/aur). 6. `git clone --depth 1` upstream →
`/opt/ofm-gateway/upstream` (**zero npm deps — standalone runs on plain node**,
2-core/1G machines fine). 7. systemd units: `ofm-gateway.service`,
`ofm-watch.timer` (every 60s). 8. Caddyfile (`/v1/*` only + auto Let's Encrypt
+ log rotation). 9. Firewall best-effort (ufw/firewalld). 10. Seed proxy into
`settings.json freeLane.proxyUrl`.

## Layout

```
/opt/ofm-gateway/{upstream/,ofm-watch.sh}
/etc/ofm-gateway/{last_rotate,rotate_log}
/var/lib/ofm-gateway/            # OFM_HOME: settings.json (proxy + forwardKey), stats.json …
/etc/caddy/Caddyfile
```

## Verify

```bash
systemctl is-active ofm-gateway ofm-watch.timer
curl -s https://api.example.com/v1/models -H "Authorization: Bearer <KEY>" | head -c 200
curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/v1/models   # expect 401
```

Admin (default loopback): `ssh -L 39808:127.0.0.1:39808 root@<server>` then
open `http://127.0.0.1:39808/` (one-time login link in first-start logs).

## Uninstall

```bash
systemctl disable --now ofm-gateway ofm-watch.timer
rm -rf /etc/systemd/system/{ofm-gateway.service,ofm-watch.service,ofm-watch.timer}
systemctl daemon-reload
rm -rf /opt/ofm-gateway /var/lib/ofm-gateway /etc/ofm-gateway
```