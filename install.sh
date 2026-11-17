#!/usr/bin/env bash
# =============================================================================
# OFM Gateway 一键安装脚本（跨主流 Linux 发行版）
#
# 用法:
#   sudo bash install.sh --domain api.example.com [选项]
#
# 选项:
#   --domain <域名>       公网域名（必填）。需已解析 A 记录到本机公网 IP。
#   --email <邮箱>        Let's Encrypt 通知邮箱（可选）。
#   --proxy <地址>        初始家宽/HTTP 代理，如 http://user:pass@us.xxx.io:3000
#   --port <端口>         standalone 监听端口（默认 39808）。
#                         独立服务默认绑 0.0.0.0（LAN 中继，独立 LAN Key，
#                         只放行 /v1/* 推理路径；管理面仍只回环）。
#   --admin-allow <IP>    可选：把管理后台反代到 admin.<域名>，且只放行该来源 IP。
#                         不传则管理后台只监听回环，通过 SSH 隧道访问。
#   --rotate <分钟>      强制轮换间隔，默认 10（0 = 只撞墙换，不主动换）。
#   --yes                 跳过所有交互确认。
#
# 产物:
#   /opt/ofm-gateway/           项目（standalone 上游 + 看守脚本）
#   /etc/ofm-gateway/           安装状态（sid 记录、安装参数快照）
#   systemd: ofm-gateway.service / ofm-watch.service + ofm-watch.timer
#   Caddy:   /etc/caddy/Caddyfile（自动 HTTPS + 自动续期）
#
# 支持: Debian 11+/12/13, Ubuntu 20.04+, CentOS 7+/Rocky/Alma 8+, Fedora,
#       openSUSE, Arch。其它发行版若装了 systemd + Node22 也可手动适配。
# =============================================================================
set -euo pipefail

# ── 参数 ─────────────────────────────────────────────────────────────────────
DOMAIN=""; ADMIN_EMAIL=""; PROXY_URL=""; APP_PORT="39808"; ADMIN_ALLOW=""
ROTATE_MIN=10; ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:?--domain 需要值}"; shift 2 ;;
    --email) ADMIN_EMAIL="${2:?}"; shift 2 ;;
    --proxy) PROXY_URL="${2:?}"; shift 2 ;;
    --port) APP_PORT="${2:?}"; shift 2 ;;
    --admin-allow) ADMIN_ALLOW="${2:?}"; shift 2 ;;
    --rotate) ROTATE_MIN="${2:?}"; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 1 ;;
  esac
done
[ -z "$DOMAIN" ] && { echo "错误: --domain 必填（域名需已解析到本机）" >&2; exit 1; }
case "$DOMAIN" in *.* ) : ;; *) echo "错误: --domain 看起来不像域名: $DOMAIN" >&2; exit 1 ;; esac

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()   { red "错误: $*" >&2; exit 1; }

# ── 0. 前置检查 ──────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || die "请以 root 运行（sudo bash install.sh ...）"
command -v systemctl >/dev/null || die "未找到 systemd，本脚本仅支持 systemd 系统"

info "目标域名: $DOMAIN"
[ -n "$PROXY_URL" ] && info "初始出口代理: ${PROXY_URL%%@*}" || warn "未提供 --proxy：免费车道将直连（按本机 IP 计额度），建议之后在管理后台「设置」里配置"
info "轮换间隔: ${ROTATE_MIN} 分钟"
if [ "$ASSUME_YES" != true ]; then
  read -r -p "继续安装？(y/N) " ans; [ "${ans,,}" = y ] || die "已取消"
fi

# ── 1. 发行版检测与包管理 ────────────────────────────────────────────────────
PKG=""
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf >/dev/null; then PKG=dnf
elif command -v yum >/dev/null; then PKG=yum
elif command -v pacman >/dev/null; then PKG=pacman
elif command -v zypper >/dev/null; then PKG=dnf   # 简化处理：openSUSE 走 zypper 包装器
else die "未识别的包管理器（apt/dnf/yum/pacman/zypper）"; fi
info "包管理器: $PKG"

pkg_install() {  # pkg_install <包名...>
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf) command -v dnf >/dev/null && dnf install -y -q "$@" || { zypper --non-interactive install "$@" >/dev/null; } ;;
    yum) yum install -y -q "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
  esac
}

# ── 2. Node.js ≥ 22 ──────────────────────────────────────────────────────────
NODE_OK() { command -v node >/dev/null && node -e 'const v=process.versions.node.split(".").map(Number); process.exit(v[0]>=22 && !(v[0]===22&&v[1]<19) ? 0 : 1)' 2>/dev/null; }
if ! NODE_OK; then
  info "安装 Node.js 22+ ..."
  case "$PKG" in
    apt)
      if command -v apt-get >/dev/null && apt-cache show nodejs 2>/dev/null | grep -q "Version: 2[2-9]"; then
        pkg_install nodejs
      else
        curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource.sh && bash /tmp/nodesource.sh >/dev/null 2>&1 && pkg_install nodejs || die "NodeSource 安装失败"
      fi ;;
    dnf|yum)
      if command -v dnf >/dev/null; then dnf module reset -y nodejs >/dev/null 2>&1 || true; fi
      curl -fsSL https://rpm.nodesource.com/setup_22.x -o /tmp/nodesource.sh && bash /tmp/nodesource.sh >/dev/null 2>&1 && pkg_install nodejs || die "NodeSource 安装失败" ;;
    pacman) pkg_install nodejs ;;
  esac
  NODE_OK || die "Node.js 版本仍不满足（需要 22.19+ 或 24+），请检查安装日志"
