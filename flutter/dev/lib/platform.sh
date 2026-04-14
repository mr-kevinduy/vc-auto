#!/usr/bin/env bash
# vc-auto/flutter/dev/lib/platform.sh
# Cross-platform helpers: macOS · Linux · Git Bash (Windows / MSYS2 / Cygwin)
#
# SOURCE QUA common.sh — không source trực tiếp.
# Tất cả business logic gọi helper ở đây thay vì check OS trực tiếp.

# ─── OS Detection ─────────────────────────────────────────────────────────────

is_mac()     { [[ "${OSTYPE:-}" == "darwin"* ]]; }
is_linux()   { [[ "${OSTYPE:-}" == "linux"*  ]]; }
is_windows() { [[ "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "mingw"* ]]; }
is_unix()    { is_mac || is_linux; }
is_ci()      { [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${BITRISE_IO:-}" ]; }

# ─── iOS / macOS Guard ────────────────────────────────────────────────────────
#
# Dùng ở đầu mỗi function cần macOS để skip gracefully thay vì fail.
#
# Usage:
#   require_macos "iOS build" || return 0

require_macos() {
  local feature="${1:-Tính năng này}"
  if ! is_mac; then
    skip "$feature (macOS only)"
    return 1
  fi
  return 0
}

# ─── sed in-place ─────────────────────────────────────────────────────────────
#
# macOS BSD sed cần `sed -i ''`; GNU sed (Linux / Git Bash) dùng `sed -i`.
#
# Usage: sed_inplace 's/foo/bar/' /path/to/file

sed_inplace() {
  local expr="$1" file="$2"
  if is_mac; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

# ─── base64 decode ────────────────────────────────────────────────────────────
#
# macOS / Linux: base64 --decode (GNU) hoặc base64 -d
# Windows:       certutil -decode (nếu có) hoặc GNU base64 từ Git Bash
#
# Usage:
#   echo "$ENCODED"     | base64_decode > output.bin   # stdin
#   base64_decode "$VAR" > output.bin                  # argument

base64_decode() {
  if [ $# -gt 0 ]; then
    # Input từ argument
    if is_windows && command -v certutil &>/dev/null; then
      local tmp
      tmp=$(mktemp)
      printf '%s' "$1" > "${tmp}.b64"
      certutil -decode "${tmp}.b64" "$tmp" > /dev/null 2>&1
      cat "$tmp"
      rm -f "$tmp" "${tmp}.b64"
    else
      printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -d
    fi
  else
    # Input từ stdin
    if is_windows && command -v certutil &>/dev/null; then
      local tmp
      tmp=$(mktemp)
      cat > "${tmp}.b64"
      certutil -decode "${tmp}.b64" "$tmp" > /dev/null 2>&1
      cat "$tmp"
      rm -f "$tmp" "${tmp}.b64"
    else
      base64 --decode 2>/dev/null || base64 -d
    fi
  fi
}

# ─── Package Manager Detection ────────────────────────────────────────────────
#
# Trả về tên package manager đang có trên hệ thống.
#   macOS   → brew
#   Windows → winget | choco | scoop | none
#   Linux   → apt | dnf | pacman | none

detect_pkg_manager() {
  if is_mac; then
    command -v brew    &>/dev/null && echo "brew"   && return
    echo "none"
  elif is_windows; then
    command -v winget  &>/dev/null && echo "winget" && return
    command -v choco   &>/dev/null && echo "choco"  && return
    command -v scoop   &>/dev/null && echo "scoop"  && return
    echo "none"
  else
    command -v apt-get &>/dev/null && echo "apt"    && return
    command -v dnf     &>/dev/null && echo "dnf"    && return
    command -v pacman  &>/dev/null && echo "pacman" && return
    echo "none"
  fi
}

# ─── Install FVM via package manager ──────────────────────────────────────────
#
# Trả về 0 nếu cài thành công, 1 nếu không có package manager phù hợp.

install_fvm() {
  local pkg
  pkg=$(detect_pkg_manager)
  case "$pkg" in
    brew)
      brew tap leoafarias/fvm 2>/dev/null || true
      brew install fvm 2>&1 | tail -3
      ;;
    winget)
      winget install leoafarias.fvm --silent 2>&1 | tail -3
      ;;
    choco)
      choco install fvm -y 2>&1 | tail -3
      ;;
    scoop)
      scoop install fvm 2>&1 | tail -3
      ;;
    *)
      # Fallback: dart pub global (cross-platform)
      if command -v dart &>/dev/null; then
        dart pub global activate fvm
      elif is_linux; then
        curl -fsSL https://fvm.app/install.sh | bash 2>&1 | tail -5
        export PATH="$HOME/.pub-cache/bin:$PATH"
      else
        return 1
      fi
      ;;
  esac
}

# ─── Install Flutter via package manager ──────────────────────────────────────
#
# Fallback khi FVM không khả dụng.

install_flutter_direct() {
  local pkg
  pkg=$(detect_pkg_manager)
  case "$pkg" in
    brew)
      brew install --cask flutter 2>&1 | tail -5
      ;;
    choco)
      choco install flutter -y 2>&1 | tail -5
      ;;
    scoop)
      scoop bucket add extras
      scoop install flutter 2>&1 | tail -5
      ;;
    winget)
      warn "winget chưa có package Flutter chính thức — dùng choco hoặc tải thủ công:"
      info "https://docs.flutter.dev/get-started/install/windows"
      return 1
      ;;
    apt|dnf|pacman)
      warn "Linux package manager không có Flutter — dùng FVM hoặc tải thủ công:"
      info "https://docs.flutter.dev/get-started/install/linux"
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# ─── Install Java via package manager ─────────────────────────────────────────

