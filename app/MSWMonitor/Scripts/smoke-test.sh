#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
APP_PATH="$APP_DIR/build/MSWMonitor.app"
LOG_DIR="$APP_DIR/build/logs"
SMOKE_LOG="$LOG_DIR/smoke-ui.log"
DERIVED_DATA="$APP_DIR/build/DerivedData/Smoke"
PRODUCTS_DIR="$APP_DIR/build/SmokeProducts"

mkdir -p "$LOG_DIR"
rm -f "$SMOKE_LOG" "$LOG_DIR/smoke-app.log" "$LOG_DIR/smoke-launch.log"
/bin/rm -rf -- "$DERIVED_DATA" "$PRODUCTS_DIR"

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
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  test 2>&1 | tee "$SMOKE_LOG"

grep -q '^\*\* TEST SUCCEEDED \*\*$' "$SMOKE_LOG"
