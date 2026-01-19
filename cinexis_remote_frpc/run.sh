#!/usr/bin/with-contenv bashio
set -euo pipefail

# --- Read options from add-on config ---
FRPS_HOST="$(bashio::config 'frps_host')"
FRPS_PORT="$(bashio::config 'frps_port')"
TOKEN="$(bashio::config 'token')"

HA_SCHEME="$(bashio::config 'ha_scheme')"
HA_HOST="$(bashio::config 'ha_host')"
HA_PORT="$(bashio::config 'ha_port')"

# Optional override if you want fixed HomeID; otherwise derived from machine-id
HOME_ID_OVERRIDE="$(bashio::config 'home_id' || true)"

# --- Generate a stable HomeID ---
if [[ -n "${HOME_ID_OVERRIDE:-}" && "${HOME_ID_OVERRIDE:-null}" != "null" ]]; then
  HOME_ID="${HOME_ID_OVERRIDE}"
else
  # Stable across restarts; different per machine
  if [[ -f /etc/machine-id ]]; then
    HOME_ID="$(cut -c1-20 /etc/machine-id)"
  else
    HOME_ID="$(head -c 32 /dev/urandom | sha256sum | cut -c1-20)"
  fi
fi

PUBLIC_HOST="${HOME_ID}.ha.cinexis.cloud"
PUBLIC_URL="https://${PUBLIC_HOST}"
HA_TARGET="${HA_SCHEME}://${HA_HOST}:${HA_PORT}"

bashio::log.info "========================================"
bashio::log.info " Cinexis Remote FRPC"
bashio::log.info "----------------------------------------"
bashio::log.info " HomeID      : ${HOME_ID}"
bashio::log.info " Public URL  : ${PUBLIC_URL}"
bashio::log.info " HA Target   : ${HA_TARGET}"
bashio::log.info " FRPS        : ${FRPS_HOST}:${FRPS_PORT}"
bashio::log.info "========================================"

# --- Write FRPC config (TOML) ---
# IMPORTANT:
# - type=http enables vhost routing in frps (vhost_http_port=8080)
# - host_header_rewrite makes HA see a safe Host (localhost)
# - request_headers ensures HA sees https + correct external host
cat > /data/frpc.toml <<EOF
serverAddr = "${FRPS_HOST}"
serverPort = ${FRPS_PORT}
auth.method = "token"
auth.token = "${TOKEN}"

[[proxies]]
name = "ha_ui"
type = "http"
localIP = "${HA_HOST}"
localPort = ${HA_PORT}
customDomains = ["${PUBLIC_HOST}"]

# Make HA happier behind proxy
hostHeaderRewrite = "127.0.0.1"

[proxies.transport]
useEncryption = true
useCompression = true

[proxies.requestHeaders]
set.X-Forwarded-Proto = "https"
set.X-Forwarded-Host = "${PUBLIC_HOST}"
set.X-Forwarded-Port = "443"
EOF

bashio::log.info "[INFO] starting frpc..."
exec /usr/local/bin/frpc -c /data/frpc.toml
