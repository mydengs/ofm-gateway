#!/usr/bin/env bash
# =============================================================================
# OFM Watch — 免费车道自动恢复看守（standalone 版）
#
# 由 ofm-watch.timer 每分钟调用。检测两类故障并自动处置:
#   A) 额度墙: standalone 断路器开窗（真实 429 后本地拒发，默认按 Retry-After）
#   B) 代理侧坏网关: 最近请求连续失败（粘性 sid 会把流量黏在坏网关上）
#
# 处置: 随机换 sid（住宅代理按 sid 记忆出口，新 sid = 全新家宽 IP）→ 清窗。
#   换 sid 前做健康探测：对候选 sid 用 curl 经代理打 api.ipify.org，取第一个
#   健康的写入 settings.json —— 只换上验证过活的网关，不盲换。
#
# 退出码恒为 0（任何异常静默跳过，下个周期重试），防 timer 告警风暴。
# 状态:
#   /etc/ofm-gateway/last_rotate   上次处置时间戳（节流 90s）
#   /etc/ofm-gateway/rotate_log    轮换轨迹（时间 | 新IP | sid | 原因）
# =============================================================================
set -u
DATA="${OFM_HOME:-/var/lib/ofm-gateway}"
SETTINGS="$DATA/settings.json"
STATE_DIR=/etc/ofm-gateway
LAST_F="$STATE_DIR/last_rotate"; LOG_F="$STATE_DIR/rotate_log"
GAP=90; MAX_TRIES=6
mkdir -p "$STATE_DIR" 2>/dev/null
touch "$LAST_F" "$LOG_F" 2>/dev/null

now() { date +%s; }
NOW=$(now)
LAST=$(cat "$LAST_F" 2>/dev/null || echo 0)
[ $((NOW - LAST)) -lt "$GAP" ] && exit 0

# ── standalone 数据里有什么 ─────────────────────────────────────────────────
# settings.json: freeLane.proxyUrl / forwardKey
# stats.json:    samples[]（每次请求成败），用于连续失败检测
# 断路器窗口在内存里（standalone 进程内），文件层面无法直接读 —— 用连续失败
# 作为开窗的等价信号（429 秒失败 → stats 连续失败 → 触发换 IP + 重启服务清窗）。
[ -f "$SETTINGS" ] || exit 0

# ── B 触发: 最近 3 条请求样本连续失败（零消耗，纯本地文件）──────────────────
trigger_fail=0
if [ -f "$DATA/stats.json" ]; then
  STREAK=$(python3 - <<'PY' 2>/dev/null
import json
try:
    rows = (json.load(open('/var/lib/ofm-gateway/stats.json')) or {}).get('samples') or []
except Exception:
    print(0); raise SystemExit
n = 0
for r in reversed(rows[-6:]):
    if r.get('ok'):
        break
    n += 1
print(n)
PY
)
  [ "${STREAK:-0}" -ge 3 ] && trigger_fail=1
fi
[ "$trigger_fail" = 0 ] && { exit 0; }

# ── 换 sid 并健康探测 ───────────────────────────────────────────────────────
CUR_URL=$(python3 -c "import json;print(((json.load(open('$SETTINGS')) or {}).get('freeLane') or {}).get('proxyUrl') or '')" 2>/dev/null)
[ -z "$CUR_URL" ] && exit 0
echo "$CUR_URL" | grep -q 'sid-' || exit 0   # 无粘性参数的代理不支持本看守（无意义）

HEAD="${CUR_URL%%sid-*}"; TAIL="${CUR_URL##*sid-[A-Za-z0-9]*}"
FOUND=""; NEW_IP=""
for i in $(seq 1 $MAX_TRIES); do
  NS=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
  CAND="${HEAD}sid-${NS}${TAIL}"
  OUT=$(curl -s -m 8 --proxy "$CAND" https://ipinfo.io/json 2>/dev/null || true)
  IP=$(printf '%s' "$OUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('ip') or '')
except Exception: print('')" 2>/dev/null)
  if [ -n "$IP" ]; then FOUND="$CAND"; NEW_IP="$IP"; break; fi
done

if [ -n "$FOUND" ]; then
  ESC=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$FOUND")
  python3 - "$SETTINGS" "$ESC" <<'PY'
import json, sys
p, esc = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault('freeLane', {})['proxyUrl'] = json.loads(esc)
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=1)
PY
  # 清断路器开窗（restart 服务：standalone 的断路器在进程内存里，重启即清）
  systemctl restart ofm-gateway.service 2>/dev/null || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $NEW_IP | sid=$(echo "$FOUND" | sed -n 's/.*sid-\([A-Za-z0-9]*\).*/\1/p') | reason=proxy-fail+breaker" >> "$LOG_F"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') | ALL-FAILED | reason=proxy-fail" >> "$LOG_F"
fi
echo "$NOW" > "$LAST_F"
exit 0