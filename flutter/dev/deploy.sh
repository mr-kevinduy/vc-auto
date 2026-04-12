#!/usr/bin/env bash
# vc-auto/flutter/dev/deploy.sh
# Deploy app lên Google Play và App Store.
#
# Usage:
#   flutter-auto deploy [--project <path>] [--android|--ios] [--track <track>] [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

DEPLOY_ANDROID=false
DEPLOY_IOS=false
PLAY_TRACK="internal"
TESTFLIGHT_ONLY=false
DRY_RUN=false
ENV="prod"
AAB_PATH=""
IPA_PATH=""

for arg in "$@"; do
  case "$arg" in
    --android)    DEPLOY_ANDROID=true ;;
    --ios)        DEPLOY_IOS=true ;;
    --track)      shift; PLAY_TRACK="${1:-internal}" ;;
    --testflight) TESTFLIGHT_ONLY=true ;;
    --dry-run)    DRY_RUN=true ;;
    --env)        shift; ENV="${1:-prod}" ;;
    --aab)        shift; AAB_PATH="${1:-}" ;;
    --ipa)        shift; IPA_PATH="${1:-}" ;;
  esac
done

if ! $DEPLOY_ANDROID && ! $DEPLOY_IOS; then
  DEPLOY_ANDROID=true
  DEPLOY_IOS=true
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

dry_run_echo() {
  if $DRY_RUN; then
    echo -e "  ${GRAY}[DRY-RUN]${NC} $*"
    return 0
  fi
  return 1
}

find_latest_artifact() {
  local ext="$1"
  local dir="$PROJECT_ROOT/dist/$ENV/release"
  ls -t "$dir/"*."$ext" 2>/dev/null | head -1
}

get_version() {
  grep "^version:" "$PROJECT_ROOT/pubspec.yaml" | awk '{print $2}'
}

# ─── Android Deploy (Google Play) ─────────────────────────────────────────────

setup_play_credentials() {
  local key_file="$PROJECT_ROOT/android/google-play-key.json"

  if [ -f "$key_file" ]; then
    echo "$key_file"
    return 0
  fi

  # Decode từ CI env var
  if [ -n "${GOOGLE_PLAY_KEY_JSON:-}" ]; then
    echo "$GOOGLE_PLAY_KEY_JSON" | base64 --decode > "$key_file"
    ok "Google Play key decoded"
    echo "$key_file"
    return 0
  fi

  return 1
}

deploy_android() {
  step "Deploy Android → Google Play ($PLAY_TRACK)"

  # Tìm AAB
  if [ -z "$AAB_PATH" ]; then
    AAB_PATH=$(find_latest_artifact "aab")
  fi

  if [ -z "$AAB_PATH" ] || [ ! -f "$AAB_PATH" ]; then
    fail "AAB không tìm thấy. Chạy trước: ./scripts/automate/build.sh --android"
  fi

  local aab_size
  aab_size=$(du -sh "$AAB_PATH" | cut -f1)
  info "AAB: $AAB_PATH ($aab_size)"

  if $DRY_RUN; then
    dry_run_echo "fastlane supply --aab $AAB_PATH --track $PLAY_TRACK"
    dry_run_echo "Sẽ upload lên Google Play (track: $PLAY_TRACK)"
    return
  fi

  # Lấy credentials
  local key_file
  if ! key_file=$(setup_play_credentials); then
    fail "Google Play credentials không có.\n  Cần: android/google-play-key.json hoặc GOOGLE_PLAY_KEY_JSON env var"
  fi

  # Dùng Fastlane nếu có
  if command -v fastlane &>/dev/null && [ -f "$PROJECT_ROOT/android/fastlane/Fastfile" ]; then
    info "Dùng Fastlane..."
    cd "$PROJECT_ROOT/android"
    fastlane supply \
      --aab "../$AAB_PATH" \
      --track "$PLAY_TRACK" \
      --json_key "$key_file" \
      --package_name "$ANDROID_APP_ID"

  # Fallback: bundletool / manual upload thông qua Google Play API
  elif command -v bundletool &>/dev/null; then
    info "Dùng bundletool..."
    bundletool validate --bundle="$AAB_PATH"
    warn "Auto-upload cần Fastlane. Tải lên thủ công qua Google Play Console:"
    info "  https://play.google.com/console"

  else
    warn "Fastlane chưa cài."
    echo ""
    echo "  Cài Fastlane:"
    echo "    gem install fastlane"
    echo ""
    echo "  Hoặc upload thủ công:"
    echo "    AAB: $AAB_PATH"
    echo "    Console: https://play.google.com/console"
    echo ""

    # Hướng dẫn setup Fastlane
    if ! is_ci && confirm "Tạo Fastfile cho Android?"; then
      _create_android_fastfile
    fi
    return 1
  fi

  ok "Deploy Android → Google Play ($PLAY_TRACK) hoàn tất"
}

