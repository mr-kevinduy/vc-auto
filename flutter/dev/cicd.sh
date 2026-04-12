#!/usr/bin/env bash
# vc-auto/flutter/dev/cicd.sh
# Full CI/CD pipeline: doctor → deps → test → build → deploy
#
# Usage:
#   flutter-auto cicd [--project <path>] [--android|--ios] [--env <env>] [--stage <stage>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

PLATFORM="all"
ENV="prod"
STAGE=""
SKIP_TEST=false
SKIP_DEPLOY=false
PLAY_TRACK="internal"
TESTFLIGHT_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --project|-p)  ;;  # đã xử lý
    --android)     PLATFORM="android" ;;
    --ios)         PLATFORM="ios" ;;
    --env)         shift; ENV="${1:-prod}" ;;
    --stage)       shift; STAGE="${1:-}" ;;
    --skip-test)   SKIP_TEST=true ;;
    --skip-deploy) SKIP_DEPLOY=true ;;
    --play-track)  shift; PLAY_TRACK="${1:-internal}" ;;
    --testflight)  TESTFLIGHT_ONLY=true ;;
  esac
done

# ─── Pipeline State ───────────────────────────────────────────────────────────

PIPELINE_START=$SECONDS
declare -A STAGE_STATUS=()
declare -A STAGE_DURATION=()

stage_start() {
  echo ""
  echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${BLUE}│  Stage: $(printf '%-33s' "$1")│${NC}"
  echo -e "${BOLD}${BLUE}└─────────────────────────────────────────┘${NC}"
  STAGE_STATUS["$1"]="running"
  _STAGE_START=$SECONDS
}

stage_done() {
  local name="$1"
  local elapsed=$((SECONDS - _STAGE_START))
  STAGE_STATUS["$name"]="✅ passed"
  STAGE_DURATION["$name"]="${elapsed}s"
  ok "Stage '$name' hoàn tất [${elapsed}s]"
}

stage_fail() {
  local name="$1"
  local elapsed=$((SECONDS - _STAGE_START))
  STAGE_STATUS["$name"]="❌ failed"
  STAGE_DURATION["$name"]="${elapsed}s"
  echo -e "${RED}  ✗ Stage '$name' thất bại [${elapsed}s]${NC}"
}

stage_skip() {
  local name="$1"
  STAGE_STATUS["$name"]="⏭  skipped"
  STAGE_DURATION["$name"]="-"
  skip "Stage '$name'"
}

# ─── Stages ───────────────────────────────────────────────────────────────────

_proj_flag() { echo "--project" "$PROJECT_ROOT"; }

run_check() {
  stage_start "doctor"
  local check_args="--strict $(_proj_flag)"
  case "$PLATFORM" in
    android) check_args="$check_args --android" ;;
    ios)     check_args="$check_args --ios" ;;
  esac

  if bash "$SCRIPT_DIR/doctor.sh" $check_args; then
    stage_done "doctor"
  else
    stage_fail "doctor"
    fail "Pre-check thất bại — pipeline dừng"
  fi
}

run_deps() {
  stage_start "deps"
  if bash "$SCRIPT_DIR/deps.sh" "$(_proj_flag)"; then
    stage_done "deps"
  else
    stage_fail "deps"
    fail "Dependency install thất bại"
  fi
}

run_test() {
  if $SKIP_TEST; then
    stage_skip "test"
    return
  fi

  stage_start "test"
  require_flutter
  cd "$PROJECT_ROOT"

  local log_file
  log_file=$(log_file "test")

  info "flutter analyze..."
  if ! "$FLUTTER_CMD" analyze 2>&1 | tee "$log_file" | tail -5; then
    stage_fail "test"
    fail "flutter analyze thất bại"
  fi

  info "flutter test..."
  if ! "$FLUTTER_CMD" test --coverage 2>&1 | tee -a "$log_file" | tail -10; then
    stage_fail "test"
    fail "flutter test thất bại"
  fi

  # Coverage check
  if [ -f "coverage/lcov.info" ]; then
    local covered total pct
    covered=$(grep -E "^DA:" coverage/lcov.info | grep -v ",0$" | wc -l | tr -d ' ')
    total=$(grep -E "^DA:" coverage/lcov.info | wc -l | tr -d ' ')
    if [ "$total" -gt 0 ]; then
      pct=$(( covered * 100 / total ))
      if [ "$pct" -ge 80 ]; then
        ok "Test coverage: $pct% (≥80% ✓)"
      else
        warn "Test coverage: $pct% (<80% — xem xét thêm tests)"
      fi
    fi
  fi

  stage_done "test"
}

