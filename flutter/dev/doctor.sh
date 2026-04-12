#!/usr/bin/env bash
# vc-auto/flutter/dev/doctor.sh
# Kiểm tra toàn bộ dev tools: version đang cài, version yêu cầu, trạng thái.
#
# Usage:
#   flutter-auto doctor [--project <path>]
#   flutter-auto doctor [--project <path>] --android
#   flutter-auto doctor [--project <path>] --ios
#   flutter-auto doctor [--project <path>] --ci
#   flutter-auto doctor [--project <path>] --strict   # exit 1 nếu có lỗi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

CHECK_ANDROID=true
CHECK_IOS=true
CHECK_CI=false
CHECK_SIGNING=true    # false khi --local: bỏ qua signing/store cred checks
STRICT=false
FIX_MODE=false        # --fix: tự sửa pubspec.yaml nếu phát hiện constraint sai
DEEP_CHECK=false      # --deep: query pub.dev cho từng package (chậm hơn)
LOCAL_MODE=false      # --local: chỉ check những gì cần cho dev local
DEPLOY_MODE=false     # --deploy: full check + CI tools (= default + --ci)

for arg in "$@"; do
  case "$arg" in
    --project|-p) ;;
    --android) CHECK_ANDROID=true;  CHECK_IOS=false ;;
    --ios)     CHECK_IOS=true;      CHECK_ANDROID=false ;;
    --ci)      CHECK_CI=true ;;
    --strict)  STRICT=true ;;
    --fix)     FIX_MODE=true ;;
    --deep)    DEEP_CHECK=true ;;
    --local)
      LOCAL_MODE=true
      CHECK_SIGNING=false    # không cần signing/store creds cho local dev
      CHECK_CI=false
      ;;
    --deploy)
      DEPLOY_MODE=true
      CHECK_CI=true          # deploy cần Fastlane, Firebase CLI, store creds
      CHECK_SIGNING=true
      ;;
  esac
done

# Exported cho setup.sh đọc sau khi doctor chạy
DOCTOR_REQUIRED_FLUTTER=""
DOCTOR_REQUIRED_DART=""
DOCTOR_HAS_CONFLICT=false

# pub get gate — lưu output nếu thất bại để handle_pubget_blocking() dùng
PUB_GET_FAILED=false
PUB_GET_ERROR_OUTPUT=""

# Chi tiết conflict — mỗi entry: "sdk_type|declared|required|strictest_pkg"
# sdk_type: flutter | dart
declare -a CONFLICT_DETAILS=()

# Fix suggestions cho các vấn đề KHÔNG phải conflict (optional)
# Mỗi entry: "Tên tool|lệnh_fix"
declare -a FIX_SUGGESTIONS=()

# ─── Counters & Row collector ─────────────────────────────────────────────────

PASS=0; WARN=0; FAIL=0
declare -a ROWS=()   # format: "TOOL|INSTALLED|REQUIRED|STATUS_CODE|NOTE"
                     # STATUS_CODE: ok | warn | fail | skip | info

add_row() {
  # add_row <tool> <installed> <required> <status: ok|warn|fail|skip|info> [note] [fix_cmd]
  ROWS+=("$1|$2|$3|$4|${5:-}")
  case "$4" in
    ok)   ((PASS++)) ;;
    warn) ((WARN++)); [ -n "${6:-}" ] && FIX_SUGGESTIONS+=("$1|${6}") ;;
    fail) ((FAIL++)); [ -n "${6:-}" ] && FIX_SUGGESTIONS+=("$1|${6}")
          $STRICT && { print_table; exit 1; } ;;
  esac
}

# Thêm fix suggestion thủ công (không gắn với add_row)
add_fix() {
  FIX_SUGGESTIONS+=("$1|$2")
}

# ─── Version helpers ──────────────────────────────────────────────────────────

# So sánh và trả về nhãn hợp lệ/không hợp lệ
ver_status() {
  local installed="$1" required="$2"
  if [ -z "$installed" ] || [ "$installed" = "-" ]; then
    echo "fail"
  elif [ -z "$required" ] || [ "$required" = "-" ]; then
    echo "ok"
  elif version_gte "$installed" "$required"; then
    echo "ok"
  else
    echo "fail"
  fi
}

# ─── Section: Flutter / FVM ───────────────────────────────────────────────────

