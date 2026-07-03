#!/bin/sh
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
  cat >&2 <<'EOF'
xcodegen is required to generate BatteryMonitor.xcodeproj from project.yml.

Install it with one of:
  brew install xcodegen
  mint install yonaskolb/XcodeGen
EOF
  exit 1
fi

xcodegen generate --spec project.yml

if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -list -project BatteryMonitor.xcodeproj
else
  echo "BatteryMonitor.xcodeproj generated. Full Xcode is required for xcodebuild verification."
fi
