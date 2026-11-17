# OFM Gateway

> 一键把 [Our Free Model](https://github.com/Ebony-Vinyl/dsh-our-free-model) 独立服务变成
> **公网可访问的 OpenAI 兼容 API**，带管理后台（请求记录 / 用量统计 / 出口代理管理），
> 并自动接管家宽动态 IP 轮换与撞墙自愈。任意第三方客户端（ChatBox、NextChat、
> Cherry Studio、OpenAI SDK…）填上地址和 Key 即可使用。

```
公网客户端 ──HTTPS──> Caddy(域名, 自动证书) ──> standalone 管理面(127.0.0.1:39808)
局域网客户端 ──LAN Key──> LAN 中继(0.0.0.0:39809, 只放行 /v1/*) ──┘
                                                      └─ 出网 ──> 家宽HTTP代理 ──> 上游
```

默认端口 **39808**（standalone 主服务，仅回环）；`--lan` 同时开 **39809 局域网
中继**（绑 0.0.0.0，独立 LAN Key，只转发 `/v1/*` 推理路径——管理面永不暴露）。
LAN Key 在管理后台设置页查看/轮换。

## 一分钟安装

```bash
curl -fsSL https://raw.githubusercontent.com/mydengs/ofm-gateway/main/install.sh \
  | sudo bash -s -- --domain api.example.com \
      --proxy "http://user:pass@us.yourproxy.io:3000" \
      --yes
```

安装完成后会打印：

- **API 地址**：`https://api.example.com/v1`
- **API Key**（文件：`/var/lib/ofm-gateway/settings.json` 的 `forwardKey`）
- **管理后台**：`http://127.0.0.1:39808/`（隧道访问）或 `https://admin.api.example.com/`（带 `--admin-allow` 时）
- **局域网推理**：`http://<服务器内网IP>:39809/v1`（需 LAN Key，管理页设置里查看）

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
| **批量测试**（ofm-admin） | 一键并发测试全部模型（并发 4，逐模型真实推理），输出 ✅/❌+原因 |
| **模型别名**（ofm-admin） | 自定义模型 ID 映射（如 `my-ds` → `deepseek-v4.1-flash-free`），合并进 `/v1/models`，调用自动重写，客户端无感 |
| **订阅看板**（ofm-admin） | 当前出口 IP、撞墙/轮换轨迹、累计 token 消耗 |

## ofm-admin 管理网关（批量测试 / 别名 / 看板）

独立薄服务（127.0.0.1:18902，systemd `ofm-admin`，随 install.sh 部署），Token 在
`/etc/ofm-gateway/admin.token`。经 `--admin-allow` 的 admin 子域访问，或直接隧道：

```bash
# 一键批量测试全部模型（并发 4，约 15-60 秒）
curl -X POST http://127.0.0.1:18902/admin/models/test-all -H "Authorization: Bearer $(cat /etc/ofm-gateway/admin.token)"

# 别名映射（第三方客户端无感：清单合并 + 调用自动重写）
curl -X POST http://127.0.0.1:18902/admin/aliases -H "Authorization: Bearer $(cat /etc/ofm-gateway/admin.token)" \
  -H 'Content-Type: application/json' -d '{"alias":"my-ds","target":"deepseek-v4.1-flash-free"}'
# 之后 https://域名/v1/models 里会出现 my-ds，调用它等于调用目标模型
# 重复 POST 同名 alias = 幂等改目标（返回 replaced:true + previous）；
# 想防止误改就加 "strict":true —— 已存在时返回 409 并回显 current。

# 订阅看板（出口 IP / 轮换轨迹 / 累计消耗）
curl http://127.0.0.1:18902/admin/dashboard -H "Authorization: Bearer $(cat /etc/ofm-gateway/admin.token)"
```

## 管理后台怎么访问

- **默认（SSH 隧道，最安全）**：
  ```bash
  ssh -L 39808:127.0.0.1:39808 root@<服务器>
  # 浏览器打开 http://127.0.0.1:39808/ （一次性登录链接在首次启动日志里）
  ```
- **可选（`--admin-allow <你的IP>`）**：公网 `https://admin.<域名>/`，仅该 IP 可访问。

## 常用运维

```bash
systemctl status ofm-gateway          # 服务状态
journalctl -u ofm-gateway -f          # 实时日志
cat /etc/ofm-gateway/rotate_log       # IP 轮换轨迹
cd /opt/ofm-gateway/upstream && git pull && systemctl restart ofm-gateway   # 升级（仅当 upstream/ 是 git clone 得来）
bash install.sh --domain <域名> --upgrade --yes                            # 升级（发布包本地化模式，旧版留 upstream.bak）
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