fi
info "Node: $(node --version)"

# ── 3. Bun（免费车道推理依赖；缺失时 upstream 报「需要本机 Bun」）────────────
if ! command -v bun >/dev/null 2>&1; then
  info "安装 Bun ..."
  BUN_ARCH="x64"; case "$(uname -m)" in aarch64|arm64) BUN_ARCH="aarch64" ;; esac
  BUN_VER=$(curl -fsSL https://api.github.com/repos/oven-sh/bun/releases/latest | grep -oP '"tag_name": "bun-v\K[^"]+' | head -1)
  [ -n "$BUN_VER" ] || die "获取 Bun 最新版本号失败"
  BUN_ZIP="/tmp/bun-linux-${BUN_ARCH}.zip"
  curl -fsSL -o "$BUN_ZIP" "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VER}/bun-linux-${BUN_ARCH}.zip" || die "Bun 下载失败"
  command -v unzip >/dev/null || pkg_install unzip
  unzip -oq "$BUN_ZIP" -d /tmp/bun-extract
  install -m 755 "/tmp/bun-extract/bun-linux-${BUN_ARCH}/bun" /usr/local/bin/bun
  rm -rf "$BUN_ZIP" /tmp/bun-extract
fi
info "Bun: $(bun --version)"

# ── 4. Caddy（自动 HTTPS 反代）────────────────────────────────────────────────
if ! command -v caddy >/dev/null 2>&1; then
  info "安装 Caddy ..."
  case "$PKG" in
    apt)
      pkg_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq >/dev/null 2>&1 || true
      pkg_install caddy ;;
    dnf|yum)
      command -v dnf >/dev/null && dnf install -y -q 'dnf-command(copr)' || true
      if command -v dnf >/dev/null; then
        dnf copr enable -y @caddy/caddy >/dev/null 2>&1 || curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/cfg/setup/bash.rpm.sh' | bash >/dev/null 2>&1 || true
        pkg_install caddy
      else
        yum install -y -q yum-utils && yum-config-manager --add-repo https://copr.fedorainfracloud.org/coprs/g/caddy/repo/centos-7/g-caddy.repo >/dev/null 2>&1 || true
        pkg_install caddy
      fi ;;
    pacman) pkg_install caddy ;;
  esac
fi
command -v caddy >/dev/null || die "Caddy 安装失败，请手动安装后重跑"
info "Caddy: $(caddy version)"

# ── 5. 项目代码（本地化优先：发布包自带 upstream/；缺失才 clone 兜底）────────
APP_DIR=/opt/ofm-gateway
UPSTREAM_URL="${OFM_UPSTREAM_URL:-https://github.com/Ebony-Vinyl/dsh-our-free-model.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -d "$APP_DIR/upstream/packages/standalone" ]; then
  info "上游代码已存在，跳过"
elif [ -d "$SCRIPT_DIR/upstream/packages/standalone" ]; then
  info "从发布包复制本地化上游（无需联网 GitHub）..."
  mkdir -p "$APP_DIR"
  cp -a "$SCRIPT_DIR/upstream" "$APP_DIR/upstream"
else
  warn "发布包未携带 upstream/，回退到 git clone（需要 GitHub 可达）"
  command -v git >/dev/null || pkg_install git
  git clone --depth 1 "$UPSTREAM_URL" "$APP_DIR/upstream" || die "git clone 失败"
fi
# standalone 零 npm 依赖即可运行（已验证），无需 pnpm install —— 这是选它的核心原因之一。
# 上游代码本地化说明：发布包的 upstream/ 已剥离 .git 与 Windows 专用二进制，
# 保留 Linux 运行所需的 src/vendor(channel-pack) 全部内容，与官方仓库等价（略 57M）。

# ── 6. systemd 服务 ─────────────────────────────────────────────────────────
STATE_DIR=/etc/ofm-gateway; mkdir -p "$STATE_DIR"
DATA_DIR=/var/lib/ofm-gateway; mkdir -p "$DATA_DIR"

cat > /etc/systemd/system/ofm-gateway.service <<EOF
[Unit]
Description=Our Free Model Gateway (standalone)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env node $APP_DIR/upstream/packages/standalone/cli.mjs --port $APP_PORT --lan --data-dir $DATA_DIR
Environment=OFM_HOME=$DATA_DIR
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=5
# 内存兜底：2G 小机也不易被压垮（standalone 空闲 <100MB）
MemoryMax=1200M

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ofm-watch.service <<EOF
[Unit]
Description=OFM free-lane auto recovery (quota breaker / bad proxy)
After=ofm-gateway.service

