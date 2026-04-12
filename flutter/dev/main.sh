#!/usr/bin/env bash
# vc-auto/flutter/dev/main.sh
# Entry point — interactive menu, project-agnostic.
#
# Usage:
#   flutter-auto                              # Menu (dùng pwd làm project)
#   flutter-auto /path/to/project            # Menu với project cụ thể
#   flutter-auto --project /path/to/project  # Tương đương
#   flutter-auto doctor [--project <path>]   # Pre-check tools
#   flutter-auto setup  [--project <path>]   # Setup môi trường
#   flutter-auto deps   [--project <path>]   # Quản lý dependencies
#   flutter-auto build  [--project <path>]   # Build app
#   flutter-auto deploy [--project <path>]   # Deploy lên stores
#   flutter-auto cicd   [--project <path>]   # Full CI/CD pipeline
#
# Hoặc dùng env var:
#   FLUTTER_PROJECT=/path/to/project flutter-auto

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse project path từ đầu args ──────────────────────────────────────────

PROJECT_ARG=""
CMD_ARGS=()

_parse_top_args() {
  local skip_next=false
  local first_positional=true
  for arg in "$@"; do
    if $skip_next; then
      PROJECT_ARG="$arg"; skip_next=false; continue
    fi
    if [ "$arg" = "--project" ] || [ "$arg" = "-p" ]; then
      skip_next=true; continue
    fi
    # Arg đầu tiên là directory → project path
    if $first_positional && [ -d "$arg" ] 2>/dev/null; then
      PROJECT_ARG="$arg"; first_positional=false; continue
    fi
    first_positional=false
    CMD_ARGS+=("$arg")
  done
}

_parse_top_args "$@"

# Build PROJECT_FLAG để truyền xuống sub-scripts
PROJECT_FLAG=()
if [ -n "$PROJECT_ARG" ]; then
  PROJECT_FLAG=("--project" "$PROJECT_ARG")
elif [ -n "${FLUTTER_PROJECT:-}" ]; then
  PROJECT_FLAG=("--project" "$FLUTTER_PROJECT")
fi

# ─── Shortcut Mode ────────────────────────────────────────────────────────────

if [ ${#CMD_ARGS[@]} -gt 0 ]; then
  cmd="${CMD_ARGS[0]}"
  rest=("${CMD_ARGS[@]:1}")
  case "$cmd" in
    local)  exec bash "$SCRIPT_DIR/local.sh"  "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    run)    exec bash "$SCRIPT_DIR/run.sh"    "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    doctor) exec bash "$SCRIPT_DIR/doctor.sh" "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    setup)  exec bash "$SCRIPT_DIR/setup.sh"  "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    deps)   exec bash "$SCRIPT_DIR/deps.sh"   "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    build)  exec bash "$SCRIPT_DIR/build.sh"  "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    deploy) exec bash "$SCRIPT_DIR/deploy.sh" "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    cicd)   exec bash "$SCRIPT_DIR/cicd.sh"   "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${rest[@]+"${rest[@]}"}" ;;
    env-init) exec bash "$SCRIPT_DIR/setup.sh" "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" --env-init "${rest[@]+"${rest[@]}"}" ;;
    help|-h|--help) :;;
    *)
      echo -e "${RED}Unknown command: $cmd${NC}"
      echo "Chạy không có argument để xem interactive menu."
      exit 1
      ;;
  esac
fi

# ─── Init project cho interactive menu ───────────────────────────────────────

init_project "${PROJECT_ARG:-}"

# ─── Interactive Menu ─────────────────────────────────────────────────────────

_run() {
  bash "$SCRIPT_DIR/$1.sh" "${PROJECT_FLAG[@]+"${PROJECT_FLAG[@]}"}" "${@:2}"
}

show_header() {
  clear
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║         Flutter Automation — vc-auto             ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Project : ${CYAN}$APP_NAME${NC}"
  echo -e "  Path    : ${GRAY}$PROJECT_ROOT${NC}"

  if [ -n "$FLUTTER_CMD" ]; then
    local fv
    fv=$("$FLUTTER_CMD" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "  Flutter : ${GREEN}$fv${NC}"
  else
    echo -e "  Flutter : ${RED}not found${NC}"
  fi

  local ver branch
  ver=$(grep "^version:" "$PROJECT_ROOT/pubspec.yaml" 2>/dev/null | awk '{print $2}')
  branch=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo '?')
  echo -e "  Version : ${CYAN}$ver${NC}  Branch: ${CYAN}$branch${NC}"
  echo ""
}

show_menu() {
  echo -e "  ${BOLD}Development${NC}"
  echo -e "  ${CYAN}1${NC}  Local dev  ${GRAY}(doctor → setup → deps → run)${NC}"
  echo -e "  ${CYAN}2${NC}  Run app    ${GRAY}(flutter run)${NC}"
  echo ""
  echo -e "  ${BOLD}Project${NC}"
  echo -e "  ${CYAN}3${NC}  Pre-check tools"
  echo -e "  ${CYAN}4${NC}  Setup environment"
  echo -e "  ${CYAN}5${NC}  Manage dependencies"
  echo ""
  echo -e "  ${BOLD}Deploy${NC}"
  echo -e "  ${CYAN}6${NC}  Build app"
  echo -e "  ${CYAN}7${NC}  Deploy to stores"
  echo -e "  ${CYAN}8${NC}  Full CI/CD pipeline"
  echo ""
  echo -e "  ${GRAY}0  Exit${NC}"
  echo ""
}

