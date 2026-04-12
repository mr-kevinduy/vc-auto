# vc-auto / flutter

Bộ automation scripts cho Flutter — **hoàn toàn độc lập**, áp dụng được cho **bất kỳ Flutter project nào** chỉ bằng cách cung cấp đường dẫn đến project.

---

## Cấu trúc

```
vc-auto/flutter/
├── README.md
└── dev/
    ├── main.sh        # Entry point / interactive menu
    ├── local.sh       # Local development workflow (doctor→setup→deps→run)
    ├── doctor.sh      # Kiểm tra dev tools & version conflicts
    ├── setup.sh       # Cài đặt & cấu hình môi trường
    ├── run.sh         # Chạy app, test, analyze
    ├── deps.sh        # Quản lý Flutter dependencies
    ├── build.sh       # Build Android (APK/AAB) & iOS (IPA)
    ├── signing.sh     # Cấu hình Android keystore & iOS certificates
    ├── deploy.sh      # Deploy Google Play & App Store
    ├── cicd.sh        # Full CI/CD pipeline
    └── lib/
        ├── common.sh  # Shared utilities (logging, project resolution, OS detection)
        ├── config.sh  # Đọc .vc-auto.yaml project config
        └── env.sh     # Quản lý .env.<stage> và dart-define injection
```

---

## Setup một lần — dùng mãi mãi

### 1. Cấp quyền thực thi

```bash
chmod +x /path/to/vc-auto/flutter/dev/*.sh
chmod +x /path/to/vc-auto/flutter/dev/lib/*.sh
```

### 2. Tạo alias toàn cục (khuyến nghị)

Thêm vào `~/.zshrc` hoặc `~/.bashrc`:

```bash
export VC_AUTO="/path/to/vc-auto"
alias flutter-auto="$VC_AUTO/flutter/dev/main.sh"
```

```bash
source ~/.zshrc
```

Từ giờ gõ `flutter-auto` từ bất kỳ đâu.

---

## Cách cung cấp Project Path

Scripts tự đọc `pubspec.yaml`, `build.gradle`, `project.pbxproj` để lấy thông tin project — **không cần cấu hình thêm gì**.

| Cách | Ví dụ |
|---|---|
| Argument đầu tiên | `flutter-auto /path/to/project build --android` |
| Flag `--project` | `flutter-auto --project /path/to/project deps` |
| Env var | `FLUTTER_PROJECT=/path/to/project flutter-auto cicd` |
| Từ trong project | `cd /path/to/project && flutter-auto` |

---

## Interactive Menu

```bash
flutter-auto /path/to/project
```

```
╔══════════════════════════════════════════════════╗
║         Flutter Automation — vc-auto             ║
╚══════════════════════════════════════════════════╝

  Project : My Flutter App
  Path    : /path/to/my-flutter-project
  Flutter : 3.29.0
  Version : 1.2.0+10  Branch: main

  Development
  1  Local dev  (doctor → setup → deps → run)
  2  Run app    (flutter run)

  Project
  3  Pre-check tools
  4  Setup environment
  5  Manage dependencies

  Deploy
  6  Build app
  7  Deploy to stores
  8  Full CI/CD pipeline

  0  Exit
```

---

## Workflows

### Development local

Dành cho phát triển hàng ngày. Không cần signing, store credentials, hay Fastlane.
Build mode luôn là **debug**.

```bash
# Workflow đầy đủ: doctor → setup → deps → run
flutter-auto local /path/to/project

# Tùy chỉnh
flutter-auto local /path/to/project --android          # Chạy trên Android emulator
flutter-auto local /path/to/project --ios              # Chạy trên iOS simulator
flutter-auto local /path/to/project --device <id>      # Device cụ thể
flutter-auto local /path/to/project --flavor dev       # Dùng flavor dev (default: local)
flutter-auto local /path/to/project --check            # analyze + test, không run app
flutter-auto local /path/to/project --skip-doctor      # Bỏ qua doctor check
flutter-auto local /path/to/project --skip-setup       # Bỏ qua setup
flutter-auto local /path/to/project --skip-deps        # Bỏ qua pub get
```

### Deploy (multi-stage)

Dành cho build release và deploy lên stores. Yêu cầu signing config và store credentials.

