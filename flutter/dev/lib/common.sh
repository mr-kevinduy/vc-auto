#!/usr/bin/env bash
# vc-auto/flutter/dev/lib/common.sh
# Shared utilities — project-agnostic, dùng được cho mọi Flutter project.

# ─── Script Location ──────────────────────────────────────────────────────────

AUTOMATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Colors & Logging ─────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail()  { echo -e "${RED}  ✗${NC} $*"; exit 1; }
info()  { echo -e "${BLUE}  ℹ${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }
skip()  { echo -e "${GRAY}  –${NC} $* ${GRAY}(skip)${NC}"; }
header() {
  local title="$1"
  local len=${#title}
  local line
  line=$(printf '═%.0s' $(seq 1 $((len + 4))))
  echo ""
  echo -e "${BOLD}${BLUE}╔${line}╗${NC}"
  echo -e "${BOLD}${BLUE}║  ${title}  ║${NC}"
  echo -e "${BOLD}${BLUE}╚${line}╝${NC}"
  echo ""
}

# ─── Project Resolution ───────────────────────────────────────────────────────
#
# Thứ tự ưu tiên:
#   1. --project <path>  argument (được parse bởi từng script)
#   2. FLUTTER_PROJECT   environment variable
#   3. Current directory (pwd)
#
# Gọi init_project sau khi parse args:
#   init_project "${PROJECT_ARG:-}"

PROJECT_ROOT=""
APP_NAME=""
ANDROID_APP_ID=""
IOS_BUNDLE_ID=""
FLUTTER_MIN_VERSION="3.0.0"
DART_MIN_VERSION="3.0.0"
JAVA_MIN_VERSION="17"

init_project() {
  local path="${1:-${FLUTTER_PROJECT:-$(pwd)}}"

  # Resolve absolute path
  if [ ! -d "$path" ]; then
    fail "Project directory không tồn tại: $path"
  fi
  PROJECT_ROOT="$(cd "$path" && pwd)"

  # Validate Flutter project
  if [ ! -f "$PROJECT_ROOT/pubspec.yaml" ]; then
    fail "Không phải Flutter project (pubspec.yaml không có tại: $PROJECT_ROOT)"
  fi

  # Đọc project info từ pubspec.yaml
  _read_project_info

  # Setup log dir trong project
  LOG_DIR="$PROJECT_ROOT/.logs/automate"
  mkdir -p "$LOG_DIR"

  export PROJECT_ROOT APP_NAME ANDROID_APP_ID IOS_BUNDLE_ID
  export FLUTTER_MIN_VERSION DART_MIN_VERSION LOG_DIR

  # Re-resolve sau khi PROJECT_ROOT được set — để detect .fvm/flutter_sdk (fvm use)
  FLUTTER_CMD="$(find_flutter 2>/dev/null || echo '')"
  export FLUTTER_CMD
}

_read_project_info() {
  local yaml="$PROJECT_ROOT/pubspec.yaml"

  # App name: dùng description nếu có, fallback sang name
  APP_NAME=$(grep "^description:" "$yaml" 2>/dev/null | sed 's/^description:[[:space:]]*//' | tr -d '"' | head -1)
  if [ -z "$APP_NAME" ]; then
    APP_NAME=$(grep "^name:" "$yaml" | awk '{print $2}' | head -1)
  fi

  # Flutter minimum version từ pubspec environment
  local f_ver
  f_ver=$(grep -A3 "^environment:" "$yaml" | grep "flutter:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  FLUTTER_MIN_VERSION="${f_ver:-3.0.0}"

  # Dart minimum version
  local d_ver
  d_ver=$(grep -A3 "^environment:" "$yaml" | grep "sdk:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  DART_MIN_VERSION="${d_ver:-3.0.0}"

  # Android App ID từ build.gradle hoặc build.gradle.kts
  ANDROID_APP_ID=""
  for gradle in \
    "$PROJECT_ROOT/android/app/build.gradle.kts" \
    "$PROJECT_ROOT/android/app/build.gradle"; do
    if [ -f "$gradle" ]; then
      ANDROID_APP_ID=$(grep -E 'applicationId\s*[=:]?\s*"[^"]+"' "$gradle" \
        | grep -oE '"[^"]+"' | tr -d '"' | head -1)
      [ -n "$ANDROID_APP_ID" ] && break
    fi
  done

  # iOS Bundle ID từ project.pbxproj
  IOS_BUNDLE_ID=""
  local pbxproj="$PROJECT_ROOT/ios/Runner.xcodeproj/project.pbxproj"
  if [ -f "$pbxproj" ]; then
    IOS_BUNDLE_ID=$(grep "PRODUCT_BUNDLE_IDENTIFIER" "$pbxproj" \
      | grep -v "Tests\|Widget\|Extension" \
      | grep -oE '= [^;]+;' | tr -d '= ;' \
      | grep -v '^\$(.*)\.' \
      | head -1)
  fi
}

# ─── Parse --project Argument ─────────────────────────────────────────────────
#
# Dùng trong từng script để extract --project trước khi parse các args khác.
# Usage: PROJECT_ARG=$(extract_project_arg "$@")

extract_project_arg() {
  local next_is_project=false
  for arg in "$@"; do
    if $next_is_project; then
      echo "$arg"
      return 0
    fi
    if [ "$arg" = "--project" ] || [ "$arg" = "-p" ]; then
      next_is_project=true
    fi
  done
  echo ""
}

# ─── Flutter Finder ───────────────────────────────────────────────────────────
#
# Luôn trả về ĐƯỜNG DẪN BINARY THỰC (không bao giờ là compound command như "fvm flutter").
# Điều này đảm bảo "$FLUTTER_CMD" hoạt động đúng ở mọi call site.
#
# Thứ tự ưu tiên:
#   1. FVM project-local  (.fvm/flutter_sdk — fvm use X)
#   2. fvm which flutter  (FVM 3.x, trả về path thực)
#   3. FVM global symlink (~/.fvm/default hoặc ~/fvm/default — fvm global X)
#   4. Scan FVM versions dir (lấy version mới nhất đã cài)
#   5. PATH / vị trí cài đặt phổ biến

find_flutter() {
  # 1. FVM project-local symlink
  if [ -n "${PROJECT_ROOT:-}" ] && [ -x "$PROJECT_ROOT/.fvm/flutter_sdk/bin/flutter" ]; then
    echo "$PROJECT_ROOT/.fvm/flutter_sdk/bin/flutter"
    return 0
  fi

  # 2. FVM installed — resolve actual binary path (không dùng compound "fvm flutter")
  if command -v fvm &>/dev/null; then
    # 2a. fvm which flutter — FVM 3.x trả về path đầy đủ
    local fvm_which
    fvm_which=$(fvm which flutter 2>/dev/null | grep -E '^/' | head -1 | tr -d '[:space:]')
    if [ -n "$fvm_which" ] && [ -x "$fvm_which" ]; then
      echo "$fvm_which"
      return 0
    fi

    # 2b. FVM global symlink — fvm global X tạo symlink này
    local fvm_home="${FVM_HOME:-}"
    for fvm_default in \
      "${fvm_home:+$fvm_home/default/bin/flutter}" \
      "$HOME/.fvm/default/bin/flutter" \
      "$HOME/fvm/default/bin/flutter"; do
      [ -z "$fvm_default" ] && continue
      if [ -x "$fvm_default" ]; then
        echo "$fvm_default"
        return 0
      fi
    done

    # 2c. Scan FVM versions dir — lấy version mới nhất đã cài
    for fvm_versions in \
      "${fvm_home:+$fvm_home/versions}" \
      "$HOME/fvm/versions" \
      "$HOME/.fvm/versions"; do
      [ -z "$fvm_versions" ] && continue
      if [ -d "$fvm_versions" ]; then
        local latest
        latest=$(ls -d "$fvm_versions"/*/bin/flutter 2>/dev/null \
          | sort -V | tail -1)
        if [ -n "$latest" ] && [ -x "$latest" ]; then
          echo "$latest"
          return 0
        fi
      fi
    done
    # FVM có nhưng chưa install version nào
    return 1
  fi

  # 3. Không có FVM — tìm trong PATH và vị trí phổ biến
  local flutter_path
  flutter_path=$(command -v flutter 2>/dev/null)
  if [ -n "$flutter_path" ]; then
    echo "$flutter_path"
    return 0
  fi

  for c in \
    "/opt/homebrew/share/flutter/bin/flutter" \
    "/opt/homebrew/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "$HOME/flutter/bin/flutter"; do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done

  return 1
}

FLUTTER_CMD="$(find_flutter 2>/dev/null || echo '')"

# ─── Version Utils ────────────────────────────────────────────────────────────

version_tuple() {
  echo "$1" | awk -F'.' '{printf "%05d%05d%05d", $1, $2, $3}'
}

version_gte() {
  [ "$(version_tuple "$1")" -ge "$(version_tuple "$2")" ]
}

# ─── Require Guards ───────────────────────────────────────────────────────────

require_flutter() {
  if [ -z "$FLUTTER_CMD" ]; then
    if command -v fvm &>/dev/null; then
      fail "FVM đã cài nhưng chưa có Flutter version nào active.\n  Chạy: fvm install <version> && fvm global <version>\n  Hoặc: flutter-auto setup --project $PROJECT_ROOT"
    else
      fail "Flutter không tìm thấy.\n  Cài qua FVM (khuyến nghị): flutter-auto setup --project $PROJECT_ROOT\n  Hoặc: https://docs.flutter.dev/get-started/install"
    fi
  fi
  # Thêm bin dir vào PATH để dart, pub, ... cũng hoạt động
  export PATH="$(dirname "$FLUTTER_CMD"):$PATH"
}

require_android_sdk() {
  if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    fail "ANDROID_HOME chưa set.\n  Chạy: $(basename "$0") env --setup-android"
  fi
  ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
  export ANDROID_HOME
}

require_project() {
  if [ -z "$PROJECT_ROOT" ] || [ ! -f "$PROJECT_ROOT/pubspec.yaml" ]; then
    fail "Project chưa được khởi tạo. Dùng --project <path> hoặc FLUTTER_PROJECT=<path>"
  fi
}

# ─── Logging ──────────────────────────────────────────────────────────────────

LOG_DIR="${LOG_DIR:-/tmp/flutter-automate}"

log_file() {
  mkdir -p "$LOG_DIR"
  echo "$LOG_DIR/$(date +%Y%m%d_%H%M%S)_$1.log"
}

# ─── Confirmation ─────────────────────────────────────────────────────────────

confirm() {
  local msg="${1:-Tiếp tục?}"
  local default="${2:-y}"
  if [ "$default" = "y" ]; then
    read -r -p "  ${msg} [Y/n] " reply
    reply="${reply:-y}"
  else
    read -r -p "  ${msg} [y/N] " reply
    reply="${reply:-n}"
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ─── OS / Environment Detection ───────────────────────────────────────────────

is_mac()   { [[ "$OSTYPE" == "darwin"* ]]; }
is_linux() { [[ "$OSTYPE" == "linux"*  ]]; }
is_ci()    { [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${BITRISE_IO:-}" ]; }
