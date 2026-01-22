#!/usr/bin/with-contenv bash
set -euo pipefail

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

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
need curl; need sed; need tr; need awk

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

echo "Cinexis node_id: $NODE_ID"

# HA upstream: prefer Supervisor DNS name "homeassistant"
HASS_UPSTREAM="homeassistant"
if curl -fsS --max-time 2 "http://homeassistant:${HA_PORT}/" >/dev/null 2>&1; then
  :
else
  GW="$(ip route | awk '/default/ {print $3; exit}' || true)"
  if [ -n "${GW:-}" ] && curl -fsS --max-time 2 "http://${GW}:${HA_PORT}/" >/dev/null 2>&1; then
    HASS_UPSTREAM="$GW"
  fi
fi
echo "==> HA upstream selected: ${HASS_UPSTREAM}:${HA_PORT}"

DEBUG_PRINT_SECRET="$(opt_bool debug_print_secret false)"
if [ "$DEBUG_PRINT_SECRET" = "true" ]; then
  echo "=== DEBUG: device_secret (copy this) ==="
  echo "$DEVICE_SECRET"
  echo "=== END DEBUG ==="
  echo "Turn off debug_print_secret after copying."
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
    echo "License claim OK (http $code)"
    printf '%s\n' "$LICENSE_KEY" > "$LICENSE_CACHE"
    return 0
  fi
  echo "Claim failed (http $code):"
  [ -f /tmp/claim.out ] && cat /tmp/claim.out || true
  return 1
}

heartbeat_once() {
  local payload code
  payload="$(printf '{"node_id":"%s"}' "$NODE_ID")"
  code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" \
    -H 'Content-Type: application/json' -d "$payload" || true)"
  if [ "$code" != "200" ]; then
    echo "Heartbeat failed (http $code)"
    [ -f /tmp/hb.out ] && cat /tmp/hb.out || true
    return 2
  fi
  if grep -q '"allowed":true' /tmp/hb.out; then
    echo "License status: allowed ✅"
    return 0
  fi
  echo "License status: NOT allowed yet."
  cat /tmp/hb.out || true
  return 1
}

if [ -n "${LICENSE_KEY:-}" ]; then
  echo "==> Claiming license (idempotent)"
  for i in 1 2 3 4 5; do
    if claim_once; then break; fi
    echo "Retrying claim in ${RETRY_SECS}s... (attempt $i/5)"
    sleep "$RETRY_SECS"
  done
else
  echo "==> No license_key set. Using node-based licensing."
  echo "==> Assign a license to this node_id in Cinexis Console:"
  echo "    node_id=$NODE_ID"
fi

echo "==> Heartbeat check"
while true; do
  set +e
  heartbeat_once
  rc=$?
  set -e
  if [ "$rc" = "0" ]; then
    break
  fi
  if [ "$AUTO_WAIT" != "true" ]; then
    echo "ERROR: Not allowed and auto_wait_for_license=false. Exiting."
    exit 1
  fi
  echo "Waiting ${RETRY_SECS}s for license to be assigned..."
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

echo "==> Starting frpc with OIDC auth"
exec /usr/local/bin/frpc -c "$FRPC_TOML"
