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
SHARE_DIR="/share/cinexis"

NODE_ID_FILE_DATA="${DATA_DIR}/node_id"
NODE_ID_FILE_SHARE="${SHARE_DIR}/node_id"

SECRET_FILE_DATA="${DATA_DIR}/device_secret"
SECRET_FILE_SHARE="${SHARE_DIR}/device_secret"

FRPC_TOML="${DATA_DIR}/frpc.toml"

HA_HOST="${HA_HOST:-homeassistant}"
HA_PORT="${HA_PORT:-8123}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[cinexis] ERROR: missing $1"; exit 1; }; }
need curl
need sed
need tr

mkdir -p "$DATA_DIR" || true
if [ -d /share ]; then
  mkdir -p "$SHARE_DIR" || true
fi

uuid_ok() {
  echo "$1" | tr 'A-Z' 'a-z' | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid 2>/dev/null | tr 'A-Z' 'a-z'
    return 0
  fi
  h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
  echo "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}

atomic_write() {
  f="$1"
  v="$2"
  tmp="${f}.tmp.$$"
  printf "%s\n" "$v" > "$tmp"
  mv -f "$tmp" "$f"
}

read_first() {
  for f in "$@"; do
    if [ -s "$f" ]; then
      cat "$f" 2>/dev/null | tr -d '\r\n'
      return 0
    fi
  done
  return 1
}

# -------- node_id (prefer /share) --------
NODE_ID="$(read_first "$NODE_ID_FILE_SHARE" "$NODE_ID_FILE_DATA" || true)"
NODE_ID="$(echo "${NODE_ID:-}" | tr 'A-Z' 'a-z' | tr -d '\r\n')"

if ! uuid_ok "$NODE_ID"; then
  echo "[cinexis] node_id missing/corrupt -> generating new"
  NODE_ID="$(gen_uuid)"
  # write to share first (strongest persistence), then data
  if [ -d "$SHARE_DIR" ]; then atomic_write "$NODE_ID_FILE_SHARE" "$NODE_ID"; fi
  atomic_write "$NODE_ID_FILE_DATA" "$NODE_ID"
else
  # ensure both locations have it (copy forward)
  if [ -d "$SHARE_DIR" ] && [ ! -s "$NODE_ID_FILE_SHARE" ]; then atomic_write "$NODE_ID_FILE_SHARE" "$NODE_ID"; fi
  if [ ! -s "$NODE_ID_FILE_DATA" ]; then atomic_write "$NODE_ID_FILE_DATA" "$NODE_ID"; fi
fi

# -------- device_secret (prefer /share) --------
DEVICE_SECRET="$(read_first "$SECRET_FILE_SHARE" "$SECRET_FILE_DATA" || true)"
DEVICE_SECRET="$(echo "${DEVICE_SECRET:-}" | tr -d '\r\n')"

if [ -z "${DEVICE_SECRET:-}" ]; then
  echo "[cinexis] device_secret missing -> generating new"
  DEVICE_SECRET="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
  if [ -d "$SHARE_DIR" ]; then atomic_write "$SECRET_FILE_SHARE" "$DEVICE_SECRET"; fi
  atomic_write "$SECRET_FILE_DATA" "$DEVICE_SECRET"
else
  if [ -d "$SHARE_DIR" ] && [ ! -s "$SECRET_FILE_SHARE" ]; then atomic_write "$SECRET_FILE_SHARE" "$DEVICE_SECRET"; fi
  if [ ! -s "$SECRET_FILE_DATA" ]; then atomic_write "$SECRET_FILE_DATA" "$DEVICE_SECRET"; fi
fi

get_ha_name() {
  # No HA API perms needed: read HA's storage file (read-only)
  if [ -r /config/.storage/core.config ]; then
    n="$(tr -d '\n' </config/.storage/core.config \
      | sed -n 's/.*"location_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1 || true)"
    if [ -n "${n:-}" ]; then
      echo "$n"
      return
    fi
  fi
  # fallback
  hostname 2>/dev/null || echo "Home Assistant"
}

HA_NAME="$(get_ha_name)"

echo "[cinexis] starting"
echo "[cinexis] node_id: $NODE_ID"
echo "[cinexis] ha_name: $HA_NAME"
echo "[cinexis] HA upstream: ${HA_HOST}:${HA_PORT}"

# register loop
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

# best-effort name update
curl -fsS -m 5 -H 'Content-Type: application/json' \
  -d "$(printf '{"node_id":"%s","ha_name":"%s"}' "$NODE_ID" "$HA_NAME")" \
  "$NAME_URL" >/dev/null 2>&1 || true

# wait for license bind
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
