#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
APP_PATH="$APP_DIR/build/MSWMonitor.app"
LOG_DIR="$APP_DIR/build/logs"
SMOKE_LOG="$LOG_DIR/smoke-ui.log"
DERIVED_DATA="$APP_DIR/build/DerivedData/Smoke"
PRODUCTS_DIR="$APP_DIR/build/SmokeProducts"

TEST_TARGET="MSWMonitorUITests"
case "${1:-}" in
  "") ;;
  --monitor-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testStatusItemMinimalPopoverAndQuit"
    ;;
  --repair-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testDedicatedRuntimeRepairClearsEverySurfaceAfterVerifiedReactivation"
    ;;
  --picker-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testDirectFolderPickerFromStatusPopover"
    ;;
  --preferences-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testApplicationPreferencesUpdateWorkspaceActions"
    ;;
  --navigation-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testUnifiedWindowUsesTopTabsAndWorkspaceSections"
    ;;
  --secrets-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testSecretsTabAddEditRemoveWildcardConfirmationAndRestartBadges"
    ;;
  --lifecycle-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testUnifiedWindowOwnsLifecycleConfirmationAndVerifiesRestartGap"
    ;;
  --backup-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testBackupDestinationSelectionShowsRequiredSpaceConfirmation"
    ;;
  --backup-result-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testBackupResultCardSuccessPartialAndFailure"
    ;;
  --backup-operations-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testBackupConcurrentFixtureReattachesAfterRelaunchAndAdvancesCounters"
    ;;
  --network-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testNetworkShowsActivePortsFirst"
    ;;
  --files-cache-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testFilesStayCachedAcrossWorkspaceTabs"
    ;;
  --failure-only)
    TEST_TARGET="MSWMonitorUITests/MSWMonitorUITests/testOperationFailureOpensDetailedLogs"
    ;;
  *)
    print -u2 "usage: $0 [--monitor-only|--repair-only|--picker-only|--preferences-only|--navigation-only|--secrets-only|--lifecycle-only|--backup-only|--backup-result-only|--backup-operations-only|--network-only|--files-cache-only|--failure-only]"
    exit 64
    ;;
esac

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
  "-only-testing:$TEST_TARGET" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  test 2>&1 | tee "$SMOKE_LOG"

grep -q '^\*\* TEST SUCCEEDED \*\*$' "$SMOKE_LOG"
