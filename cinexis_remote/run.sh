#!/usr/bin/env bash
set -euo pipefail

# Home Assistant add-ons typically start here.
# We delegate to Cinexis entrypoint which:
# - generates node_id + device_secret
# - claims license
# - checks heartbeat
# - writes frpc.toml with OIDC
# - execs frpc
exec /usr/bin/cinexis-entrypoint.sh
