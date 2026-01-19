#!/usr/bin/with-contenv bash
set -euo pipefail

OPTIONS="/data/options.json"
STATE_DIR="/data/state"
HOMEID_FILE="${STATE_DIR}/homeid"
FRPC_TOML="/data/frpc.toml"

mkdir -p "${STATE_DIR}"

# Defaults (work even if options UI is not available)
FRPS_HOST="cinexis.cloud"
FRPS_PORT="7000"
TOKEN=""
HA_SCHEME="http"
HA_HOST="127.0.0.1"
HA_PORT="8123"

# If HA provides options.json, use it
if [ -f "${OPTIONS}" ]; then
  FRPS_HOST="$(jq -r '.frps_host // "'"${FRPS_HOST}"'"' "${OPTIONS}")"
  FRPS_PORT="$(jq -r '.frps_port // '"${FRPS_PORT}"'' "${OPTIONS}")"
  TOKEN="$(jq -r '.token // ""' "${OPTIONS}")"
  HA_SCHEME="$(jq -r '.ha_scheme // "'"${HA_SCHEME}"'"' "${OPTIONS}")"
  HA_HOST="$(jq -r '.ha_host // "'"${HA_HOST}"'"' "${OPTIONS}")"
  HA_PORT="$(jq -r '.ha_port // '"${HA_PORT}"'' "${OPTIONS}")"
else
  echo "[WARN] ${OPTIONS} not found. Using defaults."
fi

# Persistent homeid
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

if [ -z "${TOKEN}" ]; then
  echo "[WARN] token is empty. If your VPS frps.ini has token enabled, connection will fail."
  echo "[WARN] Set token in add-on options to match VPS /opt/cinexis-cloud/frp/frps.ini"
fi

cat > "${FRPC_TOML}" <<EOF
serverAddr = "${FRPS_HOST}"
serverPort = ${FRPS_PORT}
transport.tls.enable = true

# Auth token (optional). If empty, FRP may reject depending on server config.
auth.method = "token"
auth.token = "${TOKEN}"

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${PUBLIC_HOST}"]
EOF

# Keep the add-on alive even if frpc exits
while true; do
  echo "[INFO] starting frpc..."
  /usr/bin/frpc -c "${FRPC_TOML}" || true
  echo "[WARN] frpc exited. Retrying in 5 seconds..."
  sleep 5
done
