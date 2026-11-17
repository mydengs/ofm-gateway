# CHANGELOG

格式基于 Keep a Changelog，版本号遵循语义化版本。

## [1.0.1] - 2026-11-17

### 修复
- `install.sh` 新增 `--upgrade`：发布包本地化模式下覆盖 `/opt/ofm-gateway/upstream/`（旧版保留为
  `upstream.bak`）并重启服务。原先打印的 `cd /opt/ofm-gateway/upstream && git pull` 在本地化部署下
  必然失败（该目录由 `cp -a` 产生，无 `.git`）——升级提示改指向 `--upgrade`，README/CHANGELOG 同步。
- `ofm-admin.mjs` 别名校验修正：原 `!alias.includes('/') === false` 与注释意图相反（实际是"含 `/`
  才通过"），改为白名单校验 `[A-Za-z0-9._:-]+`。
  `POST /admin/aliases` 改为幂等 upsert：重复 POST 同名 alias 直接改目标并返回
  `{replaced:true, previous}`；传 `"strict":true` 时已存在则返回 409（防误改）。

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
- 版本升级：`bash install.sh --domain <域名> --upgrade --yes`（覆盖 upstream/，旧版留 `upstream.bak`）；
  若 upstream/ 是 git clone 得来则 `cd /opt/ofm-gateway/upstream && git pull && systemctl restart` 亦可。