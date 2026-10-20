#!/bin/bash
# Generate Z-Push config from environment variables, then exec Apache.
set -euo pipefail

ZPUSH_HOME="${ZPUSH_HOME:-/usr/share/z-push}"
STATE_DIR="${STATE_DIR:-/var/lib/z-push}"
LOG_DIR="${LOG_DIR:-/var/log/z-push}"
SETCFG="php /usr/local/lib/z-push-docker/zpush-setconfig.php"

log() { echo "[z-push] $*"; }
warn() { echo "[z-push] WARNING: $*" >&2; }
env_or() { local v="${!1-}"; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi; }
is_true() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac; }
loglevel_const() {
  local l; l="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; l="${l#LOGLEVEL_}"
  case "$l" in OFF|FATAL|ERROR|WARN|INFO|DEBUG|WBXML|DEVICEID|WBXMLSTACK) echo "LOGLEVEL_$l";;
    *) warn "unknown log level '$1', using WARN" ; echo LOGLEVEL_WARN;; esac
}

mkdir -p "$STATE_DIR" "$LOG_DIR"
chown -R www-data:www-data "$STATE_DIR" "$LOG_DIR"

# ---------- time zone ----------
TIMEZONE="${TIMEZONE:-${TZ:-UTC}}"
if [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then warn "unknown TIMEZONE '$TIMEZONE', using UTC"; TIMEZONE=UTC; fi
export TZ="$TIMEZONE"

# ---------- logging ----------
LOG_TARGET="$(env_or LOG_TARGET stdout | tr '[:upper:]' '[:lower:]')"
LOGLEVEL_C="$(loglevel_const "$(env_or LOGLEVEL WARN)")"
AD_LOGLEVEL_C="$(loglevel_const "$(env_or AUTODISCOVER_LOGLEVEL "$(env_or LOGLEVEL WARN)")")"
case "$LOG_TARGET" in
  stdout)
    # Everything to the container log; WARN+ would otherwise be written twice.
    ZP_LOGFILE='php://stderr'; ZP_LOGERRORFILE='/dev/null'
    AD_LOGFILE='php://stderr'; AD_LOGERRORFILE='/dev/null' ;;
  file)
    ZP_LOGFILE="$LOG_DIR/z-push.log"; ZP_LOGERRORFILE="$LOG_DIR/z-push-error.log"
    AD_LOGFILE="$LOG_DIR/autodiscover.log"; AD_LOGERRORFILE="$LOG_DIR/autodiscover-error.log" ;;
  *) echo "[z-push] LOG_TARGET must be 'stdout' or 'file'" >&2; exit 1 ;;
esac

# ---------- PHP runtime ini ----------
{
  echo "memory_limit = $(env_or PHP_MEMORY_LIMIT 256M)"
  echo "date.timezone = $TIMEZONE"
  if [ "$LOG_TARGET" = file ]; then echo "error_log = $LOG_DIR/php-error.log"; fi
} > /usr/local/etc/php/conf.d/zz-runtime.ini

# ---------- core config.php ----------
CFG="$ZPUSH_HOME/config.php"
cp "$CFG.dist" "$CFG"
$SETCFG "$CFG" \
  TIMEZONE str "$TIMEZONE" \
  STATE_DIR str "${STATE_DIR%/}/" \
  LOGBACKEND str filelog \
  LOGFILEDIR str "${LOG_DIR%/}/" \
  LOGFILE str "$ZP_LOGFILE" \
  LOGERRORFILE str "$ZP_LOGERRORFILE" \
  LOGLEVEL raw "$LOGLEVEL_C" \
  LOGAUTHFAIL bool "$(env_or LOGAUTHFAIL false)" \
  BACKEND_PROVIDER str "$(env_or BACKEND_PROVIDER BackendIMAP)" \
  USE_FULLEMAIL_FOR_LOGIN bool "$(env_or USE_FULLEMAIL_FOR_LOGIN true)" \
  PROVISIONING bool "$(env_or PROVISIONING true)" \
  LOOSE_PROVISIONING bool "$(env_or LOOSE_PROVISIONING true)" \
  PING_INTERVAL int "$(env_or PING_INTERVAL 30)" \
  PING_LOWER_BOUND_LIFETIME intfalse "$(env_or PING_LOWER_BOUND_LIFETIME false)" \
  PING_HIGHER_BOUND_LIFETIME intfalse "$(env_or PING_HIGHER_BOUND_LIFETIME 900)" \
  RETRY_AFTER_DELAY int "$(env_or RETRY_AFTER_DELAY 300)" \
  USE_CUSTOM_REMOTE_IP_HEADER strfalse "$(env_or USE_CUSTOM_REMOTE_IP_HEADER HTTP_X_FORWARDED_FOR)" \
  SCRIPT_TIMEOUT int 0

