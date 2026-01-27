#!/usr/bin/env bash
set -euo pipefail

API="https://api.cinexis.cloud"
DATA_DIR="/share/cinexis"
NODE_FILE="$DATA_DIR/node_id"
SEC_FILE="$DATA_DIR/device_secret"
LOCK_FILE="$DATA_DIR/run.pid"

mkdir -p "$DATA_DIR"

# ---- stale-safe single instance lock ----
if [ -f "$LOCK_FILE" ]; then
  oldpid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "[cinexis] another instance already running; idling"
    sleep infinity
  fi
  rm -f "$LOCK_FILE" || true
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE" >/dev/null 2>&1 || true' EXIT

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return
  fi
  h="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
  echo "$h" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}
gen_secret() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; }

[ -f "$NODE_FILE" ] || gen_uuid > "$NODE_FILE"
[ -f "$SEC_FILE" ]  || gen_secret > "$SEC_FILE"

NODE_ID="$(tr -d '\r\n' <"$NODE_FILE")"
DEVICE_SECRET="$(tr -d '\r\n' <"$SEC_FILE")"

# HA “Name” from /config/.storage/core.config (no jq dependency)
HA_NAME="Home Assistant"
if [ -f /config/.storage/core.config ]; then
  n="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /config/.storage/core.config | head -n1 || true)"
  [ -n "${n:-}" ] && HA_NAME="$n"
fi

echo "[cinexis] node_id: $NODE_ID"
echo "[cinexis] ha_name: $HA_NAME"
echo "[cinexis] HA upstream: homeassistant:8123"

# Register node+secret (idempotent)
while true; do
  code="$(curl -sS -o /tmp/cinx_reg.out -w '%{http_code}' \
    -X POST "$API/licensing/v1/nodes/register" \
    -H "Content-Type: application/json" \
    -d "{\"node_id\":\"$NODE_ID\",\"device_secret\":\"$DEVICE_SECRET\",\"ha_name\":\"$HA_NAME\"}" \
    || echo 000)"
  if [ "$code" = "200" ]; then
    echo "[cinexis] node register OK"
    break
  fi
  echo "[cinexis] node register failed (http $code); retry in 10s"
  sleep 10
done

# Wait until allowed (admin binds license to node_id)
while true; do
  hb_code="$(curl -sS -o /tmp/cinx_hb.out -w '%{http_code}' \
    -X POST "$API/licensing/v1/nodes/heartbeat" \
    -H "Content-Type: application/json" \
    -d "{\"node_id\":\"$NODE_ID\"}" \
    || echo 000)"
  if [ "$hb_code" = "200" ] && grep -q '"allowed":true' /tmp/cinx_hb.out 2>/dev/null; then
    echo "[cinexis] license status: allowed ✅"
    break
  fi
  echo "[cinexis] not allowed yet (http $hb_code); retry in 15s"
  sleep 15
done

echo "[cinexis] public url: https://$NODE_ID.ha.cinexis.cloud/"

cat > /data/frpc.toml <<TOML
serverAddr = "api.cinexis.cloud"
serverPort = 7000

auth.method = "oidc"
auth.oidc.clientID = "$NODE_ID"
auth.oidc.clientSecret = "$DEVICE_SECRET"
auth.oidc.audience = "frps"
auth.oidc.tokenEndpointURL = "$API/frp/oidc/token"

[[proxies]]
name = "ha_ui_${NODE_ID}"
type = "http"
localIP = "homeassistant"
localPort = 8123
customDomains = ["$NODE_ID.ha.cinexis.cloud"]

requestHeaders.set.x-forwarded-for = "127.0.0.1"
requestHeaders.set.x-forwarded-proto = "http"
requestHeaders.set.x-forwarded-host = "homeassistant"
requestHeaders.set.forwarded = ""
# Critical: avoid HA 400 by rewriting Host to local HA
hostHeaderRewrite = "homeassistant"
TOML

while true; do
  echo "[cinexis] starting frpc"
  frpc -c /data/frpc.toml || true
  sleep 5
done
