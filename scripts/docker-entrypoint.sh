#!/bin/bash
set -euo pipefail

ZPUSH_HOME="${ZPUSH_HOME:-/usr/share/z-push}"
STATE_DIR="${STATE_DIR:-/var/lib/z-push}"
LOG_DIR="${LOG_DIR:-/var/log/z-push}"

mkdir -p "$STATE_DIR" "$LOG_DIR"
chown -R www-data:www-data "$STATE_DIR" "$LOG_DIR" || true

env_or() {
  local v="${!1-}"
  if [ -n "${v}" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

php_bool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) echo true ;;
    *) echo false ;;
  esac
}

php_quote() {
  printf "%s" "$1" | sed "s/'/\\\\'/g"
}

php_sed_define() {
  local file="$1" const="$2" value="$3"
  sed -i -E "s#define\('${const}'[[:space:]]*,[[:space:]]*[^)]+\)#define('${const}', ${value})#g" "$file"
}

# ---- main settings ----
TIMEZONE="$(env_or TIMEZONE Asia/Shanghai)"
BACKEND_PROVIDER="$(env_or BACKEND_PROVIDER BackendIMAP)"
USE_FULLEMAIL_FOR_LOGIN="$(php_bool "$(env_or USE_FULLEMAIL_FOR_LOGIN true)")"
LOOSE_PROVISIONING="$(php_bool "$(env_or LOOSE_PROVISIONING true)")"
PROVISIONING="$(php_bool "$(env_or PROVISIONING true)")"
PING_INTERVAL="$(env_or PING_INTERVAL 30)"
PING_HIGHER_BOUND_LIFETIME="$(env_or PING_HIGHER_BOUND_LIFETIME false)"
USE_CUSTOM_REMOTE_IP_HEADER="$(env_or USE_CUSTOM_REMOTE_IP_HEADER HTTP_X_FORWARDED_FOR)"
LOGLEVEL_NAME="$(env_or LOGLEVEL LOGLEVEL_INFO)"
LOGAUTHFAIL="$(php_bool "$(env_or LOGAUTHFAIL false)")"

case "$LOGLEVEL_NAME" in
  LOGLEVEL_*) ;;
  OFF|FATAL|ERROR|WARN|INFO|DEBUG|WBXML|DEVICEID|WBXMLSTACK)
    LOGLEVEL_NAME="LOGLEVEL_${LOGLEVEL_NAME}" ;;
  *) LOGLEVEL_NAME="LOGLEVEL_INFO" ;;
esac

if [ "$(printf '%s' "$USE_CUSTOM_REMOTE_IP_HEADER" | tr '[:upper:]' '[:lower:]')" = "false" ]; then
  REMOTE_IP_PHP="false"
else
  REMOTE_IP_PHP="'$(php_quote "$USE_CUSTOM_REMOTE_IP_HEADER")'"
fi

PING_HIGHER_PHP="$PING_HIGHER_BOUND_LIFETIME"
if [ "$(printf '%s' "$PING_HIGHER_BOUND_LIFETIME" | tr '[:upper:]' '[:lower:]')" = "false" ]; then
  PING_HIGHER_PHP="false"
fi

if [ ! -f "${ZPUSH_HOME}/config.php.dist" ]; then
  cp "${ZPUSH_HOME}/config.php" "${ZPUSH_HOME}/config.php.dist"
fi
cp "${ZPUSH_HOME}/config.php.dist" "${ZPUSH_HOME}/config.php"

php_sed_define "${ZPUSH_HOME}/config.php" TIMEZONE "'$(php_quote "$TIMEZONE")'"
php_sed_define "${ZPUSH_HOME}/config.php" STATE_DIR "'$(php_quote "$STATE_DIR")/'"
php_sed_define "${ZPUSH_HOME}/config.php" LOGBACKEND "'filelog'"
php_sed_define "${ZPUSH_HOME}/config.php" LOGLEVEL "${LOGLEVEL_NAME}"
php_sed_define "${ZPUSH_HOME}/config.php" LOGAUTHFAIL "${LOGAUTHFAIL}"
php_sed_define "${ZPUSH_HOME}/config.php" LOGFILEDIR "'$(php_quote "$LOG_DIR")/'"
php_sed_define "${ZPUSH_HOME}/config.php" BACKEND_PROVIDER "'$(php_quote "$BACKEND_PROVIDER")'"
php_sed_define "${ZPUSH_HOME}/config.php" USE_FULLEMAIL_FOR_LOGIN "${USE_FULLEMAIL_FOR_LOGIN}"
php_sed_define "${ZPUSH_HOME}/config.php" PROVISIONING "${PROVISIONING}"
php_sed_define "${ZPUSH_HOME}/config.php" LOOSE_PROVISIONING "${LOOSE_PROVISIONING}"
php_sed_define "${ZPUSH_HOME}/config.php" PING_INTERVAL "${PING_INTERVAL}"
php_sed_define "${ZPUSH_HOME}/config.php" PING_HIGHER_BOUND_LIFETIME "${PING_HIGHER_PHP}"
php_sed_define "${ZPUSH_HOME}/config.php" USE_CUSTOM_REMOTE_IP_HEADER "${REMOTE_IP_PHP}"
php_sed_define "${ZPUSH_HOME}/config.php" SCRIPT_TIMEOUT "0"