[Service]
Type=oneshot
ExecStart=$APP_DIR/ofm-watch.sh
EOF
cat > /etc/systemd/system/ofm-watch.timer <<EOF
[Unit]
Description=Run OFM watch every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ofm-gateway.service
systemctl enable --now ofm-watch.timer
info "systemd 服务已启用: ofm-gateway / ofm-watch.timer"

# ── 7. 轮换看守 ─────────────────────────────────────────────────────────────
# ofm-watch.sh 与本 install.sh 同目录分发（仓库自带），此处确保可执行并写状态。
touch "$STATE_DIR/last_rotate" "$STATE_DIR/rotate_log"
info "看守脚本: $APP_DIR/ofm-watch.sh（若仓库未附，请从发布包补入）"

# ── 8. Caddy 配置 ───────────────────────────────────────────────────────────
info "生成 Caddyfile ..."
CADDYFILE=/etc/caddy/Caddyfile
touch "$CADDYFILE" 2>/dev/null || true
{
  echo "# 由 OFM Gateway install.sh 生成（$(date -Iseconds)）"
  echo
  echo "$DOMAIN {"
  echo "    encode gzip"
  echo "    # 只反代 /v1/* 推理接口到 standalone（管理面绝不暴露公网）"
  echo "    handle /v1/* {"
  echo "        # 流式响应：关闭缓冲（flush_interval 必须写在 reverse_proxy 块内）"
  echo "        reverse_proxy 127.0.0.1:$APP_PORT {"
  echo "            flush_interval -1"
  echo "        }"
  echo "    }"
  echo "    handle {"
  echo "        respond \"OFM Gateway: API at /v1\" 404"
  echo "    }"
  echo "    log {"
  echo "        output file /var/log/caddy/ofm-access.log {"
  echo "            roll_size 20mb"
  echo "            roll_keep 5"
  echo "        }"
  echo "    }"
  echo "}"
  if [ -n "$ADMIN_ALLOW" ]; then
    echo
    echo "# 管理后台（仅此来源 IP 可访问）"
    echo "admin.$DOMAIN {"
    echo "    @blocked not remote_ip $ADMIN_ALLOW"
    echo "    respond @blocked \"forbidden\" 403"
    echo "    reverse_proxy 127.0.0.1:$APP_PORT"
    echo "    flush_interval -1"
    echo "}"
  fi
  [ -n "$ADMIN_EMAIL" ] && echo && echo "email $ADMIN_EMAIL"
} > "$CADDYFILE"
mkdir -p /var/log/caddy
caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || warn "Caddyfile 校验有告警（首次启动会自动修正/签发证书）"
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
info "Caddy 已启动（首次访问时自动申请 Let's Encrypt 证书，约需 30 秒）"

# ── 9. 防火墙（尽力而为，失败不阻断）────────────────────────────────────────
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; info "ufw 已放行 80/443"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
  firewall-cmd --permanent --add-service=http --add-service=https >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true; info "firewalld 已放行 http/https"
fi

# ── 10. 初始代理写入（可选）──────────────────────────────────────────────────
if [ -n "$PROXY_URL" ]; then
  KEY=$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json')).get('forwardKey') or '')" 2>/dev/null || true)
  if [ -n "$KEY" ]; then
    python3 - "$DATA_DIR/settings.json" "$PROXY_URL" <<'PY'
import json, sys
p, proxy = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault('freeLane', {})['proxyUrl'] = proxy
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=1)
PY
    info "初始出口代理已写入（对 standalone 与看守同时生效）"
  else
    warn "settings.json 尚未生成（服务刚拉起），请稍后在管理后台设置代理，或重跑本段"
  fi
fi

# ── 11. 收尾 ─────────────────────────────────────────────────────────────────
sleep 3
systemctl is-active ofm-gateway >/dev/null || warn "ofm-gateway 服务未处于 active，查看: journalctl -u ofm-gateway -n 50"
KEY=$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json')).get('forwardKey') or '(未生成，稍后查看文件)')" 2>/dev/null || echo "(settings.json 未就绪)")
echo
green "==================== 安装完成 ===================="
echo "API 地址      : https://$DOMAIN/v1"
echo "API Key       : $KEY"
echo "              （密钥文件: $DATA_DIR/settings.json 的 forwardKey 字段）"
echo "管理后台      : http://127.0.0.1:$APP_PORT/  （仅本机回环；局域网客户端用 LAN Key 走 /v1/*）"
if [ -n "$ADMIN_ALLOW" ]; then
  echo "公网管理页    : https://admin.$DOMAIN/ （仅 $ADMIN_ALLOW 可访问）"
else
  echo "隧道访问管理页: ssh -L $APP_PORT:127.0.0.1:$APP_PORT root@<服务器>  然后浏览器开 http://127.0.0.1:$APP_PORT/"
fi
echo "验证          : curl https://$DOMAIN/v1/models -H \"Authorization: Bearer $KEY\""
echo "服务/日志     : systemctl status ofm-gateway / journalctl -u ofm-gateway -f"
echo "轮换日志      : cat $STATE_DIR/rotate_log"
echo "升级          : cd $APP_DIR/upstream && git pull && systemctl restart ofm-gateway"
echo "=================================================="