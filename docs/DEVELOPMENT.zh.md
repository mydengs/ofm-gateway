# OFM Gateway — 开发说明

## 本地开发环境搭建

```bash
# 1. 克隆（发布包已含本地化 upstream/，无需额外拉官方仓库）
git clone https://github.com/<你的用户名>/ofm-gateway.git
cd ofm-gateway

# 2. standalone 零依赖直跑（Node ≥22.19）
node upstream/packages/standalone/cli.mjs --port 39808 --data-dir /tmp/ofm-dev

# 3. 冒烟测试
curl -s http://127.0.0.1:39808/health
# {"ok":true,"service":"our-free-model-standalone",...}

# 4. 第一次拿一次性登录链接（管理后台）
#    启动日志里打印 http://127.0.0.1:39808/#login=<one-time-token>
```

## 本地跑看守（不接 systemd 调试）

```bash
OFM_HOME=/tmp/ofm-dev bash -x ./ofm-watch.sh
# 查看做了什么：cat /etc/ofm-gateway/rotate_log
```

注意：看守用 `systemctl restart ofm-gateway` 清断路器——本地调试时这个
systemd 单元不存在会静默失败（`|| true`），属预期。

## 调试技巧

### 验证代理链路（不花额度）

```bash
# 出口 IP
curl -s --proxy "$PROXY" https://api.ipify.org
# 上游模型清单（GET 不花额度）
curl -s --proxy "$PROXY" -H "Authorization: Bearer public" \
  https://opencode.ai/inference/v1/models | head -c 200
```

### 验证推理（花少量额度）

用 standalone 网关走完整链路（推荐——它自动处理流式与指纹）：

```bash
KEY=$(python3 -c "import json;print(json.load(open('/tmp/ofm-dev/settings.json'))['forwardKey'])")
curl -s http://127.0.0.1:39808/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"our-free-model/deepseek-v4.1-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

⚠️ 手工直打上游（绕过 standalone）要求：Bun 运行时 + 流式 + 完整整形
（x-opencode 头 + 官方工具集）。curl 的 429 不代表额度问题（TLS 指纹）。

### Bun 的作用与降级

- 上游对推理请求做 TLS 指纹校验，Bun fetch 可通过；Node fetch/curl 不行。
- Bun 缺失时 standalone 自动降级 `node` 传输（`OUR_FREE_MODEL_FREE_TRANSPORT=node`
  强制）。降级后部分环境可能可用，遇到 403 FreeTierError 先查 Bun。
- 调试 Bun：`OUR_FREE_MODEL_BUN=/path/to/bun` 指定可执行文件。

## 二次开发指引

### 想改模型整形/指纹规则

不要动本项目——改上游 `upstream/src/o2a/` 目录（opencode2api 的 JS 移植），
然后 `git pull` 冲突时 rebase。上游每次官方客户端改版会同步（见上游
`src/o2a/SYNC.md`）。

### 想加聚合渠道 / 账号渠道

都在 standalone 管理后台的对应页面完成（76 家 provider 注册表、十个账号
渠道登录），**不需要写代码**。配置落盘在 `/var/lib/ofm-gateway/`。

### 想改轮换策略

编辑 `ofm-watch.sh`：
- `GAP`（节流秒数）、`MAX_TRIES`（探测候选数）在文件头。
- 触发条件（连续失败阈值 ≥3）在「B 触发」段。
- 轮换日志格式在写 `$LOG_F` 的行。

### 想加管理面公网访问

install.sh 的 `--admin-allow` 生成 `admin.<域名>` 子域 + IP 白名单。手动加：

```bash
# Caddyfile 追加（然后 caddy reload --config /etc/caddy/Caddyfile）
admin.api.example.com {
    @blocked not remote_ip <你的IP>
    respond @blocked "forbidden" 403
    reverse_proxy 127.0.0.1:39808
}
```

## 测试矩阵（发布前）

| 项 | 方法 |
|---|---|
| shell 语法 | `bash -n install.sh ofm-watch.sh` |
| standalone 冒烟 | `node cli.mjs --help`、`--port 19901` 起服务 curl /health |
| 干净机演练 | 用 Docker `debian:12` / `rockylinux:9` 跑 install.sh（需 --domain 用 nip.io 假域名 + 本机 Caddy 跳过证书验证） |
| 看守逻辑 | 伪造 stats.json 连续失败 → 观察是否换 sid + 重启 |

## 发布到 GitHub

```bash
git init && git add . && git commit -m "feat: OFM Gateway 1.0.0"
git remote add origin git@github.com:<你>/ofm-gateway.git
git push -u origin main

# 打 tag
git tag v1.0.0 && git push origin v1.0.0
```

发布后用户一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/<你>/ofm-gateway/main/install.sh | sudo bash -s -- ...
```

> 注意：发布包里**包含本地化的 upstream/**（官方仓库剥离 .git 与 Windows
> 专用二进制，保留 Linux 运行所需的全部代码与 vendor 元数据，约 57M），
> 安装时直接复制、完全离线可装；本地缺失才回退 git clone 兜底。
> 上游版权归其作者（MIT），随包分发符合其许可。

## 已知限制

1. 看守的断路器清窗依赖 `systemctl restart`（进程内存态），本地非 systemd
   调试时无效。
2. `--admin-allow` 的 IP 白名单是 Caddy `remote_ip` 匹配，代理/CDN 后置时
   要改用 `X-Forwarded-For` 匹配。
3. 升级上游后建议跑一遍 `/v1/models` 冒烟（指纹规则可能变）。