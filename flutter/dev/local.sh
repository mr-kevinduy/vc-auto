#!/usr/bin/env bash
# vc-auto/flutter/dev/local.sh
# Local development workflow.
#
# Flow: doctor(local) → setup(nếu cần) → deps → run(debug)
#
# Usage:
#   flutter-auto local [--project <path>]
#   flutter-auto local --android                # Chạy trên Android device/emulator
#   flutter-auto local --ios                    # Chạy trên iOS simulator/device
#   flutter-auto local --device <id>            # Device cụ thể
#   flutter-auto local --flavor <name>          # Flavor (default: local)
#   flutter-auto local --check                  # analyze + test, không run app
#   flutter-auto local --skip-doctor            # Bỏ qua doctor check
#   flutter-auto local --skip-setup             # Bỏ qua setup
#   flutter-auto local --skip-deps              # Bỏ qua pub get
#
# Khác với deploy: không cần signing, store credentials, Fastlane.
# Build mode luôn là debug.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/env.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

PLATFORM=""
DEVICE_ID=""
SKIP_DOCTOR=false
SKIP_SETUP=false
SKIP_DEPS=false
CHECK_ONLY=false
FLAVOR="local"

_skip_next=false
for arg in "$@"; do
  if $_skip_next; then _skip_next=false; continue; fi
  case "$arg" in
    --project|-p)    _skip_next=true ;;
    --android)       PLATFORM="android" ;;
    --ios)           PLATFORM="ios" ;;
    --device)        _skip_next=true; DEVICE_ID="${arg#*=}" ;;
    --flavor)        _skip_next=true ;;
    --skip-doctor)   SKIP_DOCTOR=true ;;
    --skip-setup)    SKIP_SETUP=true ;;
    --skip-deps)     SKIP_DEPS=true ;;
    --check)         CHECK_ONLY=true ;;
  esac
done

# Re-parse values cho args có value
for i in "$@"; do
  case "$i" in
    --device=*)  DEVICE_ID="${i#--device=}" ;;
    --flavor=*)  FLAVOR="${i#--flavor=}" ;;
  esac
done
# Dạng --device <val> và --flavor <val>
prev=""
for arg in "$@"; do
  case "$prev" in
    --device) DEVICE_ID="$arg" ;;
    --flavor) FLAVOR="$arg" ;;
  esac
  prev="$arg"
done

# ─── Step 1: Doctor (local mode) ──────────────────────────────────────────────

run_doctor() {
  step "1/4  Doctor (local)"

  local exit_code=0
  bash "$SCRIPT_DIR/doctor.sh" \
    --project "$PROJECT_ROOT" \
    --local \
    2>&1 || exit_code=$?

  # Exit code 2 = conflict pubspec.yaml chưa được fix
  # Doctor đã hiển thị chi tiết và prompt — chỉ cần dừng ở đây
  if [ "$exit_code" -eq 2 ]; then
    fail "Local dev bị hủy do conflict pubspec.yaml chưa giải quyết.\n  Fix xong chạy lại: flutter-auto local --project $PROJECT_ROOT"
  fi

  # Exit code 1 = thiếu tools — tiếp tục vào setup để cài
  if [ "$exit_code" -ne 0 ]; then
    echo ""
    warn "Doctor phát hiện thiếu tools (exit $exit_code) — setup sẽ fix"
  fi
}

# ─── Step 2: Setup (chỉ khi cần) ──────────────────────────────────────────────

