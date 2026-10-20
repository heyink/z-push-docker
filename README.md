# Z-Push Docker (IMAP → Exchange ActiveSync)

[中文说明见下方](#中文)

Docker image and compose stack that runs [Z-Push](https://github.com/Z-Hub/Z-Push) **2.7.6** as an **Exchange ActiveSync (EAS)** gateway in front of an existing **IMAP/SMTP** mailbox. Useful when phone mail apps sync better (or only) via Exchange than plain IMAP.

**Image:** `ghcr.io/heyink/z-push-docker:latest` (built by GitHub Actions, multi-arch `linux/amd64` + `linux/arm64`).

## Features

- PHP 8.3 Apache + Z-Push IMAP backend
- Config driven entirely by environment variables (see `.env.example`)
- Joins an **external** Docker network shared with [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) (no host ports; no bundled Caddy)
- Long-poll friendly proxy labels (`read_timeout` / `write_timeout` **30m**, `flush_interval -1`)
- PHP extensions Z-Push needs: `imap`, `intl` (mail dates), `sysvsem`/`sysvshm` (Ping tracking), `pcntl` (`z-push-top`)
- Logs to `docker logs` by default, TLS certificate validation on by default, health check that exercises Z-Push
- Z-Push code is root-owned and read-only for the web user

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

## Multiple providers = multiple containers

Z-Push's IMAP backend talks to exactly **one** IMAP/SMTP server per instance (`IMAP_SERVER` is a single constant). To serve mailboxes at different providers (e.g. a MXroute-hosted domain and Gmail), run **one container per provider** from the same image. Nothing in the image is instance-specific: config is generated at container start from env vars, and state/logs live in per-container volumes.

See [`examples/multi-instance/`](examples/multi-instance/):

| File | Purpose |
|------|---------|
| `docker-compose.yml` | two services (`zpush-mxroute`, `zpush-gmail`), separate volumes, separate caddy-docker-proxy labels |
| `.env.example` | compose-level vars: `IMAGE`, `CADDY_NETWORK`, hostnames used in labels |
| `mxroute.env.example` / `gmail.env.example` | per-container IMAP/SMTP/folder settings (`env_file`) |

```bash
cd examples/multi-instance
cp .env.example .env && cp mxroute.env.example mxroute.env && cp gmail.env.example gmail.env
docker compose config && docker compose up -d
```

Label hostnames must be in `.env` (compose interpolation); `env_file` values are only passed into the container.

### Gmail / Google Workspace notes

- IMAP `imap.gmail.com:993` (SSL), SMTP `smtp.gmail.com:465` (SSL) or 587 (STARTTLS) — [Google: IMAP, POP, and SMTP](https://developers.google.com/workspace/gmail/imap/imap-smtp).
- Z-Push's IMAP backend only does password login (no XOAUTH2), so use a **Google App Password**, which requires 2-Step Verification and may be unavailable for Workspace accounts if the admin disabled it — [Sign in with app passwords](https://support.google.com/accounts/answer/185833).
- Autodiscover for `@gmail.com` cannot point at your server: on the phone choose Exchange and enter the server (e.g. `gmail-eas.example.com`) manually. The Gmail instance needs only one hostname.
- Folder names: Gmail exposes system labels under `[Gmail]/` (or `[Google Mail]/`) and marks them with RFC 6154 special-use flags (`\Sent`, `\Trash`, `\All` …) — [Gmail IMAP extensions](https://developers.google.com/workspace/gmail/imap/imap-extensions). Z-Push 2.7.6 does **not** read those flags; it compares the raw IMAP name with `IMAP_FOLDER_*`, so names must match exactly (raw modified UTF-7 if localized).
- Exclude `[Gmail]/All Mail`, `[Gmail]/Important`, `[Gmail]/Starred` (they duplicate messages from other labels).
- Gmail allows ~15 simultaneous IMAP connections per account.

#### Check folder names

```bash
docker exec -it zpush-gmail php -r '
$m = imap_open("{imap.gmail.com:993/imap/ssl}", "you@gmail.com", getenv("PW") ?: trim(fgets(STDIN)), OP_HALFOPEN);
foreach (imap_getmailboxes($m, "{imap.gmail.com:993/imap/ssl}", "*") as $b) {
  $raw = substr($b->name, strpos($b->name, "}") + 1);
  printf("%-40s %s\n", $raw, mb_convert_encoding($raw, "UTF-8", "UTF7-IMAP"));
}'
```

Use the **left (raw)** column for `IMAP_FOLDER_*` as-is (no escaping needed; the older `\&` form is still accepted).

## Configuration notes

All settings are environment variables; `.env.example` lists every option with its default. Highlights:

| Variable | Default | Notes |
|---|---|---|
| `LOG_TARGET` | `stdout` | `stdout` → `docker logs` (compose caps it with `json-file` `max-size: 10m`, `max-file: 5`). `file` → `/var/log/z-push/*.log`, rotated at `LOG_MAX_SIZE_MB` (20), keeping `LOG_MAX_FILES` (5). |
| `LOGLEVEL` / `AUTODISCOVER_LOGLEVEL` | `WARN` | `ERROR`, `WARN`, `INFO`, `DEBUG`, `WBXML` … |
| `LOGAUTHFAIL` | `false` | log failed logins at WARN (fail2ban) |
| `IMAP_OPTIONS` | `/ssl/norsh` | certificate is verified; append `/novalidate-cert` only for self-signed servers |
| `IMAP_SMTP_VERIFY_PEER` | `true` | `false` disables SMTP certificate checks (self-signed servers only) |
| `IMAP_SMTP_EHLO` | `ZPUSH_HOST` | EHLO name sent to the SMTP server |
| `IMAP_DISABLE_AUTHENTICATOR` | `GSSAPI` | empty = allow all SASL mechanisms |
| `IMAP_AUTOSEEN_ON_DELETE`, `IMAP_INLINE_FORWARD`, `IMAP_SEARCH_CHARSET` | upstream defaults | |
| `PING_INTERVAL` | `30` | seconds between IMAP checks during Ping = worst-case push latency |
| `PING_HIGHER_BOUND_LIFETIME` / `PING_LOWER_BOUND_LIFETIME` | `900` / `false` | keep the upper bound below proxy timeouts |
| `RETRY_AFTER_DELAY`, `PHP_MEMORY_LIMIT` | `300`, `256M` | |
| `TIMEZONE` | `UTC` | used for Z-Push, PHP (`date.timezone`) and Apache (`TZ`) |

The container refuses to start if a value is invalid (e.g. non-numeric `PING_INTERVAL`) and prints a summary of the effective IMAP/SMTP settings on startup.

The first time a device connects, upstream Z-Push logs `FileStateMachine ... Unable to read filename '/var/lib/z-push/users'` (WARN/FATAL) while it creates the users index; this is harmless and does not repeat.

**Health check:** the image's `HEALTHCHECK` (and the compose files) request `/Microsoft-Server-ActiveSync` without credentials and expect `401`; a PHP or configuration error returns `500` and marks the container unhealthy. Health-check requests are not written to the access log.

**Build-time patches** (`patches/`, applied with `patch --fuzz=0`; the build fails if one no longer applies):
`zpush-2.7.6-log-streams.patch` lets Z-Push log to `php://stderr`; `zpush-2.7.6-auth-loglevel.patch` logs unauthenticated requests at INFO instead of FATAL.

## Admin tools

```bash
docker exec -it z-push z-push-admin -a list          # devices and users
docker exec -it z-push z-push-admin -a lastsync      # last sync per device
docker exec -it z-push z-push-admin -a resync -u user@example.com -d <device-id>
docker exec -it z-push z-push-admin -a remove -u user@example.com -d <device-id>
docker exec -it z-push z-push-admin -a fixstates
docker exec -it z-push z-push-top                    # live view (needs -it)
```

Both wrappers run as `www-data` with the generated configuration.

## Upgrading from earlier images

- `IMAP_OPTIONS` now defaults to `/ssl/norsh` (was `/ssl/norsh/novalidate-cert` when unset) and SMTP certificates are verified (`IMAP_SMTP_VERIFY_PEER=true`). Public providers (Gmail, MXroute, …) have valid certificates; self-signed servers need the opt-outs above.
- When unset, `IMAP_SMTP_PORT` / `IMAP_SMTP_SSL` now default to `465` / `true` (was `587` / `false`).
- Logs go to `docker logs` at `WARN` by default; set `LOG_TARGET=file` and `LOGLEVEL=INFO` for the old behaviour.
- `TIMEZONE` defaults to `UTC` everywhere.
- The root `docker-compose.yml` now passes `.env` to the container with `env_file`, so new variables only need to be added to `.env`.

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

### 多服务商 = 多个容器

Z-Push IMAP 后端每个实例只能连 **一个** IMAP/SMTP 服务器。不同服务商（如 MXroute 域名邮箱 + Gmail）请用同一镜像跑 **多个容器**：各自的 env 文件、各自的 state/log 卷、各自的 Caddy 主机名。示例见 `examples/multi-instance/`。

Gmail 要点：`imap.gmail.com:993` SSL、`smtp.gmail.com:465` SSL；必须用 **应用专用密码**（需开启两步验证；Workspace 可能被管理员禁用）；Z-Push 不支持 OAuth。`@gmail.com` 无法自动发现到你的服务器，手机上手动填写服务器（如 `gmail-eas.example.com`），Gmail 实例只需一个主机名。Gmail 文件夹名可能随网页语言本地化，Z-Push 2.7.6 不识别 SPECIAL-USE 标记，需按上面的命令列出原始（UTF-7）名称并原样填写（无需转义，旧的 `\&` 写法仍兼容）。建议排除 `[Gmail]/All Mail|[Gmail]/Important|[Gmail]/Starred`。

### 配置要点 / 运维

- 所有设置均为环境变量，完整列表与默认值见 `.env.example`。
- 日志：`LOG_TARGET=stdout`（默认，`docker logs` 查看，compose 限制 10m×5）或 `file`（写入 `/var/log/z-push`，按 `LOG_MAX_SIZE_MB` 轮转）；默认 `LOGLEVEL=WARN`。
- 证书校验默认开启：`IMAP_OPTIONS=/ssl/norsh`、`IMAP_SMTP_VERIFY_PEER=true`；仅自签证书服务器才加 `/novalidate-cert` 或设为 `false`。
- 新增：`IMAP_SMTP_EHLO`、`IMAP_DISABLE_AUTHENTICATOR`（默认 GSSAPI）、`IMAP_AUTOSEEN_ON_DELETE`、`IMAP_INLINE_FORWARD`、`IMAP_SEARCH_CHARSET`、`PING_LOWER_BOUND_LIFETIME`、`RETRY_AFTER_DELAY`、`PHP_MEMORY_LIMIT`、`AUTODISCOVER_LOGLEVEL`；`TIMEZONE` 默认 `UTC`。
- 健康检查：未认证访问 `/Microsoft-Server-ActiveSync` 应返回 401。
- 管理工具：`docker exec -it z-push z-push-admin -a list`、`-a lastsync`、`-a remove -u <用户> -d <设备>`、`z-push-top`。
- 升级注意：证书校验默认开启；未设置时 SMTP 默认 465/SSL；日志默认输出到 `docker logs`；根目录 compose 改为 `env_file: .env`。

### 许可

Z-Push 为 AGPL-3.0。
