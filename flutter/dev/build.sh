#!/usr/bin/env bash
# vc-auto/flutter/dev/build.sh
# Build Flutter app cho Android và iOS.
#
# Usage:
#   flutter-auto build [--project <path>] [--android|--ios] [--debug|--release]
#   flutter-auto build --env <stage>          # Tự động detect mode từ .vc-auto.yaml
#   flutter-auto build --flavor <name>        # Flutter flavor (= --env shorthand)
#   flutter-auto build --parallel             # Build Android + iOS song song

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/env.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

BUILD_ANDROID=false
BUILD_IOS=false
BUILD_MODE=""          # tự detect từ .vc-auto.yaml nếu để trống
ANDROID_FORMAT="aab"
ENV="prod"
FLAVOR=""              # Flutter flavor name (trùng với ENV nếu không set riêng)
VERSION_OVERRIDE=""
EXTRA_ARGS=""
PARALLEL=false
MODE_OVERRIDE=false    # true khi user tường minh chỉ định --debug/--release

_skip_next=false
for arg in "$@"; do
  if $_skip_next; then _skip_next=false; continue; fi
  case "$arg" in
    --project|-p)     _skip_next=true ;;
    --android)        BUILD_ANDROID=true ;;
    --ios)            BUILD_IOS=true ;;
    --apk)            ANDROID_FORMAT="apk" ;;
    --aab)            ANDROID_FORMAT="aab" ;;
    --debug)          BUILD_MODE="debug";   MODE_OVERRIDE=true ;;
    --profile)        BUILD_MODE="profile"; MODE_OVERRIDE=true ;;
    --release)        BUILD_MODE="release"; MODE_OVERRIDE=true ;;
    --env|--flavor)   _skip_next=true ;;
    --version)        _skip_next=true ;;
    --no-shrink)      EXTRA_ARGS="$EXTRA_ARGS --no-shrink" ;;
    --parallel)       PARALLEL=true ;;
  esac
done

# Re-parse values
prev=""
for arg in "$@"; do
  case "$prev" in
    --env)     ENV="$arg" ;;
    --flavor)  FLAVOR="$arg"; ENV="$arg" ;;
    --version) VERSION_OVERRIDE="$arg" ;;
  esac
  prev="$arg"
done

# Nếu không chỉ định platform, build cả 2
if ! $BUILD_ANDROID && ! $BUILD_IOS; then
  BUILD_ANDROID=true
  BUILD_IOS=true
fi

# Load project config
vc_config_load "$PROJECT_ROOT" || true

# Tự detect build mode từ .vc-auto.yaml nếu user không chỉ định tường minh
if [ -z "$BUILD_MODE" ]; then
  BUILD_MODE=$(env_build_mode "$ENV")
fi

# Flavor = ENV nếu không set riêng
[ -z "$FLAVOR" ] && FLAVOR="$ENV"

# ─── Helpers ──────────────────────────────────────────────────────────────────

get_version() {
  if [ -n "$VERSION_OVERRIDE" ]; then
    echo "$VERSION_OVERRIDE"
  else
    grep "^version:" "$PROJECT_ROOT/pubspec.yaml" | awk '{print $2}'
  fi
}

get_build_number() {
  echo "$1" | grep -oE '\+[0-9]+' | tr -d '+' || echo ""
}

# Trả về array các dart args (env file hoặc fallback dart-define)
_build_env_args() {
  local args_str
  args_str=$(env_dart_args "$ENV" "$PROJECT_ROOT")
  echo "$args_str"
}

output_dir() {
  echo "$PROJECT_ROOT/dist/$ENV/$BUILD_MODE"
}

# ─── Pre-build ────────────────────────────────────────────────────────────────

