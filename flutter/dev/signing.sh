#!/usr/bin/env bash
# vc-auto/flutter/dev/signing.sh
# Cấu hình signing cho release: Android keystore, iOS certificates, CI secrets.
#
# Dùng cho RELEASE — không liên quan đến dev environment.
#
# Usage:
#   flutter-auto signing [--project <path>] [--android|--ios|--ci]
#   flutter-auto signing --android          # Android keystore + key.properties
#   flutter-auto signing --ios              # iOS certificates check
#   flutter-auto signing --ci               # Kiểm tra / decode CI secrets
#   flutter-auto signing                    # Tất cả

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

DO_ANDROID=false
DO_IOS=false
DO_CI=false
DO_ALL=true

for arg in "$@"; do
  case "$arg" in
    --project|-p) ;;
    --android)    DO_ANDROID=true; DO_ALL=false ;;
    --ios)        DO_IOS=true;     DO_ALL=false ;;
    --ci)         DO_CI=true;      DO_ALL=false ;;
  esac
done

if $DO_ALL; then
  DO_ANDROID=true; DO_IOS=true; DO_CI=true
fi

# ─── Android Signing ──────────────────────────────────────────────────────────

setup_android_signing() {
  step "Android Signing"

  local key_props="$PROJECT_ROOT/android/key.properties"
  local keystore="$PROJECT_ROOT/android/app/release.keystore"

  # CI: decode keystore từ secret
  if is_ci && [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
    info "Decode Android keystore từ CI secret..."
    echo "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$keystore"
    ok "Keystore decoded: android/app/release.keystore"

    cat > "$key_props" << EOF
storePassword=${ANDROID_STORE_PASSWORD:-}
keyPassword=${ANDROID_KEY_PASSWORD:-}
keyAlias=release
storeFile=../app/release.keystore
EOF
    ok "android/key.properties created from CI secrets"
    return 0
  fi

  # Dev: kiểm tra keystore + key.properties
  if [ -f "$key_props" ]; then
    ok "android/key.properties đã có"
    local ks_file
    ks_file=$(grep "storeFile" "$key_props" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
    if [ -n "$ks_file" ]; then
      # Resolve path relative to android/
      local resolved_ks="$PROJECT_ROOT/android/$ks_file"
      [ -f "$resolved_ks" ] && ok "Keystore tồn tại: $ks_file" || warn "Keystore chưa tồn tại: $ks_file"
    fi
    return 0
  fi

  warn "android/key.properties chưa có"
  echo ""
  echo -e "  ${BOLD}Tạo keystore mới:${NC}"
  echo ""
  echo "    keytool -genkey -v \\"
  echo "      -keystore android/app/release.keystore \\"
  echo "      -alias release \\"
  echo "      -keyalg RSA -keysize 2048 -validity 10000"
  echo ""
  echo -e "  ${BOLD}Sau đó tạo android/key.properties:${NC}"
  echo ""
  echo "    storePassword=<password>"
  echo "    keyPassword=<password>"
  echo "    keyAlias=release"
  echo "    storeFile=../app/release.keystore"
  echo ""

  if confirm "Tạo keystore mới ngay bây giờ?" "n"; then
    echo ""
    keytool -genkey -v \
      -keystore "$keystore" \
      -alias release \
      -keyalg RSA -keysize 2048 -validity 10000

    read -r -p "  Nhập Store Password vừa tạo: " store_pass
    read -r -p "  Nhập Key Password vừa tạo: "   key_pass

    cat > "$key_props" << EOF
storePassword=$store_pass
keyPassword=$key_pass
keyAlias=release
storeFile=../app/release.keystore
EOF
    ok "android/key.properties đã tạo"
  else
    info "Bỏ qua — tạo thủ công sau khi có keystore"
  fi
}

# ─── iOS Signing ──────────────────────────────────────────────────────────────

setup_ios_signing() {
  step "iOS Signing"

  if ! is_mac; then
    skip "iOS signing (macOS only)"
    return
  fi

  local cert_count
  cert_count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "iPhone" || echo 0)

  if [ "$cert_count" -gt 0 ]; then
    ok "$cert_count iOS signing certificate(s) found"
    security find-identity -v -p codesigning 2>/dev/null | grep "iPhone" | while read -r line; do
      echo -e "    ${GRAY}$line${NC}"
    done
  else
    warn "Không tìm thấy iOS signing certificate"
    echo ""
    echo -e "  ${BOLD}Cần có Apple Developer Account:${NC}"
    echo "    https://developer.apple.com/account"
    echo ""
    echo -e "  ${BOLD}Hoặc dùng Automatic Signing trong Xcode:${NC}"
    echo "    open $PROJECT_ROOT/ios/Runner.xcworkspace"
    echo ""
    echo -e "  ${BOLD}Xem Bundle ID của project:${NC}"
    [ -n "$IOS_BUNDLE_ID" ] && echo "    $IOS_BUNDLE_ID" || echo "    (không đọc được từ project.pbxproj)"
  fi

  # Kiểm tra Fastlane match nếu có
  if [ -f "$PROJECT_ROOT/fastlane/Matchfile" ]; then
    echo ""
    ok "Fastlane Matchfile tồn tại"
    info "Chạy 'fastlane match development' hoặc 'fastlane match appstore' để sync certs"
  fi
}

# ─── CI Secrets Check ─────────────────────────────────────────────────────────

setup_ci_secrets() {
  step "CI/CD Secrets"

  echo -e "  ${GRAY}Kiểm tra environment variables cần thiết cho release pipeline.${NC}"
  echo ""

  local android_vars=(
    "GOOGLE_PLAY_KEY_JSON:Google Play API key (base64)"
    "ANDROID_KEYSTORE_BASE64:Android keystore (base64)"
    "ANDROID_KEY_PASSWORD:Android key password"
    "ANDROID_STORE_PASSWORD:Android store password"
  )

  local ios_vars=(
    "APP_STORE_CONNECT_API_KEY:App Store Connect API key (base64)"
    "APP_STORE_CONNECT_API_KEY_ID:App Store Connect Key ID"
    "APP_STORE_CONNECT_API_ISSUER_ID:App Store Connect Issuer ID"
  )

  local other_vars=(
    "FIREBASE_TOKEN:Firebase CLI token (crashlytics / app distribution)"
  )

  local missing=()

  _check_var() {
    local var="${1%%:*}"
    local desc="${1#*:}"
    if [ -n "${!var:-}" ]; then
      ok "$var"
    else
      warn "$var ${GRAY}($desc)${NC}"
      missing+=("$var")
    fi
  }

  echo -e "  ${BOLD}Android:${NC}"
  for v in "${android_vars[@]}"; do _check_var "$v"; done
  echo ""
  echo -e "  ${BOLD}iOS:${NC}"
  for v in "${ios_vars[@]}"; do _check_var "$v"; done
  echo ""
  echo -e "  ${BOLD}Other:${NC}"
  for v in "${other_vars[@]}"; do _check_var "$v"; done

  echo ""
  if [ ${#missing[@]} -gt 0 ]; then
    warn "${#missing[@]} biến chưa set — thêm vào CI/CD secrets:"
    echo ""
    echo "  GitHub Actions → Settings → Secrets and Variables → Actions"
    echo "  Bitrise        → App → Workflow Editor → Secrets"
  else
    ok "Tất cả CI/CD secrets đã set"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header "Release Signing — $APP_NAME"
  require_project
  cd "$PROJECT_ROOT"

  echo -e "  ${GRAY}Android App ID : ${NC}${ANDROID_APP_ID:-n/a}"
  echo -e "  ${GRAY}iOS Bundle ID  : ${NC}${IOS_BUNDLE_ID:-n/a}"
  echo ""

  if $DO_ANDROID; then setup_android_signing; fi
  if $DO_IOS;     then setup_ios_signing;     fi
  if $DO_CI;      then setup_ci_secrets;      fi

  echo ""
  ok "Signing check hoàn tất!"
  echo ""
  echo -e "  ${BOLD}Tiếp theo:${NC}"
  echo "    flutter-auto build --android --release   # Build release APK/AAB"
  echo "    flutter-auto build --ios --release        # Build release IPA"
  echo "    flutter-auto deploy                       # Deploy lên stores"
  echo ""
}

main
