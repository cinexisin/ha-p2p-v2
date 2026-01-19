#!/usr/bin/with-contenv bash
set -euo pipefail

CONFIG_PATH="/data/options.json"
FRPC_TOML="/data/frpc.toml"
HOMEID_FILE="/data/cinexis_homeid"

jq_get() {
  local key="$1"
  jq -r ".$key // empty" "$CONFIG_PATH"
}

FRPS_HOST="$(jq_get frps_host)"
FRPS_PORT="$(jq_get frps_port)"
TOKEN="$(jq_get token)"
HA_SCHEME="$(jq_get ha_scheme)"
HA_HOST="$(jq_get ha_host)"
HA_PORT="$(jq_get ha_port)"
PAIR_API="$(jq_get pair_api)"
PAIR_CODE="$(jq_get pair_code)"
HOME_ID="$(jq_get home_id)"

if [[ -z "${HA_PORT}" ]]; then
  HA_PORT="8123"
fi

# Create home_id if not provided
if [[ -z "${HOME_ID}" || "${HOME_ID}" == "null" ]]; then
  if [[ -f "${HOMEID_FILE}" ]]; then
    HOME_ID="$(cat "${HOMEID_FILE}")"
  else
    HOME_ID="$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 20)"
    echo "${HOME_ID}" > "${HOMEID_FILE}"
  fi
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

# Pairing: if pair_code provided, call pairing server (optional)
if [[ -n "${PAIR_CODE}" && -n "${PAIR_API}" ]]; then
  echo "[INFO] Pairing with Cinexis Cloud..."
  # Best-effort pairing (do not crash if pairing server is down)
  curl -fsSL -X POST "${PAIR_API}/pair/confirm" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${PAIR_CODE}\",\"home_id\":\"${HOME_ID}\"}" >/dev/null || true
fi

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

# Safety checks
if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] token is empty. Please set token in add-on configuration."
  exit 1
fi

if [[ ! -x /frpc ]]; then
  echo "[ERROR] /frpc not found or not executable inside the add-on image."
  exit 1
fi

# Run frpc with retry loop
while true; do
  echo "[INFO] starting frpc..."
  /frpc -c "${FRPC_TOML}" || true
  echo "[WARN] frpc exited. Retrying in 5 seconds..."
  sleep 5
done