pre_build() {
  step "Pre-build checks"
  require_flutter
  require_project
  cd "$PROJECT_ROOT"

  local version
  version=$(get_version)
  info "App    : $APP_NAME"
  info "Version: $version"
  info "Mode   : $BUILD_MODE"
  info "Env    : $ENV"
  info "Flavor : $FLAVOR"
  env_status "$ENV" "$PROJECT_ROOT"

  # pub get nếu chưa có pubspec.lock
  if [ ! -f "pubspec.lock" ]; then
    info "pubspec.lock chưa có — chạy flutter pub get..."
    "$FLUTTER_CMD" pub get
  fi

  # Tạo code gen nếu cần
  if grep -q "build_runner" pubspec.yaml 2>/dev/null; then
    info "Chạy build_runner..."
    "$FLUTTER_CMD" pub run build_runner build --delete-conflicting-outputs 2>&1 | tail -5
  fi

  # Tạo output dir
  mkdir -p "$(output_dir)"

  ok "Pre-build OK"
}

# ─── Android Build ────────────────────────────────────────────────────────────

build_android() {
  step "Building Android ($ANDROID_FORMAT | $BUILD_MODE | $ENV)"

  require_android_sdk

  local version
  version=$(get_version)
  local build_number
  build_number=$(get_build_number "$version")
  local version_name
  version_name=$(echo "$version" | sed 's/+.*//')

  local log_file
  log_file=$(log_file "android_${BUILD_MODE}")

  local start_time=$SECONDS

  # Env args (--dart-define-from-file hoặc fallback)
  local env_args_str env_args=()
  env_args_str=$(_build_env_args)
  IFS=' ' read -ra env_args <<< "$env_args_str"

  # Flavor arg nếu project có flavor setup
  local flavor_args=()
  [ -n "$FLAVOR" ] && [ "$FLAVOR" != "prod" ] && \
    flavor_args+=("--flavor" "$FLAVOR") || true

  if [ "$ANDROID_FORMAT" = "aab" ]; then
    info "Building App Bundle (AAB)..."
    "$FLUTTER_CMD" build appbundle \
      "--$BUILD_MODE" \
      "${env_args[@]+"${env_args[@]}"}" \
      "${flavor_args[@]+"${flavor_args[@]}"}" \
      ${build_number:+--build-number="$build_number"} \
      --build-name="$version_name" \
      $EXTRA_ARGS \
      2>&1 | tee "$log_file" | grep -E "(error|warning|✓|Building|Gradle|FAILURE|SUCCESS)" || true

    local output_src="$PROJECT_ROOT/build/app/outputs/bundle/${BUILD_MODE}Release/app-release.aab"
    local output_dst="$(output_dir)/app-${version_name}+${build_number}.aab"

  else
    info "Building APK..."
    "$FLUTTER_CMD" build apk \
      "--$BUILD_MODE" \
      "${env_args[@]+"${env_args[@]}"}" \
      "${flavor_args[@]+"${flavor_args[@]}"}" \
      ${build_number:+--build-number="$build_number"} \
      --build-name="$version_name" \
      --split-per-abi \
      $EXTRA_ARGS \
      2>&1 | tee "$log_file" | grep -E "(error|warning|✓|Building|Gradle|FAILURE|SUCCESS)" || true

    local output_src="$PROJECT_ROOT/build/app/outputs/apk/${BUILD_MODE}/app-${BUILD_MODE}.apk"
    local output_dst="$(output_dir)/app-${version_name}+${build_number}.apk"
  fi

  local elapsed=$((SECONDS - start_time))

  # Copy artifact
  if [ -f "$output_src" ]; then
    cp "$output_src" "$output_dst"
    local size
    size=$(du -sh "$output_dst" | cut -f1)
    ok "Android build hoàn tất [${elapsed}s]"
    ok "Output: $output_dst ($size)"
  else
    fail "Build thất bại — xem log: $log_file"
  fi
}

# ─── iOS Build ────────────────────────────────────────────────────────────────

