#!/usr/bin/with-contenv bash
set -u
set -o pipefail

log(){ echo "[cinexis] $*"; }

DATA_DIR="/data"
NODE_ID_FILE="$DATA_DIR/node_id"
SECRET_FILE="$DATA_DIR/device_secret"
FRPC_TOML="$DATA_DIR/frpc.toml"

API_BASE_DEFAULT="https://api.cinexis.cloud"
FRPS_ADDR_DEFAULT="139.99.56.240"
FRPS_PORT_DEFAULT="7000"
HA_PORT_DEFAULT="8123"
HA_SUFFIX_DEFAULT=".ha.cinexis.cloud"

mkdir -p "$DATA_DIR"

# ---- single instance lock (prevents duplicate frpc/proxy) ----
LOCKDIR="/tmp/cinexis.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  log "another Cinexis process already running; staying alive"
  while true; do sleep 3600; done
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

# ---- minimal /data/options.json reader (no jq) ----
opt_str() {
  local key="$1" def="${2:-}"
  if [ -f /data/options.json ]; then
    local v
    v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" /data/options.json | head -n 1 || true)"
    if [ -n "${v:-}" ]; then echo "$v"; else echo "$def"; fi
  else
    echo "$def"
  fi
}
opt_int() {
  local key="$1" def="${2:-}"
  if [ -f /data/options.json ]; then
    local v
    v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\([0-9]\\+\\).*/\\1/p" /data/options.json | head -n 1 || true)"
    if [ -n "${v:-}" ]; then echo "$v"; else echo "$def"; fi
  else
    echo "$def"
  fi
}
opt_bool() {
  local key="$1" def="${2:-false}"
  if [ -f /data/options.json ]; then
    local v
    v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p" /data/options.json | head -n 1 || true)"
    if [ -n "${v:-}" ]; then echo "$v"; else echo "$def"; fi
  else
    echo "$def"
  fi
}

API_BASE="$(opt_str api_base "$API_BASE_DEFAULT")"
FRPS_ADDR="$(opt_str frps_addr "$FRPS_ADDR_DEFAULT")"
FRPS_PORT="$(opt_int frps_port "$FRPS_PORT_DEFAULT")"
HA_PORT="$(opt_int ha_port "$HA_PORT_DEFAULT")"
HA_SUBDOMAIN_SUFFIX="$(opt_str ha_subdomain_suffix "$HA_SUFFIX_DEFAULT")"
DEBUG_PRINT_SECRET="$(opt_bool debug_print_secret false)"

OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"
REGISTER_URL="${API_BASE}/licensing/v1/nodes/register"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    local h
    h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32 || true)"
    echo "${h}" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

if [ ! -s "$NODE_ID_FILE" ]; then
  gen_uuid > "$NODE_ID_FILE"
fi
NODE_ID="$(tr -d '\r\n' < "$NODE_ID_FILE" | tr 'A-Z' 'a-z')"

if [ ! -s "$SECRET_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 > "$SECRET_FILE" || true
fi
DEVICE_SECRET="$(tr -d '\r\n' < "$SECRET_FILE")"

if [ "${DEBUG_PRINT_SECRET:-false}" = "true" ]; then
  echo "=== DEBUG ==="
  echo "node_id: $NODE_ID"
  echo "device_secret: $DEVICE_SECRET"
  echo "=== END DEBUG ==="
  exit 0
fi

log "starting"
log "node_id: $NODE_ID"

# HA upstream detection (Supervisor DNS)
HASS_HOST="homeassistant"
check_upstream() { curl -fsS --max-time 2 "http://${1}:${HA_PORT}/" >/dev/null 2>&1; }

if ! check_upstream "$HASS_HOST"; then
  GW="$(ip route | awk '/default/ {print $3; exit}' || true)"
  if [ -n "${GW:-}" ] && check_upstream "$GW"; then
    HASS_HOST="$GW"
  fi
fi
log "HA upstream selected: ${HASS_HOST}:${HA_PORT}"

# register node (best-effort, continue on failure)
register_once() {
  local payload code
  payload="$(printf '{"node_id":"%s","device_secret":"%s"}' "$NODE_ID" "$DEVICE_SECRET")"
  code="$(curl -sS -o /tmp/register.out -w '%{http_code}' -X POST "$REGISTER_URL" -H 'Content-Type: application/json' -d "$payload" || true)"
  if [ "$code" = "200" ] || [ "$code" = "409" ]; then
    log "node register OK (http $code)"
    return 0
  fi
  log "node register failed (http $code) -> $(head -c 200 /tmp/register.out 2>/dev/null || true)"
  return 1
}
register_once || true

# wait for license binding by server
while true; do
  hb_payload="$(printf '{"node_id":"%s"}' "$NODE_ID")"
  hb_code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" -H 'Content-Type: application/json' -d "$hb_payload" || true)"
  if [ "$hb_code" = "200" ] && grep -q '"allowed":true' /tmp/hb.out; then
    log "license status: allowed ✅"
    break
  fi
  log "not allowed yet (http $hb_code); retry in 15s"
  sleep 15
done

log "public url: https://${NODE_ID}${HA_SUBDOMAIN_SUFFIX}/"

cat > "$FRPC_TOML" <<TOML
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}
loginFailExit = true

auth.method = "oidc"
auth.oidc.clientID = "${NODE_ID}"
auth.oidc.clientSecret = "${DEVICE_SECRET}"
auth.oidc.audience = "frps"
auth.oidc.tokenEndpointURL = "${OIDC_TOKEN_URL}"

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "${HASS_HOST}"
localPort = ${HA_PORT}
customDomains = ["${NODE_ID}${HA_SUBDOMAIN_SUFFIX}"]
TOML

while true; do
  log "starting frpc (single instance)"
  /usr/local/bin/frpc -c "$FRPC_TOML"
  rc=$?
  log "frpc exited rc=$rc; restarting in 5s"
  sleep 5
done