```bash
# Build + deploy staging lên Google Play Internal
flutter-auto /path/to/project cicd --android --env stg

# Build + deploy production lên cả 2 stores
flutter-auto /path/to/project cicd --env prod

# Chỉ build (không deploy)
flutter-auto /path/to/project build --env prod --parallel

# Deploy artifact đã build
flutter-auto /path/to/project deploy --android --track production
flutter-auto /path/to/project deploy --ios --testflight
```

---

## Project Config (`.vc-auto.yaml`)

Tạo file này ở root của Flutter project để cấu hình flavors và environments. Commit vào repository.

```bash
# Tạo template tự động
flutter-auto env-init /path/to/project
```

```yaml
# .vc-auto.yaml
flavors:
  local:
    env_file: .env.local
    debug: true

  dev:
    env_file: .env.dev
    debug: true
    deploy_target: firebase   # firebase | internal | alpha | beta | production

  stg:
    env_file: .env.stg
    debug: false
    deploy_target: internal

  prod:
    env_file: .env.prod
    debug: false
    deploy_target: production
```

Scripts tự đọc config này để:
- Xác định `--debug` hay `--release` theo stage
- Inject env vars đúng file cho từng stage
- Chọn deploy target phù hợp

---

## Environment Variables (`.env.<stage>`)

Mỗi stage có file `.env` riêng. **Không commit** các file này — thêm `.env.*` vào `.gitignore`.

```bash
# Tạo templates cho local/dev/stg/prod
flutter-auto env-init /path/to/project
```

```bash
# .env.local
ENV=local
API_URL=http://localhost:3000

# .env.dev
ENV=dev
API_URL=https://dev.api.example.com

# .env.stg
ENV=stg
API_URL=https://stg.api.example.com

# .env.prod
ENV=prod
API_URL=https://api.example.com
```

Khi build, scripts tự động inject bằng `--dart-define-from-file .env.<stage>`.
Truy cập trong Dart:

```dart
const apiUrl = String.fromEnvironment('API_URL');
const env    = String.fromEnvironment('ENV', defaultValue: 'local');
```

---

## Tham chiếu nhanh

### local — Local development workflow

```bash
flutter-auto local /path/to/project                  # doctor → setup → deps → run
flutter-auto local /path/to/project --android        # Run trên Android
flutter-auto local /path/to/project --ios            # Run trên iOS
flutter-auto local /path/to/project --flavor dev     # Dùng flavor dev
flutter-auto local /path/to/project --check          # Chỉ analyze + test
flutter-auto local /path/to/project --skip-doctor    # Skip doctor
```

---

### run — Chạy app / test / analyze

```bash
flutter-auto run /path/to/project                    # flutter run (tự chọn device)
flutter-auto run /path/to/project --android          # Android emulator/device
flutter-auto run /path/to/project --ios              # iOS simulator/device
flutter-auto run /path/to/project --device <id>      # Device cụ thể
flutter-auto run /path/to/project --test             # flutter test --coverage
flutter-auto run /path/to/project --analyze          # flutter analyze
flutter-auto run /path/to/project --check            # analyze + test (pre-commit)
flutter-auto run /path/to/project --devices          # Liệt kê devices
```

---

### doctor — Kiểm tra môi trường

```bash
flutter-auto doctor /path/to/project                 # Full check
flutter-auto doctor /path/to/project --local         # Chỉ check những gì cần cho dev local
flutter-auto doctor /path/to/project --deploy        # Full check + CI tools (cho release)
flutter-auto doctor /path/to/project --android       # Chỉ Android
flutter-auto doctor /path/to/project --ios           # Chỉ iOS
flutter-auto doctor /path/to/project --ci            # + CI tools (Fastlane, Firebase CLI...)
flutter-auto doctor /path/to/project --fix           # Tự sửa pubspec.yaml nếu có conflict
flutter-auto doctor /path/to/project --deep          # Query pub.dev cho từng package
flutter-auto doctor /path/to/project --strict        # Exit 1 nếu có lỗi (dùng trong CI)
```

**Mode `--local`** — dùng cho dev hàng ngày: bỏ qua signing certs, store credentials.
**Mode `--deploy`** — dùng trước khi release: check đầy đủ bao gồm Fastlane, Firebase CLI, store creds.

Sau khi in bảng kết quả, doctor **tự động gợi ý fix** cho từng vấn đề:

```
  Có 2 vấn đề có thể tự động fix:

  1  CocoaPods
     → brew install cocoapods
  2  Podfile.lock
     → cd ios && pod install

  a  Fix tất cả
  0  Bỏ qua

  Chọn [0-2/a]:
```