# ---- IMAP backend ----
IMAP_SERVER="$(env_or IMAP_SERVER localhost)"
IMAP_PORT="$(env_or IMAP_PORT 993)"
IMAP_OPTIONS="$(env_or IMAP_OPTIONS /ssl/norsh/novalidate-cert)"
IMAP_FOLDER_CONFIGURED="$(php_bool "$(env_or IMAP_FOLDER_CONFIGURED true)")"
IMAP_FOLDER_PREFIX="$(env_or IMAP_FOLDER_PREFIX '')"
IMAP_FOLDER_PREFIX_IN_INBOX="$(php_bool "$(env_or IMAP_FOLDER_PREFIX_IN_INBOX false)")"
IMAP_FOLDER_INBOX="$(env_or IMAP_FOLDER_INBOX INBOX)"
IMAP_FOLDER_SENT="$(env_or IMAP_FOLDER_SENT Sent)"
IMAP_FOLDER_DRAFT="$(env_or IMAP_FOLDER_DRAFT Drafts)"
IMAP_FOLDER_TRASH="$(env_or IMAP_FOLDER_TRASH Trash)"
IMAP_FOLDER_SPAM="$(env_or IMAP_FOLDER_SPAM Junk)"
IMAP_FOLDER_ARCHIVE="$(env_or IMAP_FOLDER_ARCHIVE Archive)"
IMAP_SMTP_METHOD="$(env_or IMAP_SMTP_METHOD smtp)"
IMAP_SMTP_HOST="$(env_or IMAP_SMTP_HOST "$IMAP_SERVER")"
IMAP_SMTP_PORT="$(env_or IMAP_SMTP_PORT 587)"
IMAP_SMTP_AUTH="$(php_bool "$(env_or IMAP_SMTP_AUTH true)")"
IMAP_SMTP_SSL="$(php_bool "$(env_or IMAP_SMTP_SSL false)")"
if [ "$IMAP_SMTP_SSL" = "true" ]; then
  case "$IMAP_SMTP_HOST" in
    ssl://*|tls://*) ;;
    *) IMAP_SMTP_HOST="ssl://${IMAP_SMTP_HOST}" ;;
  esac
fi
IMAP_DEFAULTFROM="$(env_or IMAP_DEFAULTFROM '')"
IMAP_EXCLUDED_FOLDERS="$(env_or IMAP_EXCLUDED_FOLDERS '')"

if [ ! -f "${ZPUSH_HOME}/backend/imap/config.php.dist" ]; then
  cp "${ZPUSH_HOME}/backend/imap/config.php" "${ZPUSH_HOME}/backend/imap/config.php.dist"
fi
cp "${ZPUSH_HOME}/backend/imap/config.php.dist" "${ZPUSH_HOME}/backend/imap/config.php"
IMAP_CFG="${ZPUSH_HOME}/backend/imap/config.php"

php_sed_define "$IMAP_CFG" IMAP_SERVER "'$(php_quote "$IMAP_SERVER")'"
php_sed_define "$IMAP_CFG" IMAP_PORT "${IMAP_PORT}"
php_sed_define "$IMAP_CFG" IMAP_OPTIONS "'$(php_quote "$IMAP_OPTIONS")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_CONFIGURED "${IMAP_FOLDER_CONFIGURED}"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_PREFIX "'$(php_quote "$IMAP_FOLDER_PREFIX")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_PREFIX_IN_INBOX "${IMAP_FOLDER_PREFIX_IN_INBOX}"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_INBOX "'$(php_quote "$IMAP_FOLDER_INBOX")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_SENT "'$(php_quote "$IMAP_FOLDER_SENT")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_DRAFT "'$(php_quote "$IMAP_FOLDER_DRAFT")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_TRASH "'$(php_quote "$IMAP_FOLDER_TRASH")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_SPAM "'$(php_quote "$IMAP_FOLDER_SPAM")'"
php_sed_define "$IMAP_CFG" IMAP_FOLDER_ARCHIVE "'$(php_quote "$IMAP_FOLDER_ARCHIVE")'"
php_sed_define "$IMAP_CFG" IMAP_SMTP_METHOD "'$(php_quote "$IMAP_SMTP_METHOD")'"
php_sed_define "$IMAP_CFG" IMAP_DEFAULTFROM "'$(php_quote "$IMAP_DEFAULTFROM")'"
php_sed_define "$IMAP_CFG" IMAP_EXCLUDED_FOLDERS "'$(php_quote "$IMAP_EXCLUDED_FOLDERS")'"

