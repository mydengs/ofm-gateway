# OFM Gateway — Architecture (EN)

## Components

```
clients ──HTTPS──> Caddy (auto TLS, /v1/* only) ──> standalone (127.0.0.1:39808)
                                                     ├─ /v1/* OpenAI-compatible
                                                     ├─ admin console (loopback)
                                                     └─ egress → residential proxy (sid sticky) → OpenCode/Kilo
```

## Request flow

1. Client `POST /v1/chat/completions` (Bearer forwardKey) → Caddy → standalone.
2. Key check → lane select by model id (`our-free-model/*` = OpenCode free lane).
3. Fingerprint shaping: official system prompt + 13 official tools +
   `x-opencode-*` headers, stable session id per conversation.
4. **Bun worker** performs the real inference through `freeLane.proxyUrl`
   (TLS fingerprint must match the official client; Node fetch / curl fail).
5. Upstream SSE → OpenAI-compatible SSE frames back to the client.
6. Per-request stats recorded to stats.json.

## Why standalone (not the DSH plugin)

| | DSH plugin | standalone |
|---|---|---|
| deps | full DSH host + frontend build (kills 2-core boxes) | **zero npm deps**, plain node |
| auth | DSH cookie | standalone Bearer key |
| deploy | profile-bound | one systemd unit |

## Why Caddy

Built-in auto HTTPS + renewal; a 6-line Caddyfile replaces 60 lines of
nginx + acme.sh + cron + deploy hooks.

## Why an external watcher (timer + script)

- Zero changes to upstream code → upgrade without merge conflicts.
- The quota breaker lives in the standalone process memory — a service restart
  is the most reliable way to clear it after rotating the proxy sid.
- The watcher and the admin UI share `settings.json freeLane.proxyUrl`: manual
  edits in the UI are never overwritten unless the watcher detects real failures.

## Quota model (architecture-level)

Upstream quota is 4-layer, no account system: (1) **egress IP** — primary
bucket, 429 windows grow with repeated hits (measured up to 17.5h); (2)
**session** — stable id per conversation, minting fresh sessions per request
guarantees 429; (3) **project** — `x-opencode-project` × egress bucketing;
(4) **client fingerprint** — UA/headers/toolset/system prompt/TLS; mismatch =
403 FreeTierError. The watcher's rotation is the countermeasure for (1).