install_java() {
  local version="${1:-17}"
  local pkg
  pkg=$(detect_pkg_manager)
  case "$pkg" in
    brew)
      brew install --cask "temurin@${version}" 2>&1 | tail -3
      ;;
    choco)
      choco install temurin${version} -y 2>&1 | tail -3
      ;;
    scoop)
      scoop bucket add java
      scoop install "temurin${version}-jdk" 2>&1 | tail -3
      ;;
    winget)
      winget install EclipseAdoptium.Temurin.${version}.JDK --silent 2>&1 | tail -3
      ;;
    apt)
      sudo apt-get install -y "openjdk-${version}-jdk" 2>&1 | tail -3
      ;;
    dnf)
      sudo dnf install -y "java-${version}-openjdk-devel" 2>&1 | tail -3
      ;;
    pacman)
      sudo pacman -S --noconfirm "jdk${version}-openjdk" 2>&1 | tail -3
      ;;
    *)
      warn "Không tìm thấy package manager — cài Java thủ công từ: https://adoptium.net"
      return 1
      ;;
  esac
}

# ─── Install CocoaPods ────────────────────────────────────────────────────────
#
# macOS only — luôn check require_macos trước khi gọi.

install_cocoapods() {
  require_macos "CocoaPods" || return 1
  if command -v brew &>/dev/null; then
    brew install cocoapods 2>&1 | tail -3
  else
    sudo gem install cocoapods
  fi
}

# ─── Android SDK default paths ────────────────────────────────────────────────
#
# Trả về danh sách candidates theo OS, mỗi path trên 1 dòng.
# Caller dùng vòng lặp để tìm path tồn tại đầu tiên.

android_sdk_candidates() {
  if is_mac; then
    echo "$HOME/Library/Android/sdk"
    echo "$HOME/Android/Sdk"
  elif is_windows; then
    # MSYS2 format: /c/Users/... hoặc dùng env var Windows
    local local_app="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}"
    echo "$local_app/Android/sdk"
    echo "$local_app/Android/Sdk"
    echo "C:/Android/sdk"
    echo "C:/Android/Sdk"
  else
    echo "$HOME/Android/Sdk"
    echo "$HOME/Android/sdk"
    echo "/opt/android-sdk"
    echo "/usr/lib/android-sdk"
  fi
}

# ─── Flutter fallback paths ───────────────────────────────────────────────────
#
# Dùng bởi find_flutter() khi không tìm thấy qua PATH hay FVM.

flutter_fallback_paths() {
  if is_mac; then
    echo "/opt/homebrew/share/flutter/bin/flutter"
    echo "/opt/homebrew/bin/flutter"
    echo "$HOME/development/flutter/bin/flutter"
    echo "$HOME/flutter/bin/flutter"
  elif is_windows; then
    echo "$HOME/flutter/bin/flutter"
    echo "$HOME/development/flutter/bin/flutter"
    echo "C:/flutter/bin/flutter"
    echo "C:/src/flutter/bin/flutter"
  else
    echo "$HOME/flutter/bin/flutter"
    echo "$HOME/development/flutter/bin/flutter"
    echo "/opt/flutter/bin/flutter"
    echo "/usr/local/flutter/bin/flutter"
  fi
}

# ─── FVM global candidates ────────────────────────────────────────────────────
#
# Paths tới flutter binary được set bởi `fvm global`.

fvm_global_candidates() {
  if is_windows; then
    local local_app="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}"
    echo "$local_app/fvm/default/bin/flutter"
    echo "$HOME/fvm/default/bin/flutter"
  else
    echo "${FVM_HOME:-$HOME/fvm}/default/bin/flutter"
    echo "$HOME/.fvm/default/bin/flutter"
    echo "$HOME/fvm/default/bin/flutter"
  fi
}

# ─── FVM versions directories ─────────────────────────────────────────────────
#
# Directories chứa các Flutter version được cài bởi FVM.

fvm_versions_dirs() {
  if is_windows; then
    local local_app="${LOCALAPPDATA:-$USERPROFILE/AppData/Local}"
    echo "$local_app/fvm/versions"
    echo "$HOME/fvm/versions"
  else
    echo "${FVM_HOME:-$HOME/fvm}/versions"
    echo "$HOME/.fvm/versions"
    echo "$HOME/fvm/versions"
  fi
}

# ─── Open Simulator ───────────────────────────────────────────────────────────
#
# macOS: open -a Simulator
# Windows / Linux: warn và return 1

open_simulator() {
  if is_mac; then
    open -a Simulator
  else
    warn "iOS Simulator chỉ chạy được trên macOS"
    return 1
  fi
}

# ─── Shell config file ────────────────────────────────────────────────────────
#
# Trả về path file shell config để append PATH exports.

shell_config_file() {
  if is_windows; then
    # Git Bash dùng ~/.bashrc hoặc ~/.bash_profile
    [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" && return
    echo "$HOME/.bash_profile"
  else
    [ -f "$HOME/.zshrc"      ] && echo "$HOME/.zshrc"      && return
    [ -f "$HOME/.bashrc"     ] && echo "$HOME/.bashrc"      && return
    [ -f "$HOME/.bash_profile" ] && echo "$HOME/.bash_profile" && return
    echo "$HOME/.zshrc"
  fi
}
