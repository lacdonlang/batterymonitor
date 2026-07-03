#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="BatteryMonitor.xcodeproj"
SCHEME="BatteryMonitor"
CONFIGURATION="${BATTERY_MONITOR_SIGNED_CONFIGURATION:-Release}"
DERIVED_DATA="${BATTERY_MONITOR_SIGNED_DERIVED_DATA:-DerivedData/SignedRelease}"
DEVELOPMENT_TEAM="${BATTERY_MONITOR_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
CODE_SIGN_IDENTITY="${BATTERY_MONITOR_CODE_SIGN_IDENTITY:-}"
ALLOW_PROVISIONING_UPDATES="${BATTERY_MONITOR_ALLOW_PROVISIONING_UPDATES:-0}"
DRY_RUN="${BATTERY_MONITOR_SIGNED_BUILD_DRY_RUN:-0}"

if [ -z "$DEVELOPMENT_TEAM" ]; then
  cat >&2 <<'EOF'
BATTERY_MONITOR_DEVELOPMENT_TEAM is required for signed Release builds.

Example:
  BATTERY_MONITOR_DEVELOPMENT_TEAM=ABCDE12345 \
    BATTERY_MONITOR_CODE_SIGN_IDENTITY="Apple Development" \
    ./scripts/build_signed_release.sh

Use BATTERY_MONITOR_SIGNED_BUILD_DRY_RUN=1 to validate the command without building.
Run ./scripts/signed_qa_readiness.sh first to check signing prerequisites before
starting signed-system manual QA.
EOF
  exit 1
fi

if [ ! -d "$PROJECT" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec project.yml
  else
    echo "Missing $PROJECT and xcodegen is not installed" >&2
    exit 1
  fi
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Full Xcode is required for signed Release builds" >&2
  exit 1
fi

if [ ! -x "./scripts/system_qa_preflight.sh" ]; then
  echo "Missing executable system QA preflight script" >&2
  exit 1
fi

PROVISIONING_FLAG=""
if [ "$ALLOW_PROVISIONING_UPDATES" = "1" ]; then
  PROVISIONING_FLAG="-allowProvisioningUpdates"
fi

print_command() {
  echo "xcodebuild $PROVISIONING_FLAG -project $PROJECT -scheme $SCHEME -configuration $CONFIGURATION -derivedDataPath $DERIVED_DATA DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:-<automatic>} build"
  echo "BATTERY_MONITOR_REQUIRE_SIGNED_APP=1 ./scripts/system_qa_preflight.sh $DERIVED_DATA/Build/Products/$CONFIGURATION/BatteryMonitor.app"
}

if [ "$DRY_RUN" = "1" ]; then
  print_command
  echo "Signed Release build dry run OK"
  exit 0
fi

if [ -n "$CODE_SIGN_IDENTITY" ]; then
  xcodebuild \
    $PROVISIONING_FLAG \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    build
else
  xcodebuild \
    $PROVISIONING_FLAG \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    build
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/BatteryMonitor.app"
BATTERY_MONITOR_REQUIRE_SIGNED_APP=1 ./scripts/system_qa_preflight.sh "$APP_PATH"

echo "Created signed Release app: $APP_PATH"
