#!/usr/bin/env bash
# vc-auto/flutter/dev/setup.sh
# Cài đặt và cấu hình môi trường phát triển Flutter.
#
# Usage:
#   flutter-auto setup [--project <path>] [--install-flutter|--setup-android|--setup-ios|--setup-signing|--ci]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── Parse Args ───────────────────────────────────────────────────────────────

PROJECT_ARG="$(extract_project_arg "$@")"
init_project "${PROJECT_ARG:-}"

DO_FLUTTER=false
DO_ANDROID=false
DO_IOS=false
DO_ALL=true
SKIP_PREFLIGHT=false

for arg in "$@"; do
  case "$arg" in
    --project|-p)      ;;  # đã xử lý
    --flutter)         DO_FLUTTER=true; DO_ALL=false ;;
    --install-flutter) DO_FLUTTER=true; DO_ALL=false ;;  # alias cũ
    --android)         DO_ANDROID=true; DO_ALL=false ;;
    --setup-android)   DO_ANDROID=true; DO_ALL=false ;;  # alias cũ
    --ios)             DO_IOS=true;     DO_ALL=false ;;
    --setup-ios)       DO_IOS=true;     DO_ALL=false ;;  # alias cũ
    --skip-preflight)  SKIP_PREFLIGHT=true ;;
  esac
done

if $DO_ALL; then
  DO_FLUTTER=true; DO_ANDROID=true; DO_IOS=true
fi

# ─── Preflight: chạy doctor trước khi setup ───────────────────────────────────
#
# Mục đích:
#   1. Hiển thị trạng thái tools hiện tại
#   2. Phát hiện version conflict (packages vs pubspec.yaml vs installed)
#   3. Nếu conflict → confirm fix pubspec.yaml trước khi cài
#   4. Xác định target version chính xác cần cài

run_preflight() {
  if $SKIP_PREFLIGHT; then
    warn "Bỏ qua preflight doctor (--skip-preflight)"
    return 0
  fi

  step "Preflight — Kiểm tra môi trường"

  # Chạy doctor với --local mode (không cần check signing/store cho setup)
  # Exit codes:
  #   0 = tất cả OK
  #   1 = thiếu tools (setup sẽ cài)
  #   2 = CONFLICT pubspec.yaml — phải fix trước khi setup, không thể tiếp tục
  local doctor_exit=0
  bash "$SCRIPT_DIR/doctor.sh" --project "$PROJECT_ROOT" --local 2>&1 || doctor_exit=$?

  echo ""
  echo -e "  $(printf '─%.0s' $(seq 1 60))"
  echo ""

  if [ "$doctor_exit" -eq 2 ]; then
    # Doctor đã hiển thị conflict chi tiết và user từ chối fix
    # Không cần hiển thị thêm — chỉ dừng hẳn
    fail "Setup bị hủy do conflict chưa được giải quyết.\n  Chạy lại sau khi sửa pubspec.yaml:\n  flutter-auto setup --project $PROJECT_ROOT"
  elif [ "$doctor_exit" -ne 0 ]; then
    # exit 1 = thiếu tools — setup sẽ cài, tiếp tục bình thường
    warn "Doctor phát hiện thiếu một số tools (exit $doctor_exit)"
    info "Setup sẽ cài đặt những gì còn thiếu..."
    echo ""
  else
    ok "Preflight passed — môi trường sạch"
    echo ""
  fi
}

