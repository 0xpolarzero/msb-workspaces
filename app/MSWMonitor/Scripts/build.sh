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

# Local verification stays unsigned by default. A release-capable build can opt
# into an installed Apple team signing identity without changing the script.
typeset -a signingSettings
# An explicit CODE_SIGNING_ALLOWED value always wins.
typeset signingAllowed="${CODE_SIGNING_ALLOWED:-}"
if [[ -z "$signingAllowed" ]]; then
  if [[ -n "${CODE_SIGN_IDENTITY:-}" || -n "${DEVELOPMENT_TEAM:-}" ]]; then
    signingAllowed=YES
  else
    signingAllowed=NO
  fi
fi
signingSettings=("CODE_SIGNING_ALLOWED=$signingAllowed")
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  signingSettings+=("CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}")
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  signingSettings+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
fi

typeset -a connectSettings
if [[ -n "${MSW_CONNECT_BASE_URL:-}" ]]; then
  connectSettings+=("MSW_CONNECT_BASE_URL=${MSW_CONNECT_BASE_URL}")
fi
if [[ -n "${MSW_CONNECT_CLIENT_ID:-}" ]]; then
  connectSettings+=("MSW_CONNECT_CLIENT_ID=${MSW_CONNECT_CLIENT_ID}")
fi
if [[ -n "${MSW_CONNECT_INSTALLATION_URL:-}" ]]; then
  connectSettings+=("MSW_CONNECT_INSTALLATION_URL=${MSW_CONNECT_INSTALLATION_URL}")
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
  "${signingSettings[@]}" \
  "${connectSettings[@]}" \
  build 2>&1 | tee "$LOG_DIR/build.log"

test -x "$BUILD_DIR/MSWMonitor.app/Contents/MacOS/MSWMonitor"
