#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
BUILD_DIR="$APP_DIR/build"
LOG_DIR="$BUILD_DIR/logs"

mkdir -p "$LOG_DIR"

if [[ -d "$BUILD_DIR/Silo.app" ]]; then
  /bin/rm -rf -- "$BUILD_DIR/Silo.app"
fi

# Local verification uses a complete ad-hoc signature by default. A
# release-capable build can opt into an installed Apple team signing identity.
typeset -a signingSettings
typeset localAdHocSigning=NO
if (( ! ${+CODE_SIGNING_ALLOWED} && ! ${+CODE_SIGN_IDENTITY} && ! ${+DEVELOPMENT_TEAM} )); then
  localAdHocSigning=YES
fi
# An explicit CODE_SIGNING_ALLOWED value always wins.
typeset signingAllowed="${CODE_SIGNING_ALLOWED:-}"
if [[ -z "$signingAllowed" ]]; then
  signingAllowed=YES
fi
signingSettings=("CODE_SIGNING_ALLOWED=$signingAllowed")
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  signingSettings+=("CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}")
elif [[ "$localAdHocSigning" == YES ]]; then
  signingSettings+=("CODE_SIGN_IDENTITY=-")
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  signingSettings+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
fi

xcodebuild \
  -project "$APP_DIR/Silo.xcodeproj" \
  -scheme Silo \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR/DerivedData/Build" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  "${signingSettings[@]}" \
  build 2>&1 | tee "$LOG_DIR/build.log"

test -x "$BUILD_DIR/Silo.app/Contents/MacOS/Silo"
