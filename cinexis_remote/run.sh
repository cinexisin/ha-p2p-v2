#!/usr/bin/with-contenv bash
set -euo pipefail

CONFIG_PATH="/data/options.json"
FRPC_TOML="/data/frpc.toml"

HOMEID_FILE="/data/cinexis_homeid"
TOKEN_FILE="/data/cinexis_token"

jq_get() {
  local key="$1"
  jq -r ".$key // empty" "$CONFIG_PATH"
}

PAIR_API="$(jq_get pair_api)"
PAIR_CODE="$(jq_get pair_code)"

FRPS_HOST="$(jq_get frps_host)"
FRPS_PORT="$(jq_get frps_port)"

HA_SCHEME="$(jq_get ha_scheme)"
HA_HOST="$(jq_get ha_host)"
HA_PORT="$(jq_get ha_port)"

# Defaults
[[ -n "${FRPS_HOST}" ]] || FRPS_HOST="cinexis.cloud"
[[ -n "${FRPS_PORT}" ]] || FRPS_PORT="7000"
[[ -n "${HA_SCHEME}" ]] || HA_SCHEME="http"
[[ -n "${HA_HOST}" ]] || HA_HOST="127.0.0.1"
[[ -n "${HA_PORT}" ]] || HA_PORT="8123"

# Load persisted home_id/token if present
HOME_ID=""
TOKEN=""

if [[ -f "${HOMEID_FILE}" ]]; then
  HOME_ID="$(cat "${HOMEID_FILE}" 2>/dev/null || true)"
fi

if [[ -f "${TOKEN_FILE}" ]]; then
  TOKEN="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"
fi

# Pairing flow (pair_code -> {home_id, token})
if [[ -n "${PAIR_CODE}" && -n "${PAIR_API}" ]]; then
  echo "[INFO] Pairing with Cinexis Cloud..."

  set +e
  RESP="$(curl -fsSL -X POST "${PAIR_API}/pair/confirm" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${PAIR_CODE}\"}" 2>/dev/null)"
  CURL_RC=$?
  set -e

  if [[ "${CURL_RC}" -ne 0 || -z "${RESP}" ]]; then
    echo "[WARN] Pairing failed (network/HTTP). Continuing with any saved credentials..."
  else
    # Expect: {"home_id":"...","token":"..."}
    NEW_HOME_ID="$(echo "${RESP}" | jq -r '.home_id // empty' 2>/dev/null || true)"
    NEW_TOKEN="$(echo "${RESP}" | jq -r '.token // empty' 2>/dev/null || true)"

    if [[ -n "${NEW_HOME_ID}" && -n "${NEW_TOKEN}" ]]; then
      HOME_ID="${NEW_HOME_ID}"
      TOKEN="${NEW_TOKEN}"
      echo -n "${HOME_ID}" > "${HOMEID_FILE}"
      chmod 600 "${HOMEID_FILE}" || true
      echo -n "${TOKEN}" > "${TOKEN_FILE}"
      chmod 600 "${TOKEN_FILE}" || true
      echo "[INFO] Pairing OK. Saved home_id + token."
    else
      echo "[WARN] Pairing response missing fields. Continuing with any saved credentials..."
    fi
  fi
fi

# If still no home_id, generate and persist
if [[ -z "${HOME_ID}" ]]; then
  HOME_ID="$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 20)"
  echo -n "${HOME_ID}" > "${HOMEID_FILE}"
  chmod 600 "${HOMEID_FILE}" || true
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

# Safety checks
if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] No token available."
  echo "        Enter a Pair Code in the add-on config and restart the add-on."
  exit 1
fi

if [[ ! -x /frpc ]]; then
  echo "[ERROR] /frpc not found or not executable inside the add-on image."
  exit 1
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

# Run frpc with retry loop
while true; do
  echo "[INFO] starting frpc..."
  /frpc -c "${FRPC_TOML}" || true
  echo "[WARN] frpc exited. Retrying in 5 seconds..."
  sleep 5
done
