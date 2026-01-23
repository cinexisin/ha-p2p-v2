#!/usr/bin/env sh
set -eu

log(){ echo "[cinexis] $*"; }

# Persist identity across updates & even uninstall/reinstall (prefer /share)
PERSIST_BASE="/data"
if [ -d /share ] && [ -w /share ]; then
  PERSIST_BASE="/share"
fi
PERSIST_DIR="${PERSIST_BASE}/cinexis"
mkdir -p "$PERSIST_DIR"

DATA_DIR="/data"
mkdir -p "$DATA_DIR"

NODE_ID_FILE="${PERSIST_DIR}/node_id"
SECRET_FILE="${PERSIST_DIR}/device_secret"
LOCKDIR="${PERSIST_DIR}/.lock"

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_PORT="${HA_PORT:-8123}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

API_BASE="${API_BASE:-https://api.cinexis.cloud}"
OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"
REGISTER_URL="${API_BASE}/licensing/v1/nodes/register"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# ---- SINGLE INSTANCE LOCK ----
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  log "another instance already running; idling (prevents duplicate frpc/proxy)"
  while true; do sleep 3600; done
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

sanitize_uuid(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '\r\n '; }
valid_uuid(){ printf '%s' "$1" | grep -Eq "$UUID_RE"; }

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    h="$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)"
    printf '%s\n' "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

get_ha_core_uuid() {
  f="/config/.storage/core.uuid"
  [ -f "$f" ] || return 1
  v="$(sed -n 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([a-fA-F0-9-]\{36\}\)".*/\1/p' "$f" | head -n1 || true)"
  v="$(sanitize_uuid "$v")"
  valid_uuid "$v" || return 1
  printf '%s' "$v"
}

get_ha_name() {
  f="/config/.storage/core.config"
  [ -f "$f" ] || { printf 'Home Assistant'; return 0; }
  n="$(sed -n 's/.*"location_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1 || true)"
  n="$(printf '%s' "$n" | tr -d '\r\n')"
  [ -n "$n" ] && printf '%s' "$n" || printf 'Home Assistant'
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

# ---- NODE ID ----
NODE_ID=""
if [ -f "$NODE_ID_FILE" ]; then
  NODE_ID="$(sanitize_uuid "$(cat "$NODE_ID_FILE" 2>/dev/null || true)")"
fi
if [ -z "${NODE_ID:-}" ] || ! valid_uuid "$NODE_ID"; then
  CORE_UUID="$(get_ha_core_uuid || true)"
  if [ -n "${CORE_UUID:-}" ] && valid_uuid "$CORE_UUID"; then
    NODE_ID="$CORE_UUID"
  else
    NODE_ID="$(gen_uuid)"
  fi
  printf '%s\n' "$NODE_ID" > "$NODE_ID_FILE"
fi

# ---- DEVICE SECRET ----
if [ ! -f "$SECRET_FILE" ]; then
  cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 > "$SECRET_FILE" || true
fi
DEVICE_SECRET="$(cat "$SECRET_FILE" 2>/dev/null | tr -d '\r\n' || true)"
[ -n "$DEVICE_SECRET" ] || { log "ERROR: device_secret missing"; exit 1; }

HA_NAME="$(get_ha_name)"

log "starting"
log "node_id: $NODE_ID"
log "ha_name: $HA_NAME"
log "HA upstream: homeassistant:${HA_PORT}"

# ---- REGISTER NODE (non-fatal, but keeps retrying) ----
register_once() {
  name_esc="$(json_escape "$HA_NAME")"
  payload="{\"node_id\":\"$NODE_ID\",\"device_secret\":\"$DEVICE_SECRET\",\"ha_name\":\"$name_esc\"}"
  code="$(curl -sS -o /tmp/reg.out -w '%{http_code}' -X POST "$REGISTER_URL" \
    -H 'Content-Type: application/json' -d "$payload" || true)"
  if [ "$code" = "200" ] || [ "$code" = "409" ]; then
    log "node register OK"
    return 0
  fi
  body="$(head -c 240 /tmp/reg.out 2>/dev/null || true)"
  log "node register failed (http $code) -> ${body:-"(no body)"}"
  return 1
}

# keep trying register in background loop, but don't block startup forever
( i=0; while true; do
    register_once && exit 0
    i=$((i+1))
    # backoff: 5s then 15s
    [ "$i" -lt 3 ] && sleep 5 || sleep 15
  done ) &

# ---- HEARTBEAT WAIT LOOP ----
hb_payload="{\"node_id\":\"$NODE_ID\"}"
while true; do
  hb_code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" \
    -H 'Content-Type: application/json' -d "$hb_payload" || true)"
  if [ "$hb_code" = "200" ] && grep -q '"allowed":true' /tmp/hb.out; then
    log "license status: allowed ✅"
    break
  fi
  log "not allowed yet (http $hb_code); retry in 15s"
  sleep 15
done

VHOST="${NODE_ID}${HA_SUBDOMAIN_SUFFIX}"
log "public url: https://${VHOST}/"

FRPC_TOML="${DATA_DIR}/frpc.toml"
cat > "$FRPC_TOML" <<TOML
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

auth.method = "oidc"
auth.oidc.clientID = "${NODE_ID}"
auth.oidc.clientSecret = "${DEVICE_SECRET}"
auth.oidc.audience = "frps"
auth.oidc.tokenEndpointURL = "${OIDC_TOKEN_URL}"

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "homeassistant"
localPort = ${HA_PORT}
customDomains = ["${VHOST}"]
TOML

log "starting frpc (will restart on failure)"
while true; do
  /usr/local/bin/frpc -c "$FRPC_TOML" || true
  log "frpc exited; retry in 10s"
  sleep 10
done
