#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/share/cinexis"
NODE_FILE="$DATA_DIR/node_id"
LOCK="$DATA_DIR/.lock"
mkdir -p "$DATA_DIR"

exec 9>"$LOCK" || exit 0
flock -n 9 || { echo "[cinexis] another instance already running; idling"; sleep infinity; }

if [ ! -f "$NODE_FILE" ]; then
  uuidgen | tr 'A-Z' 'a-z' > "$NODE_FILE"
fi
NODE_ID="$(cat "$NODE_FILE")"

HA_NAME="Home Assistant"
if [ -f /config/.storage/core.config ]; then
  HA_NAME="$(jq -r '.data.config.name // "Home Assistant"' /config/.storage/core.config)"
fi

echo "[cinexis] node_id: $NODE_ID"
echo "[cinexis] ha_name: $HA_NAME"
echo "[cinexis] HA upstream: homeassistant:8123"

API="https://api.cinexis.cloud"

while true; do
  curl -fsS -X POST "$API/licensing/v1/nodes/register" \
    -H "Content-Type: application/json" \
    -d "{\"node_id\":\"$NODE_ID\",\"ha_name\":\"$HA_NAME\"}" || true

  RESP="$(curl -fsS -X POST "$API/licensing/v1/nodes/heartbeat" \
    -H "Content-Type: application/json" \
    -d "{\"node_id\":\"$NODE_ID\"}" || true)"

  echo "$RESP" | grep -q '"allowed":true' && break
  echo "[cinexis] not allowed yet; retry in 15s"
  sleep 15
done

echo "[cinexis] license status: allowed ✅"
echo "[cinexis] public url: https://$NODE_ID.ha.cinexis.cloud/"

cat > /data/frpc.toml <<TOML
serverAddr = "api.cinexis.cloud"
serverPort = 7000

auth.method = "oidc"
auth.oidc.clientID = "$NODE_ID"
auth.oidc.clientSecret = "$NODE_ID"
auth.oidc.audience = "frps"
auth.oidc.tokenEndpointURL = "$API/frp/oidc/token"

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "homeassistant"
localPort = 8123
customDomains = ["$NODE_ID.ha.cinexis.cloud"]
TOML

while true; do
  echo "[cinexis] starting frpc"
  frpc -c /data/frpc.toml || true
  sleep 5
done