check_flutter_sdk() {
  # Detect FVM
  local fvm_active=false
  local fvm_ver=""
  if command -v fvm &>/dev/null; then
    fvm_ver=$(fvm --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fvm_active=true
  fi
  if [ -f "$PROJECT_ROOT/.fvm/fvm_config.json" ]; then
    local fvm_pinned
    fvm_pinned=$(grep -oE '"flutterSdkVersion":\s*"[^"]+"' "$PROJECT_ROOT/.fvm/fvm_config.json" \
      | grep -oE '"[0-9][^"]+"' | tr -d '"' 2>/dev/null || echo "")
    if [ -n "$fvm_pinned" ]; then
      add_row "FVM (pinned)" "$fvm_pinned" "-" "info" "project pin: $PROJECT_ROOT/.fvm/fvm_config.json"
    fi
  fi
  if $fvm_active && [ -n "$fvm_ver" ]; then
    add_row "fvm" "$fvm_ver" "-" "info" "$(command -v fvm)"
  fi

  # Flutter — FLUTTER_CMD luôn là path thực nhờ find_flutter()
  if [ -z "$FLUTTER_CMD" ]; then
    if $fvm_active; then
      add_row "Flutter" "NOT FOUND" ">=$FLUTTER_MIN_VERSION" "fail" \
        "FVM có nhưng chưa install version — chạy: fvm install <ver> && fvm global <ver>" \
        "flutter-auto setup --project $PROJECT_ROOT --flutter"
    else
      add_row "Flutter" "NOT FOUND" ">=$FLUTTER_MIN_VERSION" "fail" \
        "Cài: flutter-auto setup --flutter" \
        "flutter-auto setup --project $PROJECT_ROOT --flutter"
    fi
    return
  fi

  local flutter_out dart_line
  flutter_out=$("$FLUTTER_CMD" --version 2>/dev/null)
  local flutter_ver dart_ver channel engine_ver
  flutter_ver=$(echo "$flutter_out" | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  dart_ver=$(echo "$flutter_out"    | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+'    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  channel=$(echo "$flutter_out"     | grep -oE 'channel [a-z]+' | awk '{print $2}' | head -1)
  engine_ver=$(echo "$flutter_out"  | grep -oE 'Engine • revision [a-f0-9]+' | awk '{print $3}' | head -1)

  local f_status
  f_status=$(ver_status "$flutter_ver" "$FLUTTER_MIN_VERSION")

  # Ghi chú rõ: dùng FVM hay direct
  local via_label=""
  if $fvm_active; then
    if [[ "$FLUTTER_CMD" == *"/.fvm/flutter_sdk/"* ]]; then
      via_label="via FVM (local) • "
    elif [[ "$FLUTTER_CMD" == *"/fvm/"* ]]; then
      via_label="via FVM • "
    fi
  fi

  local f_note="${via_label}${FLUTTER_CMD}"
  [ -n "$channel" ] && f_note="${via_label}channel: $channel  |  $FLUTTER_CMD"
  add_row "Flutter" "${flutter_ver:--}" ">=$FLUTTER_MIN_VERSION" "$f_status" "$f_note"

  # Dart (bundled với Flutter)
  local d_status
  d_status=$(ver_status "$dart_ver" "$DART_MIN_VERSION")
  add_row "Dart SDK" "${dart_ver:--}" ">=$DART_MIN_VERSION" "$d_status" "bundled với Flutter"
}

# ─── Section: pubspec.yaml ────────────────────────────────────────────────────

check_pubspec() {
  local yaml="$PROJECT_ROOT/pubspec.yaml"
  local flutter_installed dart_installed
  flutter_installed=$("$FLUTTER_CMD" --version 2>/dev/null | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  dart_installed=$("$FLUTTER_CMD" --version 2>/dev/null | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  # Flutter constraint vs installed
  if [ -n "$FLUTTER_MIN_VERSION" ] && [ "$FLUTTER_MIN_VERSION" != "3.0.0" ]; then
    local f_compat
    f_compat=$(ver_status "${flutter_installed:-0.0.0}" "$FLUTTER_MIN_VERSION")
    add_row "pubspec flutter" ">=$FLUTTER_MIN_VERSION" \
      "installed $flutter_installed" \
      "$f_compat" \
      "$PROJECT_ROOT/pubspec.yaml"
  else
    add_row "pubspec flutter" "(not declared)" "-" "warn" "Thêm environment.flutter vào pubspec.yaml"
  fi

  # Dart constraint vs installed
  if [ -n "$DART_MIN_VERSION" ] && [ "$DART_MIN_VERSION" != "3.0.0" ]; then
    local d_compat
    d_compat=$(ver_status "${dart_installed:-0.0.0}" "$DART_MIN_VERSION")
    add_row "pubspec dart sdk" ">=$DART_MIN_VERSION <4.0.0" \
      "installed $dart_installed" \
      "$d_compat" \
      "$PROJECT_ROOT/pubspec.yaml"
  fi

  # pubspec.lock
  if [ -f "$PROJECT_ROOT/pubspec.lock" ]; then
    local pkg_count
    pkg_count=$(grep -c "^  source:" "$PROJECT_ROOT/pubspec.lock" 2>/dev/null || echo "?")
    add_row "pubspec.lock" "exists" "$pkg_count packages" "ok" ""
  else
    add_row "pubspec.lock" "NOT FOUND" "-" "warn" "Chạy: flutter pub get"
  fi
}

# ─── Section: General ─────────────────────────────────────────────────────────

check_general() {
  # git
  if command -v git &>/dev/null; then
    local git_ver
    git_ver=$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "git" "$git_ver" "-" "ok" "$(command -v git)"
  else
    add_row "git" "NOT FOUND" "-" "fail" "Cài: brew install git"
  fi

  # Homebrew (macOS)
  if is_mac; then
    if command -v brew &>/dev/null; then
      local brew_ver
      brew_ver=$(brew --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      add_row "Homebrew" "$brew_ver" "-" "ok" "$(command -v brew)"
    else
      add_row "Homebrew" "NOT FOUND" "-" "warn" "Cài: https://brew.sh"
    fi
  fi

  # Python3
  if command -v python3 &>/dev/null; then
    local py_ver
    py_ver=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "Python3" "$py_ver" "-" "ok" "$(command -v python3)"
  else
    add_row "Python3" "NOT FOUND" "-" "warn" ""
  fi

  # Node.js
  if command -v node &>/dev/null; then
    local node_ver
    node_ver=$(node --version 2>/dev/null | tr -d 'v')
    add_row "Node.js" "$node_ver" "-" "ok" "$(command -v node)"
  else
    add_row "Node.js" "NOT FOUND" "-" "warn" "Cài: brew install node  (cần cho Firebase CLI)"
  fi
}

# ─── Section: Android ─────────────────────────────────────────────────────────

check_android() {
  # ── Local mode: chỉ check SDK + adb, bỏ qua signing/store ──────────────────
  # (CHECK_SIGNING=false khi --local)

  # Java / JDK
  if command -v java &>/dev/null; then
    local java_full java_ver java_vendor java_home_path
    java_full=$(java -version 2>&1)
    java_ver=$(echo "$java_full" | grep -oE '"[0-9]+\.[0-9]*|"[0-9]+' | tr -d '"' | head -1)
    # Java 9+ → major version trực tiếp
    if echo "$java_ver" | grep -qE '^1\.'; then
      java_ver=$(echo "$java_ver" | cut -d'.' -f2)
    fi
    java_vendor=$(echo "$java_full" | grep -oiE '(openjdk|temurin|corretto|graalvm|zulu|adoptopenjdk)' \
      | head -1 || echo "")
    java_home_path="${JAVA_HOME:-$(java -XshowSettings:all -version 2>&1 | grep 'java.home' | awk '{print $3}' | head -1)}"

    local j_status
    j_status=$(ver_status "$java_ver" "$JAVA_MIN_VERSION")
    local j_note="${java_vendor:+$java_vendor  }${java_home_path:+path: $java_home_path}"
    add_row "Java (JDK)" "$java_ver" ">=$JAVA_MIN_VERSION" "$j_status" "$j_note"
  else
    add_row "Java (JDK)" "NOT FOUND" ">=$JAVA_MIN_VERSION" "fail" \
      "Cài: brew install --cask temurin@$JAVA_MIN_VERSION"
  fi

  # ANDROID_HOME / SDK
  local sdk_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -n "$sdk_home" ] && [ -d "$sdk_home" ]; then
    # Tìm build-tools version cao nhất
    local build_tools_ver=""
    if [ -d "$sdk_home/build-tools" ]; then
      build_tools_ver=$(ls "$sdk_home/build-tools" 2>/dev/null | sort -V | tail -1)
    fi
    local sdk_note="build-tools: ${build_tools_ver:-(none)}"
    add_row "Android SDK" "$sdk_home" "-" "ok" "$sdk_note"

    # Platform versions đã cài
    if [ -d "$sdk_home/platforms" ]; then
      local platforms
      platforms=$(ls "$sdk_home/platforms" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
      add_row "Android platforms" "${platforms:-(none)}" "-" "info" ""
    fi
  else
    add_row "Android SDK" "NOT FOUND" "-" "fail" \
      "Set ANDROID_HOME hoặc chạy: flutter-auto setup --setup-android"
  fi

  # adb
  if command -v adb &>/dev/null; then
    local adb_ver
    adb_ver=$(adb version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "adb" "$adb_ver" "-" "ok" "$(command -v adb)"
  else
    add_row "adb" "NOT FOUND" "-" "warn" "Thêm \$ANDROID_HOME/platform-tools vào PATH"
  fi

  # Gradle wrapper
  if [ -f "$PROJECT_ROOT/android/gradlew" ]; then
    local gradle_ver=""
    if [ -f "$PROJECT_ROOT/android/gradle/wrapper/gradle-wrapper.properties" ]; then
      gradle_ver=$(grep "distributionUrl" "$PROJECT_ROOT/android/gradle/wrapper/gradle-wrapper.properties" \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    fi
    add_row "Gradle wrapper" "${gradle_ver:-(unknown)}" "-" "ok" \
      "android/gradle/wrapper/gradle-wrapper.properties"
  else
    add_row "Gradle wrapper" "NOT FOUND" "-" "warn" ""
  fi

  # Android App ID detected
  if [ -n "$ANDROID_APP_ID" ]; then
    add_row "Android App ID" "$ANDROID_APP_ID" "-" "info" ""
  fi

  # Signing — bỏ qua khi LOCAL_MODE
  if $CHECK_SIGNING; then
    if [ -f "$PROJECT_ROOT/android/key.properties" ]; then
      add_row "Android signing" "key.properties ✓" "-" "ok" "$PROJECT_ROOT/android/key.properties"
    else
      add_row "Android signing" "NOT FOUND" "-" "warn" \
        "Cần cho release build — chạy: flutter-auto signing --android" \
        "flutter-auto signing --project $PROJECT_ROOT --android"
    fi

    # Google Play credentials
    if [ -f "$PROJECT_ROOT/android/google-play-key.json" ]; then
      add_row "Google Play key" "google-play-key.json ✓" "-" "ok" ""
    elif [ -n "${GOOGLE_PLAY_KEY_JSON:-}" ]; then
      add_row "Google Play key" "env var ✓" "-" "ok" "GOOGLE_PLAY_KEY_JSON"
    else
      add_row "Google Play key" "NOT FOUND" "-" "warn" "Cần cho deploy lên Google Play"
    fi
  else
    add_row "Android signing" "(skipped)" "-" "skip" "local mode — không cần cho debug"
  fi
}

# ─── Section: iOS ─────────────────────────────────────────────────────────────

check_ios() {
  if ! is_mac; then
    add_row "iOS tools" "-" "-" "skip" "Chỉ kiểm tra được trên macOS"
    return
  fi

  # Xcode
  if command -v xcodebuild &>/dev/null; then
    local xcode_ver xcode_build
    xcode_ver=$(xcodebuild -version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    xcode_build=$(xcodebuild -version 2>/dev/null | grep 'Build version' | awk '{print $3}')
    local xcode_path
    xcode_path=$(xcode-select -p 2>/dev/null || echo "")
    add_row "Xcode" "${xcode_ver:--}" "-" "ok" \
      "Build $xcode_build  |  $xcode_path"
  else
    add_row "Xcode" "NOT FOUND" "-" "fail" "Cài từ App Store"
  fi

  # Xcode CLI Tools
  if xcode-select -p &>/dev/null; then
    local cli_path
    cli_path=$(xcode-select -p)
    add_row "Xcode CLI Tools" "installed" "-" "ok" "$cli_path"
  else
    add_row "Xcode CLI Tools" "NOT FOUND" "-" "fail" "Chạy: xcode-select --install"
  fi

  # iOS SDK version
  local ios_sdk_ver=""
  ios_sdk_ver=$(xcodebuild -showsdks 2>/dev/null | grep "iphonesimulator" \
    | grep -oE '[0-9]+\.[0-9]+' | sort -V | tail -1)
  if [ -n "$ios_sdk_ver" ]; then
    add_row "iOS SDK" "$ios_sdk_ver" "-" "info" "iphonesimulator$ios_sdk_ver"
  fi

  # Ruby (cần cho CocoaPods / Fastlane)
  if command -v ruby &>/dev/null; then
    local ruby_ver
    ruby_ver=$(ruby --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "Ruby" "$ruby_ver" "-" "ok" "$(command -v ruby)"
  else
    add_row "Ruby" "NOT FOUND" "-" "warn" "Cần cho CocoaPods/Fastlane"
  fi

  # CocoaPods
  if command -v pod &>/dev/null; then
    local pod_ver
    pod_ver=$(pod --version 2>/dev/null)
    add_row "CocoaPods" "$pod_ver" "-" "ok" "$(command -v pod)"

    # Podfile.lock
    if [ -f "$PROJECT_ROOT/ios/Podfile.lock" ]; then
      add_row "Podfile.lock" "exists" "-" "ok" "$PROJECT_ROOT/ios/Podfile.lock"
    else
      add_row "Podfile.lock" "NOT FOUND" "-" "warn" \
        "Chạy: cd ios && pod install" \
        "cd $PROJECT_ROOT/ios && pod install && cd -"
    fi
  else
    add_row "CocoaPods" "NOT FOUND" "-" "fail" \
      "Cài: brew install cocoapods" \
      "brew install cocoapods"
  fi

  # iOS Simulator
  if xcrun simctl list devices 2>/dev/null | grep -q "Booted"; then
    local sim_name
    sim_name=$(xcrun simctl list devices 2>/dev/null \
      | grep "Booted" | head -1 | sed 's/ (.*//;s/^[[:space:]]*//')
    add_row "iOS Simulator" "Booted" "-" "ok" "$sim_name"
  else
    add_row "iOS Simulator" "not running" "-" "warn" "Mở Simulator.app để chạy"
  fi

  # iOS Bundle ID
  if [ -n "$IOS_BUNDLE_ID" ]; then
    add_row "iOS Bundle ID" "$IOS_BUNDLE_ID" "-" "info" ""
  fi

  # Signing + Store creds — bỏ qua khi LOCAL_MODE
  if $CHECK_SIGNING; then
    local cert_lines
    cert_lines=$(security find-identity -v -p codesigning 2>/dev/null | grep "iPhone" || true)
    if [ -n "$cert_lines" ]; then
      local cert_count cert_names
      cert_count=$(echo "$cert_lines" | wc -l | tr -d ' ')
      cert_names=$(echo "$cert_lines" | grep -oE '"[^"]+"' | tr -d '"' | head -2 | paste -sd ', ')
      add_row "iOS Signing" "$cert_count certificate(s)" "-" "ok" "$cert_names"
    else
      add_row "iOS Signing" "NOT FOUND" "-" "warn" \
        "Cần Apple Developer certificate cho release build"
    fi

    # App Store Connect API key
    local p8_file
    p8_file=$(ls "$PROJECT_ROOT/ios/AuthKey_"*.p8 2>/dev/null | head -1 || true)
    if [ -n "$p8_file" ]; then
      add_row "ASC API key" "$(basename "$p8_file")" "-" "ok" "$p8_file"
    elif [ -n "${APP_STORE_CONNECT_API_KEY:-}" ]; then
      add_row "ASC API key" "env var ✓" "-" "ok" "APP_STORE_CONNECT_API_KEY"
    else
      add_row "ASC API key" "NOT FOUND" "-" "warn" "Cần cho deploy lên App Store"
    fi
  else
    add_row "iOS Signing" "(skipped)" "-" "skip" "local mode — không cần cho debug"
  fi
}

# ─── Section: CI/CD Tools ─────────────────────────────────────────────────────

check_ci_tools() {
  # Fastlane
  if command -v fastlane &>/dev/null; then
    local fl_ver
    fl_ver=$(fastlane --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "Fastlane" "${fl_ver:--}" "-" "ok" "$(command -v fastlane)"
  else
    add_row "Fastlane" "NOT FOUND" "-" "warn" "Cài: gem install fastlane"
  fi

  # Firebase CLI
  if command -v firebase &>/dev/null; then
    local fb_ver
    fb_ver=$(firebase --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "Firebase CLI" "${fb_ver:--}" "-" "ok" "$(command -v firebase)"
  else
    add_row "Firebase CLI" "NOT FOUND" "-" "warn" "Cài: npm install -g firebase-tools"
  fi

  # GitHub CLI
  if command -v gh &>/dev/null; then
    local gh_ver
    gh_ver=$(gh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "GitHub CLI" "${gh_ver:--}" "-" "ok" "$(command -v gh)"
  else
    add_row "GitHub CLI" "NOT FOUND" "-" "skip" "Optional"
  fi

  # jq
  if command -v jq &>/dev/null; then
    local jq_ver
    jq_ver=$(jq --version 2>/dev/null | tr -d 'jq-')
    add_row "jq" "$jq_ver" "-" "ok" "$(command -v jq)"
  else
    add_row "jq" "NOT FOUND" "-" "warn" "Cài: brew install jq"
  fi

  # curl
  if command -v curl &>/dev/null; then
    local curl_ver
    curl_ver=$(curl --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    add_row "curl" "$curl_ver" "-" "ok" "$(command -v curl)"
  else
    add_row "curl" "NOT FOUND" "-" "fail" ""
  fi
}

# ─── Section: Package Compatibility ──────────────────────────────────────────
#
# Kiểm tra xem Flutter/Dart đang cài có đáp ứng được yêu cầu
# thực tế của TẤT CẢ packages trong project không.
#
# Có 2 cấp độ:
#   Fast  (mặc định): chạy flutter pub get → bắt lỗi conflict
#   Deep  (--deep):   query pub.dev API cho từng direct dependency

check_package_compat() {
  # Bỏ qua nếu Flutter không có
  if [ -z "$FLUTTER_CMD" ]; then
    add_row "pkg compat" "skip" "-" "skip" "Flutter chưa cài"
    return
  fi

  cd "$PROJECT_ROOT"

  # ── Bước 1: flutter pub get → detect conflict ngay ───────────────────────
  local pub_out pub_exit
  pub_out=$($FLUTTER_CMD pub get 2>&1) && pub_exit=0 || pub_exit=$?

  if [ "$pub_exit" -ne 0 ]; then
    # Lưu toàn bộ output để handle_pubget_blocking() hiển thị đầy đủ
    PUB_GET_FAILED=true
    PUB_GET_ERROR_OUTPUT="$pub_out"
    DOCTOR_HAS_CONFLICT=true

    local conflict_msg
    conflict_msg=$(echo "$pub_out" | grep -E "(Because|requires|version solving|incompatible)" \
      | head -3 | tr '\n' ' ')
    add_row "pub get" "FAILED (exit $pub_exit)" "-" "fail" \
      "${conflict_msg:-Chi tiết xem sau bảng}"
    return
  fi

  add_row "pub get" "OK" "-" "ok" "Không có version conflict"

  # ── Bước 2: Xác định version tối thiểu thực tế mà packages yêu cầu ──────
  # Fast mode: đọc pubspec.lock + query pub.dev API cho direct deps
  # Deep mode: query tất cả packages trong lock

  local required_flutter="0.0.0"
  local required_dart="0.0.0"
  local conflict_pkgs=()

  local yaml="$PROJECT_ROOT/pubspec.yaml"
  local lock="$PROJECT_ROOT/pubspec.lock"

  if [ ! -f "$lock" ]; then
    add_row "pkg constraints" "pubspec.lock missing" "-" "warn" "Chạy: flutter pub get"
    return
  fi

  # Lấy danh sách packages cần check
  local pkg_list=()
  if $DEEP_CHECK; then
    # Tất cả hosted packages trong lock
    while IFS= read -r pkg; do
      pkg_list+=("$pkg")
    done < <(grep -E "^  [a-z]" "$lock" | awk '{print $1}' | tr -d ':')
  else
    # Chỉ direct dependencies từ pubspec.yaml
    while IFS= read -r pkg; do
      pkg_list+=("$pkg")
    done < <(awk '/^dependencies:/,/^[a-z]/' "$yaml" \
      | grep -E "^  [a-z]" | awk '{print $1}' | tr -d ':' \
      | grep -vE "^(flutter|flutter_localizations)$")
  fi

  local total=${#pkg_list[@]}
  local checked=0
  local max_f_pkg="" max_d_pkg=""

  echo ""
  info "Checking $total packages từ $($DEEP_CHECK && echo 'pubspec.lock' || echo 'pubspec.yaml (direct deps)')..."

  for pkg in "${pkg_list[@]}"; do
    checked=$((checked + 1))
    printf "\r  ${GRAY}[%d/%d] %s%-30s${NC}" "$checked" "$total" "" "$pkg"

    # Lấy resolved version từ pubspec.lock
    local version
    version=$(awk "/^  $pkg:/{f=1} f && /version:/{print \$2; exit}" "$lock" | tr -d '"')
    [ -z "$version" ] && continue

    # Query pub.dev
    local result
    result=$(curl -sf --max-time 8 \
      "https://pub.dev/api/packages/$pkg/versions/$version" 2>/dev/null) || continue

    local f_min d_min
    f_min=$(echo "$result" | grep -o '"flutter":"[^"]*"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    d_min=$(echo "$result" | grep -o '"sdk":"[^"]*"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [ -n "$f_min" ] && version_gte "$f_min" "${required_flutter:-0.0.0}" \
       && [ "$f_min" != "$required_flutter" ]; then
      required_flutter="$f_min"
      max_f_pkg="$pkg@$version"
    fi
    if [ -n "$d_min" ] && version_gte "$d_min" "${required_dart:-0.0.0}" \
       && [ "$d_min" != "$required_dart" ]; then
      required_dart="$d_min"
      max_d_pkg="$pkg@$version"
    fi
  done
  printf "\r%70s\r" ""  # clear progress line

  # ── Bước 3: So sánh 3 chiều: declared vs required-by-pkgs vs installed ───

  local flutter_installed dart_installed
  flutter_installed=$($FLUTTER_CMD --version 2>/dev/null \
    | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  dart_installed=$($FLUTTER_CMD --version 2>/dev/null \
    | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  # Lưu để setup.sh dùng
  DOCTOR_REQUIRED_FLUTTER="$required_flutter"
  DOCTOR_REQUIRED_DART="$required_dart"

  # Flutter: 3 chiều
  if [ "$required_flutter" != "0.0.0" ]; then
    local f_declared="$FLUTTER_MIN_VERSION"

    # installed vs packages
    local f_inst_status
    f_inst_status=$(ver_status "${flutter_installed:-0.0.0}" "$required_flutter")
    add_row "Flutter (packages need)" \
      ">=$required_flutter" \
      "installed: ${flutter_installed:--}" \
      "$f_inst_status" \
      "strictest: $max_f_pkg"

    # declared vs packages — BLOCKING conflict
    if [ -n "$f_declared" ] && [ "$f_declared" != "0.0.0" ]; then
      local f_decl_status
      f_decl_status=$(ver_status "$f_declared" "$required_flutter")
      if [ "$f_decl_status" = "fail" ]; then
        DOCTOR_HAS_CONFLICT=true
        # Track chi tiết để hiển thị rõ ràng trong conflict block
        CONFLICT_DETAILS+=("flutter|$f_declared|$required_flutter|$max_f_pkg")
        add_row "pubspec flutter env" \
          "declared: >=$f_declared" \
          "⚠ need: >=$required_flutter" \
          "fail" \
          "Phải cập nhật trước khi cài Flutter — nếu không sẽ cài sai version"
      else
        add_row "pubspec flutter env" \
          "declared: >=$f_declared" \
          "required: >=$required_flutter" \
          "ok" ""
      fi
    fi
  else
    add_row "Flutter (packages need)" "no constraint" "-" "info" \
      "$($DEEP_CHECK && echo 'checked all packages' || echo 'checked direct deps only')"
  fi

  # Dart: 3 chiều
  if [ "$required_dart" != "0.0.0" ]; then
    local d_declared="$DART_MIN_VERSION"

    local d_inst_status
    d_inst_status=$(ver_status "${dart_installed:-0.0.0}" "$required_dart")
    add_row "Dart (packages need)" \
      ">=$required_dart" \
      "installed: ${dart_installed:--}" \
      "$d_inst_status" \
      "strictest: $max_d_pkg"

    if [ -n "$d_declared" ] && [ "$d_declared" != "0.0.0" ]; then
      local d_decl_status
      d_decl_status=$(ver_status "$d_declared" "$required_dart")
      if [ "$d_decl_status" = "fail" ]; then
        DOCTOR_HAS_CONFLICT=true
        CONFLICT_DETAILS+=("dart|$d_declared|$required_dart|$max_d_pkg")
        add_row "pubspec dart sdk env" \
          "declared: >=$d_declared" \
          "⚠ need: >=$required_dart" \
          "fail" \
          "Phải cập nhật trước khi cài Dart — nếu không sẽ cài sai version"
      else
        add_row "pubspec dart sdk env" \
          "declared: >=$d_declared" \
          "required: >=$required_dart" \
          "ok" ""
      fi
    fi
  fi
}

# ─── Fix pubspec.yaml environment ─────────────────────────────────────────────

apply_fix() {
  local req_flutter="${1:-$DOCTOR_REQUIRED_FLUTTER}"
  local req_dart="${2:-$DOCTOR_REQUIRED_DART}"
  local yaml="$PROJECT_ROOT/pubspec.yaml"

  if [ -z "$req_flutter" ] && [ -z "$req_dart" ]; then
    info "Không có gì để fix."
    return 0
  fi

  echo ""
  echo -e "  ${BOLD}Fix pubspec.yaml environment constraints:${NC}"
  echo ""

  local cur_flutter cur_dart
  cur_flutter=$(grep -A3 "^environment:" "$yaml" | grep "flutter:" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  cur_dart=$(grep -A3 "^environment:" "$yaml" | grep "sdk:" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  local needs_fix=false

  if [ -n "$req_flutter" ] && [ "$req_flutter" != "0.0.0" ]; then
    if ! version_gte "${cur_flutter:-0.0.0}" "$req_flutter"; then
      echo -e "  flutter: ${YELLOW}>=${cur_flutter:-?}${NC} → ${GREEN}>=$req_flutter${NC}"
      needs_fix=true
    else
      echo -e "  flutter: ${GREEN}>=$cur_flutter${NC} (OK)"
    fi
  fi

  if [ -n "$req_dart" ] && [ "$req_dart" != "0.0.0" ]; then
    if ! version_gte "${cur_dart:-0.0.0}" "$req_dart"; then
      echo -e "  sdk:     ${YELLOW}>=${cur_dart:-?}${NC} → ${GREEN}>=$req_dart <4.0.0${NC}"
      needs_fix=true
    else
      echo -e "  sdk:     ${GREEN}>=$cur_dart${NC} (OK)"
    fi
  fi

  if ! $needs_fix; then
    ok "pubspec.yaml đã đúng — không cần sửa."
    return 0
  fi

  echo ""
  if ! is_ci && ! confirm "Tự động cập nhật pubspec.yaml?"; then
    warn "Bỏ qua — cập nhật thủ công pubspec.yaml"
    return 1
  fi

  # Backup
  cp "$yaml" "$yaml.bak"
  info "Backup: $yaml.bak"

  # Sửa flutter constraint
  if [ -n "$req_flutter" ] && [ "$req_flutter" != "0.0.0" ]; then
    if ! version_gte "${cur_flutter:-0.0.0}" "$req_flutter"; then
      sed -i.tmp "s/flutter: '>=[0-9]*\.[0-9]*\.[0-9]*'/flutter: '>=$req_flutter'/" "$yaml"
      sed -i.tmp "s/flutter: \">=[0-9]*\.[0-9]*\.[0-9]*\"/flutter: \">=$req_flutter\"/" "$yaml"
    fi
  fi

  # Sửa sdk constraint (Dart)
  if [ -n "$req_dart" ] && [ "$req_dart" != "0.0.0" ]; then
    if ! version_gte "${cur_dart:-0.0.0}" "$req_dart"; then
      sed -i.tmp "s/sdk: '>=[0-9]*\.[0-9]*\.[0-9]* <4\.0\.0'/sdk: '>=$req_dart <4.0.0'/" "$yaml"
      sed -i.tmp "s/sdk: \">=[0-9]*\.[0-9]*\.[0-9]* <4\.0\.0\"/sdk: \">=$req_dart <4.0.0\"/" "$yaml"
    fi
  fi

  rm -f "$yaml.tmp"

  # Verify
  local new_flutter new_dart
  new_flutter=$(grep -A3 "^environment:" "$yaml" | grep "flutter:" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  new_dart=$(grep -A3 "^environment:" "$yaml" | grep "sdk:" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  ok "pubspec.yaml đã cập nhật:"
  echo -e "    flutter: ${GREEN}>=$new_flutter${NC}"
  echo -e "    sdk:     ${GREEN}>=$new_dart <4.0.0${NC}"
}

# ─── Print Table ──────────────────────────────────────────────────────────────

print_table() {
  local col1=22 col2=26 col3=26

  echo ""
  printf "  ${BOLD}%-${col1}s  %-${col2}s  %-${col3}s  %s${NC}\n" \
    "Tool" "Installed" "Required / Info" "Status"
  printf "  %s\n" "$(printf '─%.0s' $(seq 1 90))"

  local last_section=""
  for row in "${ROWS[@]}"; do
    IFS='|' read -r tool installed required status note <<< "$row"

    # Section break dựa trên prefix tool name (flutter/dart/pubspec / java/android / ios / ci)
    local section=""
    case "$tool" in
      Flutter|Dart*|fvm|FVM*|pubspec*) section="Flutter" ;;
      git|Homebrew|Python*|Node*) section="General" ;;
      Java*|Android*|adb|Gradle*) section="Android" ;;
      Xcode*|iOS*|Ruby|CocoaPods|Podfile*|ASC*) section="iOS" ;;
      Fastlane|Firebase*|GitHub*|jq|curl) section="CI/CD" ;;
    esac

    if [ -n "$section" ] && [ "$section" != "$last_section" ]; then
      echo ""
      echo -e "  ${BOLD}${CYAN}── $section ──${NC}"
      last_section="$section"
    fi

    local icon color
    case "$status" in
      ok)   icon="✓"; color="$GREEN" ;;
      warn) icon="⚠"; color="$YELLOW" ;;
      fail) icon="✗"; color="$RED" ;;
      skip) icon="–"; color="$GRAY" ;;
      info) icon="·"; color="$BLUE" ;;
      *)    icon=" "; color="$NC" ;;
    esac

    local installed_display="$installed"
    local required_display="$required"

    # Truncate nếu quá dài
    [ ${#installed_display} -gt $((col2-1)) ] && installed_display="${installed_display:0:$((col2-3))}..."
    [ ${#required_display}  -gt $((col3-1)) ] && required_display="${required_display:0:$((col3-3))}..."

    printf "  ${color}${icon}${NC} %-${col1}s  ${color}%-${col2}s${NC}  %-${col3}s" \
      "$tool" "$installed_display" "$required_display"

    # Note nằm trên dòng riêng nếu có
    if [ -n "$note" ]; then
      printf "\n  ${GRAY}  %-${col1}s  %s${NC}\n" "" "$note"
    else
      echo ""
    fi
  done

  echo ""
  printf "  %s\n" "$(printf '─%.0s' $(seq 1 90))"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  local result_line="  ${GREEN}✓ $PASS OK${NC}   ${YELLOW}⚠ $WARN warnings${NC}   ${RED}✗ $FAIL errors${NC}"
  echo -e "$result_line"
  echo ""

  if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}$FAIL lỗi cần fix trước khi build/deploy.${NC}"
    echo -e "  Chạy ${CYAN}flutter-auto setup${NC} để tự động cài đặt."
  elif [ "$WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}$WARN cảnh báo — có thể bỏ qua nhưng nên fix.${NC}"
  else
    echo -e "  ${GREEN}${BOLD}Tất cả OK — sẵn sàng build!${NC}"
  fi
  echo ""

  if [ "$FAIL" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ─── pub get Gate (BLOCKING) ──────────────────────────────────────────────────
#
# Nếu pub get thất bại → không thể xác định version cần cài → dừng hẳn.
# Không có auto-fix: user phải tự sửa pubspec.yaml / lock và chạy lại.

handle_pubget_blocking() {
  $PUB_GET_FAILED || return 0

  echo ""
  echo -e "  ${RED}${BOLD}$(printf '═%.0s' $(seq 1 64))${NC}"
  echo -e "  ${RED}${BOLD}  ⛔  flutter pub get THẤT BẠI — bắt buộc fix trước${NC}"
  echo -e "  ${RED}${BOLD}$(printf '═%.0s' $(seq 1 64))${NC}"
  echo ""

  # ── Hiển thị SDK version hiện tại vs yêu cầu ───────────────────────────────
  local cur_flutter="" cur_dart=""
  if [ -n "${FLUTTER_CMD:-}" ]; then
    local _ver_out
    _ver_out=$("$FLUTTER_CMD" --version 2>/dev/null)
    cur_flutter=$(echo "$_ver_out" | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    cur_dart=$(echo "$_ver_out" | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  fi

  echo -e "  ${BOLD}SDK hiện tại vs yêu cầu (pubspec.yaml):${NC}"
  echo ""
  local f_color="$GREEN"
  if [ -n "$cur_flutter" ] && ! version_gte "$cur_flutter" "${FLUTTER_MIN_VERSION:-3.0.0}" 2>/dev/null; then
    f_color="$RED"
  fi
  printf "    %-8s  current: ${f_color}%-14s${NC}  required (pubspec): ${CYAN}>=%s${NC}\n" \
    "Flutter" "${cur_flutter:-(unknown)}" "${FLUTTER_MIN_VERSION:-?}"

  local d_color="$GREEN"
  if [ -n "$cur_dart" ] && ! version_gte "$cur_dart" "${DART_MIN_VERSION:-3.0.0}" 2>/dev/null; then
    d_color="$RED"
  fi
  printf "    %-8s  current: ${d_color}%-14s${NC}  required (pubspec): ${CYAN}>=%s${NC}\n" \
    "Dart" "${cur_dart:-(unknown)}" "${DART_MIN_VERSION:-?}"
  echo ""

  # ── Xác định lệnh pub get phù hợp (fvm nếu có) ─────────────────────────────
  local pub_cmd="flutter pub get"
  if command -v fvm &>/dev/null; then
    pub_cmd="fvm flutter pub get"
  fi

  echo -e "  ${BOLD}${RED}Output đầy đủ của flutter pub get:${NC}"
  echo ""
  # Thêm Flutter SDK version vì pub get chỉ in Dart SDK
  [ -n "$cur_flutter" ] && \
    echo "    The current Flutter SDK version is ${cur_flutter}."
  echo "$PUB_GET_ERROR_OUTPUT" | sed 's/^/    /'
  echo ""
  echo -e "  ${BOLD}Cách fix:${NC}"
  echo -e "  ${GRAY}1. Xem lỗi ở trên — thường là version conflict hoặc package không tìm thấy${NC}"
  echo -e "  ${GRAY}2. Sửa pubspec.yaml: cập nhật dependencies / environment constraints${NC}"
  echo -e "  ${GRAY}3. Chạy thủ công: ${NC}${CYAN}${pub_cmd}${NC}"
  echo -e "  ${GRAY}4. Sau khi pass: chạy lại flutter-auto doctor / setup${NC}"
  echo ""
  echo -e "  ${RED}Doctor không thể tiếp tục.${NC}"
  echo ""
  exit 2
}

# ─── Conflict Block (BLOCKING) ────────────────────────────────────────────────
#
# Hiển thị chi tiết từng conflict và buộc user fix trước khi tiếp tục.
# Conflict KHÁC với suggest_fixes — không thể bỏ qua vì sẽ cài Flutter sai version.

_show_conflict_details() {
  echo ""
  echo -e "  ${RED}${BOLD}$(printf '═%.0s' $(seq 1 62))${NC}"
  echo -e "  ${RED}${BOLD}  ⛔  CONFLICT — pubspec.yaml environment không tương thích${NC}"
  echo -e "  ${RED}${BOLD}$(printf '═%.0s' $(seq 1 62))${NC}"
  echo ""
  echo -e "  ${BOLD}Packages yêu cầu version SDK cao hơn khai báo trong pubspec.yaml:${NC}"
  echo ""

  for entry in "${CONFLICT_DETAILS[@]}"; do
    IFS='|' read -r sdk_type declared required strictest_pkg <<< "$entry"

    local label upper_label
    case "$sdk_type" in
      flutter) label="flutter"; upper_label="Flutter" ;;
      dart)    label="sdk (Dart)"; upper_label="Dart" ;;
    esac

    # Dòng chính: declared → required
    printf "  ${RED}✗${NC}  ${BOLD}%-10s${NC}  pubspec khai báo: ${YELLOW}>=%s${NC}  →  cần:  ${GREEN}>=%s${NC}\n" \
      "$upper_label" "$declared" "$required"

    # Dòng phụ: package gây ra
    if [ -n "$strictest_pkg" ]; then
      printf "     ${GRAY}%-10s  package nghiêm ngặt nhất: %s${NC}\n" "" "$strictest_pkg"
    fi
    echo ""
  done

  echo -e "  ${RED}${BOLD}Tại sao phải fix trước?${NC}"
  echo -e "  ${GRAY}Nếu bỏ qua, setup sẽ cài Flutter/Dart theo version sai trong pubspec.yaml.${NC}"
  echo -e "  ${GRAY}Khi build hoặc pub get sẽ thất bại do packages không tương thích.${NC}"
  echo ""

  # Hiển thị diff cần thay đổi trong pubspec.yaml
  local yaml="$PROJECT_ROOT/pubspec.yaml"
  echo -e "  ${BOLD}Thay đổi cần thiết trong pubspec.yaml:${NC}"
  echo ""
  for entry in "${CONFLICT_DETAILS[@]}"; do
    IFS='|' read -r sdk_type declared required _ <<< "$entry"
    case "$sdk_type" in
      flutter)
        printf "  ${YELLOW}  flutter: '>=%s'${NC}  →  ${GREEN}  flutter: '>=%s'${NC}\n" "$declared" "$required"
        ;;
      dart)
        printf "  ${YELLOW}  sdk: '>=%s <4.0.0'${NC}  →  ${GREEN}  sdk: '>=%s <4.0.0'${NC}\n" "$declared" "$required"
        ;;
    esac
  done
  echo ""
}

handle_conflict_blocking() {
  [ ${#CONFLICT_DETAILS[@]} -eq 0 ] && return 0

  _show_conflict_details

  # CI mode: tự động fix
  if is_ci; then
    info "CI mode — tự động fix pubspec.yaml..."
    apply_fix "$DOCTOR_REQUIRED_FLUTTER" "$DOCTOR_REQUIRED_DART" || \
      { echo -e "${RED}  Không thể fix pubspec.yaml trong CI${NC}"; exit 2; }
    ok "pubspec.yaml đã cập nhật — tiếp tục..."
    return 0
  fi

  # --fix flag: tự động fix không hỏi
  if $FIX_MODE; then
    apply_fix "$DOCTOR_REQUIRED_FLUTTER" "$DOCTOR_REQUIRED_DART"
    return $?
  fi

  # Interactive: bắt buộc chọn — không có lựa chọn "bỏ qua"
  echo -e "  ${BOLD}${RED}Bắt buộc fix trước khi tiếp tục.${NC}"
  echo ""
  echo -e "  ${CYAN}Y${NC}  Tự động cập nhật pubspec.yaml (khuyến nghị)"
  echo -e "  ${CYAN}n${NC}  Thoát — tự sửa thủ công"
  echo ""
  read -r -p "  Cập nhật pubspec.yaml? [Y/n] " reply
  reply="${reply:-y}"

  if [[ "$reply" =~ ^[Yy]$ ]]; then
    echo ""
    apply_fix "$DOCTOR_REQUIRED_FLUTTER" "$DOCTOR_REQUIRED_DART"
    local fix_result=$?
    if [ "$fix_result" -eq 0 ]; then
      echo ""
      ok "pubspec.yaml đã cập nhật — chạy lại doctor để xác nhận:"
      echo -e "  ${CYAN}flutter-auto doctor --project $PROJECT_ROOT${NC}"
      echo ""
    fi
    return "$fix_result"
  else
    echo ""
    echo -e "  ${RED}Đã thoát. Sửa pubspec.yaml thủ công:${NC}"
    for entry in "${CONFLICT_DETAILS[@]}"; do
      IFS='|' read -r sdk_type declared required _ <<< "$entry"
      case "$sdk_type" in
        flutter) echo -e "    ${GRAY}environment.flutter: '>=$required'${NC}" ;;
        dart)    echo -e "    ${GRAY}environment.sdk: '>=$required <4.0.0'${NC}" ;;
      esac
    done
    echo ""
    echo -e "  Sau đó chạy lại: ${CYAN}flutter-auto doctor --project $PROJECT_ROOT${NC}"
    echo ""
    exit 2   # exit code 2 = conflict unresolved (phân biệt với exit 1 = general error)
  fi
}

# ─── Optional Fix Suggestions ─────────────────────────────────────────────────
#
# CHỈ dùng cho các vấn đề không blocking (CocoaPods, adb, signing...).
# Conflict version KHÔNG được phép vào đây.

suggest_fixes() {
  [ ${#FIX_SUGGESTIONS[@]} -eq 0 ] && return 0
  is_ci && return 0

  echo ""
  echo -e "  ${BOLD}${YELLOW}${#FIX_SUGGESTIONS[@]} vấn đề có thể tự động fix (tuỳ chọn):${NC}"
  echo ""

  local i=1
  for entry in "${FIX_SUGGESTIONS[@]}"; do
    IFS='|' read -r label cmd <<< "$entry"
    echo -e "  ${CYAN}$i${NC}  $label"
    echo -e "     ${GRAY}→ $cmd${NC}"
    i=$((i + 1))
  done

  echo ""
  echo -e "  ${CYAN}a${NC}  Fix tất cả"
  echo -e "  ${GRAY}0  Bỏ qua${NC}"
  echo ""
  read -r -p "  Chọn [0-$((i-1))/a]: " choice

  case "$choice" in
    0|"") return 0 ;;
    a|A)
      for entry in "${FIX_SUGGESTIONS[@]}"; do
        IFS='|' read -r label cmd <<< "$entry"
        echo ""
        step "Fix: $label"
        eval "$cmd" && ok "$label — OK" || warn "$label — thất bại, kiểm tra thủ công"
      done
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
        IFS='|' read -r label cmd <<< "${FIX_SUGGESTIONS[$((choice-1))]}"
        echo ""
        step "Fix: $label"
        eval "$cmd" && ok "$label — OK" || warn "$label — thất bại"
      else
        warn "Lựa chọn không hợp lệ"
        return 0
      fi
      ;;
  esac

  echo ""
  if confirm "Chạy lại doctor để kiểm tra?"; then
    echo ""
    local extra_flags=()
    $LOCAL_MODE  && extra_flags+=("--local")
    $DEPLOY_MODE && extra_flags+=("--deploy")
    $CHECK_CI    && extra_flags+=("--ci")
    exec bash "$0" --project "$PROJECT_ROOT" "${extra_flags[@]+"${extra_flags[@]}"}"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode_label="full"
  $LOCAL_MODE  && mode_label="local (development)"
  $DEPLOY_MODE && mode_label="deploy"

  header "Flutter Doctor — $APP_NAME"
  require_project

  echo -e "  Project : ${CYAN}$PROJECT_ROOT${NC}"
  echo -e "  Android : ${CYAN}${ANDROID_APP_ID:-(not detected)}${NC}"
  echo -e "  iOS     : ${CYAN}${IOS_BUNDLE_ID:-(not detected)}${NC}"
  echo -e "  Mode    : ${CYAN}$mode_label${NC}"
  $DEEP_CHECK && echo -e "            ${YELLOW}+ deep check (query pub.dev cho tất cả packages)${NC}"

  check_flutter_sdk
  check_pubspec
  check_package_compat
  check_general

  $CHECK_ANDROID && check_android
  $CHECK_IOS     && check_ios
  $CHECK_CI      && check_ci_tools

  print_table
  print_summary

  # ── pub get Gate (BLOCKING) ─────────────────────────────────────────────────
  # pub get phải pass trước — nếu không không xác định được version chính xác.
  # Exit code 2 ngay nếu thất bại, không cần xử lý conflict.
  handle_pubget_blocking

  # ── Conflict (BLOCKING) — phải xử lý trước mọi thứ khác ────────────────────
  # Tách biệt hoàn toàn khỏi suggest_fixes.
  # Exit code 2 nếu user từ chối fix.
  handle_conflict_blocking

  # ── Optional fixes (chỉ sau khi đã clear conflict) ─────────────────────────
  suggest_fixes
}

main
