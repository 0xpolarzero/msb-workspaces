#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
BUILD_DIR="$APP_DIR/build"
LOG_DIR="$BUILD_DIR/logs"
TEST_PRODUCTS_DIR="$BUILD_DIR/TestProducts"

mkdir -p "$LOG_DIR"

xcodebuild \
  -project "$APP_DIR/Silo.xcodeproj" \
  -scheme Silo \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR/DerivedData/Tests" \
  -only-testing:SiloTests \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$TEST_PRODUCTS_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee "$LOG_DIR/test.log"