Kiểm tra đầy đủ: Flutter/Dart version, FVM, pubspec constraints vs packages vs installed, Java, Android SDK, Xcode, CocoaPods, simulator, signing certificates, store credentials.

---

### setup — Cài đặt môi trường

```bash
flutter-auto setup /path/to/project                  # Full setup (Flutter + Android + iOS)
flutter-auto setup /path/to/project --flutter        # Cài/upgrade Flutter (ưu tiên FVM)
flutter-auto setup /path/to/project --android        # Setup Android SDK + Java
flutter-auto setup /path/to/project --ios            # CocoaPods + pod install
flutter-auto setup /path/to/project --signing        # Android keystore + iOS signing
flutter-auto setup /path/to/project --ci             # Decode secrets từ CI env vars
```

Setup Flutter **ưu tiên FVM** (Flutter Version Manager):
- Tôn trọng version được pin trong `.fvm/fvm_config.json`
- Cho phép nhiều project dùng Flutter version khác nhau
- Fallback sang Homebrew nếu FVM không khả dụng

---

### deps — Dependency management

```bash
flutter-auto deps /path/to/project                   # flutter pub get
flutter-auto deps /path/to/project --update          # flutter pub upgrade
flutter-auto deps /path/to/project --outdated        # Xem packages cũ
flutter-auto deps /path/to/project --check-env       # Validate environment constraints
flutter-auto deps /path/to/project --clean           # Clean + reinstall từ đầu
flutter-auto deps /path/to/project --fix             # pub upgrade --major-versions
```

---

### build — Build app

```bash
flutter-auto build /path/to/project                          # Android + iOS (release)
flutter-auto build /path/to/project --android                # Chỉ Android AAB (release)
flutter-auto build /path/to/project --android --apk          # Android APK
flutter-auto build /path/to/project --android --apk --debug  # APK debug
flutter-auto build /path/to/project --ios                    # iOS IPA (release)
flutter-auto build /path/to/project --ios --debug            # iOS no-codesign
flutter-auto build /path/to/project --env stg                # Staging build
flutter-auto build /path/to/project --env prod --parallel    # Android + iOS song song
flutter-auto build /path/to/project --flavor dev             # Flutter flavor
flutter-auto build /path/to/project --version 1.2.3+45       # Override version
```

`--env` / `--flavor` tự động:
- Xác định `--debug` hay `--release` từ `.vc-auto.yaml`
- Inject `--dart-define-from-file .env.<stage>`

`--parallel`: build Android và iOS đồng thời, tiết kiệm ~40% thời gian.

Output: `{project}/dist/{env}/{mode}/`

---

### deploy — Deploy lên stores

```bash
flutter-auto deploy /path/to/project                           # Deploy cả 2 stores
flutter-auto deploy /path/to/project --android                 # Google Play (internal)
flutter-auto deploy /path/to/project --android --track alpha
flutter-auto deploy /path/to/project --android --track beta
flutter-auto deploy /path/to/project --android --track production
flutter-auto deploy /path/to/project --ios                     # App Store
flutter-auto deploy /path/to/project --ios --testflight        # TestFlight only
flutter-auto deploy /path/to/project --dry-run                 # Preview, không deploy thật
```

---

### cicd — Full CI/CD pipeline

```bash
flutter-auto cicd /path/to/project                          # Full pipeline
flutter-auto cicd /path/to/project --android               # Chỉ Android
flutter-auto cicd /path/to/project --ios                   # Chỉ iOS
flutter-auto cicd /path/to/project --env stg               # Staging
flutter-auto cicd /path/to/project --env prod              # Production
flutter-auto cicd /path/to/project --skip-test             # Bỏ qua test
flutter-auto cicd /path/to/project --skip-deploy           # Build only
flutter-auto cicd /path/to/project --stage doctor          # Chạy 1 stage
flutter-auto cicd /path/to/project --play-track beta
flutter-auto cicd /path/to/project --testflight
```

Pipeline: `doctor → deps → test → build → deploy`

```
╔══════════════════════════════════════════════╗
║           Pipeline Summary                   ║
╠══════════════════════════════════════════════╣
║  doctor      ✅ passed            12s        ║
║  deps        ✅ passed            45s        ║
║  test        ✅ passed            38s        ║
║  build       ✅ passed           142s        ║
║  deploy      ✅ passed            23s        ║
╠══════════════════════════════════════════════╣
║  TOTAL                           260s        ║
╚══════════════════════════════════════════════╝
```

