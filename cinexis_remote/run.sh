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

read_file_trim() {
  local f="$1"
  if [[ -f "$f" ]]; then
    tr -d '\r\n' < "$f"
  else
    echo ""
  fi
}

write_file_600() {
  local f="$1"
  local v="$2"
  umask 077
  printf "%s" "$v" > "$f"
}

FRPS_HOST="$(jq_get frps_host)"
FRPS_PORT="$(jq_get frps_port)"
HA_SCHEME="$(jq_get ha_scheme)"
HA_HOST="$(jq_get ha_host)"
HA_PORT="$(jq_get ha_port)"

PAIR_API="$(jq_get pair_api)"
PAIR_CODE="$(jq_get pair_code)"

if [[ -z "${FRPS_HOST}" ]]; then FRPS_HOST="cinexis.cloud"; fi
if [[ -z "${FRPS_PORT}" ]]; then FRPS_PORT="7000"; fi
if [[ -z "${HA_SCHEME}" ]]; then HA_SCHEME="http"; fi
if [[ -z "${HA_HOST}" ]]; then HA_HOST="127.0.0.1"; fi
if [[ -z "${HA_PORT}" ]]; then HA_PORT="8123"; fi
if [[ -z "${PAIR_API}" ]]; then PAIR_API="https://pair.cinexis.cloud"; fi

HOME_ID="$(read_file_trim "${HOMEID_FILE}")"
TOKEN="$(read_file_trim "${TOKEN_FILE}")"

if [[ ( -z "${HOME_ID}" || -z "${TOKEN}" ) && -n "${PAIR_CODE}" ]]; then
  echo "[INFO] Pairing with Cinexis Cloud..."
  set +e
  RESP="$(curl -fsSL -X POST "${PAIR_API}/pair/confirm" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${PAIR_CODE}\"}" 2>/dev/null)"
  CURL_RC=$?
  set -e

  if [[ "${CURL_RC}" -ne 0 || -z "${RESP}" ]]; then
    echo "[WARN] Pairing failed (could not confirm code). Please verify the code and try again."
  else
    NEW_HOME_ID="$(echo "${RESP}" | jq -r '.home_id // empty')"
    NEW_TOKEN="$(echo "${RESP}" | jq -r '.token // empty')"

    if [[ -n "${NEW_HOME_ID}" && -n "${NEW_TOKEN}" ]]; then
      HOME_ID="${NEW_HOME_ID}"
      TOKEN="${NEW_TOKEN}"
      write_file_600 "${HOMEID_FILE}" "${HOME_ID}"
      write_file_600 "${TOKEN_FILE}" "${TOKEN}"
      echo "[INFO] Pairing success. HomeID saved."
    else
      echo "[WARN] Pairing response missing home_id/token. Response was: ${RESP}"
    fi
  fi
fi

if [[ -z "${HOME_ID}" ]]; then
  HOME_ID="$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 20)"
  write_file_600 "${HOMEID_FILE}" "${HOME_ID}"
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

if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] No token available."
  echo "        Enter a valid pair_code in the add-on config, then Start the add-on again."
  exit 1
fi

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
