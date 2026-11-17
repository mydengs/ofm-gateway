# OFM Gateway — 架构设计

## 组件全景

```
                      公网
   ┌──────────────────────────────────────────────────────────┐
   │  第三方客户端 (ChatBox / NextChat / SDK / curl …)          │
   │        │ HTTPS, Authorization: Bearer <forwardKey>         │
   ▼        ▼                                                 │
 ┌────────────────────────────────────────────┐               │
 │ Caddy (systemd: caddy)                      │               │
 │  • 域名自动 Let's Encrypt 证书 + 自动续期     │               │
 │  • 只反代 /v1/* → 127.0.0.1:39808           │               │
 │  • 其它路径 404（管理面不暴露）               │               │
 │  • gzip / 流式 flush_interval -1            │               │
 └────────────────────┬───────────────────────┘               │
                      ▼                                        │
 ┌────────────────────────────────────────────┐               │
 │ standalone (node cli.mjs, systemd: ofm-gateway)              │
 │  • 端口 39808 仅回环                          │               │
 │  • /v1/* OpenAI 兼容: models/chat/responses/messages          │
 │  • 管理控制台: 请求记录/用量/设置/渠道/插件中心    │           │
 │  • API Key: forwardKey (settings.json)       │               │
 │  • 免费车道整形: x-opencode-* 指纹 + 官方工具集  │               │
 │  • Bun worker 发推理 (TLS 指纹)，缺失降 node    │               │
 └──────────┬─────────────────────────┬───────┘               │
            ▼                         ▼                        │
 ┌────────────────────┐    ┌──────────────────────────┐        │
 │ 出网链路             │    │ 管理面（回环/白名单子域）   │        │
 │ freeLane.proxyUrl  │    │ 一次一密登录链接           │        │
 │   = 家宽HTTP代理     │    │ SSH 隧道或 admin.<域名>    │        │
 │   (sid 粘性→轮换)    │    └──────────────────────────┘        │
 └──────────┬─────────┘                                         │
            ▼                                                    │
   OpenCode Zen 免费网关 / Kilo 公共网关（上游）                    │
   └──────────────────────────────────────────────────────────┘
```

## 数据流（一次对话请求）

1. 客户端 `POST https://api.example.com/v1/chat/completions`（带 forwardKey）
2. Caddy 终止 TLS，转发到 127.0.0.1:39808
3. standalone 校验 Key → 按模型 id 选车道（`our-free-model/...` → OpenCode 免费车道）
4. **请求整形**：注入官方系统提示词 + 13 件官方工具集 + `x-opencode-*` 指纹头，
   会话映射到稳定 session id（额度按会话计）
5. **Bun worker** 发出真实推理请求（经 `freeLane.proxyUrl` 指定的家宽代理出口）
   - 代理按 `sid` 参数记忆粘性出口；上游按 **出口 IP** 计免费额度
6. 上游 SSE 流式返回 → standalone 按帧解析（按响应体形状判定，不信 Content-Type）
   → 转成 OpenAI 兼容 SSE 帧给客户端
7. standalone 记录本次请求到 stats.json（token 数、耗时、成败）

## 关键设计决策与理由

### 为什么用 standalone 而不是 DSH 插件

| 维度 | DSH 插件 | standalone |
|---|---|---|
| 依赖 | 需要完整 DSH 宿主 + 前端构建链（压垮 2 核机的原因） | **零 npm 依赖**，node 直跑 |
| API 面 | 依赖 DSH 内核鉴权（cookie） | 独立 forwardKey，标准 Bearer |
| 部署 | 绑死 profile 目录 | systemd 一个单元，任意机器 |
| 升级 | 走插件管理器 | 重跑 `install.sh --upgrade` + restart |

### 为什么 Caddy 而不是 nginx

- 自动 HTTPS + 自动续期内置（nginx 需 acme.sh + cron + 证书部署，本次实战踩过
  工作目录漂移、map 重名、session cache zone 重名等坑）。
- 配置面积极小：6 行 Caddyfile 顶 60 行 nginx 配置。

### 为什么看守是独立脚本 + timer 而不是打进 standalone

- 上游 standalone 代码零改动 → 升级零冲突。
- 断路器窗口在 standalone 进程内存里，**重启即清**——看守换 sid 后 restart
  服务是最可靠的清窗方式。
- 看守与后台设置页共用 `settings.json` 的 `freeLane.proxyUrl` 字段：手动改
  与自动改互不打架（看守只在连续失败时出手）。

### 为什么轮换要「健康探测后再换」

住宅代理池存在间歇性劣化（同一 sid 时好时坏，实测 8 次探测 5 成 3 败）。
盲换 sid 会把流量黏到坏网关上更久。看守对最多 6 个候选 sid 逐个 curl
`ipinfo.io`（8 秒超时），只写入验证过能出 IP 的候选。

### Bun 的角色

上游对免费车道做 **TLS 客户端指纹**识别，插件的推理请求由 Bun 的 fetch 发出
（Node 的 fetch 指纹过不了，curl 更过不了——实测同样请求 Bun 200 / curl 429）。
standalone 同样用 Bun worker；Bun 缺失时降级 `node` 传输（部分环境可用）。

## 额度与限流的真相（架构级理解）

上游（OpenCode Zen）对免费车道的计额是**四层叠加**，没有账号体系：

1. **出口 IP**（主桶）：429 窗口按 IP 计，`Retry-After` 会递增惩罚（实测 17.5h）。
2. **会话 session**：每个对话映射稳定 session id；频繁新铸 session 反而必 429。
3. **项目 project**：`x-opencode-project` 按 project × 出口 分桶。
4. **客户端指纹**：UA / 头 / 工具集 / 系统提示词不符 → 403 FreeTierError。

**对策就是换 IP**——本项目的看守做这件事。详细的错误码判别与故障分类见
BUSINESS 文档。