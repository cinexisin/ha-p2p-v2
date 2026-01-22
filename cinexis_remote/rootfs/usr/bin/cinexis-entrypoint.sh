#!/usr/bin/with-contenv bash
set -Eeuo pipefail

trap 'echo "Cinexis ERROR: line=$LINENO exit=$?"; exit 1' ERR

log(){ echo "[cinexis] $*"; }

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_PORT="${HA_PORT:-8123}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

API_BASE="${API_BASE:-https://api.cinexis.cloud}"
OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"
CLAIM_URL="${API_BASE}/licensing/v1/licenses/claim"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"

DATA_DIR="/data"
NODE_ID_FILE="$DATA_DIR/node_id"
SECRET_FILE="$DATA_DIR/device_secret"
LICENSE_CACHE="$DATA_DIR/license_key"
FRPC_TOML="$DATA_DIR/frpc.toml"

need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing $1"; exit 1; }; }
need curl; need sed; need tr

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    local h
    h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
    echo "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

opt_string() {
  local key="$1"
  [ -f /data/options.json ] || { echo ""; return 0; }
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" /data/options.json | head -n1
}
opt_bool() {
  local key="$1" def="${2:-false}"
  [ -f /data/options.json ] || { echo "$def"; return 0; }
  local v
  v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p" /data/options.json | head -n1)"
  echo "${v:-$def}"
}
opt_int() {
  local key="$1" def="${2:-0}"
  [ -f /data/options.json ] || { echo "$def"; return 0; }
  local v
  v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" /data/options.json | head -n1)"
  echo "${v:-$def}"
}

mkdir -p "$DATA_DIR"

if [ ! -s "$NODE_ID_FILE" ]; then
  gen_uuid > "$NODE_ID_FILE"
fi
NODE_ID="$(tr -d '\r\n' < "$NODE_ID_FILE" | tr 'A-Z' 'a-z')"

if [ ! -s "$SECRET_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 > "$SECRET_FILE"
fi
DEVICE_SECRET="$(tr -d '\r\n' < "$SECRET_FILE")"

log "entrypoint starting"
log "node_id: $NODE_ID"

# Determine HA upstream (prefer Supervisor DNS)
HASS_UPSTREAM="homeassistant"
if curl -fsS --max-time 2 "http://homeassistant:${HA_PORT}/" >/dev/null 2>&1; then
  :
else
  # gateway fallback (best-effort; don't fail if ip is missing)
  GW="$( (command -v ip >/dev/null 2>&1 && ip route 2>/dev/null | sed -n 's/^default via \([^ ]*\).*/\1/p' | head -n1) || true )"
  if [ -n "${GW:-}" ] && curl -fsS --max-time 2 "http://${GW}:${HA_PORT}/" >/dev/null 2>&1; then
    HASS_UPSTREAM="$GW"
  fi
fi
log "HA upstream selected: ${HASS_UPSTREAM}:${HA_PORT}"

DEBUG_PRINT_SECRET="$(opt_bool debug_print_secret false)"
if [ "$DEBUG_PRINT_SECRET" = "true" ]; then
  log "DEBUG device_secret:"
  echo "$DEVICE_SECRET"
  log "Turn off debug_print_secret after copying."
  exit 0
fi

AUTO_WAIT="$(opt_bool auto_wait_for_license true)"
RETRY_SECS="$(opt_int retry_seconds 15)"

LICENSE_KEY="$(opt_string license_key)"
if [ -z "${LICENSE_KEY:-}" ] && [ -s "$LICENSE_CACHE" ]; then
  LICENSE_KEY="$(tr -d '\r\n' < "$LICENSE_CACHE")"
fi

claim_once() {
  local payload code
  payload="$(printf '{"license_key":"%s","node_id":"%s","device_secret":"%s"}' "$LICENSE_KEY" "$NODE_ID" "$DEVICE_SECRET")"
  code="$(curl -sS -o /tmp/claim.out -w '%{http_code}' -X POST "$CLAIM_URL" \
    -H 'Content-Type: application/json' -d "$payload" || true)"
  if [ "$code" = "200" ] || [ "$code" = "409" ]; then
    log "License claim OK (http $code)"
    printf '%s\n' "$LICENSE_KEY" > "$LICENSE_CACHE"
    return 0
  fi
  log "Claim failed (http $code)"
  [ -f /tmp/claim.out ] && cat /tmp/claim.out || true
  return 1
}

heartbeat_once() {
  local payload code
  payload="$(printf '{"node_id":"%s"}' "$NODE_ID")"
  code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" \
    -H 'Content-Type: application/json' -d "$payload" || true)"
  if [ "$code" != "200" ]; then
    log "Heartbeat failed (http $code)"
    [ -f /tmp/hb.out ] && cat /tmp/hb.out || true
    return 2
  fi
  if grep -q '"allowed":true' /tmp/hb.out; then
    log "License status: allowed ✅"
    return 0
  fi
  log "License status: NOT allowed yet"
  cat /tmp/hb.out || true
  return 1
}

if [ -n "${LICENSE_KEY:-}" ]; then
  log "Claiming license (idempotent)"
  for i in 1 2 3 4 5; do
    if claim_once; then break; fi
    log "Retrying claim in ${RETRY_SECS}s (attempt $i/5)"
    sleep "$RETRY_SECS"
  done
else
  log "No license_key set. Node-based licensing mode."
  log "Assign a license to node_id in console: $NODE_ID"
fi

log "Heartbeat check"
while true; do
  set +e
  heartbeat_once
  rc=$?
  set -e

  if [ "$rc" = "0" ]; then
    break
  fi

  if [ "$AUTO_WAIT" != "true" ]; then
    log "Not allowed and auto_wait_for_license=false. Exiting."
    exit 1
  fi

  log "Waiting ${RETRY_SECS}s for license / API availability..."
  sleep "$RETRY_SECS"
done

VHOST="${NODE_ID}${HA_SUBDOMAIN_SUFFIX}"

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
localIP = "${HASS_UPSTREAM}"
localPort = ${HA_PORT}
customDomains = ["${VHOST}"]
TOML

# Locate frpc binary safely
FRPC_BIN="/usr/local/bin/frpc"
[ -x "$FRPC_BIN" ] || FRPC_BIN="/usr/bin/frpc"
[ -x "$FRPC_BIN" ] || { log "ERROR: frpc not found"; ls -ლა /usr/local/bin /usr/bin || true; exit 1; }

log "Starting frpc (auto-restart loop enabled)"
while true; do
  set +e
  "$FRPC_BIN" -c "$FRPC_TOML"
  rc=$?
  set -e
  log "frpc exited (rc=$rc). Restarting in ${RETRY_SECS}s..."
  sleep "$RETRY_SECS"
done
