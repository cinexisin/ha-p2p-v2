#!/usr/bin/with-contenv sh
set -eu

log(){ echo "[cinexis] $*"; }

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_PORT="${HA_PORT:-8123}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

API_BASE="${API_BASE:-https://api.cinexis.cloud}"
REGISTER_URL="${API_BASE}/licensing/v1/nodes/register"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"
OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"

DATA_DIR="/data"
NODE_ID_FILE="$DATA_DIR/node_id"
SECRET_FILE="$DATA_DIR/device_secret"
FRPC_TOML="$DATA_DIR/frpc.toml"

need(){ command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing $1"; exit 1; }; }
need curl; need sed; need tr

opt_bool() {
  key="$1"; def="${2:-false}"
  [ -f /data/options.json ] || { echo "$def"; return 0; }
  v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p" /data/options.json | head -n 1)"
  echo "${v:-$def}"
}
opt_int() {
  key="$1"; def="${2:-15}"
  [ -f /data/options.json ] || { echo "$def"; return 0; }
  v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" /data/options.json | head -n 1)"
  echo "${v:-$def}"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
    echo "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
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

RETRY_SECS="$(opt_int retry_seconds 15)"
AUTO_WAIT="$(opt_bool auto_wait_for_license true)"
DEBUG_PRINT_SECRET="$(opt_bool debug_print_secret false)"

log "starting"
log "node_id: $NODE_ID"

if [ "$DEBUG_PRINT_SECRET" = "true" ]; then
  log "DEBUG device_secret (copy):"
  echo "$DEVICE_SECRET"
  log "Turn off debug_print_secret after copying."
  exit 0
fi

# HA upstream autodetect (no host_network)
HASS_UPSTREAM="homeassistant"
if curl -fsS --max-time 2 "http://homeassistant:${HA_PORT}/" >/dev/null 2>&1; then
  :
else
  GW="$( (command -v ip >/dev/null 2>&1 && ip route 2>/dev/null | sed -n 's/^default via \([^ ]*\).*/\1/p' | head -n1) || true )"
  if [ -n "${GW:-}" ] && curl -fsS --max-time 2 "http://${GW}:${HA_PORT}/" >/dev/null 2>&1; then
    HASS_UPSTREAM="$GW"
  fi
fi
log "HA upstream selected: ${HASS_UPSTREAM}:${HA_PORT}"

# Register node (non-fatal if endpoint not deployed yet)
reg_payload="$(printf '{"node_id":"%s","device_secret":"%s"}' "$NODE_ID" "$DEVICE_SECRET")"
reg_code="$(curl -sS -o /tmp/reg.out -w '%{http_code}' -X POST "$REGISTER_URL" \
  -H 'Content-Type: application/json' -d "$reg_payload" || true)"
if [ "$reg_code" = "200" ] || [ "$reg_code" = "201" ] || [ "$reg_code" = "409" ]; then
  log "node register OK (http $reg_code)"
else
  log "node register failed (http $reg_code) (continuing)"
fi

# Wait until server assigns license to this node_id
log "heartbeat wait loop (server must assign license to node_id)"
while :; do
  hb_payload="$(printf '{"node_id":"%s"}' "$NODE_ID")"
  hb_code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" \
    -H 'Content-Type: application/json' -d "$hb_payload" || true)"

  if [ "$hb_code" = "200" ] && grep -q '"allowed":true' /tmp/hb.out 2>/dev/null; then
    log "license status: allowed ✅"
    break
  fi

  if [ "$AUTO_WAIT" != "true" ]; then
    log "not allowed and auto_wait_for_license=false -> exiting"
    exit 1
  fi

  log "not allowed yet (http ${hb_code}); retry in ${RETRY_SECS}s"
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

FRPC_BIN="/usr/local/bin/frpc"
[ -x "$FRPC_BIN" ] || FRPC_BIN="/usr/bin/frpc"
[ -x "$FRPC_BIN" ] || { log "ERROR: frpc not found"; exit 1; }

log "starting frpc (auto-restart loop)"
while :; do
  "$FRPC_BIN" -c "$FRPC_TOML" || true
  log "frpc exited; restarting in ${RETRY_SECS}s"
  sleep "$RETRY_SECS"
done
