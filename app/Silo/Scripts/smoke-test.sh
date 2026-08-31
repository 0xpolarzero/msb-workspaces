#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
APP_PATH="$APP_DIR/build/Silo.app"
LOG_DIR="$APP_DIR/build/logs"
SMOKE_LOG="$LOG_DIR/smoke-ui.log"
DERIVED_DATA="$APP_DIR/build/DerivedData/Smoke"
PRODUCTS_DIR="$APP_DIR/build/SmokeProducts"

TEST_TARGET="SiloUITests"
case "${1:-}" in
  "") ;;
  --monitor-only)
    TEST_TARGET="SiloUITests/SiloUITests/testStatusItemMinimalPopoverAndQuit"
    ;;
  --repair-only)
    TEST_TARGET="SiloUITests/SiloUITests/testDedicatedRuntimeRepairClearsEverySurfaceAfterVerifiedReactivation"
    ;;
  --workspace-repair-only)
    TEST_TARGET="SiloUITests/SiloUITests/testWorkspaceRepairRoutesToRestore"
    ;;
  --picker-only)
    TEST_TARGET="SiloUITests/SiloUITests/testDirectFolderPickerFromStatusPopover"
    ;;
  --preferences-only)
    TEST_TARGET="SiloUITests/SiloUITests/testApplicationPreferencesUpdateWorkspaceActions"
    ;;
  --navigation-only)
    TEST_TARGET="SiloUITests/SiloUITests/testUnifiedWindowUsesTopTabsAndWorkspaceSections"
    ;;
  --secrets-only)
    TEST_TARGET="SiloUITests/SiloUITests/testSecretsTabAddEditRemoveWildcardConfirmationAndRestartBadges"
    ;;
  --lifecycle-only)
    TEST_TARGET="SiloUITests/SiloUITests/testUnifiedWindowOwnsLifecycleConfirmationAndVerifiesRestartGap"
    ;;
  --backup-only)
    TEST_TARGET="SiloUITests/SiloUITests/testBackupDestinationSelectionShowsRequiredSpaceConfirmation"
    ;;
  --backup-result-only)
    TEST_TARGET="SiloUITests/SiloUITests/testBackupResultCardSuccessPartialAndFailure"
    ;;
  --backup-operations-only)
    TEST_TARGET="SiloUITests/SiloUITests/testBackupConcurrentFixtureReattachesAfterRelaunchAndAdvancesCounters"
    ;;
  --network-only)
    TEST_TARGET="SiloUITests/SiloUITests/testNetworkShowsActivePortsFirst"
    ;;
  --files-cache-only)
    TEST_TARGET="SiloUITests/SiloUITests/testFilesStayCachedAcrossWorkspaceTabs"
    ;;
  --failure-only)
    TEST_TARGET="SiloUITests/SiloUITests/testOperationFailureOpensDetailedLogs"
    ;;
  *)
    print -u2 "usage: $0 [--monitor-only|--repair-only|--workspace-repair-only|--picker-only|--preferences-only|--navigation-only|--secrets-only|--lifecycle-only|--backup-only|--backup-result-only|--backup-operations-only|--network-only|--files-cache-only|--failure-only]"
    exit 64
    ;;
esac

mkdir -p "$LOG_DIR"
rm -f "$SMOKE_LOG" "$LOG_DIR/smoke-app.log" "$LOG_DIR/smoke-launch.log"
/bin/rm -rf -- "$DERIVED_DATA" "$PRODUCTS_DIR"

test -x "$APP_PATH/Contents/MacOS/Silo"

xcodebuild \
  -project "$APP_DIR/Silo.xcodeproj" \
  -scheme Silo \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  "-only-testing:$TEST_TARGET" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  test 2>&1 | tee "$SMOKE_LOG"

grep -q '^\*\* TEST SUCCEEDED \*\*$' "$SMOKE_LOG"
