# OFM Gateway — Business Logic (EN)

## Quota model

Upstream (OpenCode Zen, keyless `Bearer public`) + Kilo pool (independent).
No accounts — four fingerprints:

| Layer | Mechanism | Ops meaning |
|---|---|---|
| **Egress IP** | primary bucket; 429 windows grow (up to ~17.5h measured) | **rotate IP = reset quota** |
| **Session** | stable id per conversation (`session-map.json`) | never delete; per-request minting = 429 |
| **Project** | `x-opencode-project` × egress bucket | auto-randomized |
| **Fingerprint** | UA + x-opencode-* headers + 13 official tools + official prompt + TLS (Bun) | mismatch = 403 FreeTierError |

No published numbers ("N requests/day"). Reference: heavy agent usage
(~5.8k-token system prompts) exhausts one IP in roughly 2.5h / ~280k input tokens.

## Failure taxonomy

| Signature | Cause | Heal |
|---|---|---|
| fail in 0.2–0.6s, `FreeUsageLimitError` | 429 quota wall | watcher rotates + restart |
| ~10s timeout / `Bun worker failed...` | bad proxy gateway | watcher health-probes new sid |
| instant 403 `FreeTierError` | fingerprint rejected | upgrade standalone (upstream rule change) |

⚠️ Direct upstream probing is misleading: **non-streaming requests always get
429** (shape rejection, not quota). Use the standalone gateway or Bun+stream
for any real testing; curl's TLS fingerprint fails regardless.

## Self-healing loop (ofm-watch, every 60s)

1. Read stats.json tail → ≥3 consecutive failures? else exit (zero cost).
2. Throttle: <90s since last action → skip.
3. Rotate sid: take current proxy URL, mint up to 6 random sids, curl
   `ipinfo.io` (8s timeout) through each; write the first healthy one to
   `settings.json`.
4. `systemctl restart ofm-gateway` (clears the in-memory breaker window).
5. Log to `/etc/ofm-gateway/rotate_log` (time | new IP | sid | reason).

No generation quota is consumed (stats are local; probes hit third-party echo).

## Operations

- Dashboard: per-request logs (model/tokens/latency/failures), token heatmap,
  success rate. Falling success rate = proxy degradation or quota near — rotate.
- Costs: server (2c/1G fine) + residential proxy subscription + domain;
  upstream models are free.

## Risk boundaries

Free ≠ private (prompts go upstream as-is; Kilo may log). Upstream rules
evolve — standalone auto-follows by re-running `install.sh --upgrade`. Residential proxy quality
varies — consider a backup proxy. Usage subject to upstream & proxy ToS.
