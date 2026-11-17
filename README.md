# OFM Gateway

> 一键把 [Our Free Model](https://github.com/Ebony-Vinyl/dsh-our-free-model) 独立服务变成
> **公网可访问的 OpenAI 兼容 API**，带管理后台（请求记录 / 用量统计 / 出口代理管理），
> 并自动接管家宽动态 IP 轮换与撞墙自愈。任意第三方客户端（ChatBox、NextChat、
> Cherry Studio、OpenAI SDK…）填上地址和 Key 即可使用。

```
第三方客户端 ──HTTPS──> Caddy(域名, 自动证书) ──> standalone(127.0.0.1:18900)
                                                      ├─ /v1/*   推理接口（公网）
                                                      ├─ 管理后台  仅回环 / 可选 IP 白名单
                                                      └─ 出网 ──> 家宽HTTP代理 ──> 上游
```

## 一分钟安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/ofm-gateway/main/install.sh \
  | sudo bash -s -- --domain api.example.com \
      --proxy "http://user:pass@us.yourproxy.io:3000" \
      --yes
```

安装完成后会打印：

- **API 地址**：`https://api.example.com/v1`
- **API Key**（文件：`/var/lib/ofm-gateway/settings.json` 的 `forwardKey`）
- **管理后台**：`http://127.0.0.1:18900/`（隧道访问）或 `https://admin.api.example.com/`（带 `--admin-allow` 时）

验证：

```bash
curl https://api.example.com/v1/models -H "Authorization: Bearer <KEY>"
```

支持系统：Debian 11+/12/13、Ubuntu 20.04+、CentOS 7+/Rocky/Alma 8+、Fedora、
openSUSE、Arch（需 systemd + root）。

## 功能一览

| 功能 | 说明 |
|---|---|
| OpenAI 兼容 API | `/v1/models`、`/v1/chat/completions`（流式）、`/v1/responses`、Anthropic `/v1/messages` |
| 管理后台 | 请求记录（逐请求明细/失败原因）、用量统计（Token 热力图/成功率/缓存命中）、模型清单、渠道管理 |
| 出口代理管理 | 后台设置页直接改家宽代理地址，热生效；「测试出口」显示当前公网 IP |
| 家宽动态 IP 自愈 | 看守每分钟检查：代理坏网关/撞额度墙 → 自动换 sid 拿新 IP + 清窗 |
| 自动 HTTPS | Caddy 自动申请续期 Let's Encrypt 证书 |
| 账号渠道 | 十个免费账号渠道（可选，见上游文档） |
| 聚合渠道 | 76 家 provider 注册表，填 Key 即用 |

## 管理后台怎么访问

- **默认（SSH 隧道，最安全）**：
  ```bash
  ssh -L 18900:127.0.0.1:18900 root@<服务器>
  # 浏览器打开 http://127.0.0.1:18900/ （一次性登录链接在首次启动日志里）
  ```
- **可选（`--admin-allow <你的IP>`）**：公网 `https://admin.<域名>/`，仅该 IP 可访问。

## 常用运维

```bash
systemctl status ofm-gateway          # 服务状态
journalctl -u ofm-gateway -f          # 实时日志
cat /etc/ofm-gateway/rotate_log       # IP 轮换轨迹
cd /opt/ofm-gateway/upstream && git pull && systemctl restart ofm-gateway   # 升级
```

## 项目结构

```
ofm-gateway/
├── install.sh          # 一键安装（跨发行版）
├── ofm-watch.sh        # 轮换看守（systemd timer 每分钟）
├── docs/
│   ├── INSTALL.zh.md       # 安装详解
│   ├── INSTALL.en.md
│   ├── ARCHITECTURE.zh.md  # 架构设计
│   ├── ARCHITECTURE.en.md
│   ├── BUSINESS.zh.md      # 业务逻辑（额度/限流/轮换的真相）
│   ├── BUSINESS.en.md
│   └── DEVELOPMENT.zh.md   # 开发说明（本地调试/二次开发）
└── upstream/           # 本地化上游代码（官方 MIT，随包分发，勿手动改）
```

## 安全须知

- 免费 ≠ 私有：prompt 会直发上游（Kilo 池可能记录），**勿传敏感数据**。
- API Key 等同免费额度，勿泄露；轮换在后台可见。
- 管理后台永不与 `/v1` 同域暴露；默认仅回环。

## 致谢

- [Our Free Model](https://github.com/Ebony-Vinyl/dsh-our-free-model)（上游核心，MIT）
- [Caddy](https://caddyserver.com) / [Bun](https://bun.sh) / [Node.js](https://nodejs.org)

## License

MIT（见 LICENSE）。上游代码版权归其作者，使用受上游服务条款约束。