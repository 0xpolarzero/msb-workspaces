#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
BUILD_DIR="$APP_DIR/build"
LOG_DIR="$BUILD_DIR/logs"

mkdir -p "$LOG_DIR"

if [[ -d "$BUILD_DIR/MSWMonitor.app" ]]; then
  /bin/rm -rf -- "$BUILD_DIR/MSWMonitor.app"
fi

xcodebuild \
  -project "$APP_DIR/MSWMonitor.xcodeproj" \
  -scheme MSWMonitor \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR/DerivedData/Build" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$LOG_DIR/build.log"

test -x "$BUILD_DIR/MSWMonitor.app/Contents/MacOS/MSWMonitor"