PHB="$(env_or PING_HIGHER_BOUND_LIFETIME 900)"
if [ "$PHB" != false ] && [ "$PHB" -gt 1740 ] 2>/dev/null; then
  warn "PING_HIGHER_BOUND_LIFETIME=$PHB is close to/above Apache Timeout 1800s; keep it well below your proxy timeout"
fi

# ---------- IMAP backend ----------
# Older docs told users to write '&' as '\&' (sed escaping); values are now written verbatim.
for v in IMAP_FOLDER_INBOX IMAP_FOLDER_SENT IMAP_FOLDER_DRAFT IMAP_FOLDER_TRASH IMAP_FOLDER_SPAM IMAP_FOLDER_ARCHIVE IMAP_FOLDER_PREFIX; do
  if [ -n "${!v-}" ]; then val="${!v}"; val="${val//'\&'/'&'}"; printf -v "$v" '%s' "$val"; fi
done
IMAP_SERVER="$(env_or IMAP_SERVER localhost)"
IMAP_OPTIONS="$(env_or IMAP_OPTIONS /ssl/norsh)"
case "$IMAP_OPTIONS" in *novalidate-cert*) warn "IMAP_OPTIONS contains /novalidate-cert: the IMAP server certificate is NOT verified";; esac
IMAP_SMTP_HOST="$(env_or IMAP_SMTP_HOST "$IMAP_SERVER")"
IMAP_SMTP_PORT="$(env_or IMAP_SMTP_PORT 465)"
if is_true "$(env_or IMAP_SMTP_SSL true)"; then
  case "$IMAP_SMTP_HOST" in ssl://*|tls://*) ;; *) IMAP_SMTP_HOST="ssl://$IMAP_SMTP_HOST";; esac
fi
SMTP_VERIFY=true; is_true "$(env_or IMAP_SMTP_VERIFY_PEER true)" || { SMTP_VERIFY=false; warn "IMAP_SMTP_VERIFY_PEER=false: the SMTP server certificate is NOT verified"; }
ZPUSH_HOST="$(env_or ZPUSH_HOST "${EAS_DOMAIN:-}")"
SMTP_EHLO="$(env_or IMAP_SMTP_EHLO "$ZPUSH_HOST")"
SMTP_JSON="$(SMTP_HOST="$IMAP_SMTP_HOST" SMTP_PORT="$IMAP_SMTP_PORT" SMTP_AUTH="$(env_or IMAP_SMTP_AUTH true)" \
  SMTP_VERIFY="$SMTP_VERIFY" SMTP_EHLO="$SMTP_EHLO" php -r '
  $v = getenv("SMTP_VERIFY") === "true";
  $p = ["host" => getenv("SMTP_HOST"), "port" => (int)getenv("SMTP_PORT"),
        "auth" => in_array(strtolower(getenv("SMTP_AUTH")), ["1","true","yes","on"], true),
        "username" => "imap_username", "password" => "imap_password",
        "verify_peer" => $v, "verify_peer_name" => $v, "allow_self_signed" => !$v];
  if (getenv("SMTP_EHLO") !== "") $p["localhost"] = getenv("SMTP_EHLO");
  echo json_encode($p);')"