submenu_build() {
  echo ""
  echo -e "  ${BOLD}Build:${NC}"
  echo -e "  ${CYAN}1${NC}  Android AAB (release)"
  echo -e "  ${CYAN}2${NC}  Android APK (debug)"
  echo -e "  ${CYAN}3${NC}  iOS IPA (release)"
  echo -e "  ${CYAN}4${NC}  iOS (debug, no codesign)"
  echo -e "  ${CYAN}5${NC}  Android + iOS (release)"
  echo -e "  ${GRAY}0  Quay lại${NC}"
  echo ""; read -r -p "  Chọn: " c
  case "$c" in
    1) _run build --android --aab --release ;;
    2) _run build --android --apk --debug ;;
    3) _run build --ios --release ;;
    4) _run build --ios --debug ;;
    5) _run build --release ;;
    0) return ;;
  esac
}

submenu_deploy() {
  echo ""
  echo -e "  ${BOLD}Deploy:${NC}"
  echo -e "  ${CYAN}1${NC}  Google Play — Internal"
  echo -e "  ${CYAN}2${NC}  Google Play — Alpha"
  echo -e "  ${CYAN}3${NC}  Google Play — Beta"
  echo -e "  ${CYAN}4${NC}  Google Play — Production"
  echo -e "  ${CYAN}5${NC}  App Store — TestFlight"
  echo -e "  ${CYAN}6${NC}  App Store — Production"
  echo -e "  ${CYAN}7${NC}  Cả hai (Internal + TestFlight)"
  echo -e "  ${GRAY}0  Quay lại${NC}"
  echo ""; read -r -p "  Chọn: " c
  case "$c" in
    1) _run deploy --android --track internal ;;
    2) _run deploy --android --track alpha ;;
    3) _run deploy --android --track beta ;;
    4) _run deploy --android --track production ;;
    5) _run deploy --ios --testflight ;;
    6) _run deploy --ios ;;
    7) _run deploy --track internal --testflight ;;
    0) return ;;
  esac
}

submenu_deps() {
  echo ""
  echo -e "  ${BOLD}Dependencies:${NC}"
  echo -e "  ${CYAN}1${NC}  flutter pub get"
  echo -e "  ${CYAN}2${NC}  flutter pub upgrade"
  echo -e "  ${CYAN}3${NC}  Outdated packages"
  echo -e "  ${CYAN}4${NC}  Check environment constraints"
  echo -e "  ${CYAN}5${NC}  Clean & reinstall"
  echo -e "  ${GRAY}0  Quay lại${NC}"
  echo ""; read -r -p "  Chọn: " c
  case "$c" in
    1) _run deps ;;
    2) _run deps --update ;;
    3) _run deps --outdated ;;
    4) _run deps --check-env ;;
    5) _run deps --clean ;;
    0) return ;;
  esac
}

submenu_cicd() {
  echo ""
  echo -e "  ${BOLD}CI/CD Pipeline:${NC}"
  echo -e "  ${CYAN}1${NC}  Full pipeline (Android + iOS)"
  echo -e "  ${CYAN}2${NC}  Android only"
  echo -e "  ${CYAN}3${NC}  iOS only"
  echo -e "  ${CYAN}4${NC}  Staging (skip deploy)"
  echo -e "  ${CYAN}5${NC}  Tests only"
  echo -e "  ${GRAY}0  Quay lại${NC}"
  echo ""; read -r -p "  Chọn: " c
  case "$c" in
    1) _run cicd ;;
    2) _run cicd --android ;;
    3) _run cicd --ios ;;
    4) _run cicd --env staging --skip-deploy ;;
    5) _run cicd --stage test ;;
    0) return ;;
  esac
}

submenu_run() {
  echo ""
  echo -e "  ${BOLD}Run:${NC}"
  echo -e "  ${CYAN}1${NC}  Auto-detect device"
  echo -e "  ${CYAN}2${NC}  Android emulator/device"
  echo -e "  ${CYAN}3${NC}  iOS simulator/device"
  echo -e "  ${CYAN}4${NC}  Xem danh sách devices"
  echo -e "  ${GRAY}0  Quay lại${NC}"
  echo ""; read -r -p "  Chọn: " c
  case "$c" in
    1) _run run ;;
    2) _run run --android ;;
    3) _run run --ios ;;
    4) _run run --devices ;;
    0) return ;;
  esac
}

main() {
  while true; do
    show_header
    show_menu
    read -r -p "  Chọn [0-8]: " choice
    case "$choice" in
      1) _run local ;;
      2) submenu_run ;;
      3) _run doctor ;;
      4) _run setup ;;
      5) submenu_deps ;;
      6) submenu_build ;;
      7) submenu_deploy ;;
      8) submenu_cicd ;;
      0) echo ""; ok "Goodbye!"; echo ""; exit 0 ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
    echo ""; read -r -p "  Nhấn Enter để quay lại menu..." _
  done
}

main
