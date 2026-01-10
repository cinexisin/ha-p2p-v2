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

# 1) Install theme
if [ "${APPLY_THEME}" = "true" ]; then
  echo "[1/5] Installing Cinexis theme..."
  cp -f /rootfs/cinexis/theme.yaml "${THEMES_DIR}/theme.yaml"
fi

# 2) Install dashboard
if [ "${APPLY_DASHBOARD}" = "true" ]; then
  echo "[2/5] Installing Cinexis dashboard..."
  sed -e "s/{{HOME_LABEL}}/${HOME_LABEL}/g" \
    /rootfs/cinexis/ui-lovelace.yaml > "${CINEXIS_DIR}/ui-lovelace.yaml"
fi

# 3) Backup existing Lovelace storage (safety)
if [ "${BACKUP_UI}" = "true" ] && [ -f "${STORAGE_DIR}/lovelace" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  echo "[backup] Backing up existing UI storage to lovelace.bak-${TS}"
  cp -f "${STORAGE_DIR}/lovelace" "${STORAGE_DIR}/lovelace.bak-${TS}"
fi

CFG="${CFG_DIR}/configuration.yaml"
touch "${CFG}"

# 4) Ensure themes are loaded
if ! grep -qE '^\s*frontend:\s*$' "${CFG}"; then
  echo "[3/5] Adding frontend themes include..."
  printf "\nfrontend:\n  themes: !include_dir_merge_named themes\n" >> "${CFG}"
else
  if ! grep -qE '^\s*themes:\s*!include_dir_merge_named\s+themes\s*$' "${CFG}"; then
    echo "[3/5] frontend exists but themes include missing. Appending themes include..."
    printf "\n# Cinexis: ensure themes directory is loaded\nfrontend:\n  themes: !include_dir_merge_named themes\n" >> "${CFG}"
  fi
fi

# 5) Add Lovelace YAML dashboard config
# IMPORTANT: dashboard key must contain a hyphen (-), so we use cinexis-home
if [ "${SET_YAML_MODE}" = "true" ]; then
  if ! grep -qE '^\s*lovelace:\s*$' "${CFG}"; then
    echo "[4/5] Adding Cinexis Lovelace YAML dashboard config..."
    cat >> "${CFG}" <<'EOF'

# Cinexis: Lovelace dashboard (YAML)
lovelace:
  mode: yaml
  dashboards:
    cinexis-home:
      mode: yaml
      title: Cinexis
      icon: mdi:home-automation
      show_in_sidebar: true
      require_admin: false
      filename: cinexis/ui-lovelace.yaml
EOF
  else
    echo "[warn] 'lovelace:' already exists in configuration.yaml; not overwriting."
    echo "       If needed, manually add a dashboard pointing to cinexis/ui-lovelace.yaml"
  fi
fi

echo "[5/5] Done. Now restart Home Assistant to apply changes."
