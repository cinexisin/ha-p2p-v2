#!/usr/bin/with-contenv bash
set -euo pipefail

log(){ echo "[cinexis] $*"; }

API_BASE="${CINEXIS_API_BASE:-https://api.cinexis.cloud}"

REGISTER_URL="${API_BASE}/licensing/v1/nodes/register"
HEARTBEAT_URL="${API_BASE}/licensing/v1/nodes/heartbeat"
OIDC_TOKEN_URL="${API_BASE}/frp/oidc/token"

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

HA_UPSTREAM_HOST="homeassistant"
HA_UPSTREAM_PORT="8123"

DATA_DIR="/data"
SHARE_DIR="/share/cinexis_remote"
mkdir -p "$DATA_DIR" || true

# Prefer /share for persistence
if mkdir -p "$SHARE_DIR" 2>/dev/null && [ -w "$SHARE_DIR" ]; then
  :
else
  SHARE_DIR="$DATA_DIR"
fi

NODE_ID_FILE="$SHARE_DIR/node_id"
SECRET_FILE="$SHARE_DIR/device_secret"

LOCK_DIR="$SHARE_DIR/lock"
LOCK_PID="$LOCK_DIR/pid"

is_uuid() { echo "$1" | grep -Eqi '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then tr 'A-Z' 'a-z' </proc/sys/kernel/random/uuid; return; fi
  h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32 || true)"
  echo "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}
gen_secret() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; }

atomic_write() { tmp="$(mktemp "$1.tmp.XXXXXX")"; printf '%s\n' "$2" >"$tmp"; mv -f "$tmp" "$1"; }

ensure_node_id() {
  v=""
  [ -s "$NODE_ID_FILE" ] && v="$(tr -d '\r\n' <"$NODE_ID_FILE" | tr 'A-Z' 'a-z')"
  if ! is_uuid "$v"; then
    v="$(gen_uuid)"
    is_uuid "$v" || { sleep 1; v="$(gen_uuid)"; }
    is_uuid "$v" || { log "FATAL: could not generate valid node_id"; exit 1; }
    atomic_write "$NODE_ID_FILE" "$v"
  fi
  echo "$v"
}

ensure_secret() {
  v=""
  [ -s "$SECRET_FILE" ] && v="$(tr -d '\r\n' <"$SECRET_FILE")"
  if [ "${#v}" -lt 32 ]; then
    v="$(gen_secret)"
    [ "${#v}" -ge 32 ] || { log "FATAL: could not generate device_secret"; exit 1; }
    atomic_write "$SECRET_FILE" "$v"
  fi
  echo "$v"
}

acquire_lock() {
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ >"$LOCK_PID"
      trap 'rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
      return
    fi
    oldpid="$(cat "$LOCK_PID" 2>/dev/null || true)"
    if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
      log "another instance already running; idling"
      while kill -0 "$oldpid" 2>/dev/null; do sleep 20; done
      continue
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    sleep 1
  done
}

get_ha_name() {
  f="/config/.storage/core.config"
  if [ -r "$f" ]; then
    name="$(grep -oE '"location_name"\s*:\s*"[^"]+"' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"location_name"\s*:\s*"([^"]+)".*/\1/' || true)"
    [ -n "${name:-}" ] && { echo "$name"; return; }
  fi
  echo "Home Assistant"
}

register_node_loop() {
  node_id="$1"; secret="$2"; ha_name="$3"
  payload="$(printf '{"node_id":"%s","device_secret":"%s","ha_name":"%s"}' "$node_id" "$secret" "$(echo "$ha_name" | sed 's/"/\\"/g')")"
  while true; do
    code="$(curl -sS -o /tmp/cinx_reg.out -w '%{http_code}' -X POST "$REGISTER_URL" -H 'Content-Type: application/json' -d "$payload" || echo 000)"
    if [ "$code" = "200" ] || [ "$code" = "409" ]; then
      log "node register OK"
      return
    fi
    log "node register failed (http $code); retry in 10s"
    sleep 10
  done
}

wait_allowed() {
  node_id="$1"
  while true; do
    code="$(curl -sS -o /tmp/cinx_hb.out -w '%{http_code}' -X POST "$HEARTBEAT_URL" -H 'Content-Type: application/json' -d "{\"node_id\":\"$node_id\"}" || echo 000)"
    if [ "$code" = "200" ] && grep -q '"allowed"[[:space:]]*:[[:space:]]*true' /tmp/cinx_hb.out 2>/dev/null; then
      log "license status: allowed ✅"
      return
    fi
    log "not allowed yet; retry in 15s"
    sleep 15
  done
}

pick_host_rewrite() {
  # Try to find a Host header HA accepts (prevents aiohttp 400)
  ha_ip="$(getent hosts "$HA_UPSTREAM_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
  candidates=()
  [ -n "${ha_ip:-}" ] && candidates+=("${ha_ip}:${HA_UPSTREAM_PORT}")
  candidates+=("127.0.0.1:${HA_UPSTREAM_PORT}" "localhost:${HA_UPSTREAM_PORT}" "${HA_UPSTREAM_HOST}:${HA_UPSTREAM_PORT}")

  for h in "${candidates[@]}"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 -H "Host: $h" "http://${HA_UPSTREAM_HOST}:${HA_UPSTREAM_PORT}/" || echo 000)"
    case "$code" in
      2*|3*)
        echo "$h"
        return
        ;;
    esac
  done

  # fallback
  echo "${HA_UPSTREAM_HOST}:${HA_UPSTREAM_PORT}"
}

main() {
  acquire_lock

  NODE_ID="$(ensure_node_id)"
  DEVICE_SECRET="$(ensure_secret)"
  HA_NAME="$(get_ha_name)"

  log "node_id: $NODE_ID"
  log "ha_name: $HA_NAME"
  log "HA upstream: ${HA_UPSTREAM_HOST}:${HA_UPSTREAM_PORT}"

  register_node_loop "$NODE_ID" "$DEVICE_SECRET" "$HA_NAME"
  wait_allowed "$NODE_ID"

  HOST_REWRITE="$(pick_host_rewrite)"
  log "hostHeaderRewrite: $HOST_REWRITE"

  VHOST="${NODE_ID}${HA_SUFFIX}"
  PROXY_NAME="ha_ui_${NODE_ID}"

  cat > /data/frpc.toml <<TOML
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

auth.method = "oidc"
auth.oidc.clientID = "${NODE_ID}"
auth.oidc.clientSecret = "${DEVICE_SECRET}"
auth.oidc.audience = "frps"
auth.oidc.tokenEndpointURL = "${OIDC_TOKEN_URL}"

[[proxies]]
name = "${PROXY_NAME}"
type = "http"
localIP = "${HA_UPSTREAM_HOST}"
localPort = ${HA_UPSTREAM_PORT}
customDomains = ["${VHOST}"]

# rewrite Host to something HA accepts (auto-detected)
hostHeaderRewrite = "${HOST_REWRITE}"

# force single forwarded values (avoid aiohttp 400 on duplicates)
requestHeaders.set.x-forwarded-for = "127.0.0.1"
requestHeaders.set.x-real-ip = "127.0.0.1"
requestHeaders.set.x-forwarded-proto = "https"
requestHeaders.set.x-forwarded-host = "${HOST_REWRITE}"
TOML

  log "public url: https://${VHOST}/"

  while true; do
    log "starting frpc"
    /usr/local/bin/frpc -c /data/frpc.toml || true
    sleep 5
  done
}

main "$@"