---

## Credentials (Deploy)

Set một lần, dùng cho mọi project. Thường đặt trong CI secrets hoặc `~/.zshrc`.

| Variable | Dùng cho |
|---|---|
| `GOOGLE_PLAY_KEY_JSON` | Google Play API key (base64) |
| `APP_STORE_CONNECT_API_KEY` | App Store Connect API key (base64) |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer ID |
| `ANDROID_KEYSTORE_BASE64` | Android keystore (base64) |
| `ANDROID_KEY_PASSWORD` | Android key password |
| `ANDROID_STORE_PASSWORD` | Android store password |

---

## Dùng trong CI/CD

### GitHub Actions

```yaml
# .github/workflows/release.yml

jobs:
  android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { java-version: '17' }
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.29.0' }
      - name: Checkout vc-auto
        uses: actions/checkout@v4
        with:
          repository: your-org/vc-auto
          path: vc-auto
      - run: chmod +x vc-auto/flutter/dev/*.sh vc-auto/flutter/dev/lib/*.sh
      - run: vc-auto/flutter/dev/main.sh --project . cicd --android --env prod --play-track internal
        env:
          GOOGLE_PLAY_KEY_JSON: ${{ secrets.GOOGLE_PLAY_KEY_JSON }}
          ANDROID_KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
          ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}

  ios:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { flutter-version: '3.29.0' }
      - name: Checkout vc-auto
        uses: actions/checkout@v4
        with:
          repository: your-org/vc-auto
          path: vc-auto
      - run: chmod +x vc-auto/flutter/dev/*.sh vc-auto/flutter/dev/lib/*.sh
      - run: vc-auto/flutter/dev/main.sh --project . cicd --ios --env prod --testflight
        env:
          APP_STORE_CONNECT_API_KEY: ${{ secrets.APP_STORE_CONNECT_API_KEY }}
          APP_STORE_CONNECT_API_KEY_ID: ${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}
          APP_STORE_CONNECT_API_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_API_ISSUER_ID }}
```

### Bitrise

```yaml
- script:
    inputs:
    - content: |
        git clone https://your-repo/vc-auto.git /tmp/vc-auto
        chmod +x /tmp/vc-auto/flutter/dev/*.sh /tmp/vc-auto/flutter/dev/lib/*.sh
        FLUTTER_PROJECT="$BITRISE_SOURCE_DIR" \
          /tmp/vc-auto/flutter/dev/main.sh cicd --android --env prod
```

---

## Ví dụ thực tế — nhiều project

```bash
# Sáng: local dev trên project A (auto doctor + setup + run)
flutter-auto local ~/projects/app-a --ios

# Project B: build staging và deploy lên Firebase App Distribution
flutter-auto ~/projects/app-b cicd --android --env dev

# Project C: build production song song rồi deploy
flutter-auto ~/projects/app-c build --env prod --parallel
flutter-auto ~/projects/app-c deploy --android --track beta --ios --testflight

# Interactive menu cho project D
flutter-auto ~/projects/app-d
```

---

## Cách hoạt động

Scripts **tự đọc config từ project** khi khởi động — không cần cấu hình trước:

| Thông tin | Đọc từ |
|---|---|
| App name | `pubspec.yaml` → `description` hoặc `name` |
| Flutter min version | `pubspec.yaml` → `environment.flutter` |
| Dart min version | `pubspec.yaml` → `environment.sdk` |
| Android App ID | `android/app/build.gradle[.kts]` |
| iOS Bundle ID | `ios/Runner.xcodeproj/project.pbxproj` |
| Flavor config | `.vc-auto.yaml` (optional) |
| Env variables | `.env.<stage>` (optional) |

Logs được lưu tại: `{project}/.logs/automate/`

---

## Yêu cầu hệ thống

| Tool | Version | Bắt buộc |
|---|---|---|
| Flutter | >=3.0.0 | Tất cả |
| Dart | >=3.0.0 | Tất cả |
| Java | >=17 | Android |
| Xcode | latest | iOS (macOS only) |
| CocoaPods | latest | iOS |
| Fastlane | latest | Deploy (optional — fallback sang xcrun/altool) |
| FVM | any | Khuyến nghị để quản lý Flutter version |
| jq | any | JSON parsing trong scripts |
