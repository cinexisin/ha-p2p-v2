#!/usr/bin/env sh
set -eu

API_BASE="${API_BASE:-https://api.cinexis.cloud}"
FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"
REGISTER_URL="${API_BASE}/licensing/v1/nodes/register"
NAME_URL="${API_BASE}/licensing/v1/nodes/name"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"

DATA_DIR="/data"
NODE_ID_FILE="$DATA_DIR/node_id"
SECRET_FILE="$DATA_DIR/device_secret"
FRPC_TOML="$DATA_DIR/frpc.toml"

HA_HOST="${HA_HOST:-homeassistant}"
HA_PORT="${HA_PORT:-8123}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[cinexis] ERROR: missing $1"; exit 1; }; }
need curl
need sed
need tr

uuid_ok() {
  echo "$1" | tr 'A-Z' 'a-z' | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid 2>/dev/null | tr 'A-Z' 'a-z'
    return 0
  fi
  # fallback: 32 hex -> uuid format
  h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
  echo "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}

mkdir -p "$DATA_DIR"

if [ ! -f "$NODE_ID_FILE" ]; then
  gen_uuid > "$NODE_ID_FILE"
fi
NODE_ID="$(cat "$NODE_ID_FILE" 2>/dev/null | tr -d '\r\n' | tr 'A-Z' 'a-z' || true)"

# If node_id ever got corrupted (you saw "cinexis error: line=32..." earlier), regenerate cleanly
if ! uuid_ok "$NODE_ID"; then
  echo "[cinexis] WARNING: node_id corrupted; regenerating"
  gen_uuid > "$NODE_ID_FILE"
  NODE_ID="$(cat "$NODE_ID_FILE" | tr -d '\r\n' | tr 'A-Z' 'a-z')"
fi

if [ ! -f "$SECRET_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 > "$SECRET_FILE"
fi
DEVICE_SECRET="$(cat "$SECRET_FILE" | tr -d '\r\n')"

get_ha_name() {
  # Uses Home Assistant API token injected by homeassistant_api: true
  if [ -n "${HOMEASSISTANT_TOKEN:-}" ]; then
    n="$(curl -fsSL --connect-timeout 3 \
      -H "Authorization: Bearer ${HOMEASSISTANT_TOKEN}" \
      "http://${HA_HOST}:${HA_PORT}/api/config" 2>/dev/null \
      | tr -d '\n' \
      | sed -n 's/.*"location_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1 || true)"
    [ -n "${n:-}" ] && echo "$n" && return
  fi
  hostname 2>/dev/null || echo "Home Assistant"
}

HA_NAME="$(get_ha_name)"

echo "[cinexis] starting"
echo "[cinexis] node_id: $NODE_ID"
echo "[cinexis] ha_name: $HA_NAME"
echo "[cinexis] HA upstream: ${HA_HOST}:${HA_PORT}"

# Register node (store secret + ha_name on server)
while true; do
  code="$(curl -sS -o /tmp/register.out -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"node_id":"%s","device_secret":"%s","ha_name":"%s"}' "$NODE_ID" "$DEVICE_SECRET" "$HA_NAME")" \
    "$REGISTER_URL" || true)"
  if [ "$code" = "200" ]; then
    echo "[cinexis] node register OK"
    break
  fi
  echo "[cinexis] node register failed (http $code) -> $(head -c 200 /tmp/register.out 2>/dev/null || true)"
  sleep 10
done

# Update name (best-effort)
curl -fsS -m 5 -H 'Content-Type: application/json' \
  -d "$(printf '{"node_id":"%s","ha_name":"%s"}' "$NODE_ID" "$HA_NAME")" \
  "$NAME_URL" >/dev/null 2>&1 || true

# Wait for license assignment (admin binds a license to node_id)
while true; do
  hb_code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"node_id":"%s"}' "$NODE_ID")" \
    "$HEARTBEAT_URL" || true)"
  if [ "$hb_code" = "200" ] && grep -q '"allowed":true' /tmp/hb.out; then
    echo "[cinexis] license status: allowed ✅"
    break
  fi
  echo "[cinexis] not allowed yet (http $hb_code); retry in 15s"
  sleep 15
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
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${VHOST}"]
TOML

echo "[cinexis] public url: https://${VHOST}/"
exec /usr/local/bin/frpc -c "$FRPC_TOML"
