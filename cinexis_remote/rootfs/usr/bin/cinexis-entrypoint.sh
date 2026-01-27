#!/usr/bin/with-contenv bash
set -euo pipefail
log(){ echo "[cinexis] $*"; }

API="https://api.cinexis.cloud"
REGISTER_URL="${API}/licensing/v1/nodes/register"
HEARTBEAT_URL="${API}/licensing/v1/nodes/heartbeat"
OIDC_TOKEN_URL="${API}/frp/oidc/token"

FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

HA_HOST="homeassistant"
HA_PORT="8123"

# Local nginx strip proxy target
NGX_PORT="18080"

DATA_DIR="/data"
SHARE_DIR="/share/cinexis_remote"
mkdir -p "$DATA_DIR" || true
if mkdir -p "$SHARE_DIR" 2>/dev/null && [ -w "$SHARE_DIR" ]; then :; else SHARE_DIR="$DATA_DIR"; fi

NODE_ID_FILE="$SHARE_DIR/node_id"
SECRET_FILE="$SHARE_DIR/device_secret"

LOCK_DIR="$SHARE_DIR/lock"
LOCK_PID="$LOCK_DIR/pid"

is_uuid(){ echo "$1" | grep -Eqi '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
gen_uuid(){ tr 'A-Z' 'a-z' </proc/sys/kernel/random/uuid; }
gen_secret(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; }
atomic_write(){ tmp="$(mktemp "$1.tmp.XXXXXX")"; printf '%s\n' "$2" >"$tmp"; mv -f "$tmp" "$1"; }

ensure_node_id(){
  v=""
  [ -s "$NODE_ID_FILE" ] && v="$(tr -d '\r\n' <"$NODE_ID_FILE" | tr 'A-Z' 'a-z')"
  if ! is_uuid "$v"; then
    v="$(gen_uuid)"
    is_uuid "$v" || { sleep 1; v="$(gen_uuid)"; }
    is_uuid "$v" || { log "FATAL: cannot generate node_id"; exit 1; }
    atomic_write "$NODE_ID_FILE" "$v"
  fi
  echo "$v"
}

ensure_secret(){
  v=""
  [ -s "$SECRET_FILE" ] && v="$(tr -d '\r\n' <"$SECRET_FILE")"
  if [ "${#v}" -lt 32 ]; then
    v="$(gen_secret)"
    [ "${#v}" -ge 32 ] || { log "FATAL: cannot generate device_secret"; exit 1; }
    atomic_write "$SECRET_FILE" "$v"
  fi
  echo "$v"
}

acquire_lock(){
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

get_ha_name(){
  f="/config/.storage/core.config"
  if [ -r "$f" ]; then
    name="$(grep -oE '"location_name"\s*:\s*"[^"]+"' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"location_name"\s*:\s*"([^"]+)".*/\1/' || true)"
    [ -n "${name:-}" ] && { echo "$name"; return; }
  fi
  echo "Home Assistant"
}

register_node_loop(){
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

wait_allowed(){
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

start_nginx_strip_proxy(){
  mkdir -p /tmp/nginx
  cat > /tmp/nginx/nginx.conf <<NGX
worker_processes 1;
pid /tmp/nginx/nginx.pid;

events { worker_connections 1024; }

http {
  access_log off;
  error_log /tmp/nginx/error.log warn;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen ${NGX_PORT};

    location / {
      proxy_pass http://${HA_HOST}:${HA_PORT};
      proxy_http_version 1.1;

      # Force Host to internal HA
      proxy_set_header Host "${HA_HOST}:${HA_PORT}";

      # Websocket support
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;

      # Strip forwarded headers (this is what fixes aiohttp 400)
      proxy_set_header X-Forwarded-For "";
      proxy_set_header X-Forwarded-Proto "";
      proxy_set_header X-Forwarded-Host "";
      proxy_set_header Forwarded "";
      proxy_set_header X-Real-IP "";

      proxy_buffering off;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }
  }
}
NGX

  # Start/restart nginx safely
  if [ -f /tmp/nginx/nginx.pid ]; then
    pid="$(cat /tmp/nginx/nginx.pid 2>/dev/null || true)"
    [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
    rm -f /tmp/nginx/nginx.pid || true
  fi

  nginx -c /tmp/nginx/nginx.conf
  log "strip-proxy started: 127.0.0.1:${NGX_PORT} -> ${HA_HOST}:${HA_PORT}"
}

main(){
  acquire_lock

  NODE_ID="$(ensure_node_id)"
  DEVICE_SECRET="$(ensure_secret)"
  HA_NAME="$(get_ha_name)"

  log "node_id: $NODE_ID"
  log "ha_name: $HA_NAME"
  log "HA upstream: ${HA_HOST}:${HA_PORT}"

  start_nginx_strip_proxy

  register_node_loop "$NODE_ID" "$DEVICE_SECRET" "$HA_NAME"
  wait_allowed "$NODE_ID"

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
localIP = "127.0.0.1"
localPort = ${NGX_PORT}
customDomains = ["${VHOST}"]
TOML

  log "public url: https://${VHOST}/"

  while true; do
    log "starting frpc"
    /usr/local/bin/frpc -c /data/frpc.toml || true
    sleep 5
  done
}

main "$@"
