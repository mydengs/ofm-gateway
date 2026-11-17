# OFM Gateway — 安装详解

## 前置条件

| 项 | 要求 |
|---|---|
| OS | 主流 Linux（systemd），root 权限 |
| 域名 | 一个已解析 A 记录 → 服务器公网 IP 的域名（自动 HTTPS 需要） |
| 端口 | 80/443 对外开放（云安全组 + 本机防火墙都要放行） |
| 内存 | 建议 ≥1G（standalone 空闲占用 <100MB） |
| 代理 | 家宽动态 IP 代理（http://user:pass@host:port 形式，支持粘性 sid 参数最佳） |

## 最简安装（一行）

```bash
curl -fsSL <脚本地址>/install.sh | sudo bash -s -- \
  --domain api.example.com \
  --proxy "http://user:pass@us.yourproxy.io:3000" \
  --yes
```

## 全部参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--domain <域名>` | （必填） | 公网域名，需已解析到本机 |
| `--email <邮箱>` | 无 | Let's Encrypt 到期通知 |
| `--proxy <地址>` | 无 | 初始家宽代理地址 |
| `--port <端口>` | 39808 | standalone 回环监听端口 |
| `--admin-allow <IP>` | 无 | 开公网管理子域并只放行该 IP |
| `--rotate <分钟>` | 10 | 看守强制轮换间隔（0=只撞墙换） |
| `--yes` | 交互 | 跳过确认 |

## 安装过程发生了什么（install.sh 十个阶段）

1. **参数校验**：域名格式、root 权限、systemd 存在。
2. **发行版检测**：apt / dnf / yum / pacman / zypper 五分支。
3. **Node.js ≥22.19**：系统源版本不够时自动走 NodeSource。
4. **Bun**：GitHub 官方二进制（x64/arm64 自动识别）。失败不阻断——standalone
   在 Bun 缺失时自动降级 `node` 传输（推理仍可用，见 DEVELOPMENT 文档说明）。
5. **Caddy**：官方源安装（cloudsmith/copr/aur 按发行版选路）。
6. **项目代码**：**发布包自带本地化上游** `upstream/`（已剥离 .git 与 Windows exe，
   约 57M），直接复制到 `/opt/ofm-gateway/upstream`；本地缺失时才回退 git clone。
   完全离线可装。**standalone 零 npm 依赖，无需 pnpm install**（2 核小机无压力）。
7. **systemd**：`ofm-gateway.service`（服务）+ `ofm-watch.timer`（看守，每分钟）。
8. **Caddyfile**：域名 `/v1/*` 反代 + 自动证书 + 日志轮转。
9. **防火墙**：ufw / firewalld 尽力放行 80/443。
10. **初始代理写入**：`settings.json` 的 `freeLane.proxyUrl`（standalone 与看守共用）。

## 安装后目录布局

```
/opt/ofm-gateway/
├── upstream/                  # 本地化上游代码（官方 MIT，随包分发）
│   └── packages/standalone/   # standalone 服务入口
├── ofm-watch.sh               # 轮换看守
/etc/ofm-gateway/
├── last_rotate                # 看守节流时间戳
└── rotate_log                 # 轮换轨迹
/var/lib/ofm-gateway/          # OFM_HOME（数据目录）
├── settings.json              # ★ 代理地址 freeLane.proxyUrl / API Key forwardKey
├── stats.json                 # 请求样本（看守读它判断连续失败）
├── session-map.json           # 会话映射（勿删）
└── catalog.json               # 模型清单缓存
/etc/caddy/Caddyfile           # 反代配置
/var/log/caddy/                # 访问日志
```

## 首次访问管理后台

安装日志里的一次性登录链接 10 分钟内有效；过期后：

```bash
journalctl -u ofm-gateway --no-pager | head -10   # 重启会重新打印
# 或
systemctl restart ofm-gateway
```

隧道方式（推荐）：

```bash
ssh -L 39808:127.0.0.1:39808 root@<服务器>
# 浏览器：http://127.0.0.1:39808/
```

## 验证清单

```bash
systemctl is-active ofm-gateway ofm-watch.timer   # 应都是 active
curl -s https://api.example.com/v1/models -H "Authorization: Bearer <KEY>" | head -c 200
# 无 Key 应 401
curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/v1/models
# 管理面（隧道模式）公网应 404：
curl -s -o /dev/null -w "%{http_code}\n" https://api.example.com/
```

## 卸载

```bash
systemctl disable --now ofm-gateway ofm-watch.timer
rm -rf /etc/systemd/system/ofm-gateway.service /etc/systemd/system/ofm-watch.{service,timer}
systemctl daemon-reload
rm -rf /opt/ofm-gateway /var/lib/ofm-gateway /etc/ofm-gateway
# 域名从 Caddyfile 移除后：caddy reload --config /etc/caddy/Caddyfile
```

## 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 推理报「需要本机 Bun」 | Bun 安装失败 | `curl -fsSL https://bun.sh/install \| bash` 后重启服务 |
| 推理报 free quota window open | 撞额度墙 | 看守应在 1~2 分钟内自动换 IP；手动：后台设置页换代理地址 + 重启服务 |
| 管理页打不开（隧道模式） | 端口转发未建 | `ssh -L 39808:127.0.0.1:39808 root@<服务器>` |
| Caddy 证书签发失败 | 80 端口被占/安全组没放行 | 检查 `ss -tlnp \| grep :80`、云安全组 |
| 升级后行为变化 | 上游指纹规则更新 | 正常：`bash install.sh --domain <域名> --upgrade --yes` 跟随（旧版留 upstream.bak） |