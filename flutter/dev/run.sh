#!/usr/bin/env bash
# vc-auto/flutter/dev/run.sh
# Chạy app, test, analyze cho development.
#
# Dùng cho DEVELOPMENT — không build release, không deploy.
#
# Usage:
#   flutter-auto run [--project <path>] [--android|--ios|--device <id>]
#   flutter-auto run --test              # flutter test --coverage
#   flutter-auto run --analyze           # flutter analyze
#   flutter-auto run --check             # analyze + test (full check trước khi commit)
#   flutter-auto run --device <id>       # Chạy trên device cụ thể
#   flutter-auto run --android           # Chạy trên Android emulator/device
#   flutter-auto run --ios               # Chạy trên iOS simulator/device
#   flutter-auto run                     # flutter run (tự chọn device)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

MODE="run"          # run | test | analyze | check | devices
DEVICE_ID=""
PLATFORM=""         # android | ios | ""
FLAVOR=""
DEBUG_PORT=""

for arg in "$@"; do
  case "$arg" in
    --project|-p)  ;;
    --test)        MODE="test" ;;
    --analyze)     MODE="analyze" ;;
    --check)       MODE="check" ;;
    --devices)     MODE="devices" ;;
    --android)     PLATFORM="android" ;;
    --ios)         PLATFORM="ios" ;;
    --device)      shift; DEVICE_ID="${1:-}" ;;
    --flavor)      shift; FLAVOR="${1:-}" ;;
    --port)        shift; DEBUG_PORT="${1:-}" ;;
  esac
done

# ─── List Devices ─────────────────────────────────────────────────────────────

list_devices() {
  step "Connected Devices"
  require_flutter
  "$FLUTTER_CMD" devices 2>&1
}

# ─── Project Setup Hook ───────────────────────────────────────────────────────

run_project_setup() {
  local setup="$PROJECT_ROOT/scripts/setup.sh"
  [ -f "$setup" ] || return 0

  step "Project Setup — scripts/setup.sh"
  chmod +x "$PROJECT_ROOT/scripts/"*.sh 2>/dev/null || true
  info "Chạy $setup ..."
  bash "$setup"
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    fail "scripts/setup.sh thất bại (exit $exit_code) — hủy run"
  fi
  ok "scripts/setup.sh hoàn tất"
  echo ""
}

# ─── Flutter Run ──────────────────────────────────────────────────────────────

do_run() {
  step "Flutter Run — $APP_NAME"
  require_flutter

  cd "$PROJECT_ROOT"

  run_project_setup

  # Kiểm tra dependencies
  if [ ! -d "$PROJECT_ROOT/.dart_tool" ]; then
    info "Chưa có .dart_tool — chạy pub get trước..."
    "$FLUTTER_CMD" pub get
    echo ""
  fi

  local run_args=()

  # Device selection
  if [ -n "$DEVICE_ID" ]; then
    run_args+=("--device-id" "$DEVICE_ID")
  elif [ "$PLATFORM" = "android" ]; then
    # Tìm Android emulator/device đang connected
    local android_device
    android_device=$("$FLUTTER_CMD" devices 2>/dev/null \
      | grep -i "android\|emulator" | grep -v "web" | head -1 \
      | awk -F'•' '{print $2}' | tr -d ' ' || echo "")
      
    if [ -z "$android_device" ]; then
      warn "Không tìm thấy Android device/emulator đang chạy"
      info "Tìm kiếm emulator khả dụng..."
      local emu_id
      emu_id=$("$FLUTTER_CMD" emulators 2>/dev/null \
        | grep -i "android" | head -1 \
        | awk -F'•' '{print $1}' | tr -d ' ' || echo "")
        
      if [ -n "$emu_id" ]; then
        info "Đang khởi động Android emulator: $emu_id"
        "$FLUTTER_CMD" emulators --launch "$emu_id" >/dev/null 2>&1 &
        info "Chờ emulator khởi động (10s)..."
        sleep 10
        
        android_device=$("$FLUTTER_CMD" devices 2>/dev/null \
          | grep -i "android\|emulator" | grep -v "web" | head -1 \
          | awk -F'•' '{print $2}' | tr -d ' ' || echo "")
      else
        warn "Không có emulator Android nào được cài đặt. Hãy mở Android Studio để tạo."
      fi
    fi

    if [ -n "$android_device" ]; then
      run_args+=("--device-id" "$android_device")
      info "Device: $android_device"
    else
      warn "Vẫn không tìm thấy Android device. Để tự động chọn, lệnh chạy sẽ bỏ qua --device-id."
    fi

  elif [ "$PLATFORM" = "ios" ]; then
    local ios_device
    ios_device=$("$FLUTTER_CMD" devices 2>/dev/null \
      | grep -i "ios\|iphone\|ipad\|simulator" | grep -v "web\|macOS" | head -1 \
      | awk -F'•' '{print $2}' | tr -d ' ' || echo "")
      
    if [ -z "$ios_device" ]; then
      warn "Không tìm thấy iOS Simulator đang chạy."
      
      if open_simulator; then
         info "Đang khởi động Simulator..."
         info "Chờ Simulator boot (8s)..."
         sleep 8
         
         ios_device=$("$FLUTTER_CMD" devices 2>/dev/null \
           | grep -i "ios\|iphone\|ipad\|simulator" | grep -v "web\|macOS" | head -1 \
           | awk -F'•' '{print $2}' | tr -d ' ' || echo "")
      else
         warn "Không thể khởi chạy iOS Simulator trên hệ điều hành này."
      fi
    fi

    if [ -n "$ios_device" ]; then
      run_args+=("--device-id" "$ios_device")
      info "Device: $ios_device"
    else
      warn "Vẫn không tìm thấy iOS device. Lệnh chạy sẽ bỏ qua định danh device cụ thể."
    fi
  fi

  [ -n "$FLAVOR" ]     && run_args+=("--flavor" "$FLAVOR")
  [ -n "$DEBUG_PORT" ] && run_args+=("--observatory-port" "$DEBUG_PORT")

  echo ""
  info "Lệnh: $FLUTTER_CMD run ${run_args[*]}"
  echo -e "  ${GRAY}Hot reload: r   |   Hot restart: R   |   Quit: q${NC}"
  echo ""

  "$FLUTTER_CMD" run "${run_args[@]+"${run_args[@]}"}"
}