# Lấy Flutter version tối thiểu thực tế từ packages (dùng pub.dev API)
_get_required_flutter_version() {
  local lock="$PROJECT_ROOT/pubspec.lock"
  local yaml="$PROJECT_ROOT/pubspec.yaml"
  [ ! -f "$lock" ] && { echo "0.0.0"; return; }

  local max_ver="0.0.0"

  # Chỉ check direct dependencies (nhanh hơn)
  local pkg_list
  pkg_list=$(awk '/^dependencies:/,/^[a-z]/' "$yaml" \
    | grep -E "^  [a-z]" | awk '{print $1}' | tr -d ':' \
    | grep -vE "^(flutter|flutter_localizations)$")

  for pkg in $pkg_list; do
    local version
    version=$(awk "/^  $pkg:/{f=1} f && /version:/{print \$2; exit}" "$lock" | tr -d '"')
    [ -z "$version" ] && continue

    local result f_min
    result=$(curl -sf --max-time 6 \
      "https://pub.dev/api/packages/$pkg/versions/$version" 2>/dev/null) || continue
    f_min=$(echo "$result" | grep -o '"flutter":"[^"]*"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    [ -n "$f_min" ] && version_gte "$f_min" "$max_ver" && max_ver="$f_min"
  done

  echo "$max_ver"
}

_get_required_dart_version() {
  local lock="$PROJECT_ROOT/pubspec.lock"
  local yaml="$PROJECT_ROOT/pubspec.yaml"
  [ ! -f "$lock" ] && { echo "0.0.0"; return; }

  local max_ver="0.0.0"
  local pkg_list
  pkg_list=$(awk '/^dependencies:/,/^[a-z]/' "$yaml" \
    | grep -E "^  [a-z]" | awk '{print $1}' | tr -d ':' \
    | grep -vE "^(flutter|flutter_localizations)$")

  for pkg in $pkg_list; do
    local version
    version=$(awk "/^  $pkg:/{f=1} f && /version:/{print \$2; exit}" "$lock" | tr -d '"')
    [ -z "$version" ] && continue

    local result d_min
    result=$(curl -sf --max-time 6 \
      "https://pub.dev/api/packages/$pkg/versions/$version" 2>/dev/null) || continue
    d_min=$(echo "$result" | grep -o '"sdk":"[^"]*"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    [ -n "$d_min" ] && version_gte "$d_min" "$max_ver" && max_ver="$d_min"
  done

  echo "$max_ver"
}

# Sửa pubspec.yaml environment constraints
_fix_pubspec() {
  local req_flutter="${1:-}"
  local req_dart="${2:-}"
  local yaml="$PROJECT_ROOT/pubspec.yaml"

  cp "$yaml" "$yaml.bak"

  if [ -n "$req_flutter" ] && [ "$req_flutter" != "0.0.0" ]; then
    sed -i.tmp "s/flutter: '>=[0-9]*\.[0-9]*\.[0-9]*'/flutter: '>=$req_flutter'/" "$yaml"
    sed -i.tmp "s/flutter: \">=[0-9]*\.[0-9]*\.[0-9]*\"/flutter: \">=$req_flutter\"/" "$yaml"
  fi

  if [ -n "$req_dart" ] && [ "$req_dart" != "0.0.0" ]; then
    sed -i.tmp "s/sdk: '>=[0-9]*\.[0-9]*\.[0-9]* <4\.0\.0'/sdk: '>=$req_dart <4.0.0'/" "$yaml"
    sed -i.tmp "s/sdk: \">=[0-9]*\.[0-9]*\.[0-9]* <4\.0\.0\"/sdk: \">=$req_dart <4.0.0\"/" "$yaml"
  fi

  rm -f "$yaml.tmp"
  ok "pubspec.yaml đã cập nhật (backup: pubspec.yaml.bak)"
}

# ─── Flutter Setup ────────────────────────────────────────────────────────────
#
# Thứ tự ưu tiên:
#   1. FVM (Flutter Version Manager) — nếu đã cài hoặc có thể cài
#   2. Flutter trực tiếp qua Homebrew — fallback
#
# FVM được ưu tiên vì:
#   - Quản lý nhiều version song song
#   - Tôn trọng .fvm/fvm_config.json trong project (pinned version)
#   - Không conflict khi làm việc nhiều project khác nhau

# Trả về version được pin trong project (.fvmrc hoặc .fvm/fvm_config.json)
_fvm_pinned_version() {
  local rc_file="$PROJECT_ROOT/.fvmrc"
  if [ -f "$rc_file" ]; then
    grep -oE '"flutter":\s*"[^"]+"' "$rc_file" \
      | grep -oE '"[0-9][^"]+"' | tr -d '"' 2>/dev/null || echo ""
    return
  fi

  local config="$PROJECT_ROOT/.fvm/fvm_config.json"
  if [ -f "$config" ]; then
    grep -oE '"flutterSdkVersion":\s*"[^"]+"' "$config" \
      | grep -oE '"[0-9][^"]+"' | tr -d '"' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Cài FVM nếu chưa có
_install_fvm() {
  if command -v fvm &>/dev/null; then
    ok "fvm $(fvm --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) đã có"
    return 0
  fi

  info "Cài FVM (Flutter Version Manager)..."

  if is_mac && command -v brew &>/dev/null; then
    brew tap leoafarias/fvm 2>/dev/null || true
    brew install fvm 2>&1 | tail -3
  elif command -v dart &>/dev/null; then
    dart pub global activate fvm
  elif is_mac; then
    # Homebrew chưa có → cài Homebrew trước
    warn "Homebrew chưa có. Cài từ: https://brew.sh"
    return 1
  else
    # Linux
    curl -fsSL https://fvm.app/install.sh | bash 2>&1 | tail -5
    export PATH="$HOME/.pub-cache/bin:$PATH"
  fi

  if command -v fvm &>/dev/null; then
    ok "fvm đã cài: $(command -v fvm)"
    # Thêm FVM vào shell config
    _add_fvm_to_shell
    return 0
  else
    warn "FVM cài không thành công — fallback sang Homebrew Flutter"
    return 1
  fi
}

# Thêm FVM paths vào shell config
_add_fvm_to_shell() {
  local shell_rc="$HOME/.zshrc"
  [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && shell_rc="$HOME/.bashrc"

  local fvm_path='$HOME/.pub-cache/bin'
  local fvm_link='$HOME/fvm/default/bin'

  if ! grep -q "fvm" "$shell_rc" 2>/dev/null; then
    {
      echo ""
      echo "# FVM — Flutter Version Manager"
      echo "export PATH=\"$fvm_path:$fvm_link:\$PATH\""
    } >> "$shell_rc"
    info "Đã thêm FVM vào $shell_rc — chạy: source $shell_rc"
  fi
}

# Cài Flutter version cụ thể qua FVM và set làm active
_fvm_install_and_use() {
  local version="$1"
  local scope="${2:-global}"  # global | local

  info "fvm install $version ..."
  fvm install "$version" 2>&1 | tail -5

  if [ "$scope" = "local" ]; then
    info "fvm use $version (project local)..."
    cd "$PROJECT_ROOT"
    fvm use "$version" 2>&1 | tail -3
  else
    info "fvm global $version ..."
    fvm global "$version" 2>&1 | tail -3
  fi

  # Resolve binary path thực — không dùng "fvm flutter" compound command
  FLUTTER_CMD="$(find_flutter 2>/dev/null || echo '')"
  export FLUTTER_CMD

  if [ -n "$FLUTTER_CMD" ]; then
    local installed_ver
    installed_ver=$("$FLUTTER_CMD" --version 2>/dev/null \
      | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ok "Flutter $installed_ver active via FVM"
    ok "Binary : $FLUTTER_CMD"
    return 0
  else
    warn "FVM install xong nhưng không resolve được binary path"
    warn "Thử chạy: fvm global $version  rồi chạy lại setup"
    return 1
  fi
}

# Cài Flutter trực tiếp qua Homebrew (fallback)
_install_flutter_homebrew() {
  if ! is_mac; then
    fail "Auto-install Flutter chỉ hỗ trợ macOS.\nXem: https://docs.flutter.dev/get-started/install"
  fi

  if ! command -v brew &>/dev/null; then
    fail "Homebrew chưa cài. Cài từ: https://brew.sh"
  fi

  info "Cài Flutter qua Homebrew..."
  brew install --cask flutter 2>&1 | tail -5

  FLUTTER_CMD="$(find_flutter)"
  if [ -z "$FLUTTER_CMD" ]; then
    fail "Cài Flutter thất bại"
  fi
  ok "Flutter đã cài: $FLUTTER_CMD"
}

setup_flutter() {
  step "1. Flutter SDK"

  local pinned_ver
  pinned_ver=$(_fvm_pinned_version)

  # ── Hiển thị project requirement ──
  info "Project yêu cầu: Flutter >=$FLUTTER_MIN_VERSION  /  Dart >=$DART_MIN_VERSION"
  if [ -n "$pinned_ver" ]; then
    info "Project FVM pin: $pinned_ver  (.fvm/fvm_config.json)"
  fi
  echo ""

  # ── Xác định target version ──
  # Nếu project có pin → dùng pin, nếu không → dùng FLUTTER_MIN_VERSION
  local target_ver="${pinned_ver:-$FLUTTER_MIN_VERSION}"

  # ─────────────────────────────────────────────────────
  # Nhánh A: FVM đã có hoặc có thể cài
  # ─────────────────────────────────────────────────────
  if command -v fvm &>/dev/null || _install_fvm; then
    local fvm_ver
    fvm_ver=$(fvm --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ok "FVM $fvm_ver  ($(command -v fvm))"

    # Kiểm tra version target đã cài trong FVM chưa
    local already_installed=false
    if fvm list 2>/dev/null | grep -q "$target_ver"; then
      already_installed=true
    fi

    # Kiểm tra version active hiện tại có đủ không
    local active_ver=""
    active_ver=$(fvm flutter --version 2>/dev/null \
      | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

    if [ -n "$active_ver" ] && version_gte "$active_ver" "$FLUTTER_MIN_VERSION"; then
      ok "Flutter $active_ver đang active via FVM — đủ yêu cầu"

      if [ -n "$pinned_ver" ] && [ "$active_ver" != "$pinned_ver" ]; then
        # Project có pin khác → switch sang pinned version
        warn "Active $active_ver ≠ pinned $pinned_ver — cần switch"
        _fvm_install_and_use "$pinned_ver" "local"
      elif [ -z "$pinned_ver" ]; then
        # Chưa pin cho project → pin FLUTTER_MIN_VERSION vào project
        info "Chưa có FVM pin cho project — pin Flutter $FLUTTER_MIN_VERSION vào project..."
        _fvm_install_and_use "$FLUTTER_MIN_VERSION" "local"
      else
        # Đã pin đúng version → re-resolve binary path
        FLUTTER_CMD="$(find_flutter 2>/dev/null || echo '')"
        export FLUTTER_CMD
      fi
    else
      # Cần cài target version
      if $already_installed; then
        info "Flutter $target_ver đã có trong FVM — set active cho project..."
      else
        info "Cài Flutter $target_ver qua FVM..."
      fi

      # Luôn pin vào project (local) thay vì global
      _fvm_install_and_use "$target_ver" "local" || _install_flutter_homebrew
    fi

    # Verify Dart
    local dart_ver
    dart_ver=$(fvm dart --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    if [ -n "$dart_ver" ]; then
      if version_gte "$dart_ver" "$DART_MIN_VERSION"; then
        ok "Dart $dart_ver (bundled) — đủ yêu cầu"
      else
        warn "Dart $dart_ver < required $DART_MIN_VERSION"
      fi
    fi

  # ─────────────────────────────────────────────────────
  # Nhánh B: FVM không có, dùng Flutter trực tiếp
  # ─────────────────────────────────────────────────────
  else
    warn "FVM không khả dụng — dùng Flutter trực tiếp"

    if [ -n "$FLUTTER_CMD" ]; then
      local flutter_ver
      flutter_ver=$("$FLUTTER_CMD" --version 2>/dev/null \
        | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

      if version_gte "$flutter_ver" "$FLUTTER_MIN_VERSION"; then
        ok "Flutter $flutter_ver  ($FLUTTER_CMD) — đủ yêu cầu"
        return
      else
        warn "Flutter $flutter_ver < $FLUTTER_MIN_VERSION — cần nâng cấp"
      fi
    fi

    _install_flutter_homebrew
  fi

  # ── Final verify ──
  echo ""
  info "Verify sau cài đặt..."
  local final_cmd="${FLUTTER_CMD:-flutter}"
  local final_flutter final_dart
  final_flutter=$($final_cmd --version 2>/dev/null \
    | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  final_dart=$($final_cmd --version 2>/dev/null \
    | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

  if [ -n "$final_flutter" ]; then
    ok "Flutter $final_flutter  ✓"
    ok "Dart    $final_dart  ✓"
    info "Command: $final_cmd"
  else
    fail "Không verify được Flutter sau cài đặt. Kiểm tra PATH."
  fi
}

# ─── pub get Gate ─────────────────────────────────────────────────────────────
#
# Chạy ngay sau khi Flutter đã có — verify pub get pass trước khi cài thêm.
# Nếu thất bại: hiển thị đầy đủ lỗi và dừng hẳn (exit 1).
#
# Skip nếu Flutter chưa cài (không thể chạy pub get).

run_pub_get_gate() {
  step "pub get — Verify dependencies"

  # Re-resolve FLUTTER_CMD sau khi setup_flutter có thể vừa cài xong
  if [ -z "${FLUTTER_CMD:-}" ]; then
    FLUTTER_CMD="$(find_flutter 2>/dev/null || echo '')"
    export FLUTTER_CMD
  fi

  if [ -z "$FLUTTER_CMD" ]; then
    warn "Flutter chưa cài — bỏ qua pub get gate"
    return 0
  fi

  # Xác định lệnh pub get phù hợp (fvm nếu có)
  local pub_cmd="$FLUTTER_CMD pub get"
  local pub_label="flutter pub get"
  if command -v fvm &>/dev/null; then
    pub_label="fvm flutter pub get"
  fi
  info "Chạy ${pub_label} để verify packages..."
  echo ""

  local pub_out pub_exit=0
  pub_out=$(cd "$PROJECT_ROOT" && "$FLUTTER_CMD" pub get 2>&1) || pub_exit=$?

  if [ "$pub_exit" -ne 0 ]; then
    # Lấy SDK version hiện tại để hiển thị context
    local cur_flutter="" cur_dart=""
    local _ver_out
    _ver_out=$("$FLUTTER_CMD" --version 2>/dev/null)
    cur_flutter=$(echo "$_ver_out" | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    cur_dart=$(echo "$_ver_out" | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    echo ""
    echo -e "  ${RED}${BOLD}$(printf '═%.0s' $(seq 1 64))${NC}"
    echo -e "  ${RED}${BOLD}  ⛔  flutter pub get THẤT BẠI${NC}"
    echo -e "  ${RED}${BOLD}$(printf '═%.0s' $(seq 1 64))${NC}"
    echo ""
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
    echo -e "  ${BOLD}Output đầy đủ:${NC}"
    echo ""
    # Thêm Flutter SDK version vì pub get chỉ in Dart SDK
    [ -n "$cur_flutter" ] && \
      echo "    The current Flutter SDK version is ${cur_flutter}."
    echo "$pub_out" | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}Không thể tiếp tục setup.${NC}"
    echo -e "  ${GRAY}Fix lỗi ở trên, sau đó chạy thủ công: ${NC}${CYAN}${pub_label}${NC}"
    echo -e "  ${GRAY}Rồi chạy lại: ${NC}${CYAN}flutter-auto setup --project $PROJECT_ROOT${NC}"
    echo ""
    fail "pub get thất bại — setup bị hủy"
  fi

  local pkg_count
  pkg_count=$(grep -c "^  source:" "$PROJECT_ROOT/pubspec.lock" 2>/dev/null || echo "?")
  ok "pub get OK — $pkg_count packages resolved"
}

# ─── Android Setup ────────────────────────────────────────────────────────────

setup_android() {
  step "2. Android SDK"

  # Kiểm tra Java
  if ! command -v java &>/dev/null; then
    info "Cài Java $JAVA_MIN_VERSION via Homebrew..."
    brew install --cask temurin@${JAVA_MIN_VERSION} 2>&1 | tail -3
    ok "Java $JAVA_MIN_VERSION đã cài"
  else
    local java_ver
    java_ver=$(java -version 2>&1 | grep -oE '"[0-9]+' | tr -d '"' | head -1)
    ok "Java $java_ver đã có"
  fi

  # ANDROID_HOME
  local sdk_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

  if [ -z "$sdk_home" ]; then
    # Thử tìm Android SDK mặc định
    for candidate in \
      "$HOME/Library/Android/sdk" \
      "$HOME/Android/Sdk" \
      "/usr/local/lib/android/sdk"; do
      if [ -d "$candidate" ]; then
        sdk_home="$candidate"
        break
      fi
    done
  fi

  if [ -z "$sdk_home" ]; then
    warn "Không tìm thấy Android SDK."
    info "Cài Android Studio hoặc cmdline-tools từ:"
    info "  https://developer.android.com/studio"
    info "Sau đó set: export ANDROID_HOME=\$HOME/Library/Android/sdk"
    return
  fi

  ok "ANDROID_HOME: $sdk_home"
  export ANDROID_HOME="$sdk_home"
  export ANDROID_SDK_ROOT="$sdk_home"

  # Thêm vào shell config nếu chưa có
  local shell_rc="$HOME/.zshrc"
  if ! grep -q "ANDROID_HOME" "$shell_rc" 2>/dev/null; then
    {
      echo ""
      echo "# Android SDK"
      echo "export ANDROID_HOME=\"$sdk_home\""
      echo "export ANDROID_SDK_ROOT=\"$sdk_home\""
      echo "export PATH=\"\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$PATH\""
    } >> "$shell_rc"
    ok "Đã thêm ANDROID_HOME vào $shell_rc"
    info "Chạy: source $shell_rc"
  fi

  # Accept licenses
  if command -v sdkmanager &>/dev/null || [ -f "$sdk_home/cmdline-tools/latest/bin/sdkmanager" ]; then
    info "Accepting Android licenses..."
    yes | "$sdk_home/cmdline-tools/latest/bin/sdkmanager" --licenses &>/dev/null 2>&1 || \
    yes | sdkmanager --licenses &>/dev/null 2>&1 || true
    ok "Android licenses accepted"
  fi
}

# ─── iOS Setup ────────────────────────────────────────────────────────────────

setup_ios() {
  step "3. iOS Environment"

  if ! is_mac; then
    skip "iOS setup (macOS only)"
    return
  fi

  # CocoaPods
  if ! command -v pod &>/dev/null; then
    info "Cài CocoaPods..."
    if command -v brew &>/dev/null; then
      brew install cocoapods
    else
      sudo gem install cocoapods
    fi
    ok "CocoaPods đã cài: $(pod --version)"
  else
    ok "CocoaPods $(pod --version) đã có"
  fi

  # Pod install nếu Podfile tồn tại
  if [ -f "$PROJECT_ROOT/ios/Podfile" ]; then
    info "Chạy pod install..."
    cd "$PROJECT_ROOT/ios"
    pod install --repo-update 2>&1 | tail -5
    cd "$PROJECT_ROOT"
    ok "Pod install hoàn tất"
  fi

  # Xcode command line tools
  if ! xcode-select -p &>/dev/null; then
    info "Cài Xcode Command Line Tools..."
    xcode-select --install
    warn "Chờ cài xong rồi chạy lại script"
    exit 0
  fi
  ok "Xcode CLI tools: $(xcode-select -p)"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  header "Dev Environment Setup — $APP_NAME"
  require_project
  cd "$PROJECT_ROOT"

  run_preflight

  if $DO_FLUTTER; then setup_flutter; fi

  # pub get gate — chạy sau khi Flutter đã có, trước Android/iOS
  # Đảm bảo dependencies giải quyết được trước khi tiếp tục cài đặt
  run_pub_get_gate

  if $DO_ANDROID; then setup_android; fi
  if $DO_IOS;     then setup_ios;     fi

  echo ""
  ok "Dev environment setup hoàn tất!"
  echo ""
  echo -e "  ${BOLD}Bước tiếp theo:${NC}"
  echo "    flutter-auto deps              # Cài dependencies"
  echo "    flutter-auto run               # Chạy app (dev)"
  echo "    flutter-auto signing           # Cấu hình signing (release)"
  echo ""
}

main