build_ios() {
  step "Building iOS ($BUILD_MODE | $ENV)"

  if ! is_mac; then
    fail "iOS build chỉ chạy được trên macOS"
  fi

  if ! command -v xcodebuild &>/dev/null; then
    fail "Xcode chưa cài — cài từ App Store"
  fi

  local version
  version=$(get_version)
  local build_number
  build_number=$(get_build_number "$version")
  local version_name
  version_name=$(echo "$version" | sed 's/+.*//')

  local log_file
  log_file=$(log_file "ios_${BUILD_MODE}")

  local start_time=$SECONDS
  cd "$PROJECT_ROOT"

  local env_args_str env_args=()
  env_args_str=$(_build_env_args)
  IFS=' ' read -ra env_args <<< "$env_args_str"

  local flavor_args=()
  [ -n "$FLAVOR" ] && [ "$FLAVOR" != "prod" ] && \
    flavor_args+=("--flavor" "$FLAVOR") || true

  if [ "$BUILD_MODE" = "release" ]; then
    info "Building iOS archive..."
    "$FLUTTER_CMD" build ipa \
      --release \
      "${env_args[@]+"${env_args[@]}"}" \
      "${flavor_args[@]+"${flavor_args[@]}"}" \
      ${build_number:+--build-number="$build_number"} \
      --build-name="$version_name" \
      --export-options-plist=ios/ExportOptions.plist \
      $EXTRA_ARGS \
      2>&1 | tee "$log_file" | grep -E "(error|warning|✓|Building|Compiling|Archive|FAILURE|SUCCESS)" || true

    local output_src="$PROJECT_ROOT/build/ios/ipa/*.ipa"
    local output_dst="$(output_dir)/Runner-${version_name}+${build_number}.ipa"

    # Copy IPA
    for f in $output_src; do
      if [ -f "$f" ]; then
        cp "$f" "$output_dst"
        local size
        size=$(du -sh "$output_dst" | cut -f1)
        local elapsed=$((SECONDS - start_time))
        ok "iOS build hoàn tất [${elapsed}s]"
        ok "Output: $output_dst ($size)"
        return
      fi
    done

    fail "IPA không tìm thấy — xem log: $log_file"

  else
    # Debug / Profile — build simulator hoặc device
    info "Building iOS ($BUILD_MODE) — no codesign..."
    "$FLUTTER_CMD" build ios \
      "--$BUILD_MODE" \
      "${env_args[@]+"${env_args[@]}"}" \
      "${flavor_args[@]+"${flavor_args[@]}"}" \
      --no-codesign \
      $EXTRA_ARGS \
      2>&1 | tee "$log_file" | tail -10

    local elapsed=$((SECONDS - start_time))
    ok "iOS build ($BUILD_MODE) hoàn tất [${elapsed}s]"
    info "Output: build/ios/iphoneos/Runner.app"
  fi
}

# ─── Build Summary ────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "  ─────────────────────────────────────"
  echo -e "  ${BOLD}Build Summary${NC}"
  echo -e "  ─────────────────────────────────────"
  echo ""

  local out_dir
  out_dir="$(output_dir)"
  if [ -d "$out_dir" ]; then
    ls -lh "$out_dir" 2>/dev/null | grep -v "^total" | awk '{print "    " $9 "\t" $5}' || true
  fi
  echo ""
  info "Artifacts: $out_dir"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header "Build — $APP_NAME"
  require_project

  pre_build

  # Parallel build: Android + iOS song song khi cả 2 được yêu cầu
  if $BUILD_ANDROID && $BUILD_IOS && $PARALLEL; then
    step "Parallel build: Android + iOS"
    info "Chạy song song — xem log tại $(output_dir)/"
    echo ""

    local android_log ios_log
    android_log=$(log_file "android_parallel")
    ios_log=$(log_file "ios_parallel")

    ( build_android 2>&1 | tee "$android_log" ) &
    local pid_android=$!
    ( build_ios     2>&1 | tee "$ios_log" )     &
    local pid_ios=$!

    local android_exit=0 ios_exit=0
    wait "$pid_android" || android_exit=$?
    wait "$pid_ios"     || ios_exit=$?

    if [ "$android_exit" -ne 0 ]; then
      warn "Android build thất bại (exit $android_exit) — xem: $android_log"
    fi
    if [ "$ios_exit" -ne 0 ]; then
      warn "iOS build thất bại (exit $ios_exit) — xem: $ios_log"
    fi
    [ "$android_exit" -ne 0 ] || [ "$ios_exit" -ne 0 ] && \
      fail "Parallel build có lỗi — xem logs bên trên"
  else
    if $BUILD_ANDROID; then build_android; fi
    if $BUILD_IOS;     then build_ios;     fi
  fi

  print_summary
}

main
