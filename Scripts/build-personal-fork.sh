#!/bin/bash
# Build the personal fork without launching or replacing a running application.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null
xcodegen generate
mkdir -p Codenotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Codenotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
fork_identity="${CODENOTCH_SIGN_IDENTITY:--}"
fork_team="${CODENOTCH_SIGN_TEAM:-}"
xcodebuild -project Codenotch.xcodeproj -scheme Codenotch \
  -destination "platform=macOS,arch=$(uname -m)" -configuration Release \
  -derivedDataPath build/personal CODE_SIGN_IDENTITY="$fork_identity" \
  DEVELOPMENT_TEAM="$fork_team" CODE_SIGN_STYLE=Manual \
  -disableAutomaticPackageResolution build
fork_app="build/personal/Build/Products/Release/Codenotch.app"
/usr/libexec/PlistBuddy -c 'Print :CodenotchForkBuild' "$fork_app/Contents/Info.plist" | /usr/bin/grep -qx true
codesign --verify --deep --strict "$fork_app"
printf '\nBuilt %s/%s\nQuit Codenotch before replacing the installed app.\n' "$PWD" "$fork_app"
