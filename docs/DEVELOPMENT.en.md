# OFM Gateway — Development (EN)

## Local setup

```bash
git clone https://github.com/<you>/ofm-gateway.git && cd ofm-gateway
git clone --depth 1 https://github.com/Ebony-Vinyl/dsh-our-free-model.git upstream
node upstream/packages/standalone/cli.mjs --port 18900 --data-dir /tmp/ofm-dev
curl -s http://127.0.0.1:18900/health   # {"ok":true,...}
```

Admin one-time link prints in startup logs (`http://127.0.0.1:18900/#login=…`).

## Debugging

```bash
# egress IP (no quota cost)
curl -s --proxy "$PROXY" https://api.ipify.org
# model list (GET, no quota cost)
curl -s --proxy "$PROXY" -H "Authorization: Bearer public" https://opencode.ai/inference/v1/models

# inference via gateway (recommended — handles stream/fingerprint):
KEY=$(python3 -c "import json;print(json.load(open('/tmp/ofm-dev/settings.json'))['forwardKey'])")
curl -s http://127.0.0.1:18900/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"our-free-model/deepseek-v4.1-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'

# watcher dry-run
OFM_HOME=/tmp/ofm-dev bash -x ./ofm-watch.sh
```

Bun: required for real inference (TLS fingerprint). If missing, force legacy
transport with `OUR_FREE_MODEL_FREE_TRANSPORT=node` (may still fail 403).
Pin bun path with `OUR_FREE_MODEL_BUN=...`.

## Customization

- Fingerprint shaping: upstream `src/o2a/` (JS port of opencode2api); follow
  upstream via rebase, never patch standalone internals.
- Rotation policy: edit `ofm-watch.sh` header (`GAP`, `MAX_TRIES`) and the
  trigger block (consecutive-failure threshold).
- Public admin: append an `admin.<domain>` Caddy site with
  `@blocked not remote_ip <IP>` + `reverse_proxy 127.0.0.1:18900`.

## Test matrix before release

`bash -n` both scripts · standalone smoke (`--help`, `--port 19901`, `/health`)
· clean-container install drill (debian:12 / rocky:9) · watcher logic with
forged stats.json.

## Publishing

```bash
git init && git add . && git commit -m "feat: 1.0.0"
git remote add origin git@github.com:<you>/ofm-gateway.git
git push -u origin main && git tag v1.0.0 && git push origin v1.0.0
```

`upstream/` is intentionally excluded from the release repo (installed via
clone at install time; upstream is MIT by its own author).

## Known limits

1. Breaker clearing needs `systemctl restart` (in-memory state).
2. `--admin-allow` uses Caddy `remote_ip` (direct client IP); adjust for
   CDN/proxy chains.
3. After upstream upgrades, smoke-test `/v1/models` (fingerprint rules may change).