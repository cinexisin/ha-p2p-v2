#!/usr/bin/env sh
set -eu

# --- endpoints ---
API_BASE="${API_BASE:-https://api.cinexis.cloud}"
REGISTER_URL="${API_BASE}/licensing/v1/nodes/register"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"
OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

# --- timings ---
WAIT_ALLOWED_SLEEP="${WAIT_ALLOWED_SLEEP:-15}"
DAILY_HEARTBEAT_SECONDS="${DAILY_HEARTBEAT_SECONDS:-86400}"

# --- dirs ---
PERSIST_DIR="/share/cinexis"
DATA_DIR="/data"
mkdir -p "$PERSIST_DIR" "$DATA_DIR"

NODE_ID_FILE="${PERSIST_DIR}/node_id"
SECRET_FILE="${PERSIST_DIR}/device_secret"

# IMPORTANT: lock MUST be ephemeral (NOT in /share or /data)
LOCKDIR="/tmp/cinexis.lock"
LOCKPID="${LOCKDIR}/pid"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[cinexis] ERROR: missing $1"; exit 1; }; }
need curl
need sed
need tr

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    h="$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)"
    echo "${h}" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}

acquire_lock() {
  # fast path
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$LOCKPID"
    return 0
  fi

  # stale lock check
  if [ -f "$LOCKPID" ]; then
    oldpid="$(cat "$LOCKPID" 2>/dev/null || true)"
    if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
      return 1
    fi
  fi

  # stale -> remove and retry
  rm -rf "$LOCKDIR" 2>/dev/null || true
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$LOCKPID"
    return 0
  fi
  return 1
}

if ! acquire_lock; then
  echo "[cinexis] another instance already running; idling (prevents duplicate frpc/proxy)"
  # keep container alive without consuming CPU
  while true; do sleep 3600; done
fi

# Clean lock on normal exit paths (if we exec frpc, pid will die and lock becomes stale anyway)
trap 'rm -rf "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM

# --- identity ---
if [ ! -f "$NODE_ID_FILE" ]; then
  gen_uuid > "$NODE_ID_FILE"
fi
NODE_ID="$(cat "$NODE_ID_FILE" | tr -d '\r\n' | tr 'A-Z' 'a-z')"

if [ ! -f "$SECRET_FILE" ]; then
  cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 > "$SECRET_FILE"
fi
DEVICE_SECRET="$(cat "$SECRET_FILE" | tr -d '\r\n')"

# --- get Home Assistant NAME (location_name) via Supervisor proxy ---
# This is the HA UI "Name", NOT Linux hostname.
HA_NAME=""
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
  HA_NAME="$(curl -sS --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    http://supervisor/core/api/config 2>/dev/null \
    | sed -n 's/.*"location_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
fi
HA_NAME="$(printf "%s" "$HA_NAME" | tr -d '\r\n')"
[ -n "$HA_NAME" ] || HA_NAME="Home Assistant"

echo "[cinexis] starting"
echo "[cinexis] node_id: ${NODE_ID}"
echo "[cinexis] ha_name: ${HA_NAME}"
echo "[cinexis] HA upstream: homeassistant:8123"

# --- register node (idempotent) ---
register_node() {
  payload="$(printf '{"node_id":"%s","device_secret":"%s","ha_name":"%s"}' "$NODE_ID" "$DEVICE_SECRET" "$HA_NAME")"
  code="$(curl -sS -o /tmp/node_reg.out -w '%{http_code}' \
    -X POST "$REGISTER_URL" -H 'Content-Type: application/json' -d "$payload" || true)"
  if [ "$code" = "200" ] || [ "$code" = "409" ]; then
    echo "[cinexis] node register OK"
    return 0
  fi
  echo "[cinexis] node register failed (http $code) -> $(cat /tmp/node_reg.out 2>/dev/null || true)"
  return 1
}

heartbeat_once() {
  # include ha_name so server can update it (even if register was missed)
  payload="$(printf '{"node_id":"%s","ha_name":"%s"}' "$NODE_ID" "$HA_NAME")"
  code="$(curl -sS -o /tmp/hb.out -w '%{http_code}' \
    -X POST "$HEARTBEAT_URL" -H 'Content-Type: application/json' -d "$payload" || true)"
  echo "$code"
}

wait_until_allowed() {
  while true; do
    register_node || true

    hb_code="$(heartbeat_once)"
    if [ "$hb_code" = "200" ] && grep -q '"allowed":[[:space:]]*true' /tmp/hb.out 2>/dev/null; then
      echo "[cinexis] license status: allowed ✅"
      return 0
    fi

    echo "[cinexis] not allowed yet (http $hb_code); retry in ${WAIT_ALLOWED_SLEEP}s"
    sleep "$WAIT_ALLOWED_SLEEP"
  done
}

# --- write FRPC config ---
write_frpc() {
  FRPC_TOML="$DATA_DIR/frpc.toml"
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
name = "ha_ui_${NODE_ID}"
type = "http"
localIP = "homeassistant"
localPort = 8123
customDomains = ["${VHOST}"]
TOML

  echo "[cinexis] public url: https://${VHOST}/"
}

# --- background daily heartbeat/meta refresh ---
daily_heartbeat_loop() {
  while true; do
    sleep "$DAILY_HEARTBEAT_SECONDS"
    hb_code="$(heartbeat_once)"
    if [ "$hb_code" = "200" ]; then
      echo "[cinexis] daily heartbeat OK"
    else
      echo "[cinexis] daily heartbeat failed (http $hb_code)"
    fi
  done
}

# --- main ---
wait_until_allowed
write_frpc

daily_heartbeat_loop &

echo "[cinexis] starting frpc (will restart on failure)"
while true; do
  /usr/local/bin/frpc -c "$DATA_DIR/frpc.toml" || true
  echo "[cinexis] frpc exited; restarting in 5s"
  sleep 5
done
