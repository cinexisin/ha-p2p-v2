#!/usr/bin/with-contenv bash
set -euo pipefail

CONFIG_PATH="/data/options.json"
FRPC_TOML="/data/frpc.toml"
STATE_JSON="/data/cinexis_remote.json"

jq_get() {
  local key="$1"
  jq -r ".$key // empty" "$CONFIG_PATH"
}

FRPS_HOST="$(jq_get frps_host)"
FRPS_PORT="$(jq_get frps_port)"
HA_SCHEME="$(jq_get ha_scheme)"
HA_HOST="$(jq_get ha_host)"
HA_PORT="$(jq_get ha_port)"
PAIR_API="$(jq_get pair_api)"
PAIR_CODE="$(jq_get pair_code)"

if [[ -z "${HA_PORT}" ]]; then HA_PORT="8123"; fi

# Load existing state (home_id/token) if present
HOME_ID=""
TOKEN=""

if [[ -f "${STATE_JSON}" ]]; then
  HOME_ID="$(jq -r '.home_id // empty' "${STATE_JSON}" 2>/dev/null || true)"
  TOKEN="$(jq -r '.token // empty' "${STATE_JSON}" 2>/dev/null || true)"
fi

# If missing state, pair using pair_code
if [[ -z "${HOME_ID}" || -z "${TOKEN}" ]]; then
  if [[ -z "${PAIR_CODE}" ]]; then
    echo "[ERROR] Pairing not completed yet."
    echo "        Please enter your 6-digit Pair Code in the add-on configuration and start again."
    exit 1
  fi

  if [[ -z "${PAIR_API}" ]]; then
    echo "[ERROR] pair_api is empty."
    exit 1
  fi

  echo "[INFO] Pairing with Cinexis Cloud..."
  RESP="$(curl -fsSL -X POST "${PAIR_API}/pair/confirm" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${PAIR_CODE}\"}")" || {
      echo "[ERROR] Pairing failed. Check Pair Code and connectivity to ${PAIR_API}."
      exit 1
    }

  HOME_ID="$(echo "${RESP}" | jq -r '.home_id // empty')"
  TOKEN="$(echo "${RESP}" | jq -r '.token // empty')"

  if [[ -z "${HOME_ID}" || -z "${TOKEN}" ]]; then
    echo "[ERROR] Pairing response missing home_id/token."
    echo "Response: ${RESP}"
    exit 1
  fi

  # Persist state
  cat > "${STATE_JSON}" <<EOF
{"home_id":"${HOME_ID}","token":"${TOKEN}","paired_at":"$(date -u +%FT%TZ)"}
EOF

  echo "[INFO] Pairing OK. HomeID saved."
fi

PUBLIC_URL="https://${HOME_ID}.ha.cinexis.cloud"
HA_TARGET="${HA_SCHEME}://${HA_HOST}:${HA_PORT}"

echo "========================================"
echo " Cinexis Remote FRPC"
echo "----------------------------------------"
echo " HomeID      : ${HOME_ID}"
echo " Public URL  : ${PUBLIC_URL}"
echo " HA Target   : ${HA_TARGET}"
echo " FRPS        : ${FRPS_HOST}:${FRPS_PORT}"
echo "========================================"

# Write frpc.toml
cat > "${FRPC_TOML}" <<EOF
serverAddr = "${FRPS_HOST}"
serverPort = ${FRPS_PORT}
auth.method = "token"
auth.token = "${TOKEN}"

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${HOME_ID}.ha.cinexis.cloud"]
EOF

if [[ ! -x /frpc ]]; then
  echo "[ERROR] /frpc not found or not executable inside the add-on image."
  exit 1
fi

while true; do
  echo "[INFO] starting frpc..."
  /frpc -c "${FRPC_TOML}" || true
  echo "[WARN] frpc exited. Retrying in 5 seconds..."
  sleep 5
done
