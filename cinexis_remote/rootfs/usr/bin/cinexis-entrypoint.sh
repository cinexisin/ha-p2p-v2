#!/usr/bin/with-contenv bash
set -Eeuo pipefail

log(){ echo "[cinexis] $*"; }

# ---- Defaults (no HA yaml edits required) ----
FRPS_ADDR="${FRPS_ADDR:-139.99.56.240}"
FRPS_PORT="${FRPS_PORT:-7000}"
HA_SUBDOMAIN_SUFFIX="${HA_SUBDOMAIN_SUFFIX:-.ha.cinexis.cloud}"

API_HOST="${API_HOST:-api.cinexis.cloud}"
OIDC_TOKEN_URL="https://${API_HOST}/frp/oidc/token"
REGISTER_URL="https://${API_HOST}/licensing/v1/nodes/register"
HEARTBEAT_URL="https://${API_HOST}/licensing/v1/nodes/heartbeat"

HA_HOST="${HA_HOST:-homeassistant}"
HA_PORT="${HA_PORT:-8123}"

DATA_DIR="/data"
NODE_ID_FILE="${DATA_DIR}/node_id"
SECRET_FILE="${DATA_DIR}/device_secret"
FRPC_TOML="${DATA_DIR}/frpc.toml"

mkdir -p "$DATA_DIR"

is_uuid() {
  local x="${1,,}"
  [[ "$x" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr 'A-Z' 'a-z' < /proc/sys/kernel/random/uuid | tr -d '\r\n'
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z' | tr -d '\r\n'
  else
    # very last fallback
    local h
    h="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | tr 'A-F' 'a-f')"
    echo "${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
  fi
}

gen_secret() {
  # Avoid pipefail/SIGPIPE issues: temporarily disable pipefail for this pipeline
  set +o pipefail
  local s
  s="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
  set -o pipefail
  printf '%s' "$s"
}

read_or_create_node_id() {
  local nid=""
  if [ -s "$NODE_ID_FILE" ]; then
    nid="$(tr -d '\r\n' < "$NODE_ID_FILE" | tr 'A-Z' 'a-z')"
  fi

  if ! is_uuid "$nid"; then
    [ -n "$nid" ] && log "node_id file is invalid/corrupt -> regenerating"
    nid="$(gen_uuid)"
    echo "$nid" > "$NODE_ID_FILE"
  fi

  echo "$nid"
}

read_or_create_secret() {
  local sec=""
  if [ -s "$SECRET_FILE" ]; then
    sec="$(tr -d '\r\n' < "$SECRET_FILE")"
  fi

  if [ -z "$sec" ]; then
    sec="$(gen_secret)"
    echo "$sec" > "$SECRET_FILE"
  fi

  echo "$sec"
}

register_node() {
  local payload code
  payload="$(printf '{"node_id":"%s","device_secret":"%s"}' "$NODE_ID" "$DEVICE_SECRET")"
  code="$(curl -sS -o /tmp/cinexis_register.out -w '%{http_code}' \
    -X POST "$REGISTER_URL" -H 'Content-Type: application/json' -d "$payload" || true)"

  if [[ "$code" == "200" || "$code" == "409" ]]; then
    return 0
  fi

  log "node register failed (http $code) -> $(head -c 140 /tmp/cinexis_register.out 2>/dev/null || true)"
  return 1
}

wait_until_allowed() {
  while true; do
    local payload code
    payload="$(printf '{"node_id":"%s"}' "$NODE_ID")"
    code="$(curl -sS -o /tmp/cinexis_hb.out -w '%{http_code}' \
      -X POST "$HEARTBEAT_URL" -H 'Content-Type: application/json' -d "$payload" || true)"

    if [[ "$code" == "200" ]] && grep -q '"allowed":true' /tmp/cinexis_hb.out 2>/dev/null; then
      log "license status: allowed ✅"
      return 0
    fi

    log "not allowed yet (http $code); retry in 15s"
    sleep 15
  done
}

wait_for_ha() {
  while ! curl -fsS --max-time 2 "http://${HA_HOST}:${HA_PORT}/" >/dev/null 2>&1; do
    log "waiting for Home Assistant at ${HA_HOST}:${HA_PORT} ..."
    sleep 3
  done
}

write_frpc() {
  local vhost="${NODE_ID}${HA_SUBDOMAIN_SUFFIX}"
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
customDomains = ["${vhost}"]
TOML

  log "public url: https://${vhost}/"
}

main() {
  NODE_ID="$(read_or_create_node_id)"
  DEVICE_SECRET="$(read_or_create_secret)"

  log "starting"
  log "node_id: ${NODE_ID}"
  log "HA upstream selected: ${HA_HOST}:${HA_PORT}"

  # keep trying forever
  until register_node; do
    sleep 15
  done

  wait_until_allowed
  wait_for_ha
  write_frpc

  log "starting frpc (will restart on failure)"
  while true; do
    /usr/local/bin/frpc -c "$FRPC_TOML" || true
    log "frpc exited; retry in 10s"
    sleep 10
  done
}

main "$@"
