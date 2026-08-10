#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
APP_PATH="$APP_DIR/build/MSWMonitor.app"
LOG_DIR="$APP_DIR/build/logs"
SMOKE_LOG="$LOG_DIR/smoke-ui.log"
DERIVED_DATA="$APP_DIR/build/DerivedData/Smoke"
PRODUCTS_DIR="$APP_DIR/build/SmokeProducts"
TEST_PRODUCTS_ROOT="$HOME/Library/Developer/Xcode/DerivedData/MSWMonitor-smoke"
TEST_PRODUCTS_DIR="$TEST_PRODUCTS_ROOT/Build/Products/Debug"

mkdir -p "$LOG_DIR"
rm -f "$SMOKE_LOG" "$LOG_DIR/smoke-app.log" "$LOG_DIR/smoke-launch.log"
/bin/rm -rf -- "$DERIVED_DATA" "$PRODUCTS_DIR" "$TEST_PRODUCTS_ROOT"

test -x "$APP_PATH/Contents/MacOS/MSWMonitor"

xcodebuild \
  -project "$APP_DIR/MSWMonitor.xcodeproj" \
  -scheme MSWMonitor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:MSWMonitorUITests \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$TEST_PRODUCTS_DIR" \
  CODE_SIGN_IDENTITY=- \
  build-for-testing 2>&1 | tee "$SMOKE_LOG"

# macOS 26 may leave ad-hoc runners under a repository path suspended
# during XProtect's first scan. Run the runner from Xcode's trusted
# per-user DerivedData location and retain a local inspection symlink.
ln -s "$TEST_PRODUCTS_DIR" "$PRODUCTS_DIR"


xcodebuild \
  -project "$APP_DIR/MSWMonitor.xcodeproj" \
  -scheme MSWMonitor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:MSWMonitorUITests \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$TEST_PRODUCTS_DIR" \
  CODE_SIGN_IDENTITY=- \
  test-without-building 2>&1 | tee -a "$SMOKE_LOG"

grep -q '^\*\* TEST EXECUTE SUCCEEDED \*\*$' "$SMOKE_LOG"