run_build() {
  stage_start "build"

  local build_args="--env $ENV --release"
  case "$PLATFORM" in
    android) build_args="$build_args --android" ;;
    ios)     build_args="$build_args --ios" ;;
    all)     ;;
  esac

  if bash "$SCRIPT_DIR/build.sh" $build_args "$(_proj_flag)"; then
    stage_done "build"
  else
    stage_fail "build"
    fail "Build thất bại"
  fi
}

run_deploy() {
  if $SKIP_DEPLOY; then
    stage_skip "deploy"
    return
  fi

  stage_start "deploy"

  local deploy_args="--env $ENV"
  case "$PLATFORM" in
    android) deploy_args="$deploy_args --android --track $PLAY_TRACK" ;;
    ios)     deploy_args="$deploy_args --ios $( $TESTFLIGHT_ONLY && echo '--testflight' || echo '' )" ;;
    all)     deploy_args="$deploy_args --track $PLAY_TRACK" ;;
  esac

  if bash "$SCRIPT_DIR/deploy.sh" $deploy_args "$(_proj_flag)"; then
    stage_done "deploy"
  else
    stage_fail "deploy"
    fail "Deploy thất bại"
  fi
}

# ─── Pipeline Summary ─────────────────────────────────────────────────────────

print_pipeline_summary() {
  local total_elapsed=$((SECONDS - PIPELINE_START))
  local has_failure=false

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║           Pipeline Summary                   ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"

  for stage in doctor deps test build deploy; do
    local status="${STAGE_STATUS[$stage]:-⏭  skipped}"
    local duration="${STAGE_DURATION[$stage]:--}"
    printf "${BOLD}║${NC}  %-12s  %-22s  %6s  ${BOLD}║${NC}\n" \
      "$stage" "$status" "$duration"
    if [[ "$status" == *"failed"* ]]; then
      has_failure=true
    fi
  done

  echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
  printf "${BOLD}║${NC}  %-12s  %-22s  %6s  ${BOLD}║${NC}\n" \
    "TOTAL" "" "${total_elapsed}s"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  if $has_failure; then
    echo -e "  ${RED}${BOLD}Pipeline FAILED${NC}"
    echo ""
    return 1
  else
    echo -e "  ${GREEN}${BOLD}Pipeline PASSED ✓${NC}"
    echo ""
    return 0
  fi
}

# ─── GitHub Actions Output ────────────────────────────────────────────────────

# Nếu đang chạy trong GitHub Actions, set output variables
set_github_outputs() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    local version
    version=$(grep "^version:" "$PROJECT_ROOT/pubspec.yaml" | awk '{print $2}')
    echo "version=$version" >> "$GITHUB_OUTPUT"
    echo "env=$ENV" >> "$GITHUB_OUTPUT"
    echo "platform=$PLATFORM" >> "$GITHUB_OUTPUT"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header "CI/CD Pipeline — $APP_NAME"
  require_project
  cd "$PROJECT_ROOT"

  local version
  version=$(grep "^version:" "$PROJECT_ROOT/pubspec.yaml" | awk '{print $2}')

  echo "  Platform : $PLATFORM"
  echo "  Env      : $ENV"
  echo "  Version  : $version"
  echo "  CI mode  : $(is_ci && echo 'yes' || echo 'no')"
  echo ""

  # Single stage mode
  if [ -n "$STAGE" ]; then
    case "$STAGE" in
      doctor) run_check  ;;
      deps)   run_deps   ;;
      test)   run_test   ;;
      build)  run_build  ;;
      deploy) run_deploy ;;
      *)      fail "Stage không hợp lệ: $STAGE (doctor|deps|test|build|deploy)" ;;
    esac
    return
  fi

  # Full pipeline
  run_check
  run_deps
  run_test
  run_build
  run_deploy

  set_github_outputs
  print_pipeline_summary
}

main
