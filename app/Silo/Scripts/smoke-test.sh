#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_DIR=${SCRIPT_DIR:h}
APP_PATH="$APP_DIR/build/Silo.app"
LOG_DIR="$APP_DIR/build/logs"
SMOKE_LOG="$LOG_DIR/smoke-ui.log"
DERIVED_DATA="$APP_DIR/build/DerivedData/Smoke"
PRODUCTS_DIR="$APP_DIR/build/SmokeProducts"

TEST_TARGETS=("SiloUITests")
case "${1:-}" in
  "") ;;
  --monitor-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testStatusItemMinimalPopoverAndQuit")
    ;;
  --repair-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testDedicatedRuntimeRepairClearsEverySurfaceAfterVerifiedReactivation")
    ;;
  --workspace-repair-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testWorkspaceRepairRoutesToRestore")
    ;;
  --picker-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testDirectFolderPickerFromStatusPopover")
    ;;
  --preferences-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testApplicationPreferencesUpdateWorkspaceActions")
    ;;
  --navigation-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testUnifiedWindowUsesTopTabsAndWorkspaceSections")
    ;;
  --github-sync-only)
    TEST_TARGETS=(
      "SiloUITests/SiloUITests/testGitHubSettingsPreloadsAndEditsInline"
      "SiloUITests/SiloUITests/testGitHubSettingsKeepsEditingResponsiveWhileSyncIsDelayed"
      "SiloUITests/SiloUITests/testGitHubSetupShowsSkeletonWhileStartupCatalogLoads"
      "SiloUITests/SiloUITests/testGitHubLocalSuccessAppliesPolicyAndFinishesSetup"
      "SiloUITests/SiloUITests/testGitHubSetupShowsDelayedSavedIntentAndKeepsPolicyEditable"
      "SiloUITests/SiloUITests/testGitHubDisconnectedConnectsAndResetsInline"
      "SiloUITests/SiloUITests/testGitHubResetStaysInlineAndClearsWithoutOperationConflict"
    )
    ;;
  --secrets-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testSecretsTabAddEditRemoveWildcardConfirmationAndRestartBadges")
    ;;
  --lifecycle-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testUnifiedWindowOwnsLifecycleConfirmationAndVerifiesRestartGap")
    ;;
  --backup-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testBackupDestinationSelectionShowsRequiredSpaceConfirmation")
    ;;
  --backup-result-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testBackupResultCardSuccessPartialAndFailure")
    ;;
  --backup-operations-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testBackupConcurrentFixtureReattachesAfterRelaunchAndAdvancesCounters")
    ;;
  --network-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testNetworkShowsActivePortsFirst")
    ;;
  --files-cache-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testFilesStayCachedAcrossWorkspaceTabs")
    ;;
  --failure-only)
    TEST_TARGETS=("SiloUITests/SiloUITests/testOperationFailureOpensDetailedLogs")
    ;;
  *)
    print -u2 "usage: $0 [--monitor-only|--repair-only|--workspace-repair-only|--picker-only|--preferences-only|--navigation-only|--github-sync-only|--secrets-only|--lifecycle-only|--backup-only|--backup-result-only|--backup-operations-only|--network-only|--files-cache-only|--failure-only]"
    exit 64
    ;;
esac

mkdir -p "$LOG_DIR"
rm -f "$SMOKE_LOG" "$LOG_DIR/smoke-app.log" "$LOG_DIR/smoke-launch.log"
/bin/rm -rf -- "$DERIVED_DATA" "$PRODUCTS_DIR"

test -x "$APP_PATH/Contents/MacOS/Silo"

ONLY_TESTING_ARGS=()
for target in "${TEST_TARGETS[@]}"; do
  ONLY_TESTING_ARGS+=("-only-testing:$target")
done

xcodebuild \
  -project "$APP_DIR/Silo.xcodeproj" \
  -scheme Silo \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  "${ONLY_TESTING_ARGS[@]}" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  test 2>&1 | tee "$SMOKE_LOG"

grep -q '^\*\* TEST SUCCEEDED \*\*$' "$SMOKE_LOG"
