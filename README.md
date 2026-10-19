# Z-Push Docker (IMAP → Exchange ActiveSync)

[中文说明见下方](#中文)

Docker image and compose stack that runs [Z-Push](https://github.com/Z-Hub/Z-Push) **2.7.6** as an **Exchange ActiveSync (EAS)** gateway in front of an existing **IMAP/SMTP** mailbox. Useful when phone mail apps sync better (or only) via Exchange than plain IMAP.

**Image:** `ghcr.io/heyink/z-push-docker:latest` (built by GitHub Actions, multi-arch `linux/amd64` + `linux/arm64`).

## Features

- PHP 8.3 Apache + Z-Push IMAP backend
- Config driven entirely by environment variables (see `.env.example`)
- Joins an **external** Docker network shared with [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) (no host ports; no bundled Caddy)
- Long-poll friendly proxy labels (`read_timeout` / `write_timeout` **30m**, `flush_interval -1`)

## Quick start

```bash
cp .env.example .env
# Edit: IMAP_SERVER, IMAP_SMTP_*, EAS_DOMAIN, AUTODISCOVER_DOMAIN, CADDY_NETWORK, ZPUSH_HOST

docker compose pull
docker compose up -d
```

Find the network your Caddy container uses:

```bash
docker network ls
docker inspect <caddy_container> --format '{{json .NetworkSettings.Networks}}'
# set CADDY_NETWORK=... in .env if it is not "caddy"
```

DNS (examples):

| Type | Name | Value |
|------|------|--------|
| A/AAAA | `eas.example.com` | your VPS IP |
| A/AAAA | `autodiscover.example.com` | your VPS IP |

Leave your provider MX records unchanged.

Phone: add an **Exchange** account with email `user@example.com`, server `eas.example.com` (or rely on Autodiscover).

## Provider examples (generic)

These are typical values only — always confirm in your provider panel.

| Provider style | IMAP | SMTP | Notes |
|----------------|------|------|--------|
| Many hosts (incl. MXroute-style) | host like `<server>.mxrouting.net`, port **993** SSL | same host, port **465** SSL (or **587** / **2525** STARTTLS) | Username = full email; folders often top-level `Sent` / `Drafts` / `Trash` / `Junk` / `Archive`; empty IMAP path prefix; hierarchy separator `.` |
| Gmail | `imap.gmail.com` 993 SSL | `smtp.gmail.com` 465/587 | App password; folders like `[Gmail]/Sent Mail` |

## Honest note on “push”

Z-Push 2.7.6’s IMAP backend **polls** IMAP during ActiveSync Ping (`PING_INTERVAL`, default 30s). It is not the same as native IMAP IDLE (IDLE exists on Z-Push `develop`, not in 2.7.6). Latency ≈ poll interval + network.

## Optional Caddyfile

If you do not use docker-proxy labels, see `caddy/Caddyfile.snippet`.

## License

Z-Push is **AGPL-3.0**. Upstream: https://github.com/Z-Hub/Z-Push

---

## 中文

用 Docker 运行 [Z-Push](https://github.com/Z-Hub/Z-Push) 2.7.6，把已有 **IMAP/SMTP** 邮箱暴露成手机可用的 **Exchange ActiveSync**。

镜像：`ghcr.io/heyink/z-push-docker:latest`（Actions 多架构构建）。

### 快速开始

```bash
cp .env.example .env
# 填写 IMAP/SMTP、EAS_DOMAIN、AUTODISCOVER_DOMAIN、CADDY_NETWORK、ZPUSH_HOST
docker compose pull && docker compose up -d
```

本仓库 **不** 自带 Caddy：容器加入与 [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) 相同的外部网络（默认名 `caddy`），通过 **labels** 自动接入（超时 30m，适合长轮询 Ping）。

DNS 示例：`eas.example.com`、`autodiscover.example.com` 的 A/AAAA 指向 VPS；**不要**改动邮件服务商的 MX。

### 服务商示例（通用）

例如一类托管（主机名形如 `<server>.mxrouting.net`）：IMAP **993** SSL、SMTP **465** SSL；用户名为完整邮箱；文件夹多为顶层 `Sent`/`Drafts`/`Trash`/`Junk`/`Archive`；命名空间前缀为空。具体以控制面板为准。

### 关于推送速度

2.7.6 IMAP 后端在 Ping 期间仍是 **轮询** IMAP，延迟约等于 `PING_INTERVAL`。正式版不含 IMAP IDLE。

### 许可

Z-Push 为 AGPL-3.0。
