# CHANGELOG

格式基于 Keep a Changelog，版本号遵循语义化版本。

## [1.0.0] - 2026-11-17

### 新增
- 跨发行版一键安装 `install.sh`：自动装 Node 22+ / Bun / Caddy，
  部署 upstream standalone 服务（systemd）、轮换看守（timer）与自动 HTTPS 反代。
- `ofm-watch.sh`：免费车道自动恢复看守。检测到代理坏网关（连续失败）时
  健康探测新 sid → 写入 → 重启服务清断路器。轨迹记录到
  `/etc/ofm-gateway/rotate_log`。
- Caddy 自动签发 Let's Encrypt 证书（自动续期），只反代 `/v1/*`，
  管理面默认仅回环；可选 `--admin-allow` 开独立子域 + IP 白名单。
- 完整文档：README / 安装 / 架构 / 业务逻辑 / 开发说明（中英文）。

### 设计要点
- standalone 零 npm 依赖直跑（Node 22 即可）—— 2 核 1G 小机也能装，
  不会重演插件链的前端构建压垮问题。
- 代理（家宽动态 IP）统一管理：管理后台设置页可改，看守只兜底。
- 版本升级：`cd /opt/ofm-gateway/upstream && git pull && systemctl restart`。