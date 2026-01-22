#!/usr/bin/env sh
set -eu

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

OIDC_TOKEN_URL="https://api.cinexis.cloud/frp/oidc/token"
CLAIM_URL="https://api.cinexis.cloud/licensing/v1/licenses/claim"
HEARTBEAT_URL="https://api.cinexis.cloud/licensing/v1/nodes/heartbeat"

DATA_DIR="/data"
NODE_ID_FILE="$DATA_DIR/node_id"
SECRET_FILE="$DATA_DIR/device_secret"
FRPC_TOML="$DATA_DIR/frpc.toml"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }

need curl
need sed
need tr

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
    echo "${h}" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

mkdir -p "$DATA_DIR"

if [ ! -f "$NODE_ID_FILE" ]; then
  gen_uuid > "$NODE_ID_FILE"
fi
NODE_ID="$(tr -d '\r\n' <"$NODE_ID_FILE" | tr 'A-Z' 'a-z')"

if [ ! -f "$SECRET_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 > "$SECRET_FILE"
fi
DEVICE_SECRET="$(tr -d '\r\n' <"$SECRET_FILE")"

DEBUG_PRINT_SECRET="false"
if [ -f /data/options.json ]; then
  DEBUG_PRINT_SECRET="$(sed -n 's/.*"debug_print_secret"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' /data/options.json | head -n 1)"
fi
if [ "${DEBUG_PRINT_SECRET:-false}" = "true" ]; then
  echo "=== DEBUG: device_secret (copy this) ==="
  echo "$DEVICE_SECRET"
  echo "=== END DEBUG ==="
  echo "Turn off debug_print_secret after copying."
  exit 0
fi

LICENSE_KEY=""
if [ -f /data/options.json ]; then
  LICENSE_KEY="$(sed -n 's/.*"license_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /data/options.json | head -n 1)"
fi
if [ -z "${LICENSE_KEY}" ]; then
  echo "ERROR: license_key is not set in add-on options (/data/options.json)."
  echo "Set it and restart the add-on."
  exit 1
fi

HA_HOST=""
HA_PORT=""
if [ -f /data/options.json ]; then
  HA_HOST="$(sed -n 's/.*"ha_host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /data/options.json | head -n 1 || true)"
  HA_PORT="$(sed -n 's/.*"ha_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' /data/options.json | head -n 1 || true)"
fi

HA_HOST="${HA_HOST:-homeassistant}"
HA_PORT="${HA_PORT:-8123}"

probe() { curl -fsS --max-time 2 "http://$1:$2/" >/dev/null 2>&1; }

if probe "$HA_HOST" "$HA_PORT"; then
  :
elif probe "homeassistant" "8123"; then
  HA_HOST="homeassistant"
  HA_PORT="8123"
elif probe "127.0.0.1" "8123"; then
  HA_HOST="127.0.0.1"
  HA_PORT="8123"
else
  echo "ERROR: Cannot reach Home Assistant UI from inside the add-on."
  echo "Tried: ${HA_HOST}:${HA_PORT}, homeassistant:8123, 127.0.0.1:8123"
  exit 1
fi

echo "Cinexis node_id: $NODE_ID"
echo "==> HA upstream selected: ${HA_HOST}:${HA_PORT}"

echo "==> Claiming license (idempotent)"
claim_payload="$(printf '{"license_key":"%s","node_id":"%s","device_secret":"%s"}' "$LICENSE_KEY" "$NODE_ID" "$DEVICE_SECRET")"
http_code="$(curl -sS -o /tmp/claim.out -w '%{http_code}' -X POST "$CLAIM_URL" -H 'Content-Type: application/json' -d "$claim_payload" || true)"
if [ "$http_code" = "200" ] || [ "$http_code" = "409" ]; then
  echo "License claim OK (http $http_code)"
else
  echo "ERROR: license claim failed (http $http_code)"
  cat /tmp/claim.out || true
  exit 1
fi

echo "==> Heartbeat check"
hb_payload="$(printf '{"node_id":"%s"}' "$NODE_ID")"
hb_code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" -H 'Content-Type: application/json' -d "$hb_payload" || true)"
if [ "$hb_code" != "200" ]; then
  echo "ERROR: heartbeat failed (http $hb_code)"
  cat /tmp/hb.out || true
  exit 1
fi
if grep -q '"allowed":true' /tmp/hb.out; then
  echo "License status: allowed ✅"
else
  echo "ERROR: license status not allowed:"
  cat /tmp/hb.out || true
  exit 1
fi

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
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${VHOST}"]
TOML

echo "==> Starting frpc with OIDC auth"
exec /usr/local/bin/frpc -c "$FRPC_TOML"
