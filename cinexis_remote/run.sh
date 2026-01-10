#!/usr/bin/env bash
set -euo pipefail

CFG_DIR="/config"
CINEXIS_DIR="${CFG_DIR}/cinexis"
THEMES_DIR="${CFG_DIR}/themes/cinexis"
STORAGE_DIR="${CFG_DIR}/.storage"

HOME_LABEL="$(jq -r '.home_label' /data/options.json)"
APPLY_DASHBOARD="$(jq -r '.apply_dashboard' /data/options.json)"
APPLY_THEME="$(jq -r '.apply_theme' /data/options.json)"
SET_YAML_MODE="$(jq -r '.set_yaml_mode' /data/options.json)"
BACKUP_UI="$(jq -r '.backup_existing_ui' /data/options.json)"

mkdir -p "${CINEXIS_DIR}" "${THEMES_DIR}" "${STORAGE_DIR}"

echo "[Cinexis] Applying branding for: ${HOME_LABEL}"

if [ "${APPLY_THEME}" = "true" ]; then
  cp -f /rootfs/cinexis/theme.yaml "${THEMES_DIR}/theme.yaml"
fi

if [ "${APPLY_DASHBOARD}" = "true" ]; then
  sed -e "s/{{HOME_LABEL}}/${HOME_LABEL}/g" \
    /rootfs/cinexis/ui-lovelace.yaml > "${CINEXIS_DIR}/ui-lovelace.yaml"
fi

CFG="${CFG_DIR}/configuration.yaml"
touch "${CFG}"

if ! grep -qE '^\s*frontend:\s*$' "${CFG}"; then
  printf "\nfrontend:\n  themes: !include_dir_merge_named themes\n" >> "${CFG}"
fi

if [ "${SET_YAML_MODE}" = "true" ]; then
cat >> "${CFG}" <<'EOF'

lovelace:
  mode: yaml
  dashboards:
    cinexis:
      mode: yaml
      title: Cinexis
      icon: mdi:home-automation
      show_in_sidebar: true
      require_admin: false
      filename: cinexis/ui-lovelace.yaml
EOF
fi

echo "Restart Home Assistant"
