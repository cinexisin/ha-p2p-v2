#!/usr/bin/with-contenv bash
set -euo pipefail

OPTIONS="/data/options.json"
STATE_DIR="/data/state"
HOMEID_FILE="${STATE_DIR}/homeid"
FRPC_TOML="/data/frpc.toml"

mkdir -p "${STATE_DIR}"

FRPS_HOST="$(jq -r '.frps_host // "cinexis.cloud"' "${OPTIONS}")"
FRPS_PORT="$(jq -r '.frps_port // 7000' "${OPTIONS}")"
TOKEN="$(jq -r '.token // ""' "${OPTIONS}")"

HA_SCHEME="$(jq -r '.ha_scheme // "http"' "${OPTIONS}")"
HA_HOST="$(jq -r '.ha_host // "127.0.0.1"' "${OPTIONS}")"
HA_PORT="$(jq -r '.ha_port // 8123' "${OPTIONS}")"

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "CHANGE_ME_STRONG_TOKEN" ]; then
  echo ""
  echo "[ERROR] Set a strong token in add-on options."
  echo "It must match token in VPS: /opt/cinexis-cloud/frp/frps.ini"
  echo ""
  exit 1
fi

if [ -f "${HOMEID_FILE}" ]; then
  HOMEID="$(cat "${HOMEID_FILE}")"
else
  HOMEID="$(head -c 10 /dev/urandom | xxd -p -c 256)"
  echo "${HOMEID}" > "${HOMEID_FILE}"
fi

PUBLIC_HOST="${HOMEID}.ha.cinexis.cloud"
PUBLIC_URL="https://${PUBLIC_HOST}"

echo ""
echo "========================================"
echo " Cinexis Remote"
echo "----------------------------------------"
echo " HomeID      : ${HOMEID}"
echo " Public URL  : ${PUBLIC_URL}"
echo " HA Target   : ${HA_SCHEME}://${HA_HOST}:${HA_PORT}"
echo " FRPS        : ${FRPS_HOST}:${FRPS_PORT}"
echo "========================================"
echo ""

cat > "${FRPC_TOML}" <<EOF
serverAddr = "${FRPS_HOST}"
serverPort = ${FRPS_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
transport.tls.enable = true

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${PUBLIC_HOST}"]
EOF

exec /usr/bin/frpc -c "${FRPC_TOML}"
