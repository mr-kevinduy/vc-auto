#!/usr/bin/env bash
# vc-auto/flutter/dev/lib/config.sh
# Đọc .vc-auto.yaml project config (không cần yq — parse bằng awk/grep).
#
# Format .vc-auto.yaml:
#   flavors:
#     local:
#       env_file: .env.local
#       debug: true
#     dev:
#       env_file: .env.dev
#       debug: true
#       deploy_target: firebase
#     stg:
#       env_file: .env.stg
#       debug: false
#       deploy_target: internal
#     prod:
#       env_file: .env.prod
#       debug: false
#       deploy_target: production

VC_CONFIG_FILE=""
_VC_CONFIG_LOADED=false

# Load config từ project root
vc_config_load() {
  local root="${1:-${PROJECT_ROOT:-$(pwd)}}"
  VC_CONFIG_FILE="$root/.vc-auto.yaml"

  if [ -f "$VC_CONFIG_FILE" ]; then
    _VC_CONFIG_LOADED=true
    return 0
  fi
  _VC_CONFIG_LOADED=false
  return 1
}

vc_config_exists() {
  $_VC_CONFIG_LOADED
}

# Lấy field trong một flavor
# Usage: vc_config_get_flavor_field <flavor> <field>
vc_config_get_flavor_field() {
  local flavor="$1"
  local field="$2"

  [ ! -f "$VC_CONFIG_FILE" ] && echo "" && return

  awk "
    /^  ${flavor}:/ { in_flavor=1; next }
    in_flavor && /^  [a-z]/ { in_flavor=0 }
    in_flavor && /^    ${field}:/ {
      sub(/^[[:space:]]*${field}:[[:space:]]*/, \"\")
      sub(/[[:space:]]*\$/, \"\")
      print; exit
    }
  " "$VC_CONFIG_FILE"
}

# Liệt kê tất cả flavor names
vc_config_flavors() {
  [ ! -f "$VC_CONFIG_FILE" ] && echo "" && return

  awk '
    /^flavors:/ { in_flavors=1; next }
    in_flavors && /^[^ ]/ { in_flavors=0 }
    in_flavors && /^  [a-z][a-z0-9_]*:/ {
      gsub(/^[[:space:]]*|:[[:space:]]*$/, "")
      print
    }
  ' "$VC_CONFIG_FILE"
}

# Đường dẫn env file của flavor (fallback: .env.<flavor>)
vc_config_env_file() {
  local flavor="$1"
  local root="${2:-${PROJECT_ROOT:-$(pwd)}}"

  local configured
  configured=$(vc_config_get_flavor_field "$flavor" "env_file")

  if [ -n "$configured" ]; then
    echo "$root/$configured"
  else
    echo "$root/.env.$flavor"
  fi
}

# Flavor có dùng debug mode không? (default: local/dev=true, stg/prod=false)
vc_config_is_debug() {
  local flavor="$1"

  local configured
  configured=$(vc_config_get_flavor_field "$flavor" "debug")

  if [ -n "$configured" ]; then
    [ "$configured" = "true" ]
    return $?
  fi

  case "$flavor" in
    local|dev) return 0 ;;
    *) return 1 ;;
  esac
}

# Deploy target cho flavor (firebase/internal/alpha/beta/production)
vc_config_deploy_target() {
  local flavor="$1"

  local configured
  configured=$(vc_config_get_flavor_field "$flavor" "deploy_target")

  if [ -n "$configured" ]; then
    echo "$configured"
    return
  fi

  case "$flavor" in
    local)  echo "" ;;
    dev)    echo "firebase" ;;
    stg)    echo "internal" ;;
    prod)   echo "production" ;;
    *)      echo "internal" ;;
  esac
}

# Tạo .vc-auto.yaml template cho project
vc_config_generate_template() {
  local root="${1:-${PROJECT_ROOT:-$(pwd)}}"
  local config_file="$root/.vc-auto.yaml"

  if [ -f "$config_file" ]; then
    warn ".vc-auto.yaml đã tồn tại: $config_file"
    return 1
  fi

  cat > "$config_file" << 'EOF'
# .vc-auto.yaml — vc-auto project config
# Commit file này vào repository (không chứa secrets).

flavors:
  local:
    env_file: .env.local
    debug: true

  dev:
    env_file: .env.dev
    debug: true
    deploy_target: firebase   # firebase | internal | alpha | beta | production

  stg:
    env_file: .env.stg
    debug: false
    deploy_target: internal

  prod:
    env_file: .env.prod
    debug: false
    deploy_target: production
EOF

  ok ".vc-auto.yaml tạo tại: $config_file"
  info "Tiếp theo: tạo .env.local, .env.dev, .env.stg, .env.prod"
  info "Thêm .env.* vào .gitignore"
}
