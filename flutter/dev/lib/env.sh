#!/usr/bin/env bash
# vc-auto/flutter/dev/lib/env.sh
# Quản lý environment variables và Flutter dart-defines theo stage/flavor.
#
# Stages chuẩn: local | dev | stg | prod
# Env file format: KEY=value  (không cần quotes, không có spaces quanh =)
#
# Depends: lib/config.sh (tự load nếu chưa source)

# Tự load config.sh nếu chưa có
_env_ensure_config() {
  if ! declare -f vc_config_load &>/dev/null; then
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/config.sh
    source "$dir/config.sh"
  fi
  vc_config_load "${PROJECT_ROOT:-$(pwd)}" 2>/dev/null || true
}

# Load và export tất cả vars từ .env.<stage>
# Returns 0 nếu file tìm thấy, 1 nếu không
env_load() {
  local stage="$1"
  local root="${2:-${PROJECT_ROOT:-$(pwd)}}"

  _env_ensure_config

  local env_file
  env_file=$(vc_config_env_file "$stage" "$root")

  [ ! -f "$env_file" ] && return 1

  while IFS= read -r line || [ -n "$line" ]; do
    # Bỏ qua comments và dòng trống
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    # Chỉ export các vars hợp lệ (KEY=value)
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "$line"
    fi
  done < "$env_file"

  return 0
}

# Flutter build args để inject env
# Trả về: --dart-define-from-file .env.dev  (nếu file tồn tại)
#      hoặc: --dart-define=ENV=dev            (fallback)
env_dart_args() {
  local stage="$1"
  local root="${2:-${PROJECT_ROOT:-$(pwd)}}"

  _env_ensure_config

  local env_file
  env_file=$(vc_config_env_file "$stage" "$root")

  if [ -f "$env_file" ]; then
    echo "--dart-define-from-file $env_file"
  else
    echo "--dart-define=ENV=$stage"
  fi
}

# Build mode cho stage: "debug" hoặc "release"
env_build_mode() {
  local stage="$1"

  _env_ensure_config

  if vc_config_is_debug "$stage" 2>/dev/null; then
    echo "debug"
  else
    echo "release"
  fi
}

# In trạng thái env file của stage
env_status() {
  local stage="$1"
  local root="${2:-${PROJECT_ROOT:-$(pwd)}}"

  _env_ensure_config

  local env_file
  env_file=$(vc_config_env_file "$stage" "$root")

  if [ -f "$env_file" ]; then
    local var_count
    var_count=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null || echo "0")
    ok "Env     : $stage  ($env_file — $var_count vars)"
  else
    warn "Env file: $env_file (chưa có — bỏ qua dart-define injection)"
  fi
}

# Tạo template .env files (local/dev/stg/prod)
env_create_templates() {
  local root="${1:-${PROJECT_ROOT:-$(pwd)}}"

  local created=0
  for stage in local dev stg prod; do
    local env_file="$root/.env.$stage"
    if [ ! -f "$env_file" ]; then
      local api_url
      case "$stage" in
        local) api_url="http://localhost:3000" ;;
        dev)   api_url="https://dev.api.example.com" ;;
        stg)   api_url="https://stg.api.example.com" ;;
        prod)  api_url="https://api.example.com" ;;
      esac

      cat > "$env_file" << EOF
# .env.$stage — $(echo "$stage" | tr '[:lower:]' '[:upper:]') environment
# KHÔNG commit file này (thêm .env.* vào .gitignore)

ENV=$stage
API_URL=$api_url
EOF
      ok "Tạo: $env_file"
      created=$((created + 1))
    else
      skip ".env.$stage (đã tồn tại)"
    fi
  done

  # Cập nhật .gitignore
  local gitignore="$root/.gitignore"
  if [ -f "$gitignore" ] && ! grep -q "^\.env\." "$gitignore" 2>/dev/null; then
    {
      echo ""
      echo "# Environment files — chứa secrets, không commit"
      echo ".env.*"
      echo "!.env.example"
    } >> "$gitignore"
    ok "Thêm .env.* vào .gitignore"
  fi

  if [ "$created" -gt 0 ]; then
    info "Điền API_URL và các biến cần thiết vào mỗi file."
  fi
}