# Inject SMTP params before MAIL_MIMEPART_CRLF; strip prior $imap_smtp_params assignments
AUTH_PHP="$IMAP_SMTP_AUTH"
SMTP_HOST_Q="$(php_quote "$IMAP_SMTP_HOST")"
TMP_CFG="$(mktemp)"
awk '
  /^global \$imap_smtp_params/ {skip=1; next}
  skip==1 {
    if ($0 ~ /^define\(/) { skip=0 }
    else if ($0 ~ /^\/\/ If you are using IMAP_SMTP_METHOD/) { skip=0 }
    else next
  }
  { print }
' "$IMAP_CFG" > "$TMP_CFG"
mv "$TMP_CFG" "$IMAP_CFG"

TMP_BLOCK="$(mktemp)"
cat > "$TMP_BLOCK" <<SMTPEOF
global \$imap_smtp_params;
\$imap_smtp_params = array(
    'host' => '${SMTP_HOST_Q}',
    'port' => ${IMAP_SMTP_PORT},
    'auth' => ${AUTH_PHP},
    'username' => 'imap_username',
    'password' => 'imap_password',
    'verify_peer' => false,
    'verify_peer_name' => false,
    'allow_self_signed' => true,
);

SMTPEOF

TMP_CFG="$(mktemp)"
awk -v bf="$TMP_BLOCK" '
  index($0, "define('\''MAIL_MIMEPART_CRLF'\''") == 1 || $0 ~ /define\('\''MAIL_MIMEPART_CRLF'\''/ {
    while ((getline line < bf) > 0) print line
    close(bf)
  }
  { print }
' "$IMAP_CFG" > "$TMP_CFG"
mv "$TMP_CFG" "$IMAP_CFG"
rm -f "$TMP_BLOCK"

# ---- Autodiscover ----
ZPUSH_HOST="$(env_or ZPUSH_HOST '')"
AD_USE_FULLEMAIL="$(php_bool "$(env_or USE_FULLEMAIL_FOR_LOGIN true)")"

if [ ! -f "${ZPUSH_HOME}/autodiscover/config.php.dist" ]; then
  cp "${ZPUSH_HOME}/autodiscover/config.php" "${ZPUSH_HOME}/autodiscover/config.php.dist"
fi
cp "${ZPUSH_HOME}/autodiscover/config.php.dist" "${ZPUSH_HOME}/autodiscover/config.php"
AD_CFG="${ZPUSH_HOME}/autodiscover/config.php"

if [ -n "$ZPUSH_HOST" ]; then
  if grep -q "ZPUSH_HOST" "$AD_CFG"; then
    sed -i -E "s#^[[:space:]]*//[[:space:]]*define\('ZPUSH_HOST'.*#define('ZPUSH_HOST', '$(php_quote "$ZPUSH_HOST")');#" "$AD_CFG"
    php_sed_define "$AD_CFG" ZPUSH_HOST "'$(php_quote "$ZPUSH_HOST")'"
  else
    sed -i "1a define('ZPUSH_HOST', '$(php_quote "$ZPUSH_HOST")');" "$AD_CFG"
  fi
fi
php_sed_define "$AD_CFG" TIMEZONE "'$(php_quote "$TIMEZONE")'"
php_sed_define "$AD_CFG" USE_FULLEMAIL_FOR_LOGIN "${AD_USE_FULLEMAIL}"
php_sed_define "$AD_CFG" BACKEND_PROVIDER "'$(php_quote "$BACKEND_PROVIDER")'"
php_sed_define "$AD_CFG" LOGFILEDIR "'$(php_quote "$LOG_DIR")/'"

# Ensure Apache (www-data) can read generated configs
chown -R www-data:www-data \
  "${ZPUSH_HOME}/config.php" \
  "${ZPUSH_HOME}/backend/imap/config.php" \
  "${ZPUSH_HOME}/autodiscover/config.php" \
  "${ZPUSH_HOME}/config.php.dist" \
  "${ZPUSH_HOME}/backend/imap/config.php.dist" \
  "${ZPUSH_HOME}/autodiscover/config.php.dist" 2>/dev/null || true
chmod 640 \
  "${ZPUSH_HOME}/config.php" \
  "${ZPUSH_HOME}/backend/imap/config.php" \
  "${ZPUSH_HOME}/autodiscover/config.php"

php -l "${ZPUSH_HOME}/config.php"
php -l "${ZPUSH_HOME}/backend/imap/config.php"
php -l "${ZPUSH_HOME}/autodiscover/config.php"

echo "[z-push] IMAP ${IMAP_SERVER}:${IMAP_PORT} options=${IMAP_OPTIONS}"
echo "[z-push] SMTP method=${IMAP_SMTP_METHOD} host=${IMAP_SMTP_HOST}:${IMAP_SMTP_PORT} auth=${IMAP_SMTP_AUTH}"
echo "[z-push] folders configured=${IMAP_FOLDER_CONFIGURED} sent=${IMAP_FOLDER_SENT} trash=${IMAP_FOLDER_TRASH}"
echo "[z-push] ZPUSH_HOST=${ZPUSH_HOST:-'(unset)'}"

exec "$@"