ICFG="$ZPUSH_HOME/backend/imap/config.php"
cp "$ICFG.dist" "$ICFG"
IMAP_ARGS=(
  IMAP_SERVER str "$IMAP_SERVER"
  IMAP_PORT int "$(env_or IMAP_PORT 993)"
  IMAP_OPTIONS str "$IMAP_OPTIONS"
  IMAP_AUTOSEEN_ON_DELETE bool "$(env_or IMAP_AUTOSEEN_ON_DELETE false)"
  IMAP_FOLDER_CONFIGURED bool "$(env_or IMAP_FOLDER_CONFIGURED true)"
  IMAP_FOLDER_PREFIX str "$(env_or IMAP_FOLDER_PREFIX '')"
  IMAP_FOLDER_PREFIX_IN_INBOX bool "$(env_or IMAP_FOLDER_PREFIX_IN_INBOX false)"
  IMAP_FOLDER_INBOX str "$(env_or IMAP_FOLDER_INBOX INBOX)"
  IMAP_FOLDER_SENT str "$(env_or IMAP_FOLDER_SENT Sent)"
  IMAP_FOLDER_DRAFT str "$(env_or IMAP_FOLDER_DRAFT Drafts)"
  IMAP_FOLDER_TRASH str "$(env_or IMAP_FOLDER_TRASH Trash)"
  IMAP_FOLDER_SPAM str "$(env_or IMAP_FOLDER_SPAM Junk)"
  IMAP_FOLDER_ARCHIVE str "$(env_or IMAP_FOLDER_ARCHIVE Archive)"
  IMAP_INLINE_FORWARD bool "$(env_or IMAP_INLINE_FORWARD true)"
  IMAP_EXCLUDED_FOLDERS str "$(env_or IMAP_EXCLUDED_FOLDERS '')"
  IMAP_DEFAULTFROM str "$(env_or IMAP_DEFAULTFROM '')"
  IMAP_SMTP_METHOD str "$(env_or IMAP_SMTP_METHOD smtp)"
  IMAP_SEARCH_CHARSET str "$(env_or IMAP_SEARCH_CHARSET UTF-8)"
)
# GSSAPI disabled by default: php-imap is built with Kerberos and would try it first.
IMAP_DISABLE_AUTH="${IMAP_DISABLE_AUTHENTICATOR-GSSAPI}"
if [ -n "$IMAP_DISABLE_AUTH" ]; then IMAP_ARGS+=(IMAP_DISABLE_AUTHENTICATOR str "$IMAP_DISABLE_AUTH"); fi
$SETCFG "$ICFG" "${IMAP_ARGS[@]}" --smtp-params "$SMTP_JSON"

# ---------- Autodiscover ----------
ACFG="$ZPUSH_HOME/autodiscover/config.php"
cp "$ACFG.dist" "$ACFG"
AD_ARGS=(
  TIMEZONE str "$TIMEZONE"
  USE_FULLEMAIL_FOR_LOGIN bool "$(env_or USE_FULLEMAIL_FOR_LOGIN true)"
  BACKEND_PROVIDER str "$(env_or BACKEND_PROVIDER BackendIMAP)"
  LOGFILEDIR str "${LOG_DIR%/}/"
  LOGFILE str "$AD_LOGFILE"
  LOGERRORFILE str "$AD_LOGERRORFILE"
  LOGLEVEL raw "$AD_LOGLEVEL_C"
)
if [ -n "$ZPUSH_HOST" ]; then AD_ARGS+=(ZPUSH_HOST str "$ZPUSH_HOST"); fi
$SETCFG "$ACFG" "${AD_ARGS[@]}"

# ---------- permissions + lint ----------
for f in "$CFG" "$ICFG" "$ACFG"; do
  chown root:www-data "$f"; chmod 640 "$f"
  php -l "$f" >/dev/null || { echo "[z-push] syntax error in generated $f" >&2; exit 1; }
done

# ---------- optional log rotation (file mode) ----------
if [ "$LOG_TARGET" = file ]; then
  MAX_MB="$(env_or LOG_MAX_SIZE_MB 20)"; MAX_FILES="$(env_or LOG_MAX_FILES 5)"
  (
    set +e
    while sleep "$(env_or LOG_ROTATE_INTERVAL 600)"; do
      for f in "$LOG_DIR"/*.log; do
        [ -f "$f" ] || continue
        [ "$(stat -c %s "$f")" -ge $((MAX_MB * 1024 * 1024)) ] || continue
        for n in $(seq $((MAX_FILES - 1)) -1 1); do if [ -f "$f.$n" ]; then mv -f "$f.$n" "$f.$((n + 1))"; fi; done
        cp -p "$f" "$f.1" && : > "$f"
        rm -f "$f.$((MAX_FILES + 1))"
      done
    done
  ) &
  log "file logging in $LOG_DIR (rotate at ${MAX_MB}MB, keep $MAX_FILES)"
fi

log "IMAP $IMAP_SERVER:$(env_or IMAP_PORT 993) options=$IMAP_OPTIONS"
log "SMTP $IMAP_SMTP_HOST:$IMAP_SMTP_PORT verify_peer=$SMTP_VERIFY ehlo=${SMTP_EHLO:-localhost}"
log "folders sent=$(env_or IMAP_FOLDER_SENT Sent) trash=$(env_or IMAP_FOLDER_TRASH Trash) excluded=$(env_or IMAP_EXCLUDED_FOLDERS '')"
log "log target=$LOG_TARGET level=$LOGLEVEL_C tz=$TIMEZONE ZPUSH_HOST=${ZPUSH_HOST:-(unset)}"

exec "$@"