run_setup() {
  step "2/4  Setup"

  # Refresh FLUTTER_CMD sau khi có thể setup
  if [ -z "$FLUTTER_CMD" ]; then
    info "Flutter chưa tìm thấy — chạy setup Flutter..."
    bash "$SCRIPT_DIR/setup.sh" \
      --project "$PROJECT_ROOT" \
      --flutter \
      --skip-preflight
    # Reload
    FLUTTER_CMD="$(find_flutter 2>/dev/null || echo '')"
  else
    local flutter_ver
    flutter_ver=$("$FLUTTER_CMD" --version 2>/dev/null \
      | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ok "Flutter $flutter_ver — OK"
  fi

  # iOS: pod install nếu Podfile.lock chưa có
  if is_mac && [ -f "$PROJECT_ROOT/ios/Podfile" ] \
     && [ ! -f "$PROJECT_ROOT/ios/Podfile.lock" ]; then
    info "Podfile.lock chưa có — chạy pod install..."
    bash "$SCRIPT_DIR/setup.sh" \
      --project "$PROJECT_ROOT" \
      --ios \
      --skip-preflight
  else
    [ -f "$PROJECT_ROOT/ios/Podfile.lock" ] && ok "CocoaPods — OK" || true
  fi
}

# ─── Step 3: Dependencies ──────────────────────────────────────────────────────

run_deps() {
  step "3/4  Dependencies"
  bash "$SCRIPT_DIR/deps.sh" --project "$PROJECT_ROOT"
}

# ─── Step 4a: Run app ──────────────────────────────────────────────────────────

run_app() {
  step "4/4  Run — $APP_NAME [$FLAVOR • debug]"
  require_flutter

  # Load env vars cho flavor
  if env_load "$FLAVOR" "$PROJECT_ROOT"; then
    info "Env loaded: $(vc_config_env_file "$FLAVOR" "$PROJECT_ROOT")"
  else
    warn ".env.$FLAVOR không tìm thấy — không inject env vars"
    info "Tạo: flutter-auto env-init  hoặc  touch $PROJECT_ROOT/.env.$FLAVOR"
  fi

  # Dart define args
  local env_args=()
  IFS=' ' read -ra env_args <<< "$(env_dart_args "$FLAVOR" "$PROJECT_ROOT")"

  # Device selection
  local run_args=()
  if [ -n "$DEVICE_ID" ]; then
    run_args+=("--device-id" "$DEVICE_ID")
  elif [ -n "$PLATFORM" ]; then
    local grep_pattern
    case "$PLATFORM" in
      android) grep_pattern="android\|emulator" ;;
      ios)     grep_pattern="ios\|iphone\|ipad\|simulator" ;;
    esac
    local detected_device
    detected_device=$("$FLUTTER_CMD" devices 2>/dev/null \
      | grep -iE "$grep_pattern" | head -1 \
      | awk -F'•' '{print $2}' | tr -d ' ' || echo "")
    if [ -n "$detected_device" ]; then
      run_args+=("--device-id" "$detected_device")
      info "Device: $detected_device"
    else
      warn "Không tìm thấy $PLATFORM device — Flutter sẽ tự chọn"
      info "Xem danh sách: flutter-auto run --devices"
    fi
  fi

  echo ""
  echo -e "  ${GRAY}Hot reload: r  |  Hot restart: R  |  Quit: q${NC}"
  echo ""

  cd "$PROJECT_ROOT"
  "$FLUTTER_CMD" run \
    --debug \
    "${env_args[@]+"${env_args[@]}"}" \
    "${run_args[@]+"${run_args[@]}"}"
}

# ─── Step 4b: Check (analyze + test) ─────────────────────────────────────────

run_check() {
  step "4/4  Check — $APP_NAME"
  bash "$SCRIPT_DIR/run.sh" --project "$PROJECT_ROOT" --check
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  vc_config_load "$PROJECT_ROOT" || true

  header "Local Dev — $APP_NAME"
  require_project

  # Header info
  echo -e "  Project : ${CYAN}$PROJECT_ROOT${NC}"
  echo -e "  Mode    : ${GREEN}debug${NC}  (local development)"
  env_status "$FLAVOR" "$PROJECT_ROOT"
  echo ""

  $SKIP_DOCTOR || run_doctor
  $SKIP_SETUP  || run_setup
  $SKIP_DEPS   || run_deps

  if $CHECK_ONLY; then
    run_check
  else
    run_app
  fi
}

main
