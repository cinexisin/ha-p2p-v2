#!/usr/bin/with-contenv bash
set -euo pipefail

CONFIG_PATH=/data/options.json
FRPC_TOML=/data/frpc.toml

jqget() { jq -r "$1 // empty" "$CONFIG_PATH"; }

PAIR_API="$(jqget '.pair_api')"
PAIR_CODE="$(jqget '.pair_code')"
FRPS_HOST="$(jqget '.frps_host')"
FRPS_PORT="$(jqget '.frps_port')"
TOKEN="$(jqget '.token')"
HOME_ID="$(jqget '.home_id')"

HA_SCHEME="$(jqget '.ha_scheme')"
HA_HOST="$(jqget '.ha_host')"
HA_PORT="$(jqget '.ha_port')"

# Defaults
: "${PAIR_API:=https://pair.cinexis.cloud}"
: "${FRPS_HOST:=cinexis.cloud}"
: "${FRPS_PORT:=7000}"
: "${HA_SCHEME:=http}"
: "${HA_HOST:=127.0.0.1}"
: "${HA_PORT:=8123}"

# If pair_code is provided, exchange it for token/home_id
if [[ -n "${PAIR_CODE}" ]]; then
  echo "[INFO] Pairing with Cinexis Cloud..."
  RESP="$(curl -fsSL -X POST "${PAIR_API}/pair/confirm" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${PAIR_CODE}\"}")"

  NEW_HOME_ID="$(echo "$RESP" | jq -r '.home_id')"
  NEW_TOKEN="$(echo "$RESP" | jq -r '.token')"
  NEW_FRPS_HOST="$(echo "$RESP" | jq -r '.frps_host')"
  NEW_FRPS_PORT="$(echo "$RESP" | jq -r '.frps_port')"

  if [[ -n "${NEW_HOME_ID}" && -n "${NEW_TOKEN}" ]]; then
    HOME_ID="$NEW_HOME_ID"
    TOKEN="$NEW_TOKEN"
    FRPS_HOST="$NEW_FRPS_HOST"
    FRPS_PORT="$NEW_FRPS_PORT"
    echo "[INFO] Pairing success. HomeID=${HOME_ID}"
  else
    echo "[ERROR] Pairing failed (bad response)."
    echo "$RESP"
    exit 1
  fi
fi

if [[ -z "${HOME_ID}" ]]; then
  echo "[ERROR] home_id is empty. Enter home_id or provide pair_code."
  exit 1
fi

if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] token is empty. Enter token or provide pair_code."
  exit 1
fi

PUBLIC_HOST="${HOME_ID}.ha.cinexis.cloud"
HA_TARGET="${HA_SCHEME}://${HA_HOST}:${HA_PORT}"

cat > "${FRPC_TOML}" <<EOF
serverAddr = "${FRPS_HOST}"
serverPort = ${FRPS_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
loginFailExit = true

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${PUBLIC_HOST}"]

# Home Assistant needs correct Host header
hostHeaderRewrite = "${PUBLIC_HOST}"
requestHeaders.set.x-forwarded-proto = "https"
EOF

echo "========================================"
echo " Cinexis Remote FRPC"
echo "----------------------------------------"
echo " HomeID      : ${HOME_ID}"
echo " Public URL  : https://${PUBLIC_HOST}"
echo " HA Target   : ${HA_TARGET}"
echo " FRPS        : ${FRPS_HOST}:${FRPS_PORT}"
echo "========================================"

echo "[INFO] starting frpc..."
while true; do
  /frpc -c "${FRPC_TOML}" || true
  echo "[WARN] frpc exited. Retrying in 5 seconds..."
  sleep 5
done