_create_android_fastfile() {
  mkdir -p "$PROJECT_ROOT/android/fastlane"

  cat > "$PROJECT_ROOT/android/fastlane/Fastfile" << 'EOF'
# android/fastlane/Fastfile
default_platform(:android)

platform :android do
  desc "Deploy to Google Play"
  lane :deploy do |options|
    track = options[:track] || "internal"
    upload_to_play_store(
      track: track,
      aab: "../build/app/outputs/bundle/release/app-release.aab",
      json_key: "google-play-key.json",
      package_name: ENV["ANDROID_APP_ID"] || "com.castme.oem.oem_mobile",
      skip_upload_apk: true,
      skip_upload_metadata: true,
      skip_upload_changelogs: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
    )
  end

  desc "Upload to Firebase App Distribution"
  lane :distribute do
    firebase_app_distribution(
      app: ENV["FIREBASE_ANDROID_APP_ID"],
      service_credentials_file: "google-play-key.json",
      groups: "internal-testers",
      apk_path: "../build/app/outputs/apk/release/app-release.apk",
    )
  end
end
EOF
  ok "Fastfile tạo xong: android/fastlane/Fastfile"
}

# ─── iOS Deploy (App Store / TestFlight) ──────────────────────────────────────

setup_appstore_credentials() {
  # Kiểm tra App Store Connect API key
  if [ -z "${APP_STORE_CONNECT_API_KEY:-}" ] || \
     [ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" ] || \
     [ -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]; then

    # Thử tìm file .p8
    local p8_file
    p8_file=$(ls "$PROJECT_ROOT/ios/AuthKey_"*.p8 2>/dev/null | head -1)
    if [ -z "$p8_file" ]; then
      return 1
    fi
  fi
  return 0
}

deploy_ios() {
  step "Deploy iOS → $( $TESTFLIGHT_ONLY && echo 'TestFlight' || echo 'App Store')"

  if ! is_mac; then
    fail "iOS deploy chỉ chạy được trên macOS"
  fi

  # Tìm IPA
  if [ -z "$IPA_PATH" ]; then
    IPA_PATH=$(find_latest_artifact "ipa")
  fi

  if [ -z "$IPA_PATH" ] || [ ! -f "$IPA_PATH" ]; then
    fail "IPA không tìm thấy. Chạy trước: ./scripts/automate/build.sh --ios"
  fi

  local ipa_size
  ipa_size=$(du -sh "$IPA_PATH" | cut -f1)
  info "IPA: $IPA_PATH ($ipa_size)"

  if $DRY_RUN; then
    dry_run_echo "xcrun altool --upload-app -f $IPA_PATH"
    dry_run_echo "Sẽ upload lên $( $TESTFLIGHT_ONLY && echo 'TestFlight' || echo 'App Store Connect')"
    return
  fi

  # Kiểm tra credentials
  if ! setup_appstore_credentials; then
    fail "App Store Connect credentials không có.\n  Cần: APP_STORE_CONNECT_API_KEY, APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID"
  fi

  # Dùng Fastlane nếu có Fastfile
  if command -v fastlane &>/dev/null && [ -f "$PROJECT_ROOT/ios/fastlane/Fastfile" ]; then
    info "Dùng Fastlane..."
    cd "$PROJECT_ROOT/ios"
    if $TESTFLIGHT_ONLY; then
      fastlane pilot upload \
        --ipa "../$IPA_PATH" \
        --api_key_path "../ios/AuthKey_*.p8" \
        --skip_waiting_for_build_processing true
    else
      fastlane deliver \
        --ipa "../$IPA_PATH" \
        --skip_metadata true \
        --skip_screenshots true
    fi

  # Fallback: xcrun altool
  elif command -v xcrun &>/dev/null; then
    info "Dùng xcrun altool..."

    # Tạo API key file nếu có env vars
    local api_key_args=""
    if [ -n "${APP_STORE_CONNECT_API_KEY:-}" ]; then
      local key_file="/tmp/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
      echo "$APP_STORE_CONNECT_API_KEY" | base64 --decode > "$key_file"
      api_key_args="--apiKey ${APP_STORE_CONNECT_API_KEY_ID} --apiIssuer ${APP_STORE_CONNECT_API_ISSUER_ID}"
    else
      local p8_file
      p8_file=$(ls "$PROJECT_ROOT/ios/AuthKey_"*.p8 2>/dev/null | head -1)
      local key_id
      key_id=$(basename "$p8_file" .p8 | sed 's/AuthKey_//')
      api_key_args="--apiKey $key_id"
    fi

    xcrun altool --upload-app \
      --type ios \
      --file "$IPA_PATH" \
      $api_key_args \
      --output-format xml

  else
    warn "Fastlane và xcrun không khả dụng."
    echo ""
    echo "  Upload thủ công qua Transporter:"
    echo "    https://apps.apple.com/app/transporter/id1450874784"
    echo ""
    echo "  Hoặc cài Fastlane:"
    echo "    gem install fastlane"
    echo ""

    if ! is_ci && confirm "Tạo Fastfile cho iOS?"; then
      _create_ios_fastfile
    fi
    return 1
  fi

  ok "Deploy iOS hoàn tất"
}

_create_ios_fastfile() {
  mkdir -p "$PROJECT_ROOT/ios/fastlane"

  cat > "$PROJECT_ROOT/ios/fastlane/Fastfile" << 'EOF'
# ios/fastlane/Fastfile
default_platform(:ios)

platform :ios do
  desc "Upload to TestFlight"
  lane :beta do
    pilot(
      ipa: "../build/ios/ipa/Runner.ipa",
      skip_waiting_for_build_processing: true,
      api_key_path: "AuthKey.json",
    )
  end

  desc "Deploy to App Store"
  lane :release do
    deliver(
      ipa: "../build/ios/ipa/Runner.ipa",
      skip_metadata: true,
      skip_screenshots: true,
      force: true,
    )
  end

  desc "Upload to Firebase App Distribution"
  lane :distribute do
    firebase_app_distribution(
      app: ENV["FIREBASE_IOS_APP_ID"],
      ipa_path: "../build/ios/ipa/Runner.ipa",
      groups: "internal-testers",
    )
  end
end
EOF
  ok "Fastfile tạo xong: ios/fastlane/Fastfile"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header "Deploy — $APP_NAME"
  require_project

  if $DRY_RUN; then
    warn "DRY-RUN mode — không thực sự deploy"
    echo ""
  fi

  local version
  version=$(get_version)
  info "Version: $version"
  info "Env: $ENV"
  echo ""

  if $DEPLOY_ANDROID; then deploy_android; fi
  if $DEPLOY_IOS;     then deploy_ios;     fi

  echo ""
  ok "Deploy hoàn tất!"
  echo ""
}

main