# ─── Flutter Analyze ──────────────────────────────────────────────────────────

do_analyze() {
  step "Flutter Analyze"
  require_flutter
  cd "$PROJECT_ROOT"

  info "Chạy flutter analyze..."
  local log_file
  log_file=$(log_file "analyze")

  local exit_code=0
  "$FLUTTER_CMD" analyze 2>&1 | tee "$log_file" || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    ok "Analyze: không có lỗi"
  else
    echo ""
    warn "Analyze phát hiện lỗi. Xem log: $log_file"
    return "$exit_code"
  fi
}

# ─── Flutter Test ─────────────────────────────────────────────────────────────

do_test() {
  step "Flutter Test"
  require_flutter
  cd "$PROJECT_ROOT"

  # Kiểm tra có test file không
  if [ -z "$(find "$PROJECT_ROOT/test" -name "*_test.dart" 2>/dev/null | head -1)" ]; then
    warn "Không tìm thấy file test trong test/"
    info "Tạo test đầu tiên: test/widget_test.dart"
    return 0
  fi

  info "Chạy flutter test --coverage..."
  local log_file
  log_file=$(log_file "test")

  local exit_code=0
  "$FLUTTER_CMD" test --coverage 2>&1 | tee "$log_file" || exit_code=$?

  # Coverage report
  if [ -f "$PROJECT_ROOT/coverage/lcov.info" ]; then
    local covered total pct
    covered=$(grep -E "^DA:" "$PROJECT_ROOT/coverage/lcov.info" | grep -v ",0$" | wc -l | tr -d ' ')
    total=$(grep -E "^DA:" "$PROJECT_ROOT/coverage/lcov.info" | wc -l | tr -d ' ')

    if [ "$total" -gt 0 ]; then
      pct=$(( covered * 100 / total ))
      echo ""
      if [ "$pct" -ge 80 ]; then
        ok "Coverage: ${pct}% (mục tiêu ≥80% ✓)"
      else
        warn "Coverage: ${pct}% (mục tiêu ≥80% — cần thêm tests)"
      fi
    fi
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo ""
    warn "Test thất bại. Xem log: $log_file"
    return "$exit_code"
  else
    ok "Tất cả tests passed"
  fi
}

# ─── Full Check (analyze + test) ──────────────────────────────────────────────

do_check() {
  step "Pre-commit Check — $APP_NAME"
  echo -e "  ${GRAY}analyze + test — chạy trước khi commit${NC}"
  echo ""

  local failed=false

  do_analyze || failed=true
  echo ""
  do_test    || failed=true

  echo ""
  if $failed; then
    fail "Check thất bại — sửa lỗi trước khi commit"
  else
    ok "Tất cả checks passed — sẵn sàng commit"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  require_project
  cd "$PROJECT_ROOT"

  case "$MODE" in
    devices) list_devices ;;
    run)     do_run       ;;
    analyze) do_analyze   ;;
    test)    do_test      ;;
    check)   do_check     ;;
    *)       fail "Mode không hợp lệ: $MODE" ;;
  esac
}

main
