#!/usr/bin/env bash
# vc-auto/flutter/dev/deps.sh
# Quản lý Flutter dependencies.
#
# Usage:
#   flutter-auto deps [--project <path>] [--update|--outdated|--check-env|--clean|--fix]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

MODE="get"

for arg in "$@"; do
  case "$arg" in
    --project|-p) ;;  # đã xử lý
    --update)    MODE="update"    ;;
    --outdated)  MODE="outdated"  ;;
    --check-env) MODE="check-env" ;;
    --clean)     MODE="clean"     ;;
    --fix)       MODE="fix"       ;;
  esac
done

# ─── Actions ──────────────────────────────────────────────────────────────────

do_get() {
  step "Installing dependencies"
  require_flutter

  cd "$PROJECT_ROOT"
  info "flutter pub get..."
  "$FLUTTER_CMD" pub get

  ok "Dependencies installed"
  echo ""
  local pkg_count
  pkg_count=$(grep -c "source:" pubspec.lock 2>/dev/null || echo "?")
  info "Tổng: ~$pkg_count packages (kể cả transitive)"
}

do_update() {
  step "Updating dependencies"
  require_flutter
  cd "$PROJECT_ROOT"

  info "flutter pub upgrade..."
  "$FLUTTER_CMD" pub upgrade 2>&1

  ok "Upgrade hoàn tất"

  # Sau khi upgrade, check environment constraints
  do_check_env
}

do_outdated() {
  step "Checking outdated packages"
  require_flutter
  cd "$PROJECT_ROOT"

  echo ""
  "$FLUTTER_CMD" pub outdated 2>&1
}

do_check_env() {
  step "Checking environment constraints"

  if command -v python3 &>/dev/null; then
    local checker="$PROJECT_ROOT/check_flutter_env.py"
    if [ -f "$checker" ]; then
      info "Chạy check_flutter_env.py..."
      python3 "$checker"
    else
      warn "check_flutter_env.py không tìm thấy ở project root"
      _manual_check_env
    fi
  else
    warn "Python3 không có — dùng manual check"
    _manual_check_env
  fi
}

_manual_check_env() {
  # Fallback: đọc pubspec.yaml hiện tại và so sánh với flutter version
  require_flutter

  local flutter_ver dart_ver
  flutter_ver=$("$FLUTTER_CMD" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  dart_ver=$("$FLUTTER_CMD" --version 2>/dev/null | grep 'Dart' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  local yaml="$PROJECT_ROOT/pubspec.yaml"
  local declared_flutter declared_dart

  declared_flutter=$(grep "flutter:" "$yaml" | grep -v "sdk:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  declared_dart=$(grep "sdk:" "$yaml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  echo ""
  echo "  Installed:   Flutter $flutter_ver  /  Dart $dart_ver"
  echo "  Declared:    Flutter >=${declared_flutter:-?}  /  Dart >=${declared_dart:-?}"
  echo ""

  if [ -n "$declared_flutter" ] && ! version_gte "$flutter_ver" "$declared_flutter"; then
    warn "Flutter $flutter_ver < declared minimum $declared_flutter"
  else
    ok "Flutter version OK"
  fi

  if [ -n "$declared_dart" ] && ! version_gte "$dart_ver" "$declared_dart"; then
    warn "Dart $dart_ver < declared minimum $declared_dart"
  else
    ok "Dart version OK"
  fi
}

do_clean() {
  step "Clean & reinstall"
  require_flutter
  cd "$PROJECT_ROOT"

  if ! is_ci; then
    warn "Sẽ xóa: .dart_tool/, build/, pubspec.lock"
    confirm "Tiếp tục?" || exit 0
  fi

  info "flutter clean..."
  "$FLUTTER_CMD" clean

  info "Xóa pubspec.lock..."
  rm -f pubspec.lock

  if is_mac && [ -d "ios/Pods" ]; then
    info "Xóa iOS Pods..."
    rm -rf ios/Pods ios/Podfile.lock
  fi

  info "flutter pub get (fresh)..."
  "$FLUTTER_CMD" pub get

  if is_mac && [ -f "ios/Podfile" ]; then
    info "pod install..."
    cd ios && pod install --repo-update 2>&1 | tail -5 && cd ..
  fi

  ok "Clean & reinstall hoàn tất"
}

do_fix() {
  step "Upgrade to major versions"
  require_flutter
  cd "$PROJECT_ROOT"

  warn "Lệnh này sẽ nâng cấp lên major versions mới (có thể breaking changes)"
  if ! is_ci; then
    confirm "Tiếp tục?" || exit 0
  fi

  "$FLUTTER_CMD" pub upgrade --major-versions 2>&1

  ok "Upgrade hoàn tất"
  warn "Hãy chạy tests để đảm bảo không có breaking changes:"
  echo "  flutter test"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header "Dependency Manager — $APP_NAME"
  require_project

  case "$MODE" in
    get)        do_get       ;;
    update)     do_update    ;;
    outdated)   do_outdated  ;;
    check-env)  do_check_env ;;
    clean)      do_clean     ;;
    fix)        do_fix       ;;
  esac

  echo ""
}

main
